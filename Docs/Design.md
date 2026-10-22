# Delphi.IOUring – Design Specification

Status: **Draft v1.1** (2026-10-22) – Milestones 1 and 2 complete: Delphi 13 and
Free Pascal 3.2.2 on Windows, Win32 and Win64 (§12.1). Milestone 1 (Phases 1–5):
complete Windows API unit, core ring (implementation notes in §5.2),
sequential reader (notes in §7), read-only stream (notes in §8.1),
benchmarks ([Benchmarks.md](Benchmarks.md)). Milestone 3 started: the
atomics unit (Phase 10, notes in §10.6), the request pool (Phase 11, notes
in §10.7) and the request queue (Phase 12, notes in §10.8). Things marked **[DECIDE]**
need an answer from the project owner; things marked **[VERIFY]** must be
proven by a spike or unit test before building on them, and become
**[VERIFIED]** with the answer once a test proves them. Decisions already made
are listed in §15.

---

## 1. Goals, and what is not planned

### Goals

1. Give Delphi code access to the OS "submission/completion ring" I/O APIs:
   - **Windows**: IoRing, **latest API version only** (currently
     `IORING_VERSION_4`, Windows 11 24H2+), **Win32 and Win64**.
   - **Linux** (later, via Free Pascal): `io_uring`, **x86-64/AArch64 only**.
2. The lowest level is a **complete (100 %) translation of the OS API**, in
   its own unit with no dependencies on the rest of the library, so that other
   projects can use it on its own (§6).
3. A **thin, OS-independent abstraction** over those rings that adds close to
   zero overhead compared to calling the OS API directly. Records instead of
   objects wherever that makes sense (§4).
4. Higher-level building blocks on top, the first being a **read-only,
   sequential, read-ahead `TStream`** for large files, where the OS fills the
   next buffers in the background while user code is processing the current
   one, so in the best case `Read` never waits for I/O.
5. Both **blocking (sync)** and **non-blocking (async)** usage styles, where
   the sync style is just a thin layer on top of the async core.
6. Later: an **I/O engine** (I/O thread / thread pool, lock-free hand-over)
   that many threads can feed requests into, so that lots of requests are in
   flight at once (§10), and rules for overlapping reads/writes to the same
   file region (§11).
7. **Compilers**: Delphi 13 first, then the latest Free Pascal / Lazarus on
   Windows, then Linux through Free Pascal (§12).
8. Unit-tested (DUnitX) and benchmarked against `TFileStream` /
   `TBufferedFileStream` so that the speed claims are measured, not assumed.

### Not planned (for now)

- Older Windows versions. No overlapped/IOCP fallback: on Windows without
  IoRing V4 the library reports "not available" and raises if used (§5.6).
  (The API unit itself still works on older IoRing versions – §6.)
- Networking (sockets). Windows IoRing does not support sockets; io_uring does.
  It can be added later on Linux only.
- macOS (no ring API).
- 32-bit Linux.
- A general-purpose async framework (tasks, futures, promises). The library
  exposes completions; other frameworks can be built on top.

---

## 2. Platform facts this design is based on

### 2.1 Windows IoRing

Sources: Windows SDK 10.0.26100 headers `um/ioringapi.h`, `um/ntioring_x.h`,
`um/winbase.h`, `shared/winerror.h`; Microsoft Learn
<https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/>; and the
development machine (Windows 11, build 26300).

Microsoft Learn only documents the V1 functions (all marked "Windows Build
22000"); the pages for the write, flush, scatter and gather functions do not
exist (404). **The SDK header is the source of truth** for those.

| Fact | Value |
| --- | --- |
| Exported from | `kernel32.dll` and `KernelBase.dll` (API sets `api-ms-win-core-ioring-l1-1-0/1/2`); import library `kernel32.lib` |
| `QueryIoRingCapabilities` on dev PC | MaxVersion = **400** (V4), MaxSQ = 65536, MaxCQ = 131072, Features = `SET_COMPLETION_EVENT` (not user-mode emulated) |
| Calling convention | `STDAPI` = `HRESULT __stdcall` |

API versions (`IORING_VERSION`):

| Version | Value | Adds | First OS |
| --- | --- | --- | --- |
| `IORING_VERSION_1` | 1 | NOP, READ, REGISTER_FILES, REGISTER_BUFFERS, CANCEL | Windows 11 21H2 (build 22000) |
| `IORING_VERSION_2` | 2 | Fix: completion event could miss empty→non-empty signal | |
| `IORING_VERSION_3` | 300 | WRITE, FLUSH, `IOSQE_FLAGS_DRAIN_PRECEDING_OPS` | Windows 11 22H2 |
| `IORING_VERSION_4` | 400 | READ_SCATTER, WRITE_GATHER | Windows 11 24H2 [VERIFY exact build, and Server 2025] |

**The library requires V4**, so everything in the table is always available
to it: read, write, flush, drain, scatter/gather, a reliable completion event.

Functions (16) – the API set `-l1-1-1` adds write/flush, `-l1-1-2` adds
scatter/gather:

```c
HRESULT QueryIoRingCapabilities(IORING_CAPABILITIES* capabilities);
BOOL    IsIoRingOpSupported(HIORING ioRing, IORING_OP_CODE op);
HRESULT CreateIoRing(IORING_VERSION, IORING_CREATE_FLAGS, UINT32 sqSize, UINT32 cqSize, HIORING* h);
HRESULT GetIoRingInfo(HIORING, IORING_INFO*);
HRESULT SubmitIoRing(HIORING, UINT32 waitOperations, UINT32 milliseconds, UINT32* submittedEntries);
HRESULT CloseIoRing(HIORING);
HRESULT PopIoRingCompletion(HIORING, IORING_CQE*);           // S_OK, or S_FALSE when queue empty
HRESULT SetIoRingCompletionEvent(HIORING, HANDLE hEvent);
HRESULT BuildIoRingCancelRequest(HIORING, IORING_HANDLE_REF file, UINT_PTR opToCancel, UINT_PTR userData);
HRESULT BuildIoRingReadFile(HIORING, IORING_HANDLE_REF, IORING_BUFFER_REF, UINT32 bytes, UINT64 offset, UINT_PTR userData, IORING_SQE_FLAGS);
HRESULT BuildIoRingRegisterFileHandles(HIORING, UINT32 count, HANDLE const handles[], UINT_PTR userData);
HRESULT BuildIoRingRegisterBuffers(HIORING, UINT32 count, IORING_BUFFER_INFO const buffers[], UINT_PTR userData);
// V3:
HRESULT BuildIoRingWriteFile(HIORING, IORING_HANDLE_REF, IORING_BUFFER_REF, UINT32 bytes, UINT64 offset, FILE_WRITE_FLAGS, UINT_PTR userData, IORING_SQE_FLAGS);
HRESULT BuildIoRingFlushFile(HIORING, IORING_HANDLE_REF, FILE_FLUSH_MODE, UINT_PTR userData, IORING_SQE_FLAGS);
// V4:
HRESULT BuildIoRingReadFileScatter(HIORING, IORING_HANDLE_REF, UINT32 segCount, FILE_SEGMENT_ELEMENT segs[], UINT32 bytes, UINT64 offset, UINT_PTR userData, IORING_SQE_FLAGS);
HRESULT BuildIoRingWriteFileGather(HIORING, IORING_HANDLE_REF, UINT32 segCount, FILE_SEGMENT_ELEMENT segs[], UINT32 bytes, UINT64 offset, FILE_WRITE_FLAGS, UINT_PTR userData, IORING_SQE_FLAGS);
```

Plus four helpers that are macros / C++ constructors in the header:
`IoRingHandleRefFromHandle`, `IoRingHandleRefFromIndex`,
`IoRingBufferRefFromPointer`, `IoRingBufferRefFromIndexAndOffset`.

Error codes (`winerror.h`, facility 0x46):

| Name | Value | Meaning |
| --- | --- | --- |
| `IORING_E_REQUIRED_FLAG_NOT_SUPPORTED` | 0x80460001 | A required flag is unknown to the implementation |
| `IORING_E_SUBMISSION_QUEUE_FULL` | 0x80460002 | `Build*`: no free SQ entry – submit and retry |
| `IORING_E_VERSION_NOT_SUPPORTED` | 0x80460003 | `CreateIoRing`: unknown/unsupported version |
| `IORING_E_SUBMISSION_QUEUE_TOO_BIG` | 0x80460004 | `CreateIoRing`: SQ size too big |
| `IORING_E_COMPLETION_QUEUE_TOO_BIG` | 0x80460005 | `CreateIoRing`: CQ size too big |
| `IORING_E_SUBMIT_IN_PROGRESS` | 0x80460006 | Another thread is submitting on the same ring right now |
| `IORING_E_CORRUPT` | 0x80460007 | Shared ring buffers are corrupt |
| `IORING_E_COMPLETION_QUEUE_TOO_FULL` | 0x80460008 | Not enough free CQ space for all entries being submitted |

Learn also names `IORING_E_WAIT_TIMEOUT`, `IORING_E_UNKNOWN_VERSION` and
`IORING_E_UNKNOWN_REQUIRED_FLAG`, which do not exist in the SDK headers.
**[VERIFIED]** what Windows really returns (Windows 11 build 26300, tests in
`Tests.Backend.Windows.API`):

| Situation | Result |
| --- | --- |
| `CreateIoRing` with an unknown version | `IORING_E_VERSION_NOT_SUPPORTED` |
| `CreateIoRing` with SQ size > max | `IORING_E_SUBMISSION_QUEUE_TOO_BIG` |
| `Build*` with a full SQ | `IORING_E_SUBMISSION_QUEUE_FULL` |
| `SubmitIoRing` when the CQ can't take all completions | `IORING_E_COMPLETION_QUEUE_TOO_FULL`; the entries stay in the SQ and can be submitted after popping |
| `SubmitIoRing` whose wait times out | `HRESULT_FROM_WIN32(ERROR_TIMEOUT)` = **0x800705B4** (not `WAIT_TIMEOUT`). The entries **are** submitted, but `submittedEntries` is **not written**. |
| `SubmitIoRing` while another thread is waiting inside `SubmitIoRing` on the same ring | `IORING_E_SUBMIT_IN_PROGRESS` |
| `PopIoRingCompletion` on an empty CQ | `S_FALSE`, and the `IORING_CQE` is **zeroed** (Learn says "unmodified") |
| Cancelled operation | its own completion is `HRESULT_FROM_WIN32(ERROR_OPERATION_ABORTED)`; the cancel entry completes with `S_OK` |
| `IsIoRingOpSupported` on a V4 ring | `TRUE` for all op codes, `IORING_OP_NOP` included |

Important semantics:

- `Build*` functions only write an entry into the user-mode submission queue
  (no kernel transition). `SubmitIoRing` is the one syscall that hands the
  whole batch to the kernel and can optionally wait for N completions.
- **Queue sizes**: `CreateIoRing` rounds the SQ size up to a power of two,
  and the CQ size up to a power of two that is **at least 2 × the SQ size**.
  `GetIoRingInfo` returns the real sizes.
- A ring is closed with `CloseIoRing`, **not** `CloseHandle`.
- **Submit**: `waitOperations = 0` means don't wait; `milliseconds` is
  ignored then. `IORING_SUBMIT_WAIT_ALL = MAXUINT32` waits for everything.
  `waitOperations` must be less than (entries in SQ + operations in
  progress). If `SubmitIoRing` fails with anything other than the wait
  timeout, **all entries stay in the SQ**. If a single entry is invalid, that
  entry is completed immediately with an error in the CQ; the rest go ahead.
- **CQ space**: submit fails with `IORING_E_COMPLETION_QUEUE_TOO_FULL` if the
  CQ can't take the completions of everything being submitted. Popping
  completions regularly is therefore mandatory, not optional.
- **One submitter at a time**: a concurrent submit on another thread fails
  with `IORING_E_SUBMIT_IN_PROGRESS`. Combined with the unsynchronized
  user-mode queues this means: a ring belongs to one thread (§5.4).
- Completions can arrive **out of order**; `UserData` identifies the request.
  `UserData` needs to be unique only if the request may be cancelled.
- **Cancel** is only a request: the target can still complete normally or
  with an error. The cancel entry gets its own completion, which may arrive
  before or after the target's. The target's own completion is the final
  word.
- **Completion event** (`SetIoRingCompletionEvent`): signalled only when the
  CQ goes from **empty to non-empty**. So: pop until `S_FALSE`, then wait –
  otherwise the wait can block forever. The kernel duplicates the event
  handle; `NULL` clears it; one event per ring.
- The kernel runs the submitted requests **in parallel**; there is no ordering
  between entries unless `IOSQE_FLAGS_DRAIN_PRECEDING_OPS` is used (that
  entry waits until *all* earlier entries are finished – a full barrier).
- **Registration**: `REGISTER_FILES` / `REGISTER_BUFFERS` replace the whole
  previous registration and act as a barrier for later entries. The input
  array must stay valid until that operation completes. Entries with
  `INVALID_HANDLE_VALUE` (files) or `Address = nil, Length = 0` (buffers)
  are "sparse" – a way to release single entries. Registration lets the
  kernel validate/map once instead of on every I/O – this is where much of
  the IoRing gain comes from.
- `IORING_CREATE_SKIP_BUILDER_PARAM_CHECKS` (advisory flag) skips argument
  validation in `Build*` – a possible release-mode speed option.
- Scatter/gather: **[VERIFIED]** like the classic `ReadFileScatter`, the
  IoRing versions need a handle opened with `FILE_FLAG_NO_BUFFERING` and
  page-sized, page-aligned segments. On a buffered handle `Build*` succeeds
  but the completion is `E_INVALIDARG`.
- **[VERIFIED]** File handles opened **without** `FILE_FLAG_OVERLAPPED` work
  too. (Whether the I/O on them is still fully asynchronous is not tested.)
- **[VERIFIED]** A thread that waits inside `SubmitIoRing` blocks all other
  submits on that ring. So when more than one thread may submit, wait with the
  completion event, never with `SubmitIoRing(…, waitOperations > 0, …)`.
- **No socket support**, files only.

### 2.2 Linux io_uring (for the later FPC/Linux backend)

- Three syscalls: `io_uring_setup` (425), `io_uring_enter` (426),
  `io_uring_register` (427) – same numbers on x86-64 and AArch64.
- SQ/CQ rings and the SQE array are `mmap`ed shared memory; SQE = 64 bytes,
  CQE = 16 bytes (`user_data: u64; res: s32; flags: u32`).
- `res` is bytes transferred or **negative errno**.
- No liburing dependency is planned; raw syscalls + memory barriers, so it
  works with FPC without C libraries. [DECIDE later: liburing would be simpler]
- Can be disabled (`kernel.io_uring_disabled` sysctl, seccomp in containers –
  PostgreSQL documents the same caveat), so availability is a runtime check.
- Rich op set (read/write/fsync/openat/close/statx/accept/send/recv/…),
  linked SQEs, fixed files/buffers, SQPOLL mode.

### 2.3 Consequence for the abstraction

The **common subset** of both is: *prepare N entries → submit (optionally
wait) → reap completions identified by a pointer-sized user value*, with
registered files and buffers, read/write/flush, scatter/gather and a drain
barrier. That is the shape of the core API. Everything outside the subset
(sockets, linked SQEs, SQPOLL) stays available in the complete API units
(§6) for people who need it, but not in the core abstraction.

---

## 3. Architecture

```
 ┌────────────────────────────────────────────────────────────────────────┐
 │ Layer 3 – Convenience (classes, because TStream is a class)            │
 │   Delphi.IOUring.Streams   TSequentialReadOnlyFileStream               │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 2 – Helpers / engine (records where possible)                    │
 │   Delphi.IOUring.SequentialReader  TIORingSequentialReader (record)   │
 │   later: Delphi.IOUring.Engine     I/O thread(s), request pool,        │
 │                                    read streams, overlap handling      │
 │   Delphi.IOUring.Atomics           CAS / fences / wait-on-address      │
 │   Delphi.IOUring.RequestPool       request slots, lock-free free list  │
 │   Delphi.IOUring.RequestQueue      lock-free queue to the I/O thread   │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 1 – Core abstraction (OS independent, records)                   │
 │   Delphi.IOUring.Backend.Custom    shared types, constants, errors     │
 │   Delphi.IOUring.Backend.Windows   TWindowsIORing (record)             │
 │   Delphi.IOUring.Backend.Posix     TLinuxIORing (record)               │
 │   Delphi.IOUring                   TIORing = platform ring, helpers    │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 0 – Complete OS API translations (standalone, reusable)          │
 │   Delphi.IOUring.Backend.Windows.API   100 % of ioringapi.h            │
 │   Delphi.IOUring.Backend.Posix.API     100 % of linux/io_uring.h       │
 └────────────────────────────────────────────────────────────────────────┘
```

Unit responsibilities:

| Unit | Contents | Depends on |
| --- | --- | --- |
| `Delphi.IOUring.Backend.Windows.API` | Complete translation of the Windows IoRing API (§6). Nothing else. | `Winapi.Windows` only |
| `Delphi.IOUring.Backend.Posix.API` | Complete translation of the Linux io_uring user API (§6.4). | RTL only |
| `Delphi.IOUring.Backend.Custom` | OS-neutral types (`TIORingCompletion`, `TIORingFileRef`, `TIORingBufferRef`, flags, capabilities), `EIORingError`, shared inline helper routines | RTL only |
| `Delphi.IOUring.Backend.Windows` | `TWindowsIORing` record, built on the Windows API unit | Custom, Windows.API |
| `Delphi.IOUring.Backend.Posix` | `TLinuxIORing` record, built on the Posix API unit | Custom, Posix.API |
| `Delphi.IOUring` *(new)* | `TIORing` = the platform ring type (compile-time alias), `IORingAvailable`, blocking helpers | Custom + platform unit via `{$IFDEF}` |
| `Delphi.IOUring.SequentialReader` *(new)* | Read-ahead engine, usable without streams | `Delphi.IOUring` |
| `Delphi.IOUring.Streams` | `TStream` descendants | SequentialReader |
| `Delphi.IOUring.Atomics` *(new)* | `TAtomic`: one place for atomics, so Delphi/FPC and x86/ARM differences live in one unit (§10.5, §10.6) | RTL only |
| `Delphi.IOUring.RequestPool` *(new)* | `TIORingRequestPool` (request slots, states, handles, waiting) and `TIORingFreeList` (lock-free stack) (§10.3, §10.7) | `Delphi.IOUring`, Atomics |
| `Delphi.IOUring.RequestQueue` *(new)* | `TIORingRequestQueue`: bounded lock-free queue from the producers to an I/O thread (§10.5, §10.8) | `Delphi.IOUring`, Atomics |
| `Delphi.IOUring.Engine` *(later)* | §10, §11 | `Delphi.IOUring`, Atomics, RequestPool |

The "all OS-specific code lives in the `Backend.<OS>` units" rule still holds:
the `.API` units are the raw translation, the `Backend.<OS>` unit next to it
is the library's implementation on top of it. The new `Delphi.IOUring` unit
is needed because `Backend.Custom` must not use the platform units (that
would make them circular); it sits above both and is the unit user code
normally `uses`.

---

## 4. Performance principles ("superfast abstraction")

The cost that matters is **kernel transitions and data copies**, measured in
microseconds. So:

1. **No virtual dispatch, no allocation per operation.** There is no runtime
   backend choice, so the backend is chosen at **compile time**:
   ```pascal
   {$IFDEF MSWINDOWS} TIORing = TWindowsIORing; {$ENDIF}
   {$IFDEF LINUX}     TIORing = TLinuxIORing;   {$ENDIF}
   ```
   Both records expose the same set of methods. Calls are direct (no virtual
   dispatch). No interfaces (no ref-count traffic), no anonymous methods, no
   `TObject` per request on the hot path. The shared unit tests are compiled
   against `TIORing`, which keeps the two implementations honest.

   **`inline` – decided in Phase 2:** the public methods are **not** `inline`.
   User code reaches them through the aliases in `Delphi.IOUring`, and Delphi
   expands an inline routine only if the caller also lists the unit that
   implements it; otherwise every call site gets hint H2443. A normal call
   costs about 1 ns next to the 50–100 ns of the Windows `Build*` call it
   wraps. `inline` stays on private helpers inside the units.
2. **Records instead of objects** – see §4.1.
3. **Batching is the main lever.** `PrepareRead` does not submit; `Submit`
   does. `PopCompletions(var Buffer: array of TIORingCompletion): Integer`
   reaps many at once.
4. **Registered buffers and file handles** are first-class, because they are a
   major part of the gain on both platforms.
5. **User data is a raw `NativeUInt`** – exactly the OS type (`UINT_PTR` on
   Windows; on Linux x64 the 64-bit `user_data`). Callers encode a slot index
   or pointer in it. No lookup tables inside the core. On Win32 that means 32
   bits, which is enough for an index + generation counter (§10.3).
6. **Buffers come from `VirtualAlloc` / `mmap`** (page aligned) so
   unbuffered I/O (`FILE_FLAG_NO_BUFFERING` / `O_DIRECT`) is possible.
7. **Bounded concurrency.** More in-flight requests is not always better:
   PostgreSQL warns that very high `effective_io_concurrency` raises latency
   for everybody. Queue depth is a tunable with a sensible default, never
   "as many as possible".
8. **Lock-free hand-over between threads** where it is on the hot path (§10.5).
9. **Measure throughput *and* CPU time.** PostgreSQL's measurements showed
   synchronous I/O with 8 parallel workers matching io_uring throughput, but
   using much more CPU. The value of rings is often "same speed with fewer
   threads and less CPU", and the benchmarks must show that (Plan, Phase 5).

Realistic expectation: for a *single* sequential reader, buffered Windows I/O
with `FILE_FLAG_SEQUENTIAL_SCAN` already gets OS read-ahead. The clear wins
are expected with (a) unbuffered I/O on large files (no cache pollution, no
extra copy), (b) many outstanding requests (NVMe queue depth), (c) many small
random reads batched into one submit, (d) cold data on high-latency storage
(network/cloud disks, where PostgreSQL reports 2–3× on cold reads). The
benchmark will tell us where we are.

### 4.1 Records, managed records and classes – which one where

| Kind | Used for | Why |
| --- | --- | --- |
| **Plain record** (with methods, no managed fields) | Everything per operation: file/buffer refs, completions, request slots, slot tables, stats | Zero set-up and clean-up cost, lives on the stack or inside another structure, no heap allocation. |
| **Custom managed record** (`Initialize` / `Finalize`) | Things that **own** an OS resource: `TIORing` (ring handle), `TIORingBufferPool` (`VirtualAlloc` memory), `TIORingSequentialReader` (file handle + ring + buffers) | Automatic clean-up when the variable goes out of scope (no `try/finally Free`), still no heap allocation for the owner itself. |
| **Class** | Only where the language requires it: `TStream` descendants, threads, and later the engine (shared by many threads) | `TStream` is a class; a thread must own its state on the heap. |

Rules for the managed (owning) records:

- **Copying is forbidden**: the `Assign` operator (Delphi) / `Copy` operator
  (FPC) raises. Two copies of a ring would close the same handle twice.
  Therefore they are passed as `var`, or `const [ref]` (`constref` in FPC).
- Opened with a method (`Ring.Open(...)`), not returned from a function – a
  function result would be a copy.
- The extra cost of a managed record is an implicit `try/finally` plus the
  `Initialize`/`Finalize` calls in each routine that declares one as a local.
  That is fine for long-lived owners and **never** used for per-operation
  values – those are plain records.
- Delphi and FPC declare the operators differently (Delphi:
  `Initialize(out)`, `Finalize(var)`, `Assign(var; const [ref])`; FPC:
  `Initialize(var)`, `Finalize(var)`, `Copy(constref; var)`). This is one of
  the few places where `{$IFDEF FPC}` is accepted, inside the record
  declaration only.
- **[VERIFIED]** in Phase 2 (Delphi 13, Release build, micro-benchmark):
  a routine with a local `TIORing` costs **+2.3 ns per call on Win32 and
  +1.2 ns on Win64** compared to the same routine with a plain record (the
  implicit `try/finally`, `Initialize`, `Finalize` → `Close` on a closed ring,
  and the dynamic-array field). Fine for owners, too much for per-operation
  values – as planned. A plain `const` parameter of type `TIORing` is passed
  by reference (no copy, no `Assign`), the same as `const [ref]`; tested in
  Delphi. **[VERIFIED]** in Milestone 2 for FPC 3.2.2 (Win32, Win64): `Initialize`,
  `Finalize` (end of scope closes and waits) and `Copy` (raises) work, and
  `const` as well as `constref` parameters pass the original (no copy).

### 4.2 Lighter alternatives to RTL classes (idea for later)

Some performance-oriented Delphi libraries replace RTL classes that have
grown heavy over the years (`TList<T>`, `TStringList`, `TDictionary`…) with
small record-based versions. The core of this library is designed around
fixed-size arrays and does not need general containers. If profiling later
shows an RTL container on a hot path, a minimal record-based replacement
(growable array, ring buffer, open-addressing hash map) goes into its own
unit. **Not planned until a benchmark asks for it.**

---

## 5. Core API (Layer 1) – draft

### 5.1 Types (`Delphi.IOUring.Backend.Custom`)

All plain records.

```pascal
type
  TIORingUserData = NativeUInt;

  TIORingOp = (ioRead, ioWrite, ioFlush, ioCancel,
    ioRegisterFiles, ioRegisterBuffers, ioReadScatter, ioWriteGather);
  TIORingOps = set of TIORingOp;

  TIORingCapabilities = record
    BackendName: string;          // 'Windows IoRing', 'Linux io_uring'
    NativeVersion: Cardinal;      // IORING_VERSION / kernel features mask
    MaxSubmissionQueueSize: Cardinal;
    MaxCompletionQueueSize: Cardinal;
    SupportedOps: TIORingOps;
  end;

  // A file reference: raw OS handle or index into registered files.
  TIORingFileRef = record
    Registered: Boolean;
    Handle: THandle;      // raw handle / fd
    Index: Cardinal;      // registered index
    class function FromHandle(const AHandle: THandle): TIORingFileRef; static; inline;
    class function FromIndex(const AIndex: Cardinal): TIORingFileRef; static; inline;
  end;

  // A buffer reference: raw pointer or (registered index, offset).
  TIORingBufferRef = record
    Registered: Boolean;
    Address: Pointer;
    Index: Cardinal;
    Offset: Cardinal;
    class function FromPointer(const AAddress: Pointer): TIORingBufferRef; static; inline;
    class function FromRegistered(const AIndex, AOffset: Cardinal): TIORingBufferRef; static; inline;
  end;

  TIORingSubmitFlag = (sfDrainPreceding);
  TIORingSubmitFlags = set of TIORingSubmitFlag;

  TIORingCompletion = record
    UserData: TIORingUserData;
    NativeResult: Integer;        // HRESULT on Windows, res (bytes or -errno) on Linux
    BytesTransferred: NativeUInt; // 0 when failed
    function Succeeded: Boolean; inline;
    function IsEndOfFile: Boolean; inline;   // HRESULT_FROM_WIN32(ERROR_HANDLE_EOF) / res = 0 on read
    function ErrorMessage: string;
    procedure RaiseIfFailed;
  end;

  EIORingError = class(Exception)
    NativeCode: Integer;
  end;
  EIORingNotSupported = class(EIORingError);
```

Notes:
- Own records instead of OS records keep user code OS-neutral. The backend
  converts them into `IORING_HANDLE_REF`/`IORING_BUFFER_REF` (a couple of
  register moves – negligible next to the `Build*` call).
- **[DECIDE later]** `TIORingFileRef`/`TIORingBufferRef` could alternatively
  be defined per platform with identical layout to the OS struct, saving the
  conversion. Start with the neutral records; switch if the benchmark shows it.

### 5.2 The ring

A custom managed record (owns the ring handle and the completion event).
Same public surface on every platform:

```pascal
type
  TWindowsIORing = record
  private
    FHandle: HIORING;
    FCompletionEvent: THandle;
    FPendingCount: Cardinal;
    ...
  public
    class operator Initialize(out ADest: TWindowsIORing);       // zero fields
    class operator Finalize(var ADest: TWindowsIORing);         // Close
    class operator Assign(var ADest: TWindowsIORing;
      const [ref] ASource: TWindowsIORing);                     // raises: not copyable

    procedure Open(const ASubmissionQueueSize: Cardinal = 256;
      const ACompletionQueueSize: Cardinal = 0);  // 0 = let the OS pick (≥ 2 × SQ)
    procedure Close;                               // cancels + drains in-flight I/O
    function IsOpen: Boolean; inline;

    // --- prepare (no syscall) ---  Return False if the SQ is full.
    // (No PrepareNop: Windows has IORING_OP_NOP but no Build function for it.)
    function PrepareRead(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
      const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []): Boolean; inline;
    function PrepareWrite(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
      const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []; const AWriteThrough: Boolean = False): Boolean; inline;
    function PrepareFlush(const AFile: TIORingFileRef; const AMode: TIORingFlushMode;
      const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = []): Boolean; inline;
    function PrepareReadScatter(...): Boolean;
    function PrepareWriteGather(...): Boolean;
    function PrepareCancel(const AFile: TIORingFileRef; const ATargetUserData,
      AUserData: TIORingUserData): Boolean;
    function PrepareRegisterFiles(const AHandles: array of THandle;
      const AUserData: TIORingUserData): Boolean;
    function PrepareRegisterBuffers(const ABuffers: array of TIORingBufferInfo;
      const AUserData: TIORingUserData): Boolean;

    // --- submit (one syscall) ---
    // Submits everything prepared; optionally waits until AWaitCount completions
    // are available or ATimeoutMs elapses. Returns number of entries submitted.
    function Submit(const AWaitCount: Cardinal = 0;
      const ATimeoutMs: Cardinal = INFINITE): Cardinal;

    // --- reap (no syscall on either platform) ---
    function TryPopCompletion(out ACompletion: TIORingCompletion): Boolean; inline;
    function PopCompletions(var ACompletions: array of TIORingCompletion): Integer;

    // --- waiting without submitting ---
    function WaitForCompletions(const ACount: Cardinal; const ATimeoutMs: Cardinal): Boolean;
    // OS event (Windows event / Linux eventfd) signalled when CQ goes from empty
    // to non-empty. Lets a ring be integrated into an existing event loop /
    // WaitForMultipleObjects. Rule: pop until empty before waiting on it.
    function CompletionEventHandle: THandle;

    class function Available: Boolean; static;
    class function QueryCapabilities: TIORingCapabilities; static;

    property SubmissionQueueSize: Cardinal read ...;   // actual (power of two)
    property CompletionQueueSize: Cardinal read ...;   // actual (power of two, ≥ 2 × SQ)
    property PendingCount: Cardinal read ...;          // submitted, not yet popped
  end;
```

Usage:

```pascal
var
  LRing: TIORing;
  LCompletion: TIORingCompletion;
begin
  LRing.Open(64);             // closed automatically at the end of the routine
  LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1);
  LRing.Submit(1);
  if LRing.TryPopCompletion(LCompletion) then
    LCompletion.RaiseIfFailed;
end;
```

Design rules:

- `Prepare*` returning `Boolean` (not raising) keeps the hot loop
  exception-free; "queue full" (`IORING_E_SUBMISSION_QUEUE_FULL`) is a normal
  flow-control signal → caller submits and retries. Invalid arguments still
  raise.
- The ring never owns file handles or user buffers. It tracks only
  `PendingCount` so `Close` can **cancel + drain** outstanding I/O before
  closing (otherwise the kernel could write into freed memory).
- **CQ space is guarded**: `Submit` never submits more entries than the CQ
  has room for (CQ size − `PendingCount`); this avoids
  `IORING_E_COMPLETION_QUEUE_TOO_FULL` instead of reacting to it.
- `Submit` with a wait that times out is not an error; it returns normally
  and the caller pops whatever arrived.

#### Implementation notes (Phase 2)

The code (`Delphi.IOUring.Backend.Windows.pas`, `Delphi.IOUring.pas`) is the
reference; this is what it does where the draft above was open or differs:

- **Close waits.** `CloseIoRing` does **not** cancel operations that are still
  in flight – the kernel writes into the buffer after the ring is closed
  (**[VERIFIED]**, test `CloseIoRing_WithPendingRead_DoesNotCancelIt`). So
  `Close` (and the end of scope) pops and waits, using the completion event,
  until every submitted operation has completed, then closes. Prepared but not
  submitted entries are dropped. An operation that may never complete (pipe
  read) must be cancelled first: `PrepareCancel`, or `CancelIoEx(Handle, nil)`,
  which **[VERIFIED]** also cancels ring operations. Without that, `Close`
  waits forever – the only alternative would be freeing memory the kernel is
  still writing to.
- **Completion event** is created in `Open` (auto-reset) and always set; `Close`
  needs it to wait without submitting anything.
- **Room check:** `Prepare*` returns False when the SQ is full **or** when
  `PreparedCount + PendingCount` reached the CQ size, so `SubmitIoRing` never
  fails with `IORING_E_COMPLETION_QUEUE_TOO_FULL` (tested). `Prepare*` on a
  closed ring raises instead of returning False (no endless retry loop).
- **Waiting:** `Submit(AWaitCount)` and `WaitForCompletions(ACount)` wait for
  at most the number of outstanding operations. **[VERIFIED]** the count
  includes completions already in the CQ (3 queued → a wait for 3 returns at
  once). `WaitForCompletions` uses the same system call as `Submit`, so it
  also submits prepared entries.
- **Zero-copy pop:** `TIORingCompletion` has the layout of `IORING_CQE` and
  `TIORingBufferInfo` that of `IORING_BUFFER_INFO` (compile-time `{$IF SizeOf}`
  checks + tests), so completions are popped straight into the caller's record.
- **Registration arrays are copied** and kept until the ring is idle (nothing
  prepared, nothing in flight), because the kernel reads them only when the
  registration runs (tested by spoiling the caller's arrays before Submit).
- **Scatter/gather:** `TIORingSegment` = `FILE_SEGMENT_ELEMENT`; the caller's
  segment array is used directly (must stay valid until the completion).
  **[VERIFIED]** only `SegmentCount` entries are used – no terminating entry.
- **Copying a ring** raises `EInvalidOpException` (the `Assign` / FPC `Copy`
  operator). `Open` on an open ring raises `EIORingError`.
- **`ReadAt` / `WriteAt`** need an idle ring and raise otherwise; `ReadAt`
  returns 0 at or after EOF.
- `GetIoRingInfo` on a closed ring handle still returns `S_OK` (it can't be
  used to check whether a ring is open).

### 5.3 Sync vs async

There is only **one** mechanism – the async ring. "Sync" is a helper in
`Delphi.IOUring`:

```pascal
// Blocking helpers: Prepare + Submit(wait 1) + Pop, raise on error.
function ReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;
function WriteAt(...): Cardinal;
```

Usage styles, from fastest/most manual to most convenient:

1. **Poll style** (core): prepare N, `Submit`, later `TryPopCompletion` in your
   own loop; dispatch on `UserData`. Zero allocations.
2. **Wait style**: `Submit(AWaitCount)` / `WaitForCompletions` – blocking until
   enough data is there.
3. **Event style**: `CompletionEventHandle` in `WaitForMultipleObjects` /
   `MsgWaitForMultipleObjects` (GUI thread friendly) / `epoll`.
4. **Engine style** (later, §10): hand requests to an I/O thread from any
   thread, get notified through a wait or a `procedure of object` callback.

### 5.4 Threading model

- A ring is **single-owner**: one thread prepares/submits/pops at a time.
  The OS enforces part of this (`IORING_E_SUBMIT_IN_PROGRESS`), and the
  user-mode queues are not synchronized. No internal locks.
- Typical patterns: one ring per worker thread, or one ring per stream
  (the sequential stream does this).
- Multi-threaded use goes through the engine (§10), which owns the rings.

### 5.5 Error handling

- OS-level failure of ring calls (`CreateIoRing`, `SubmitIoRing`…) → raise
  `EIORingError` with the HRESULT/errno and a readable message (the
  `IORING_E_*` codes get their own texts).
- Per-I/O failures come back in `TIORingCompletion.NativeResult`; the core
  never raises for them – helpers (`ReadAt`, streams) do.
- EOF is not an error: Windows returns `HRESULT_FROM_WIN32(ERROR_HANDLE_EOF)`
  (0x80070026) for reads at/after EOF; Linux returns `res = 0`.
  `IsEndOfFile` normalizes it. **[VERIFIED]** A read that starts before EOF
  and crosses it completes with `S_OK` and a short count; a read starting at
  or after EOF completes with 0x80070026 and 0 bytes.

### 5.6 Availability

- No fallback backend. `TIORing.Available` is `True` only when:
  - Windows: the IoRing functions are exported, `QueryIoRingCapabilities`
    reports `MaxVersion >= IORING_VERSION_4` and the
    `IORING_FEATURE_UM_EMULATION` flag is **not** set.
  - Linux: `io_uring_setup` succeeds and the needed ops are supported.
- Opening a ring when `Available = False` raises `EIORingNotSupported` with a
  message saying what is missing (OS too old, emulated, disabled by policy).
- The executable must still **load** on older Windows so that an application
  can check `Available` and choose its own path. Therefore the imports use
  the `delayed` directive (§6).
- When a future IoRing version appears, the library raises its minimum only
  if it starts using something the new version adds.

---

## 6. Layer 0 – complete OS API translations

### 6.1 Rules for the API units

- **100 % of the public API** of the header(s), with the original C names
  (`CreateIoRing`, `IORING_CQE`, `IORING_E_SUBMISSION_QUEUE_FULL`, …) like
  the RTL `Winapi.*` units do, plus `P…` pointer types.
- **Standalone**: depends only on `Winapi.Windows` (Delphi) / `Windows` (FPC).
  No initialization section, no global state, no exceptions – just
  declarations and the four inline helper functions. Another project can copy
  or use this one unit without the rest of the library.
- Covers **all IoRing versions**, not only V4. Functions added in later
  versions are `delayed` imports, so an application using only V1 functions
  still runs on Windows 11 21H2. (The library's own higher layers require V4.)
- Each declaration gets a short comment with the minimum version and a link
  to the Microsoft page (where one exists).

### 6.2 Contents checklist (Windows)

| Group | Items |
| --- | --- |
| Handle | `HIORING` |
| Enums (as `Cardinal` + constants) | `IORING_VERSION` (`_INVALID`, `_1`, `_2`, `_3` = 300, `_4` = 400), `IORING_FEATURE_FLAGS`, `IORING_OP_CODE` (NOP … WRITE_GATHER), `IORING_SQE_FLAGS`, `IORING_CREATE_REQUIRED_FLAGS`, `IORING_CREATE_ADVISORY_FLAGS`, `IORING_REF_KIND`, `FILE_WRITE_FLAGS`, `FILE_FLUSH_MODE` |
| Records | `IORING_CREATE_FLAGS`, `IORING_INFO`, `IORING_CAPABILITIES`, `IORING_HANDLE_REF`, `IORING_REGISTERED_BUFFER`, `IORING_BUFFER_REF`, `IORING_BUFFER_INFO`, `IORING_CQE`, `FILE_SEGMENT_ELEMENT` (if the RTL lacks it) |
| Constants | `IORING_SUBMIT_WAIT_ALL`, all 8 `IORING_E_*` HRESULTs |
| Functions (16) | all of §2.1 |
| Helpers (4, `inline`) | `IoRingHandleRefFromHandle`, `IoRingHandleRefFromIndex`, `IoRingBufferRefFromPointer`, `IoRingBufferRefFromIndexAndOffset` |

### 6.3 Declarations draft (Windows)

```pascal
type
  HIORING = type NativeUInt;

  // C enums are 4 bytes: declared as Cardinal + constants (no {$MINENUMSIZE} games, FPC-safe)
  IORING_VERSION = Cardinal;          // IORING_VERSION_1 = 1, _2 = 2, _3 = 300, _4 = 400
  IORING_OP_CODE = Cardinal;          // NOP=0 READ=1 REGISTER_FILES=2 REGISTER_BUFFERS=3 CANCEL=4 WRITE=5 FLUSH=6 READ_SCATTER=7 WRITE_GATHER=8
  IORING_SQE_FLAGS = Cardinal;        // IOSQE_FLAGS_NONE=0, IOSQE_FLAGS_DRAIN_PRECEDING_OPS=1
  IORING_REF_KIND = Cardinal;         // IORING_REF_RAW=0, IORING_REF_REGISTERED=1
  IORING_FEATURE_FLAGS = Cardinal;    // UM_EMULATION=1, SET_COMPLETION_EVENT=2
  FILE_WRITE_FLAGS = Cardinal;        // NONE=0, WRITE_THROUGH=1
  FILE_FLUSH_MODE = Cardinal;         // DEFAULT=0, DATA=1, MIN_METADATA=2, NO_SYNC=3

  IORING_CREATE_FLAGS = record
    Required: Cardinal;               // IORING_CREATE_REQUIRED_FLAGS_NONE
    Advisory: Cardinal;               // IORING_CREATE_SKIP_BUILDER_PARAM_CHECKS = 1
  end;

  IORING_INFO = record
    IoRingVersion: IORING_VERSION;
    Flags: IORING_CREATE_FLAGS;
    SubmissionQueueSize: UInt32;
    CompletionQueueSize: UInt32;
  end;

  IORING_CAPABILITIES = record
    MaxVersion: IORING_VERSION;
    MaxSubmissionQueueSize: UInt32;
    MaxCompletionQueueSize: UInt32;
    FeatureFlags: IORING_FEATURE_FLAGS;
  end;

  IORING_HANDLE_REF = record          // Win32: 8 bytes, Win64: 16 bytes
    Kind: IORING_REF_KIND;
    case Integer of
      0: (Handle: THandle);
      1: (Index: UInt32);
  end;

  IORING_REGISTERED_BUFFER = record
    BufferIndex: UInt32;
    Offset: UInt32;
  end;

  IORING_BUFFER_REF = record          // Win32: 12 bytes, Win64: 16 bytes
    Kind: IORING_REF_KIND;
    case Integer of
      0: (Address: Pointer);
      1: (IndexAndOffset: IORING_REGISTERED_BUFFER);
  end;

  IORING_BUFFER_INFO = record
    Address: Pointer;
    Length: UInt32;
  end;

  IORING_CQE = record                 // Win32: 12 bytes, Win64: 24 bytes
    UserData: UIntPtr;
    ResultCode: HRESULT;
    Information: NativeUInt;          // ULONG_PTR
  end;

function CreateIoRing(Version: IORING_VERSION; Flags: IORING_CREATE_FLAGS;
  SubmissionQueueSize, CompletionQueueSize: UInt32; out Ring: HIORING): HRESULT;
  stdcall; external kernel32 name 'CreateIoRing' delayed;
function BuildIoRingReadFile(Ring: HIORING; FileRef: IORING_HANDLE_REF;
  DataRef: IORING_BUFFER_REF; NumberOfBytesToRead: UInt32; FileOffset: UInt64;
  UserData: UIntPtr; SqeFlags: IORING_SQE_FLAGS): HRESULT;
  stdcall; external kernel32 name 'BuildIoRingReadFile' delayed;
// ... all 16

function IoRingHandleRefFromHandle(const AHandle: THandle): IORING_HANDLE_REF; inline;
// ... all 4 helpers
```

`delayed` keeps the code simple (plain function declarations, no
function-pointer variables) and the per-call cost is one indirect jump, the
same as a normal import. The library's `Available` check uses
`GetProcAddress` for `QueryIoRingCapabilities`, so the check itself can
never fail with a delay-load error. **[VERIFIED]** FPC 3.2.2 does **not**
support `delayed` ("`;` expected but `DELAYED` found"). So in FPC the
`external … delayed` part is left out (`{$IFNDEF FPC}`), and each function is
a small wrapper in the implementation section that looks the real function up
with `GetProcAddress` on its first call and keeps the pointer (Milestone 2).
An FPC program therefore also starts on Windows without IoRing. A function
the OS does not have returns `E_NOTIMPL` (`IsIoRingOpSupported`: False)
instead of raising Delphi's delay-load error. The extra call costs about 1 ns.

ABI risks – **[VERIFIED]** in Phase 1: record sizes and offsets match on Delphi
Win32 and Win64 and on FPC 3.2.2 i386; records passed by value work on Win32
and Win64 (reads, writes, registered buffers and scatter/gather return the
right data). Original notes:

1. `SizeOf` and field offsets of every record on Win32 and Win64 match the C
   layout above (in Delphi **and** later in FPC).
2. **Records passed by value** (`IORING_CREATE_FLAGS`, `IORING_HANDLE_REF`,
   `IORING_BUFFER_REF`):
   - Win64: MS x64 ABI passes >8-byte structs as a pointer to a caller copy;
     Delphi does the same for non-`const` record value params. Expected OK.
   - Win32 stdcall: the struct must be pushed on the stack by value. Do not
     declare them `const` (Delphi may pass `const` records by reference).
     Prove with a real `BuildIoRingReadFile` + read of a known file on Win32.
     Fallback if it fails: declare the params as separate scalar arguments
     (`Kind, Value`) which is binary-identical on the stack. Either way the
     cost is a few extra pushes – not a meaningful performance hit.

### 6.4 Linux API unit (later)

Same rules: complete translation of the `linux/io_uring.h` user API of a
pinned kernel version (all opcodes, SQE/CQE layouts, setup/enter/register
flags, `io_uring_params`, offsets structs, register opcodes, feature flags),
plus the three syscall wrappers. x86-64 and AArch64 only.

---

## 7. Layer 2 – Sequential read-ahead reader

The main first use case: read a large file front to back as fast as possible,
with the OS filling the next buffers while the caller processes the current
one.

`TIORingSequentialReader` is a **custom managed record** (owns the file
handle, the ring and the buffer memory; not copyable, §4.1).

```pascal
type
  TIORingSequentialReaderOption = (
    sroUnbuffered,          // FILE_FLAG_NO_BUFFERING / O_DIRECT
    sroNoSequentialScanHint,// default sends FILE_FLAG_SEQUENTIAL_SCAN / posix_fadvise
    sroFixedReadAhead,      // benchmarks: no adaptive ramp-up
    sroNoRegistration       // benchmarks: no registered file/buffers
  );
  TIORingSequentialReaderOptions = set of TIORingSequentialReaderOption;

  TIORingSequentialReader = record
  public
    // Initialize / Finalize / Assign operators per §4.1
    procedure Open(const AFileName: string;
      const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = 1024 * 1024;   // multiple of 4096
      const ABufferCount: Cardinal = 8); overload; // = max read-ahead depth
    procedure Open(const AHandle: THandle; const AOwnsHandle: Boolean; ...); overload;
    procedure Close;   // waits for the reads in flight, then releases everything

    // Copying API (used by the stream)
    function Read(var ABuffer; const ACount: NativeInt): NativeInt;

    // Zero-copy API: borrow the next filled chunk; it stays valid until
    // ReleaseChunk (which immediately re-queues that buffer for the next read).
    function TryAcquireChunk(out AData: PByte; out ALength: NativeInt;
      const AWait: Boolean = True): Boolean;
    procedure ReleaseChunk;

    function DataReady: Boolean;   // True if the next Read would not block
    property Position: Int64;      // bytes delivered to the caller
    property Size: Int64;          // file size taken at open
    property Eof: Boolean;
    property Stats: TIORingReaderStats;  // plain record: reads issued, bytes, stalls, wait time
  end;
```

Algorithm:

1. Open the file (`CreateFile` with `FILE_FLAG_OVERLAPPED`,
   `FILE_SHARE_READ`, plus flags per options), read its size once.
2. Allocate `BufferCount × BufferSize` with one `VirtualAlloc`, register it as
   buffers, register the file handle.
3. Prime: prepare reads for the first slots at offsets `0, B, 2B, …` (not past
   EOF), one `Submit`.
4. Slots form a circular queue (fixed array of plain records) with states
   `Free → InFlight → Ready → InUse`. `UserData = slot index`. Completions may
   come out of order; they only flip the slot's state + store the byte count.
5. `Read`: copy from the head slot; when the head slot is consumed, re-queue it
   at `NextOffset` (if < Size) and advance the head. Before blocking, pop all
   available completions; block only if the head slot is still `InFlight`
   (`Submit(1)` / `WaitForCompletions`). Re-queued slots are batched into one
   `Submit` per head advance.
6. **Adaptive read-ahead** (idea taken from PostgreSQL's read streams): start
   with a small look-ahead distance (e.g. 2 buffers); every time `Read` has
   to wait (a *stall*), double the distance up to `BufferCount`. Small files
   and fast consumers don't pay for deep queues; slow storage gets deep
   queues automatically. Fixed distance = `BufferCount` is the fallback if
   adaptivity doesn't pay off in benchmarks.
7. Big reads (`ACount ≥ BufferSize`) still go through the buffers in v1.
   Later optimization: read directly into the caller's buffer when aligned.
8. Unbuffered mode: offsets/lengths are sector multiples (BufferSize is), the
   last read requests a full buffer and gets a short count – fine.
   Sector size via `GetFileInformationByHandleEx(FileStorageInfo)`.
   PostgreSQL's experience: direct I/O is *slower* for many workloads unless
   you have your own cache – so it is opt-in, buffered is the default.
9. **Size is fixed at open.** If another process appends to the file while it
   is being read (e.g. a log file), the reader stops at the original size and
   does not see the appended data. A short read before `Size` (file shrank)
   is treated as EOF.

"Data for free": after priming, as long as the caller processes data slower
than the disk delivers it, `DataReady` is always `True` and `Read` is just a
`Move`. `Stats.Stalls` shows how often that was *not* the case.

### Implementation notes (Phase 3)

The code (`Delphi.IOUring.SequentialReader.pas`) is the reference; where it
differs from the sketch above:

- **Options:** `sroUnbuffered`, `sroNoSequentialScanHint`, plus two for
  benchmarking: `sroFixedReadAhead` (all buffers in flight from the start)
  and `sroNoRegistration` (raw handle and buffer pointers instead of
  registered ones).
- **Buffer size** must be a multiple of 4096 (not 64 KiB): that is the page
  size and covers the sector size of usual disks. With `sroUnbuffered` the
  reader also checks it against the volume's logical sector size.
  Buffer count: 1–1024. Defaults: 1 MiB × 8.
- **Slot states** are `Free → InFlight → Ready`; "in use" is simply the head
  slot. Errors are delivered in order: a failed read raises `EIORingError`
  when `Read` reaches that buffer, not when the completion arrives.
- **Registration:** the file and the whole buffer block are registered with
  the ring and submitted together with the first reads (a registration is a
  barrier for the entries after it). Skipped above 4 GiB of buffers (32-bit
  offsets in a registered buffer reference).
- **Data appended after Open is never delivered:** each read's byte count is
  cut to what the size at open allows (the last read asks for a whole buffer,
  so it could return appended bytes otherwise). Tested.
- **File shorter than at Open:** a short read moves the end; `Size` keeps the
  size at open, `Eof` becomes True at the new end. Tested.
- **OS-specific file calls** (open with flags, size, sector size, page memory,
  clock) are in the backend unit as `TWindowsIORingPlatform`, exported as
  `TIORingPlatform` – the reader itself has no Windows code.
- `Close` closes the ring first (which waits for the reads in flight), then
  frees the buffers, then closes the file if the reader owns it.
- **Benchmarks (Phase 5, [Benchmarks.md](Benchmarks.md)):** a cold 10 GiB file is
  read at disk speed (~6.75 GiB/s, 2.7–4× `TFileStream`), the same as
  overlapped `ReadFile` with the same read-ahead; no gain when the file is in
  the cache. The tuning sweep confirmed the **defaults** (1 MiB × 8, adaptive
  read-ahead, sequential-scan hint, registration): within 1 % of the best in
  both buffered and unbuffered mode. Unbuffered reading needs ~4 reads and
  2–4 MiB in flight on that disk, buffered ~8 MiB.

---

## 8. Layer 3 – Streams

Principle: **small, specific stream classes** that contain only the code they
need, instead of one `TIORingStream` that does everything with lots of modes.
They are classes because `TStream` is a class; the work is done by the
record they contain.

### 8.1 `TSequentialReadOnlyFileStream = class(TStream)`

```pascal
type
  TSequentialReadOnlyFileStream = class(TStream)
  private
    FReader: TIORingSequentialReader;   // embedded record, no extra allocation
  public
    constructor Create(const AFileName: string;
      const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = 1024 * 1024;
      const ABufferCount: Cardinal = 8);
    ...
  end;
```

Read-only, forward-only. The constructor takes only the options this class
actually supports (the same set as the reader – today: unbuffered,
sequential-scan hint).

| Member | Behaviour |
| --- | --- |
| `Read(var Buffer; Count: Longint): Longint` and the `TBytes`/`Int64` overloads | Delegates to the reader. Returns < Count only at EOF. |
| `Write*` | Raises `EIORingStreamError` ("stream is read-only"). |
| `SetSize` | Raises. |
| `Seek(0, soCurrent)` | Returns `Position`. **Must** work: `TStream.GetPosition` is implemented as `Seek(0, soCurrent)`. |
| `Seek(X, …)` resolving to the current position | No-op, returns `Position` (makes `Position := Position` and `CopyFrom(S, 0)` on a fresh stream work, since `CopyFrom` does `Source.Position := 0`). |
| `Seek` to any other position, forward or backward | Raises `EIORingStreamError` ("stream is sequential"). |
| `GetSize` | Overridden to return the size known at open (the default implementation in `TStream` seeks to the end, which would raise). |
| `Position := …` | Goes through `Seek` → same rules. |

Exception class: `EIORingStreamError = class(EStreamError)` so that existing
code catching `EStreamError` keeps working.

#### Implementation notes (Phase 4)

- `Delphi.IOUring.Streams`. The stream overrides `Read`/`Write` for `Longint`
  and, in Delphi on 64-bit, the new `NativeInt` overloads of Delphi 13 (so
  big reads go straight to the reader instead of being split by `TStream`).
  The `TBytes`, `Read64`/`Write64` and `ReadData` overloads all end up there.
- `SetSize` is overridden in both forms (`Int64` and the deprecated `Longint`
  one), so no path changes the size silently.
- Only the 64-bit `Seek` is overridden; the old `Seek(Longint, Word)` is routed
  to it by `TStream` (tested).
- **Open errors:** a file that cannot be opened raises **`EFOpenError`** with
  the same message format as `TFileStream` ("Cannot open file "…". <reason>"),
  so it is a drop-in for code that catches that. Wrong buffer arguments raise
  `EIORingError`. The stream opens the handle itself and hands it to the
  reader, which then owns it (also if the reader's `Open` fails – tested by an
  exclusive open right after the failed constructor).
- Extra properties: `FileName`, and `Stats` (the reader's statistics, for
  benchmarks). No zero-copy API on the stream – that stays on the reader.
- Tested with `TMemoryStream.CopyFrom(S, 0)` and in parts, `TBytesStream.LoadFromStream`
  and `TStreamReader.ReadLine` (20 000 lines). A second `CopyFrom(S, 0)` after
  reading raises (it would need a rewind).

### 8.2 Later stream classes (each its own specific class)

- `TSequentialWriteOnlyFileStream` – write-behind: `Write` copies into a
  buffer, full buffers are submitted, `Destroy`/`Flush` waits for all.
- A random-access class – mostly convenience; random I/O gains come from
  batching, which `TStream` can't express. The real tool for that is the
  engine's batched API (§10).

---

## 9. What we take from PostgreSQL 18 AIO

PostgreSQL 18 (2025) added asynchronous I/O with three `io_method`s: `sync`,
`worker` (a pool of I/O worker processes, default, portable) and `io_uring`
(one ring per backend process, Linux). Lessons relevant to us:

| PostgreSQL | For this library |
| --- | --- |
| **Read streams**: the consumer tells the stream which blocks it will need next (a callback); the stream issues reads ahead with a bounded, growing look-ahead distance. | Sequential reader = read stream with "next block = previous + 1". The engine (§10.4) generalizes it with a block-provider callback for "random, but known in advance" reads (index lookups, many small records). |
| **I/O combining** (`io_combine_limit`, default 128 kB): adjacent block reads are merged into one vectored request. | Engine merges adjacent requests on the same file into one request (contiguous buffer, or scatter/gather – which we always have with V4). |
| **Concurrency limits** (`effective_io_concurrency` 16, `io_max_concurrency` ≤ 64 per process). Too high hurts latency. | Per-stream and per-engine in-flight limits, with defaults chosen from benchmarks. |
| **I/O handle life cycle** (`HANDED_OUT → DEFINED → STAGED → SUBMITTED → COMPLETED`), handles identified by id + **generation** so a reused handle can't be confused with its previous use. | Request pool with the same states; `UserData` = slot index + generation (§10.3). |
| **Batch mode**: stage several I/Os, submit them with one syscall. | Already the core model (Prepare/Submit). Engine drains its input queue into one `Submit` per loop. |
| **Worker pool**: one shared submission queue, a submit wakes one worker which wakes at most two more (avoid thundering herd); failed/crashed worker → its requests fail. | Engine with N I/O threads, careful wake-up policy, every request always completes (success, error or cancelled). |
| Only work whose future blocks are **known in advance** benefits (seq scans, bitmap scans, VACUUM); single-block OLTP lookups stay synchronous. Writes stayed synchronous in v18. | Same honesty for us: async is for read-ahead and batches. A single blocking `ReadAt` is not faster than `ReadFile`. |
| **Monitoring** (`pg_aios` view) was needed to understand behaviour. | Stats counters on reader and engine (issued, completed, in flight, stalls, wait time). |
| A process can **wait for an I/O another process started** on the same buffer instead of issuing a duplicate. | The basis of the overlap handling in §11. |

Sources: credativ "PostgreSQL 18 Asynchronous Disk I/O – Deep Dive",
Cybertec "PostgreSQL 18: better I/O performance with AIO", Neon PG18 AIO docs,
PostgreSQL wiki "AIO", interdb.jp appendix 2 (io_uring examples),
mattrucker.com "PostgreSQL 18 async I/O".

---

## 10. I/O engine (later, Layer 2) – outline

Not part of the first milestone; designed now so the core doesn't block it.

### 10.1 Why

A single-owner ring is perfect for one stream on one thread. Real
applications have many threads that each want "a few" I/Os. To get many
requests in flight at once (what NVMe and cloud disks need), something has to
collect requests from all threads into a few rings. That is the engine.

### 10.2 Shape

```
 producer threads ──► lock-free request queue ──► I/O thread k ──► ring k ──► kernel
       ▲                                              │
       └──── wake (WaitOnAddress / futex) ◄───────────┘ completions
              or procedure-of-object callback on the I/O thread
```

- `TIORingEngine` (class – shared by many threads) owns 1..N I/O threads,
  each with its own ring.
- The kernel already runs requests of *one* ring in parallel, so **N = 1 is
  the default**; N > 1 only helps when one thread can't build/reap fast enough
  (very high IOPS). Measure before adding.
- Requests are routed to a ring by file (all requests for one file go to one
  ring) – keeps registered-file tables small and makes the overlap rules
  (§11) local to one thread, so they need no locks.
- I/O thread loop: drain request queue → `Prepare*` all → one `Submit` → pop
  all completions → notify → when idle, sleep until either new requests or a
  completion arrive. Spinning briefly before sleeping is a tunable.

### 10.3 Request pool

- Fixed-size array of plain request records (no allocation per request).
- States: `Free → Defined → Queued → Submitted → Completed → Free`.
- `UserData` = `slot index` + `generation` packed into a `NativeUInt`
  (Win32: the index bits follow the capacity, the generation gets the rest).
  A stale completion or a late `Wait` on a reused slot is detected.
- A request handle is a small plain record (one `NativeUInt`) the caller
  can `Wait` on, poll, or cancel.
- Built in Phase 11 (`Delphi.IOUring.RequestPool`); details in §10.7.

### 10.4 Engine APIs (sketch)

- `ReadAsync / WriteAsync / FlushAsync(...) : TIORingRequestHandle`, `Wait`,
  `WaitAll`, `TryGetResult`.
- `BeginBatch / EndBatch`: many requests from one thread go into the queue as
  one unit (one wake-up of the I/O thread).
- **Read stream with block provider**: caller supplies a callback
  (`procedure of object`) returning the next (offset, length) it will need;
  engine keeps up to *distance* reads in flight, merges adjacent ones,
  delivers buffers in the order the provider produced them.
- Completion notification options: wait, callback on the I/O thread (must be
  short), or posting to a per-consumer completion queue.

### 10.5 Lock-free hand-over between threads

Locks are used only on cold paths (start-up, registration changes,
shutdown). On the hot path:

| Where | Technique |
| --- | --- |
| Producers → I/O thread | **Bounded MPSC/MPMC array queue** with a sequence number per cell (Vyukov style): producers claim a cell with one CAS on the tail counter, the I/O thread reads without CAS. No allocation, fixed memory. **Built in Phase 12 as a full MPMC queue (the consumer uses one CAS too), with backoff; it beats an SRW-lock queue everywhere** (§10.8, [Benchmarks.md](Benchmarks.md#request-queue-phase-12)). |
| Request pool free list | **Lock-free stack** (Treiber) of slot indices. ABA problem solved with a tag/generation in the same word as the index, swapped with one CAS (64-bit CAS on Win32 = `CMPXCHG8B`). Optional per-thread small cache of free slots to avoid contention. **Built in Phase 11, with exponential backoff; it wins or ties against an SRW lock in every case measured** (§10.7, [Benchmarks.md](Benchmarks.md#engine-structures-phase-11)). The per-thread cache is not needed so far. |
| I/O thread → waiting producer | Per-request **state word**. The waiter spins briefly, then sleeps with `WaitOnAddress` (Windows) / `futex` (Linux). The I/O thread calls `WakeByAddressSingle` only if the "someone is waiting" bit is set – no syscall when nobody sleeps. |
| I/O thread sleeping | Waits on {request-queue signal, ring completion event}. Producers signal only when the I/O thread has announced it is going to sleep (a flag set with CAS), so a busy engine costs producers no syscall. |
| Counters / stats | Owned by one thread where possible; otherwise atomic increments on counters padded to their own **cache line** (64 bytes) to avoid false sharing. Queue head/tail counters are padded the same way. |

All atomics go through one small unit, `Delphi.IOUring.Atomics` (CAS,
exchange, add, load-acquire, store-release, CPU pause/yield, wait/wake on
address). Delphi intrinsics (`AtomicCmpExchange`, …) and FPC routines
(`InterlockedCompareExchange…`) differ, and AArch64 (Linux) needs real
acquire/release ordering where x86 doesn't, so keeping it in one unit keeps
the rest of the code portable.

Lock-free is not automatically faster: under low contention a slim lock
(SRW lock) can be just as fast and simpler. Each structure gets a benchmark
against a lock-based version before it is accepted; if the lock wins or
ties, the lock stays.

### 10.6 Atomics unit – implementation notes (Phase 10)

`Delphi.IOUring.Atomics` has one type, `TAtomic`: a record with only static
class methods (nothing to create). Most methods are `inline`.

| Group | Methods | Types |
| --- | --- | --- |
| Read-modify-write, full barrier | `CompareExchange`, `TryCompareExchange`, `Exchange` (return the old value); `FetchAdd` (old value); `Increment`, `Decrement` (new value) | `Integer`, `Cardinal`, `Int64`, `UInt64`; `Pointer` for the first three |
| Ordered load / store | `LoadAcquire`, `StoreRelease` | the same five types |
| Other | `FullBarrier`, `CpuPause` | – |
| Sleep / wake | `WaitWhileEqual` (with timeout), `WakeOne`, `WakeAll` | 32-bit only – the Linux futex has the same limit |

`NativeInt` / `NativeUInt` variables pick the 32-bit or 64-bit versions by
themselves (both compilers). Only the `Integer` and `Int64` versions have
their own code; the others call them through a typecast of the same size.
Constants: `IORING_CACHE_LINE_SIZE = 64`, `IORING_WAIT_INFINITE`.

| | Delphi | Free Pascal |
| --- | --- | --- |
| CAS, exchange, add | intrinsics (`AtomicCmpExchange`, `AtomicExchange`, `AtomicIncrement`), 64-bit also on Win32 | RTL `Interlocked*` (calls). i386 has no 64-bit versions at all: `CompareExchange(Int64)` is `LOCK CMPXCHG8B` in assembler, 64-bit exchange/add are CAS loops |
| 64-bit load / store on Win32 | one SSE move (assembler) | the same |
| 64-bit store on x64 | plain store | 1-instruction assembler routine (see below) |
| `FullBarrier` | `MemoryBarrier` | `LOCK OR [ESP/RSP], 0` |
| `CpuPause` | `YieldProcessor` (`PAUSE`) | `PAUSE` in assembler |
| Sleep / wake | `WaitOnAddress`, `WakeByAddressSingle`, `WakeByAddressAll` from `api-ms-win-core-synch-l1-2-0.dll` (Windows 8+), normal import | the same |

The unit stops with a compile error on CPUs other than x86/x64 (they need
real acquire/release barriers – Milestone 4) and on systems other than
Windows (futex – Milestone 4).

Findings **[VERIFIED]**:

- **A plain 64-bit read on Win32 can see half of a write.** One thread
  switches a value between `$00000000FFFFFFFF` and `$FFFFFFFF00000000`,
  another reads it 2 million times: plain reads saw a mixed value 49–5 381
  times per run, `LoadAcquire` never. On Win64 plain reads were always whole.
- **FPC x64 writes a 64-bit constant that does not fit in 32 bits as two
  32-bit stores** (`movl $0,(%rax)` + `movl $-1,4(%rax)`), with and without
  optimization. After inlining, `StoreRelease(X, $FFFFFFFF00000000)` became
  such a store, and the test above found 4 244 half-written values. Fix: on
  FPC x64 the 64-bit `StoreRelease` is a 1-instruction assembler routine (the
  value arrives in a register). Delphi Win64 puts the constant in a register
  and writes it with one store (checked in the machine code, with and
  without optimization).
- **Neither compiler keeps a shared value in a register across loop
  rounds.** FPC's code at `-O3` and `-O4` reads the variable again in every
  round (checked in the assembler output). The test
  `Spin_SeesWriteOfOtherThread` (a loop without any call in it) passes with
  Delphi Release and FPC `-O3`.
- **`WaitOnAddress` spins briefly before it sleeps** (seen from the timing):
  two threads passing a turn back and forth with wait/wake need only
  ~0.15–0.3 µs per hand-over, which is too fast for a kernel sleep. So a
  waiter that is woken quickly costs no system call; the ping-pong test
  holds every 16th turn for 200 µs so that the other thread really sleeps
  and must be woken.

Tests: `Tests.Atomics` (DUnitX) and `Tests.FPC.Atomics` (FPCUnit), 20 each:
every method for every type (64-bit values have different upper and lower
halves); counters from 4 threads that must come out exact; the half-write
test; release/acquire hand-over of data 100 000 times; the spin-loop test;
wait timeout, wake one, wake all; ping-pong without lost wake-ups. They pass
with Delphi Debug and Release, and with FPC with and without `-O3`
(`Build-FPC.ps1 -Optimize`), Win32 and Win64.

### 10.7 Request pool – implementation notes (Phase 11)

`Delphi.IOUring.RequestPool` has two managed records (copying one raises,
like `TIORing`):

- **`TIORingFreeList`** – a lock-free stack (Treiber) of the indices
  0..Capacity-1. The top index and a 32-bit tag share one 64-bit word on a
  cache line of its own. Every take and give changes the tag in the same
  compare-exchange, so a thread that read an old top always fails and tries
  again (no ABA problem). The links stay in memory until `Close`, so reading
  the link of an index that another thread has just taken is harmless.
  After a failed compare-exchange the thread waits 1, 2, 4 … up to 1024 CPU
  pauses (**exponential backoff**); without it the stack lost to an SRW lock
  by up to 4.8× (benchmark below).
- **`TIORingRequestPool`** – the slots. A slot is a 32-bit **state word**
  plus room for the engine's own request data (the *payload*: its size is
  given to `Open`; the pool does not look at it). Slots are padded to whole
  cache lines, so two requests never share one.

State word: generation (bits 4–31) | "someone is waiting" flag (bit 3) |
state (bits 0–2: Free, Defined, Queued, Submitted, Completed).

Handle (`TIORingRequestHandle`, also the ring's `UserData`):
`generation shl IndexBits or index`. IndexBits follows the capacity (at
least 4). The generation has 28 bits on Win64; on Win32 it has the rest of
the 32 bits, at most 28 (1024 slots: 22 bits; the biggest pool, 2^20 slots:
12 bits). Generation 0 is never used, so a handle is never 0 – 0 means "no
request".

| Method | What it does |
| --- | --- |
| `TryAcquire` | Takes a free slot: Free → Defined. False if all slots are in use. |
| `TryChangeState(H, From, To)` | One compare-exchange; False if the handle is stale or the request is not in `From`. Any change among Defined, Queued, Submitted and Completed; a change to Completed also wakes the waiters. |
| `WaitFor(H, Timeout)` | Checks `SpinCount` times (default 100, with a CPU pause), then sets the waiting flag and sleeps on the state word (`TAtomic.WaitWhileEqual`). Timeout 0 only checks. |
| `Release(H)` | Defined or Completed → Free with the next generation: the old handle becomes stale at once; wakes waiters; gives the index back to the free list. |
| `State`, `IndexOf`, `Payload` | The state (or `rsStale`), the slot index, the payload address. |

Why it is safe:

- **One 32-bit word decides everything about a slot**, so every check and
  change is a single atomic operation. A stale handle can never change a
  slot that has been reused: its generation no longer matches.
- **No lost wake-ups, and no wake-up calls when nobody sleeps.** A waiter
  sets the waiting flag with a compare-exchange and then sleeps with the
  flagged value as the "expected" value. The thread that completes the
  request calls the wake function only if the word it replaced had the flag.
  If the completion comes between the two steps of the waiter, the
  compare-exchange fails or `WaitOnAddress` returns at once (the value
  differs).
- `Release` wakes waiters too: a thread waiting on a request that its owner
  released gets `wrStale` instead of sleeping until its timeout.
- Generations wrap around after 2^GenerationBits − 1 releases of the same
  slot; a handle that old is not recognised as stale (Win32 with 2^20 slots:
  4095 releases; with 1024 slots: about 4 million).

Tests: `Tests.RequestPool` (DUnitX) and `Tests.FPC.RequestPool` (FPCUnit),
23 each – free list order, capacity and errors; every slot once, handles and
generations (also the wrap-around on Win32), stale and out-of-range handles,
the state rules, payload alignment and separation, `WaitFor` (at once,
timeout 0, timeout, woken by completion, woken by release); 4 threads that
must never hold the same index or slot at once; and an **engine simulation**:
4 producers and one "I/O thread" pass 80 000 requests through a pool that is
smaller than the number of producers, with and without spinning in `WaitFor`.
All pass with Delphi Debug and Release and FPC with and without `-O3`, Win32
and Win64.

Benchmark (Design rule §10.5, details in
[Benchmarks.md](Benchmarks.md#engine-structures-phase-11)): against the same
stack behind an SRW lock, the lock-free free list **wins or ties in every
case** – 1.2–1.4× with one thread, 1.1–6.7× with 2–28 threads in a tight
loop, the same with 1 µs of work and up to 4 threads, 1.6–2.0× with 8–28
threads – in Delphi and FPC, Win32 and Win64. **It stays.**

### 10.8 Request queue – implementation notes (Phase 12)

`Delphi.IOUring.RequestQueue` has one managed record, `TIORingRequestQueue`:
a bounded first-in first-out queue of pointer-sized values (request handles)
– Dmitry Vyukov's bounded MPMC queue.

- An array of cells (a power of two; `Open` rounds up) and two position
  counters that only grow: the enqueue position and the dequeue position,
  each on a cache line of its own.
- Each cell has a **sequence number** that says whose turn the cell is:
  `P` = free for the producer of position `P`; `P + 1` = holds the value of
  position `P`; `P + Capacity` = free again, for the next lap.
- A producer claims a position with one compare-exchange on the enqueue
  position, writes the value, and then publishes it by storing the new
  sequence number (release). A consumer does the same on the dequeue side and
  stores `P + Capacity` when it has read the value. Producers and consumers
  touch different counters, so the two sides hardly disturb each other.
- **Any number of producers and consumers** may use it at once. The engine
  has one consumer per queue (the I/O thread); a single-consumer version
  could skip one compare-exchange per value, but the queue would then break
  silently if a second consumer ever came along – not worth it unless a
  benchmark shows a need.
- After a lost race (a failed compare-exchange, or a position another thread
  took first) the thread backs off with `TAtomic.BackOff` – the lesson of
  Phase 11.
- Positions are `NativeUInt`: on Win32 they wrap around after 2^32 values
  (minutes at full speed, so it *will* happen in a long-running program).
  All comparisons use the signed difference, which is correct across the
  wrap-around; `Open` has a parameter for tests to start just before it.
- `Count` is exact only when the queue is idle; otherwise it is a moment's
  picture.

Also new in `Delphi.IOUring.Atomics`: `TAtomic.BackOff` (moved from the free
list, now shared) and `IORingAllocCacheAligned` (cache-line aligned memory,
used by the pool, the free list and the queue).

Tests: `Tests.RequestQueue` (DUnitX) and `Tests.FPC.RequestQueue` (FPCUnit),
12 each – order, full and empty, capacity rounding, any value, 10 000 laps
around the array, the wrap-around of the positions (single-threaded and
under load), a closed queue; and stress with several producers and one or
several consumers: every value must come out exactly once, and with one
consumer in each producer's order. The stress tests give up after 20 s
(values lost) and `RunThreads` fails a test whose threads still run after
60 s (an endless loop), so a broken queue fails the run instead of hanging
it.

**Checking the tests themselves** (by breaking the queue on purpose):

- Producers claiming a position with a plain write instead of a
  compare-exchange: all five stress tests fail (four with "thread still runs
  after 60 s", one with "values were lost") – caught, and the run ends.
- Publishing the cell *before* writing the value: **not caught**. On x86 the
  two writes leave the CPU one instruction apart and in order, so a consumer
  almost never reads between them. Such ordering mistakes cannot be found by
  stress tests on x86; only careful reading of the code (and later AArch64,
  where memory order is weaker) can find them.

Benchmark (Design rule §10.5, details in
[Benchmarks.md](Benchmarks.md#request-queue-phase-12)): N producers → one
consumer, against a ring buffer behind an SRW lock (which first checks
"full"/"empty" without the lock, to give it a fair chance). The lock-free
queue **wins everywhere** – 4–23 % with 1–4 producers and 1 µs of work per
value, 2–65× with 8–27 producers, 3–290× in a tight loop – in Delphi and
FPC, Win32 and Win64. With the lock, the consumer has to win the same lock
as every producer and starves when there are many of them. **It stays.**

---

## 11. Overlapping reads and writes (later) – options

The OS gives **no ordering** between requests that are in flight at the same
time (§2.1). If two in-flight requests touch the same file bytes:

| Case | What can happen without rules |
| --- | --- |
| Write + write, overlapping | Final content can be from either write (or mixed at sector level). |
| Read + in-flight write, overlapping | Read can see old data, new data, or a mix. |
| Write + in-flight read, overlapping | Read can see the new data even though it was issued first. |
| Read + read, same range | Correct, but the same bytes are read twice (wasted I/O). |

Options, from cheapest to most capable:

- **A. User's responsibility (core ring, always).** The raw ring never adds
  rules – that would cost every user. Documented loudly. Tools: wait for the
  earlier completion before issuing the dependent request, or use
  `sfDrainPreceding` (full barrier, expensive).
- **B. In-flight range table in the engine (opt-in per file).** The I/O thread
  keeps, per file, the ranges currently in flight. A new request that
  overlaps an in-flight one:
  - write after read/write → held back until the earlier ones complete
    (preserves issue order: no lost update, no "read sees the future");
  - read after write → held back, or, if the write's buffer covers the whole
    range, answered directly from that buffer (read-your-writes, no I/O);
  - read of a range already being read → attached to the existing request
    (one I/O, several waiters – the PostgreSQL "wait for the I/O someone
    else started" idea).

  Cost: one lookup per request in a small per-file structure, on the I/O
  thread only (no locks, §10.2 routing). Negligible next to a syscall.
- **C. Block cache / buffer manager** (what PostgreSQL really has): the engine
  owns a page cache, each block has an "I/O in progress" state, all access
  goes through it. Most powerful, but that is a database buffer pool – very
  likely out of scope.

**[DECIDE later]**: A is fixed for the core. Proposal for the engine: B as an
opt-in, C not planned.

---

## 12. Compilers, platforms and coding conventions

### 12.1 Order of work

1. **Delphi 13 on Windows** (Win32 + Win64) – the most optimal version first.
   Decisions are made for Delphi performance; FPC must not make the Delphi
   version slower.
2. **Free Pascal / Lazarus on Windows** – same sources compile with the latest
   FPC/Lazarus (currently Lazarus 5.0 RC1 with FPC 3.2.2). This proves the
   code is portable before any Linux work starts. **State 2026-10-22:** the
   whole library compiles with FPC 3.2.2 and all FPC tests pass on Win32
   and Win64 (101 at the end of Milestone 2, 121 after Phase 10); speed is
   the same as with Delphi.
   The FPC tests are separate FPCUnit units (`Source/UnitTests/FPC`), built
   with `Source/Build-FPC.ps1` (`-Optimize` adds `-O3`).
3. **Linux through Free Pascal** (x86-64, AArch64) – new `Posix` backend; the
   upper layers should then compile unchanged.

### 12.2 Language level

The baseline is what **both** Delphi 13 and the latest FPC/Lazarus support,
looking forward (when a new FPC release adds a feature, the baseline can be
raised).

Allowed everywhere:
- Records with methods, operators, `class function … static`, `inline`.
- Custom managed records (operator declarations differ, §4.1).
- Generics in simple forms (both compilers in `{$MODE DELPHI}`).
- `sealed` / `final` classes, `strict private`.

Not allowed in shared code (FPC 3.2.2 doesn't support them, or they behave
differently):
- Inline `var` declarations, inline `const`.
- Anonymous methods / closures (FPC 3.2.2 has none; FPC's trunk has function
  references – revisit when that ships in a release).
- Delphi 13 conditional expressions (`X := if A then B else C`), multi-line
  string literals, attributes/RTTI-based behaviour.
- The `[ref]` attribute on its own – where a by-reference `const` is needed,
  write `{$IFDEF FPC}constref{$ELSE}const [ref]{$ENDIF}`.

Where `{$IFDEF FPC}` is accepted (and only there):
- `uses` clauses (`System.SysUtils` vs `SysUtils`, `Winapi.Windows` vs
  `Windows`).
- Managed-record operator declarations.
- `Delphi.IOUring.Atomics` internals.
- The API unit's import mechanism (FPC has no `delayed`, §6.3).

Found while porting (FPC 3.2.2), worth remembering:
- `for` loop counters cannot be 64-bit on 32-bit targets.
- A procedural variable in an expression is *called*; to pass the variable
  itself use an untyped `var` parameter (or `@@`).
- Hex literals above `High(Int64)` are read as signed: write `UInt64($…)`.
- The FPC Windows unit lacks some functions Delphi's has (`GetFileSizeEx`,
  `CancelIoEx`, `WaitOnAddress`): declare them locally.
- On x64, FPC writes a 64-bit constant that does not fit in 32 bits as two
  32-bit stores. Harmless in normal code, wrong for a value another thread
  reads at the same time – shared 64-bit values are written only through
  `TAtomic` (§10.6).
- `-O3` adds data-flow warnings ("does not seem to be initialized") that
  the default build does not show; build the tests with
  `Build-FPC.ps1 -Optimize` now and then.

No `{$IFDEF VERxxx}` for Delphi versions. Delphi 10.4–12 may work but are not
tested.

### 12.3 Other conventions

- Every unit includes `Delphi.IOUring.inc` (holds `{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}`
  and shared switches).
- OS constants as typed constants, not enums.
- Parameter style matching the existing skeletons: `A`-prefixed, `const`
  where possible; locals `L`-prefixed, fields `F`-prefixed.

---

## 13. Ideas parked for later

- Lighter record-based replacements for RTL containers, only if profiling
  asks for them (§4.2).
- Linux extras: sockets, linked SQEs, SQPOLL (only through the Posix API unit
  and capabilities).
- Read directly into the caller's buffer for big aligned reads (§7.7).

---

## 14. Open questions

1. **[DECIDE later]** Overlap handling in the engine (§11): B opt-in?
2. **[DECIDE later]** Linux backend: raw syscalls or liburing (§2.2)?
3. **[DECIDE later]** Neutral ref records vs OS-layout records (§5.1).

---

## 15. Decisions log

| # | Date | Decision |
| --- | --- | --- |
| 1 | 2026-10-22 | Only the **latest Windows IoRing version** is supported by the library (currently V4, Windows 11 24H2+). No fallback backend for older Windows; the app still loads there and `TIORing.Available` returns `False`. |
| 2 | 2026-10-22 | **Delphi 13** is the target; no version `{$IFDEF}`s. Older versions (10.4–12) may work but are not tested. |
| 3 | 2026-10-22 | **Win32 and Win64** supported; a small Win32 cost is acceptable. Linux, if it happens, **64-bit only**. Consequence: `TIORingUserData = NativeUInt`. |
| 4 | 2026-10-22 | The sequential read stream takes the **file size at open** and does not follow a growing file. |
| 5 | 2026-10-22 | **Small, specific stream classes**. First one: `TSequentialReadOnlyFileStream`, constructor takes only the options it supports. No seeking except "to the current position". |
| 6 | 2026-10-22 | No runtime backend choice → backend is a **compile-time alias** (`TIORing`), no virtual methods on the hot path. |
| 7 | 2026-10-22 | An **I/O engine** (thread/pool) and **overlap rules** are planned (§10, §11), after the first milestone. |
| 8 | 2026-10-22 | The lowest level is a **100 % API translation** in standalone `…API` units, usable by other projects, covering all IoRing versions. |
| 9 | 2026-10-22 | **Records instead of objects** where it makes sense: plain records per operation, custom managed records for resource owners, classes only where required (§4.1). |
| 10 | 2026-10-22 | **Lock-free / wait-free** algorithms (CAS etc.) for the engine's hot paths, each justified by a benchmark (§10.5). |
| 11 | 2026-10-22 | Compiler/platform order: **Delphi 13 Windows → latest FPC/Lazarus Windows → Linux via FPC**. Language baseline = what both Delphi 13 and the latest FPC support (§12). |
| 12 | 2026-10-22 | Lighter replacements for RTL containers: **idea only**, not planned until profiling shows a need (§4.2). |
| 13 | 2026-10-22 | Free Pascal tests are **separate FPCUnit test units** (`Source/UnitTests/FPC`), not a shared source with the DUnitX tests. |
| 14 | 2026-10-22 | In FPC the IoRing functions are **looked up with `GetProcAddress` on first use** (no `delayed` in FPC 3.2.2); a missing function returns `E_NOTIMPL`. |
