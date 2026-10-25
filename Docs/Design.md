# Pascal.IOUring – Design Specification

(Until Phase 28 the library was called Delphi.IOUring, and its units
`Delphi.IOUring.*`. Now the units have the prefix `PIR`: `PIRUnit.IORing`
(was `Delphi.IOUring`), `PIRUnit.Types` (was `….Backend.Custom`),
`PIRUnit.Windows.Ring` / `PIRUnit.Linux.Ring` (were `….Backend.Windows` /
`….Backend.Posix`) and so on – §12.10. The notes of earlier phases use the
new names, except the review of §12.10.)

Status: **version 0.1.0** (tagged 2026-10-25) – Milestones 1–7 complete
(Phases 1–28, [Plan.md](Plan.md)): Delphi 13 and Free Pascal 3.2.2 on
Windows (Win32, Win64), Free Pascal on Linux (x86-64, AArch64). Where the
notes are: the Windows API unit and the core ring (§5.2, §6), the sequential
reader and the streams (§7, §8), the engine, its structures and the block
reader (§10, §11), Linux (§5.7, §5.8, §6.4, §10.14), compilers, CI,
packages, demos and the later phases (§12), measurements in
[Benchmarks.md](Benchmarks.md). Things marked
**[DECIDE]**
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
`PIRUnit.Windows.API.Tests`):

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
| A write with `FILE_WRITE_FLAGS_WRITE_THROUGH` on a cached file (no `FILE_FLAG_NO_BUFFERING`) | fails with **0x800701FD** ("not supported on a file opened for cached IO"); on an unbuffered file it works (found in Phase 20) |

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
  too – **but Windows carries out their I/O one request at a time**, also
  through IoRing: 32 or 128 random 4 KiB reads in flight on a synchronous
  handle were no faster than one `ReadFile` after another (Phase 14,
  [Benchmarks.md](Benchmarks.md#blocks-known-in-advance-phase-14)). For
  parallel I/O, open files with `FILE_FLAG_OVERLAPPED`
  (`TIORingPlatform.OpenFileForRead` does).
- **[VERIFIED]** On an overlapped handle, **every** buffered read takes the
  asynchronous way (`ERROR_IO_PENDING`), even when the data is already in the
  file cache. For cached data that costs about 20–25 % more per read than a
  synchronous `ReadFile`, and IoRing reads pay it too (Phase 14, §10.10). So
  for small reads of cached data, synchronous `ReadFile` is faster than one
  IoRing thread; the engine with 2–4 I/O threads beats it (Phase 15,
  §10.12).
- **[VERIFIED]** **Writes are mostly done inside the submit call**, not in
  the background (Phase 17 probe: 2 GiB written in sequence in 1 MiB pieces,
  8 in flight, Delphi Win64):

  | Way of writing | Time inside `SubmitIoRing` | Speed |
  | --- | --- | ---: |
  | Buffered (new file or overwriting) | all of it: Windows copies into the file cache right there | ~5 GB/s, like `TFileStream`; ~2 GB/s with `FlushFileBuffers` |
  | Unbuffered, extending a new file | all of it: Windows does extending writes synchronously | 3.9 GB/s |
  | Unbuffered, file size set first (`SetEndOfFile`) | all of it (the space past the "valid data length" must be zeroed) | 4.2–4.4 GB/s |
  | Unbuffered, overwriting data that exists | 0.06 of 0.32 s: truly asynchronous | 6.5 GB/s (the disk) |

  So for writing in the background, the submit itself must happen on
  another thread – the engine's I/O thread. Truly asynchronous unbuffered
  writes to a new file would need `SetFileValidData` (an administrator
  privilege, and it exposes old disk contents): not for a library default.
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
  works with FPC without C libraries (decided in Phase 18, §6.4).
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
 │   PIRUnit.Streams   TSequentialReadOnlyFileStream               │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 2 – Helpers / engine (records where possible)                    │
 │   PIRUnit.SequentialReader  TIORingSequentialReader (record)   │
 │   PIRUnit.Engine            the I/O thread, Wait, callbacks     │
 │                                    later: more threads, overlaps       │
 │   PIRUnit.BlockReader       known blocks through the engine     │
 │   PIRUnit.Atomics           CAS / fences / wait-on-address      │
 │   PIRUnit.RequestPool       request slots, lock-free free list  │
 │   PIRUnit.RequestQueue      lock-free queue to the I/O thread   │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 1 – Core abstraction (OS independent, records)                   │
 │   PIRUnit.Types    shared types, constants, errors     │
 │   PIRUnit.Windows.Ring   TWindowsIORing (record)             │
 │   PIRUnit.Linux.Ring     TLinuxIORing (record)               │
 │   Pascal.IOUring                   TIORing = platform ring, helpers    │
 ├────────────────────────────────────────────────────────────────────────┤
 │ Layer 0 – Complete OS API translations (standalone, reusable)          │
 │   PIRUnit.Windows.API   100 % of ioringapi.h            │
 │   PIRUnit.Linux.API     100 % of linux/io_uring.h       │
 └────────────────────────────────────────────────────────────────────────┘
```

Unit responsibilities:

| Unit | Contents | Depends on |
| --- | --- | --- |
| `PIRUnit.Windows.API` | Complete translation of the Windows IoRing API (§6). Nothing else. | `Winapi.Windows` only |
| `PIRUnit.Linux.API` | Complete translation of the Linux io_uring user API (§6.4). | RTL only |
| `PIRUnit.Types` | OS-neutral types (`TIORingCompletion`, `TIORingFileRef`, `TIORingBufferRef`, flags, capabilities), `EIORingError`, shared inline helper routines | RTL only |
| `PIRUnit.Windows.Ring` | `TWindowsIORing` record, built on the Windows API unit | Types, Windows.API |
| `PIRUnit.Windows.Platform` | `TWindowsIORingPlatform`: files, memory, clock, wake event (Phase 28) | Types |
| `PIRUnit.Linux.Ring` | `TLinuxIORing` record, built on the Linux API unit | Types, Linux.API, Linux.Platform |
| `PIRUnit.Linux.Platform` | `TLinuxIORingPlatform`: the same for Linux (Phase 28) | Types |
| `PIRUnit.IORing` *(new)* | `TIORing` = the platform ring type (compile-time alias), `TIORingPlatform`, `IORingAvailable`, blocking helpers | Types + the platform's units via `{$IFDEF}` |
| `PIRUnit.SequentialReader` *(new)* | Read-ahead engine, usable without streams | `PIRUnit.IORing` |
| `PIRUnit.SequentialWriter` *(new)* | `TIORingSequentialWriter`: write-behind through an engine, usable without streams (§8.2) | `PIRUnit.IORing`, Engine |
| `PIRUnit.Streams` | `TStream` descendants: the read stream and the write stream | SequentialReader, SequentialWriter, Engine |
| `PIRUnit.Atomics` *(new)* | `TAtomic`: one place for atomics, so Delphi/FPC and x86/ARM differences live in one unit (§10.5, §10.6) | RTL only |
| `PIRUnit.RequestPool` *(new)* | `TIORingRequestPool` (request slots, states, handles, waiting) and `TIORingFreeList` (lock-free stack) (§10.3, §10.7) | `PIRUnit.IORing`, Atomics |
| `PIRUnit.RequestQueue` *(new)* | `TIORingRequestQueue`: bounded lock-free queue from the producers to an I/O thread (§10.5, §10.8) | `PIRUnit.IORing`, Atomics |
| `PIRUnit.Engine` *(new)* | `TIORingEngine`: one or more I/O threads, each with its own ring; `ReadAsync`/`WriteAsync`/`FlushAsync`, `Wait`, callbacks, batches (§10.4, §10.9, §10.12); the overlap rule `orKeepOrder` as an option (§11, §10.13) | `PIRUnit.IORing`, Atomics, RequestPool, RequestQueue |
| `PIRUnit.BlockReader` *(new)* | `TIORingBlockReader`: blocks known in advance (a provider or a list), read through the engine with read-ahead and merging, delivered in order (§10.4, §10.10) | `PIRUnit.IORing`, Engine |

The "all OS-specific code lives in the `PIRUnit.<System>.…` units" rule
still holds: the `.API` units are the raw translation, the `.Ring` unit next
to it is the library's ring on top of it, and the `.Platform` unit holds the
other OS services the upper layers need. The `PIRUnit.IORing` unit
is needed because `PIRUnit.Types` must not use the platform units (that
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
   User code reaches them through the aliases in `PIRUnit.IORing`, and Delphi
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

### 5.1 Types (`PIRUnit.Types`)

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
    NativeResult: Integer;        // 0, or the error: HRESULT on Windows, -errno on Linux (§5.7)
    BytesTransferred: NativeUInt; // the bytes (0 when failed)
    function Succeeded: Boolean; inline;
    function IsEndOfFile: Boolean; inline;   // Windows: HRESULT_FROM_WIN32(ERROR_HANDLE_EOF); Linux: a read of 0 bytes
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
- `TIORingFileRef`/`TIORingBufferRef` could alternatively be defined per
  platform with identical layout to the OS struct, saving the conversion.
  Decided in Phase 28 (§12.10): the neutral records stay – the conversion
  never showed in a benchmark.

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
    // are available or ATimeoutMilliseconds elapses. Returns number of entries submitted.
    function Submit(const AWaitCount: Cardinal = 0;
      const ATimeoutMilliseconds: Cardinal = INFINITE): Cardinal;

    // --- reap (no syscall on either platform) ---
    function TryPopCompletion(out ACompletion: TIORingCompletion): Boolean; inline;
    function PopCompletions(var ACompletions: array of TIORingCompletion): Integer;

    // --- waiting without submitting ---
    function WaitForCompletions(const ACount: Cardinal; const ATimeoutMilliseconds: Cardinal): Boolean;
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

The code (`PIRUnit.Windows.Ring.pas`, `PIRUnit.IORing.pas`) is the
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
- **`IORingReadAt` / `IORingWriteAt`** need an idle ring and raise otherwise; `IORingReadAt`
  returns 0 at or after EOF.
- `GetIoRingInfo` on a closed ring handle still returns `S_OK` (it can't be
  used to check whether a ring is open).

### 5.3 Sync vs async

There is only **one** mechanism – the async ring. "Sync" is a helper in
`PIRUnit.IORing`:

```pascal
// Blocking helpers: Prepare + Submit(wait 1) + Pop, raise on error.
function IORingReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;
function IORingWriteAt(...): Cardinal;
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
  never raises for them – helpers (`IORingReadAt`, streams) do.
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

### 5.7 The Linux ring – `TLinuxIORing` (Phase 20)

**Facts found before Phase 20** (WSL2, Ubuntu 24.04, kernel 6.18, FPC
3.2.2, 2026-10-24; more in §6.4):

- **[VERIFIED]** FPC 3.2.2 has no `eventfd` function and no system call
  number constants for `eventfd2` and `statx`: they need raw system calls
  with our own numbers, which differ per CPU (x86-64: 290 and 332; AArch64:
  19 and 291). `futex` has an RTL function (`Futex`, unit `Linux`), which
  knows the number itself.
- **[VERIFIED]** An `eventfd` registered with the ring
  (`IORING_REGISTER_EVENTFD`) works.
- **[VERIFIED]** `IORING_REGISTER_BUFFERS` accepts a sparse entry
  (address nil, length 0). Registering buffers a second time without
  unregistering fails with `-EBUSY`.
- **[VERIFIED]** `O_DIRECT` (unbuffered) works on WSL2's ext4. `statx` with
  `STATX_DIOALIGN` (Linux 6.1 and newer) reports the alignment: offsets 512,
  memory 4 here. A misaligned buffer fails.
- **[VERIFIED]** Reading a file opened write-only fails with `EBADF`
  (Windows: `E_ACCESSDENIED`).

**Phase 20 decisions (decided 2026-10-24):**

- **Two phases instead of one.** Phase 20: `TLinuxIORing`, the
  platform record, the atomics on Linux, and the shared suites that need no
  engine (atomics, request pool, request queue, ring, sequential reader,
  read stream) running on Linux. Phase 21: the engine on Linux (how its I/O
  thread sleeps and is woken), then the block reader, overlap rule and write
  stream suites, and the benchmarks on Linux. The Linux extras move to
  Phase 22.
- **`TLinuxIORing` (`PIRUnit.Linux.Ring`)** has the same public
  methods as `TWindowsIORing`, so `PIRUnit.IORing` exports it as `TIORing`:
  - `Open`: `io_uring_setup`, the completion queue at least twice the
    submission queue (`IORING_SETUP_CQSIZE`), the memory mapped once
    (`IORING_FEAT_SINGLE_MMAP`).
  - `Prepare*` only write an SQE (no system call): `IORING_OP_READ` /
    `WRITE` (`READ_FIXED` / `WRITE_FIXED` for registered buffers,
    `IOSQE_FIXED_FILE` for registered files), `FSYNC`, `READV` / `WRITEV`
    for scatter/gather, `ASYNC_CANCEL`. `sfDrainPreceding` =
    `IOSQE_IO_DRAIN`; write-through = `RWF_DSYNC`.
  - Flush modes: `rfmDefault` = fsync; `rfmData` and `rfmMinMetadata` =
    fdatasync; `rfmNoSync` = `sync_file_range` (writes the data, no flush
    command to the device).
  - `Submit` and `WaitForCompletions`: one `io_uring_enter`, with the
    timeout in `IORING_ENTER_EXT_ARG`; a timeout is not an error.
  - `CompletionEventHandle`: an `eventfd` registered with the ring, as §5.2
    planned.
  - The ring memory is shared with the kernel: the tails are written with
    `StoreRelease`, heads and tails are read with `LoadAcquire` (`TAtomic`).
  - Scatter/gather: `TIORingSegment` is an `iovec` (address and length);
    `IORingSegment(Address)` gives one page. Linux needs no unbuffered handle
    for it.
- **One meaning for `NativeResult` on both systems:** 0 = success,
  negative = error code (HRESULT on Windows, -errno on Linux); the bytes are
  always in `BytesTransferred`. (§5.1 planned "res" for Linux, with the
  byte count in `NativeResult`; then `NativeResult <> 0` would mean
  different things on the two systems.) End of file stays different:
  Windows reports a read at or after the end as an error
  (`IORING_RESULT_END_OF_FILE`), Linux as success with 0 bytes;
  `IsEndOfFile` is True for both, so callers check it first (the library
  does already). `IORING_RESULT_CANCELLED` is -ECANCELED on Linux.
- **Registration on Linux is a system call, not a ring
  operation.** `PrepareRegisterFiles` / `PrepareRegisterBuffers` register at
  once (unregister first: a second registration fails with `EBUSY`) and put
  a completion with the user data into a small list that `TryPopCompletion`
  returns first. So it takes effect at once, not in submission order as on
  Windows; a failure comes back in that completion (-errno), as on Windows.
- **Minimum Linux 5.11** (February 2021): it has everything above
  (`IORING_OP_READ` / `WRITE` 5.6, `IORING_FEAT_NODROP` 5.5, the timeout in
  `IORING_ENTER_EXT_ARG` 5.11). Older kernels, or io_uring switched off
  (`kernel.io_uring_disabled`, seccomp in containers): `Available` = False.
  Ubuntu 22.04 (5.15) and RHEL 9 (5.14) are newer; Debian 11 (5.10) is not.
- **`TLinuxIORingPlatform`**, the same names as on Windows: `open` with
  `O_DIRECT` for unbuffered and `posix_fadvise(SEQUENTIAL)` for the
  sequential hint; create with `O_CREAT or O_TRUNC`; `ftruncate`; `fstat`;
  the sector size from `statx` (`STATX_DIOALIGN`; 4096 if the kernel does
  not tell); `mmap` for page memory; `clock_gettime` for the clock.
  `munmap` needs the size, so `FreePages` gets a size parameter on both
  systems (its callers know the size).
- **Atomics on Linux:** `WaitWhileEqual`, `WakeOne` and `WakeAll` with the
  futex (private to the process). x86-64 needs nothing else. AArch64:
  acquire/release with real barriers (tested on GitHub's ARM64 runner since
  Phase 23; assembler routines since Phase 27, §12.9).
- **Tests on Linux:** `PIRUnit.Test.PlatformHelpers` gets its Linux side (files with
  a neutral set of open flags, pipes, page memory). The expected codes come
  from small helpers (for example "access denied": `E_ACCESSDENIED` on
  Windows, `-EBADF` on Linux). Tests of Windows-only behaviour stay in
  `{$IFDEF MSWINDOWS}`; Linux gets its own where it behaves differently.

**Phase 20 implementation notes** (2026-10-24):

- Built as decided: `TLinuxIORing`, `TLinuxIORingPlatform` and the Linux
  `TIORingSegment` (`PIRUnit.Linux.Ring`); `PIRUnit.IORing`
  exports them as `TIORing`, `TIORingPlatform` and `TIORingSegment`. The
  atomics sleep and wake with the futex. On AArch64 every atomic operation
  has DMB barriers around it, `CpuPause` does nothing (first run on ARM in
  Phase 23, §12.5; replaced in Phase 27, §12.9). `FreePages` has a size
  parameter on both systems.
- One change of plan: the **read stream suite moves to Phase 21**. The
  stream unit also holds the write stream, which needs the engine; rather
  than `{$IFDEF}`s in the library for one phase, the read stream tests run
  on Linux together with the engine.
- On Linux run, through the one Free Pascal test program: the ring tests
  (with 3 Linux-only ones, without the 2 Windows layout tests), the
  sequential reader, the atomics, the request pool and queue, besides the
  Linux API tests and the file helper tests: **137 tests**, with and without
  `-O3`, five runs in a row without a failure. The atomics' multi-thread
  tests pass with the futex.
- **[VERIFIED] How the kernel submits** (6.18): `io_uring_enter` stops at
  an entry that fails early – its error comes in its completion – and the
  next call goes on with the rest; `Submit` repeats the call until all
  prepared entries are in. When it submits entries, the call returns their
  number also when the wait times out; so `WaitForCompletions` decides
  "timed out" by counting the completions, not by the result code.
- The ring maps SQ and CQ with one `mmap`, and fills the SQ index array
  once at `Open` (slot I = SQE I). `Close` waits with `io_uring_enter`
  itself; it needs no event.
- `CompletionEventHandle` creates and registers the `eventfd` on its first
  call, so a ring that never asks pays nothing for it. The kernel signals it
  for every completion (Windows: when the queue goes from empty to
  non-empty).
- Scatter/gather: the ring copies the segments and cuts them to `ACount`
  bytes (the kernel would fill all of them), and keeps the copy until
  nothing is in flight; the caller's array stays as it is.
- The page size comes from `AT_PAGESZ` in `/proc/self/auxv`: FPC 3.2.2 has
  no function for it, and AArch64 systems have 4, 16 or 64 KiB pages.
- **[VERIFIED] on Linux** (6.18, WSL2, ext4): a cancelled pipe read
  completes with `-ECANCELED`; all four flush modes and write-through
  (`RWF_DSYNC`) succeed; a reader that leaves its scope closes its file
  (checked by counting `/proc/self/fd`, because Linux deletes open files
  too); the 100 MiB unbuffered read of the tests takes about 64 ms.
- **[VERIFIED] on Windows**, found by the new flush test:
  write-through needs an unbuffered file (§2.1). The test now writes through
  on an unbuffered file, on both systems.

### 5.8 Linux extras – sockets, linked operations, SQPOLL (Phase 22)

§2.3 keeps everything outside the common subset out of the core
abstraction: Windows IoRing has no sockets, no links and no polling thread.
The Linux API unit (§6.4) already has all of it – every opcode,
`IOSQE_IO_LINK`, `IORING_SETUP_SQPOLL` – but only for someone who builds a
ring of their own: `TLinuxIORing` has no way to put any other operation into
its queue, no way to link two entries, and `Open` takes no setup flags.
Phase 22 decides how much of it `TLinuxIORing` opens up. Nothing changes for
Windows, and the higher layers (reader, engine, streams) stay as they are.

**Facts found before Phase 22** (WSL2, kernel 6.18, a raw ring, 2026-10-24):

- **[VERIFIED]** Every setup flag tried works without root: SQPOLL (allowed
  since Linux 5.11), `SINGLE_ISSUER`, `COOP_TASKRUN`, `SINGLE_ISSUER` +
  `DEFER_TASKRUN`. The probe lists every socket operation (`SEND`, `RECV`,
  `ACCEPT`, `CONNECT`, `SENDMSG`, `RECVMSG`, `SEND_ZC`, `SOCKET`,
  `SHUTDOWN`); the kernel knows opcodes up to 62.
- **[VERIFIED] SQPOLL gains nothing here, and costs CPU time.**
  - Cached 4 KiB reads, one at a time: a normal ring 0.51 µs per read;
    SQPOLL, waiting in `io_uring_enter`: 12 µs (two threads hand over every
    read); SQPOLL, spinning on the completion queue: 0.64 µs, with 2.6× the
    CPU time. 32 at a time: normal 0.35 µs, SQPOLL spinning 0.44 µs with
    about 3× the CPU time.
  - Unbuffered (`O_DIRECT`) random 4 KiB reads, 32 or 128 in flight: the
    same number of reads per second (125–180 thousand; the noise between two
    runs is bigger than the difference), with 4–10× the CPU time – the
    polling thread.
  - `SINGLE_ISSUER` + `DEFER_TASKRUN`: as fast as a normal ring. With
    `DEFER_TASKRUN` the kernel posts completions only while the ring's
    thread waits in `io_uring_enter`; the engine, which pops completions
    without waiting, would not see them.
- **[VERIFIED] Linked operations** work as documented: a write linked to an
  `fsync` – both succeed, in order. When a linked operation fails – a short
  read (4 of 8 bytes) counts as a failure – the next one completes with
  `-ECANCELED`. With a hard link (`IOSQE_IO_HARDLINK`) the next one runs
  anyway.
- **[VERIFIED] Sockets through the ring:** on a socket pair a `RECV` waits
  in the ring until a `SEND` comes; on TCP loopback `ACCEPT` (its result is
  the new descriptor) and `CONNECT` both complete through the ring.
- A completion of `TLinuxIORing` has the user data, the error code and the
  result; the CQE flags are not passed on. The ring counts one completion
  per entry. Multishot operations (several completions per entry, flag
  `IORING_CQE_F_MORE`), zero-copy send (two completions) and
  `IOSQE_CQE_SKIP_SUCCESS` (none on success) break that count.

**Phase 22 proposal:**

- **[DECIDE] 1. A door for any operation, and linking.** Proposed (A):
  - `TLinuxIORing.PrepareSqe(AUserData, out ASqe): Boolean` gives the next
    entry of the submission queue, zeroed and with the user data set,
    counted like the other Prepare methods (False: no room). The caller
    fills in the rest with the API unit's names – any operation: sockets,
    timeouts, opening and closing files, poll … For a registered file the
    caller sets `IOSQE_FIXED_FILE`.
  - `TLinuxIORing.LinkToNext(AHard = False)` links the entry prepared last
    to the next one (`IOSQE_IO_LINK` / `IOSQE_IO_HARDLINK`). It works with
    the ring's own Prepare methods too – for example a write linked to its
    flush. Both entries must go to the kernel in the same `Submit`.
  - The rule: one entry, one completion – no multishot, no zero-copy send,
    no `IOSQE_CQE_SKIP_SUCCESS`. Documented; the ring cannot check it.
  - Both are Linux-only: code that uses them is Linux code
    (`{$IFDEF LINUX}`).

  Other choices: (B) the same plus typed socket methods (`PrepareSend`,
  `PrepareRecv`, `PrepareAccept`, `PrepareConnect`) – a few lines each on
  top of A, easy to add later when someone needs them; (C) also multishot:
  the CQE flags in the completion and a count that knows
  `IORING_CQE_F_MORE` – needs a Linux field in the shared completion
  record; later, if ever.
- **[DECIDE] 2. SQPOLL stays in the API unit.** Proposed (A):
  `TLinuxIORing` gets no setup options. Measured: no gain for file I/O and
  much more CPU time. In the ring it would need a second way to submit
  (wake the polling thread, and check the kernel's queue head before an
  entry is used again). Documented, with a test that a SQPOLL ring set up
  through the API unit works. Other choice (B): `Open` takes a Linux-only
  SQPOLL option (and its idle time) and `TLinuxIORing` handles it – for
  network servers with very high rates, which were not measured here.
- **[DECIDE] 3. Capabilities: a Linux-only record.** Proposed (A):
  `TLinuxIORing.QueryLinuxCapabilities` returns the kernel's feature bits
  (`io_uring_params.features`), the probe of all opcodes
  (`OpSupported(AOpcode)`) and whether SQPOLL may be used (a setup tried
  once). The shared `TIORingCapabilities` stays as it is – it describes the
  common subset. Other choice (B): native fields in the shared record
  (feature bits and opcodes of either system; Windows has
  `IORING_FEATURE_FLAGS` and `IsIoRingOpSupported`).
- Tests (Linux only): sockets through `PrepareSqe` (a socket pair; accept
  and connect on loopback; a waiting receive cancelled); a write linked to
  its flush; a failed link (the next one `IsCancelled`); a hard link;
  `LinkToNext` with nothing prepared (raises); the capabilities; in the
  API tests, a SQPOLL ring.
- Docs: a README section "Linux extras" with a socket example; the SQPOLL
  numbers in Benchmarks.md.
- Not in this phase: sockets in the shared `TIORing` or in the engine
  (Windows has none), AArch64 (no ARM machine yet).

**Phase 22 decisions (decided 2026-10-24):**

- **1 as proposed (A):** `PrepareSqe` and `LinkToNext` in the low-level
  `TLinuxIORing`, even though the higher layers do not use them yet.
- **2 as proposed (A):** SQPOLL, and all the other definitions, stay in the
  API unit, for extensions of the library or other code later.
- **3 changed: the capabilities move to the shared level**, not a Linux-only
  record. Windows and Linux will always differ, and Linux systems differ a
  lot among themselves (distribution, kernel, what is switched off), so one
  record describes either system. `TIORingCapabilities` gets:
  - `SystemDescription` – the system for logs and bug reports (Windows:
    version and build; Linux: the distribution from `/etc/os-release` and
    the kernel release);
  - `NotAvailableReason` – why the ring cannot be used ('' if it can);
  - `NativeFeatures` – the feature bits of the system's ring API (Windows
    `IORING_FEATURE_FLAGS`, Linux `io_uring_params.features`);
  - `NativeOps` – the system's opcodes that the kernel supports, a
    `set of Byte` (Windows `IsIoRingOpSupported`, Linux the probe);
  - `Extras` – what the system offers beyond the common subset, as a
    cross-platform set: `ieSockets`, `ieLinkedOps`, `ieSqPoll`,
    `ieRawEntries` (Windows: none);
  - `ToString` – all of it in a few lines.

  `PIRUnit.IORing` gets `IORingCapabilities`, next to `IORingAvailable`.

**Phase 22 implementation notes** (2026-10-24):

- Built as decided. `PrepareSqe` uses the same room check as the other
  Prepare methods; `LinkToNext` sets the flag on the entry prepared last,
  which is still in the submission queue (raises when nothing is prepared:
  on a closed ring, before the first Prepare, after `Submit`). The flag is
  OR-ed in, so it must come after the Prepare call (the Prepare methods set
  the entry's flags).
- Capabilities, Linux: the opcodes and the feature bits come from the probe
  that the availability check already does; the SQPOLL check (one setup
  with `IORING_SETUP_SQPOLL`) runs only when the capabilities are asked for,
  because it starts a kernel thread; the distribution comes from
  `PRETTY_NAME` in `/etc/os-release` (or `/usr/lib/os-release`).
  Windows: `RtlGetVersion` for the version (it is not lied to like
  `GetVersionEx` without a compatibility manifest; Windows 11 still says
  10.0, so builds from 22000 on are called Windows 11), and the opcodes from
  `IsIoRingOpSupported` on a small ring, once.
- **[VERIFIED]** on Linux (WSL2, 6.18): everything in the facts above, now
  through `TLinuxIORing`: a receive waits in the ring until the send, accept
  returns the new descriptor, connect, data both ways over TCP, a waiting
  receive cancelled; a write linked to its flush completes first; a failed
  or short read cancels the linked entry (`IsCancelled`), a hard link does
  not; a read of a registered file through `PrepareSqe` with
  `IOSQE_FIXED_FILE`. A SQPOLL ring through the API unit, also after its
  thread has gone to sleep (the wake-up flag).
- Tests: 11 Linux-only tests (`PIRUnit.Linux.Extras.Tests`), a SQPOLL test in the
  API tests, and a shared capabilities test (both systems).
- Found on the way: `ioringapi.h` numbers the IoRing versions 1, 2, 300,
  400, so `NativeVersion` is 400 for version 4; `ToString` says "version 4".
  Windows reports 9 opcodes (0–8) and feature bits $2
  (`IORING_FEATURE_SET_COMPLETION_EVENT`).

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

### 6.4 Linux API unit (Phase 18)

Same rules: complete translation of the `linux/io_uring.h` user API of a
pinned kernel version (all opcodes, SQE/CQE layouts, setup/enter/register
flags, `io_uring_params`, offsets structs, register opcodes, feature flags),
plus the three syscall wrappers. x86-64 and AArch64 only.

**Facts found before Phase 18** (WSL2, Ubuntu 24.04, kernel 6.18, FPC 3.2.2,
2026-10-23):

- **[VERIFIED]** FPC calls the kernel directly: `do_SysCall(425, …)` (unit
  `Syscall`) returned a ring; a Pascal `io_uring_params` record has the C
  size (120 bytes). No C library is needed.
- `liburing` is not installed by default, and its `io_uring_prep_*` helpers
  are C inline functions in its header – Pascal cannot call them anyway.
- `io_uring` is enabled (`kernel.io_uring_disabled` = 0). The installed
  header is the one of kernel 6.8 (`linux-libc-dev`, Ubuntu 24.04 LTS); the
  running kernel reports 18 feature bits, the 6.8 header names 14.
- gcc 13 is installed: layout tests can be checked against the real header.

**Phase 18 decisions (decided 2026-10-23):**

- **Raw system calls, no `liburing`** (closes open question 1 in §14): the
  unit wraps the three system calls with FPC's `do_SysCall`. The few helpers
  that `liburing` has in C (preparing an SQE, reading the rings with the right
  memory barriers) are written in Pascal in Phase 20, where `TLinuxIORing`
  needs them.
- **Pinned header: Linux 6.8** – the one installed with Ubuntu 24.04 LTS, so
  every record and constant can be checked against it on this machine. What
  newer kernels added (4 more feature bits, a few opcodes and register
  codes) can follow with a newer pin; the generated layout tests (below)
  make that cheap. The core subset (§2.3) needs nothing newer than 5.11.
- **`PIRUnit.Linux.API`, standalone** like the Windows unit:
  original C names; `{$PACKRECORDS C}`; C unions as variant parts of records;
  all constants, enums, flags and records of the header; the mmap offsets
  (`IORING_OFF_SQ_RING`, …); the wrappers `io_uring_setup`, `io_uring_enter`
  and `io_uring_register` return the kernel's result (`-errno` on failure)
  and raise nothing. FPC only (Linux goes through FPC, decision 11), x86-64
  and AArch64; the system call numbers are the same on both.
- **Layout tests generated from the C header:** a small C program, built
  with gcc on Linux, writes the size of every record, the offset of every
  field and the value of every constant into a Pascal include file, which
  is kept in the repository. The FPCUnit test compares the unit against it.
  A new pin = run the generator again.
- **Live tests:** set up a ring with its parameters, map its memory, send a
  no-op through it, register files and buffers, ask the kernel which
  opcodes it has (`IORING_REGISTER_PROBE`), and the error cases (for
  example 0 entries: `-EINVAL`).
- **A Linux test program:** `Pascal.IOUring.UnitTests.Linux.lpr` (FPCUnit;
  the Windows test project uses Windows calls throughout). `Build-FPC.ps1`
  gets `-Platform Linux64`, which compiles and runs it inside WSL, so the
  same script builds everything.
- **AArch64:** the unit is written for it (the same system call numbers;
  the records have no pointer-size differences); tested on GitHub's ARM64
  runner since Phase 23 (§12.5).

**Phase 18 implementation notes** (2026-10-23):

- Built as decided: `PIRUnit.Linux.API` (Free Pascal, Linux,
  x86-64 and AArch64; only the RTL units `BaseUnix` and `Syscall`). The test
  program is `Source/UnitTests/Linux/Pascal.IOUring.UnitTests.Linux.lpr`:
  `Build-FPC.ps1 -Project Tests -Platform Linux64 -Run`.
- How C maps to Pascal: a union is the variant part of a record; the fields
  after a union are inside its last variant, so every member keeps its C
  name (`sqe.off`, `sqe.rw_flags`, …). `io_sqring_offsets.array` is
  `&array` (a reserved word). Flexible arrays that would change `SizeOf`
  (`io_uring_cqe.big_cqe`, `io_uring_probe.ops`) are not fields; they start
  right after the record.
- **[VERIFIED] FPC aligns a variant part to the largest field in it – also
  the fields that come after the union** (they are inside its last variant).
  C aligns a union only to its own members. So FPC moved the flags union of
  `io_uring_sqe` from offset 28 to 32 (`user_data`, 8 bytes, follows it),
  and the union of `io_uring_restriction` from 2 to 4. These two records are
  `packed`: C has no gaps in them, so packed gives the C offsets. The
  generated layout tests found this on their first run. The live tests
  failed too (wrong `user_data`, a timeout that did not wait), but a read
  that uses only `off`, `addr` and `len` worked: a wrong layout can look
  fine in a simple test.
- **[VERIFIED]** FPC's `do_SysCall` returns -1 and sets `errno` on failure.
  The wrappers give back `-errno`, the kernel's own form (as liburing does).
- The layout checks: `Generate-LinuxApiLayout.sh` (bash and gcc, on Linux)
  reads the header and stops if `LinuxApiLayout.c` misses a constant, record
  or field of it (6.8: 200 constants, 20 records, 147 fields). Then the C
  program writes 373 checks (sizes, offsets, values) into
  `PIRInclude.Linux.API.Layout.inc`; the output is the same on
  every run. A name the Pascal unit does not have does not compile. A new
  header pin: run the script and add what it reports.
- **[VERIFIED] what the kernel does** (6.18 in WSL2; the live tests):
  - `io_uring_setup` rounds the entries up to a power of two, and the CQ is
    twice as big; `IORING_SETUP_CQSIZE` is rounded up too (100 → 128).
    0 entries, an unknown flag or a non-zero `resv` give `-EINVAL`; more
    than 32 768 entries give `-EINVAL`, and with `IORING_SETUP_CLAMP`
    32 768 (CQ 65 536).
  - Features `$3FFFF`: the 14 that the 6.8 header names and 4 newer ones.
    The probe reports `last_op` 62: 63 opcodes, all supported (the 6.8
    header has 55).
  - A request with a bad file descriptor is submitted; its error (`-EBADF`)
    comes in its CQE. The same for an empty slot of the registered files
    (`-EBADF`) and for `IORING_OP_READ_FIXED` outside the registered buffer
    (`-EFAULT`).
  - A read at the end of the file completes with 0 bytes; a read across the
    end with the bytes up to the end.
  - `io_uring_enter` on a file that is not a ring: `-EOPNOTSUPP`; on a bad
    descriptor: `-EBADF`. `io_uring_register` with an unknown opcode:
    `-EINVAL`.
  - Waiting with `IORING_ENTER_EXT_ARG` and a timeout, and
    `IORING_OP_TIMEOUT`, end with `-ETIME`.
- **[VERIFIED] AArch64** (Phase 23, GitHub's ARM64 runner): the Linux tests
  build and pass there, the layout tests included, and the generator gives
  the same 373 checks (only its comment lines differ). Still to look at:
  the code FPC makes for the fields of the two packed records – it may load
  them byte by byte if it thinks they could be unaligned.

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
    property Stats: TIORingSequentialReaderStats;  // plain record: reads issued, bytes, stalls, wait time
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
   *Done in Phase 26 (§12.8): the part of a call beyond what the buffers
   have asked for is read straight into the caller's memory.*
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

The code (`PIRUnit.SequentialReader.pas`) is the reference; where it
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

- `PIRUnit.Streams`. The stream overrides `Read`/`Write` for `Longint`
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

### 8.2 `TSequentialWriteOnlyFileStream` – Phase 17 decisions

Write-behind: `Write` copies into a buffer; a full buffer is written in the
background while the caller fills the next one.

**Through the engine, not an own ring.** Windows does buffered writes, and
unbuffered writes that extend a file, *inside* the submit call (§2.1). A
writer that submitted on the caller's thread – as the read stream does with
its own ring – would do all the work there itself. So full buffers go to an
engine (`WriteAsync`), and its I/O thread does the submit while the caller
goes on.

- By default the writer makes **its own engine** (1 I/O thread, requests =
  buffer count + 2). Or it takes a **shared engine** (not owned) – for many
  files at once. *(Decided 2026-10-23.)*
- Its own writes never overlap, so it needs no overlap rule. A program that
  reads the file back while it is being written gives a shared engine with
  `orKeepOrder`.

**Two parts, as on the read side:**

- `TIORingSequentialWriter` (unit `PIRUnit.SequentialWriter`): a
  managed record that does the work.
- `TSequentialWriteOnlyFileStream = class(TStream)` in
  `PIRUnit.Streams`, a thin wrapper.

```pascal
type
  TIORingSequentialWriterOption = (
    swoUnbuffered      // FILE_FLAG_NO_BUFFERING: past the file cache
  );
  TIORingSequentialWriterOptions = set of TIORingSequentialWriterOption;

  TIORingSequentialWriter = record
    // Creates the file, or empties it if it exists. AEngine = nil: an own engine
    procedure Open(const AFileName: string; const AOptions: TIORingSequentialWriterOptions = [];
      const ABufferSize: Cardinal = 1024 * 1024; const ABufferCount: Cardinal = 8;
      const AEngine: TIORingEngine = nil);
    // Copying API (used by the stream): full buffers go out at once
    procedure Write(const ABuffer; const ACount: NativeInt);
    // Zero-copy API: the free part of the current buffer; fill it, then say how much
    procedure AcquireBuffer(out AData: PByte; out ACapacity: NativeInt);
    procedure CommitBuffer(const ALength: NativeInt);
    // Sends the partly filled buffer and waits for all writes; AToDisk: also
    // FlushFileBuffers (slow: 2 instead of 5 GB/s in the probe)
    procedure Flush(const AToDisk: Boolean = False);
    // Flush(False), cut the file to its size (unbuffered), close
    procedure Close;
    property Position: Int64;      // bytes accepted
    property Stats: TIORingSequentialWriterStats;   // writes, bytes, waits for a free buffer
  end;
```

**Errors.** `Write` returns before the data is written, so a failed write
(for example a full disk) can only be reported later. The first failure is
kept – the error and the file offset – and raises **`EWriteError`** (an
`EStreamError`, as with `TStream.WriteBuffer`) at the next `Write`, `Flush`
or `Close`, and again at every later call: after a failed write the file's
content is unknown. **`Free` raises too**, if a failure was never reported –
after it has released everything. `TBufferedFileStream.Destroy` behaves the
same; the safe way is `Flush` before `Free`. *(Decided 2026-10-23.)*

**The stream.** `Create(AFileName, …)` and `Create(AFileName, AEngine, …)`;
it creates the file or empties it, like `TFileStream.Create(…, fmCreate)`,
and other programs may read it meanwhile, not write. A file that cannot be
created raises `EFCreateError` with `TFileStream`'s message. `Read` raises;
`Seek`/`Position` only to the current position (as in the read stream);
`Size` = `Position`; `SetSize` raises; `Flush(AToDisk)` is public. `Free`
waits for all writes but does not flush to the disk – like `TFileStream`:
the data is in the file cache, and Windows writes it soon.

**Unbuffered** (`swoUnbuffered`): the buffer size must be a multiple of the
sector size (checked). The last, partly filled buffer is written rounded up
to whole sectors, and `Close` cuts the file to its real size. It leaves the
file cache alone (for huge files) and was faster to the disk than buffered
writing plus `FlushFileBuffers` in the probe (3.9–4.4 against 2 GB/s).

**Left out of the first version:** appending to an existing file; setting
the expected size first (+10 % for unbuffered writes in the probe, nothing
for buffered); `SetFileValidData` (an administrator privilege); writing at
other positions (that is what the engine is for).

**Tests:** written data read back – sizes around the buffer size (0, 1, size
– 1, size, size + 1, many MiB), pieces from 1 byte to several buffers; the
zero-copy API; `Flush` and `Flush(True)`; unbuffered with a cut last buffer;
a failed write raises at the next call, again later, and at `Free` (writing
through a handle without write access gives a failing write); several
writers on one shared engine; `TStream` use: `CopyFrom`, `TStreamWriter`,
`SaveToStream`; `Position`/`Seek` rules; `EFCreateError`.

**Benchmark:** 1 and 10 GiB against `TFileStream` (64 KiB and 1 MiB writes)
and `TBufferedFileStream`; only writing, and with 200 µs of CPU work per MiB;
time until `Free` returns, and with `FlushFileBuffers`. Expected, honestly:
with nothing else to do, no gain – one thread copies into the file cache
either way, and the stream's own copy costs a little. The gain comes with
work: the writing then happens while the program works. Unbuffered writing
also keeps the file cache free.

#### Implementation notes (Phase 17)

Built as decided above: `PIRUnit.SequentialWriter` (the record) and
`TSequentialWriteOnlyFileStream` in `PIRUnit.Streams`. Where the code
adds to the decisions:

- **Buffers in turn.** The buffers in flight are always the oldest ones,
  followed by the one being filled. So a free buffer is always the next one
  after the writes in flight, "wait for a buffer" is "wait for the oldest
  write", and finished writes are collected oldest first, after every full
  buffer, at almost no cost (`TryGetResult` until the first unfinished one).
- **`Flush` with a partly filled buffer** writes that part (unbuffered:
  rounded up to whole sectors, the rest zeroed, then the file is cut to its
  size) and waits for it – but the buffer stays the current one. When it is
  full, it is written again, whole, at the same offset. So every write still
  starts where a buffer starts (sector-aligned for unbuffered writes); the
  price is that at most one buffer per `Flush` is written twice.
- **Errors:** the record raises `EIORingError` (with the Windows error code),
  like the reader and the engine; the stream turns it into `EWriteError`.
  `Write`, `CommitBuffer` and `Flush` raise a kept failure every time;
  `Close` raises it after it has released everything. The record's
  automatic cleanup at the end of scope (`Finalize`) still writes the rest but
  cannot raise. `ErrorReported` tells whether the failure has been raised
  once; the stream's destructor raises only if not.
- **A destructor that raises** leaves the object's own memory unfreed in
  Delphi (the compiler frees it only after a destructor that returns); the
  stream releases everything else first. The test frees it by hand with
  `FreeInstance`.
- **New platform calls:** `TIORingPlatform.CreateFileForWrite` (create or
  empty, write access, others may read, overlapped, optionally unbuffered)
  and `SetFileSize` (`SetFileInformationByHandle`, which works on overlapped
  handles).
- **Its own engine:** one I/O thread, buffer count + 2 requests, so starting
  a write never waits for a free request. A shared engine must allow at least
  as many requests as the writer has buffers (checked).

**Tests:** `PIRUnit.SequentialWriter.Tests` (DUnitX) and `Tests.FPC.SequentialWriter`
(FPCUnit), 25 each:

- **The record (16):** sizes around the buffer size (0, 1, size – 1, size,
  size + 1, many buffers, 1 MiB + 5) with 3 buffers used again and again;
  pieces from 1 byte to 50 000; 20 MiB with the default buffers; the
  zero-copy API with 0, all and parts of the buffer; `Flush` puts a partly
  filled buffer into the file and the next writes follow it; `Flush(True)`;
  unbuffered with a cut last buffer, and with a `Flush` in between; failed
  writes (a byte-range lock on the file through a second handle makes
  Windows refuse them) – a later `Write` raises, `Flush` raises and again,
  `Close` raises; bad arguments; wrong call order; the end of scope still
  writes the rest; stats; 4 writers in parallel on one shared engine.
- **The stream (9):** `WriteBuffer` and `CopyFrom`; `TStringList.SaveToStream`
  (20 000 lines); `Position`, `Size` and `Seek`; `Read` and `Size :=` raise;
  `EFCreateError`; a failed write raises `EWriteError` at `Flush` and later,
  and then `Free` does not; a failure never seen raises at `Free`; a shared
  engine; unbuffered.

All pass with Delphi Debug and Release and FPC with and without `-O3`, Win32
and Win64, and the Delphi tests report no memory leak.

**Benchmark** (Benchmarks.md, "Writing"): writing alone gains nothing, as
expected – Windows copies into the file cache in one thread either way.
With 200 µs of work per MiB, a 1 GiB file was written 25–45 % sooner than
with `TFileStream` (10 GiB: 3–21 %; there Windows slows every writer down to
the disk's speed). Unbuffered, the data is on the disk soonest (1 GiB in
0.26–0.55 s against 0.62–0.96 s buffered plus a flush) and with a third of
the CPU time.

### 8.3 Later stream classes (each its own specific class)

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
| Only work whose future blocks are **known in advance** benefits (seq scans, bitmap scans, VACUUM); single-block OLTP lookups stay synchronous. Writes stayed synchronous in v18. | Same honesty for us: async is for read-ahead and batches. A single blocking `IORingReadAt` is not faster than `ReadFile`. |
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
- Built in Phase 11 (`PIRUnit.RequestPool`); details in §10.7.

### 10.4 Engine APIs (sketch)

**Phase 13 decisions (2026-10-22, before coding; for review)** – built as
written; implementation notes and findings in §10.9:

- `TIORingEngine` (class, unit `PIRUnit.Engine`):
  `Create(AMaxRequests = 1024, ASubmissionQueueSize = 256)` – request pool of
  `AMaxRequests` slots, request queue of the same size (so enqueue never
  fails), one ring, one I/O thread.
- `ReadAsync(AFile: THandle; var ABuffer; ACount; AOffset; AUserData = 0;
  AOnComplete = nil): TIORingRequestHandle`, `WriteAsync(… const ABuffer …)`,
  `FlushAsync(AFile; AMode = rfmDefault; …)`. Buffer and handle must stay
  valid until the request completes. When all slots are in use, the call
  sleeps until one is free (slot-release counter + `WaitWhileEqual`).
- `Wait(H, out ACompletion: TIORingCompletion, ATimeout): Boolean` – returns
  the result (`UserData` = the caller's value) and frees the slot; False =
  timeout (handle stays valid); stale handle raises `EIORingError`. Also
  `TryGetResult` (timeout 0) and `WaitAll`.
- `AOnComplete: procedure(const ACompletion: TIORingCompletion) of object` –
  runs on the I/O thread; the request then frees itself and the call returns
  an empty handle. Exceptions in it are caught and counted.
- `BeginBatch` / `EndBatch` (per thread, threadvar): requests started in
  between do not wake the I/O thread; `EndBatch` wakes it once, so they go to
  the ring in one submit.
- Payload per slot: operation, flush mode, file handle, buffer, count,
  offset, caller's `UserData`, callback, result code, bytes, position in the
  I/O thread's in-flight list.
- I/O thread loop: take requests from the queue and prepare them (one that
  does not fit waits in a "deferred" slot) → one `Submit(0)` → pop all
  completions → sleep only if nothing happened: set the sleeping flag with
  `Exchange`, look at the queue once more, then
  `WaitForMultipleObjects({wake event, ring completion event})`. Producers set
  the wake event only if they `Exchange` the sleeping flag from 1 to 0.
- `Destroy`: stop accepting requests (counter of threads inside the start
  calls), cancel queued requests without starting them, `PrepareCancel` every
  request in the ring (cancel operations use `UserData` 0), wait for all
  completions, then let threads still in `Wait` (they wake with "cancelled")
  leave (counter) before freeing the pool. Cancelled =
  `HRESULT_FROM_WIN32(ERROR_OPERATION_ABORTED)` (new constant
  `IORING_RESULT_CANCELLED` and `TIORingCompletion.IsCancelled`).
- Stats (written by the I/O thread, read with `LoadAcquire`): requests,
  completed, failed, cancelled, submits, sleeps, callback errors.
- Not in Phase 13: cancelling one request, registered files/buffers. Known
  limit: if the ring itself fails (a system call error, not an I/O error),
  the I/O thread stops.

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

**Phase 14 decisions (2026-10-23, before coding; for review)** – the read
stream with a block provider:

- `TIORingBlockReader` (unit `PIRUnit.BlockReader`): a managed
  record like `TIORingSequentialReader`, used by one thread, reading through
  a shared `TIORingEngine` (not owned) from a file handle (not owned).
- **Callback or list: both.** The core is a provider,
  `TIORingBlockProvider = function(out ABlock: TIORingBlock): Boolean of
  object` (`TIORingBlock` = offset + length; False = no more blocks), called
  on the reader's thread, at most one block ahead of what has been sent to
  the engine. It suits blocks that are found while reading (an index, a
  tree). A plain list is the second `Open` (the blocks are copied).
- `Open(AEngine, AFile, AProvider or ABlocks, AReadAhead = 32,
  ABufferSize = 256 KiB, AMaxGap = 0)`: `AReadAhead` buffers of
  `ABufferSize` bytes, one read in flight per buffer. A block may be at
  most `ABufferSize` long (`EIORingError` otherwise). The engine must allow
  at least `AReadAhead` requests.
- **Merging:** the next block joins the current read if it starts at or
  after the read's end, at most `AMaxGap` bytes after it, and the read then
  still fits into one buffer. Blocks that overlap or go backwards start a new
  read. Scatter reads (one read into several buffers) are left out: they need
  unbuffered handles and sector-aligned blocks.
- `TryGetBlock(out ABlock, out AData, out ALength, AWait = True): Boolean` –
  the next block **in the provider's order**, zero-copy (valid until
  `ReleaseBlock`). `ALength` is shorter than the block only at the end of
  the file (0 for a block that starts at or after it). False: no more blocks
  (`Finished`), or with `AWait = False` the data is not there yet. A failed
  read raises `EIORingError`.
- New reads are started as buffers become free, all of one round in one
  engine batch (one wake-up). `Close` waits for the reads in flight.
- Stats: blocks, reads (merged blocks count once), bytes, stalls, stall time.
- Benchmark (Plan): blocks known in advance, random 4 KiB (and sorted, mixed
  sizes), cold and warm cache, against `TFileStream` + `Seek` and positioned
  `ReadFile`.

**Phase 15 decisions (2026-10-23, before coding)** – several I/O threads.
Why: Windows does the work of a request inside `SubmitIoRing`, in the
submitting thread – about 7.5 µs per unbuffered 4 KiB read here (§10.11) – so
one I/O thread cannot go beyond about 130 thousand such reads per second.
Only more submitting threads help. (With buffered reads of data that comes
from the disk, Windows' cache path is the limit first. That more threads
also help with *cached* data was found only in the Phase 15 benchmark.)

- **The engine owns its I/O threads**; users register nothing. The number is
  fixed for the engine's life: `Create(AMaxRequests, ASubmissionQueueSize,
  AIOThreads = 1)`. Default 1: it costs nothing extra, and it is enough for
  data that comes from the disk through the file cache. No automatic number
  for now: no measured rule for it yet.
- **Each I/O thread has its own ring**, "new requests" event and list of
  requests in flight. **All take requests from the one shared request
  queue** (it is safe for many consumers, §10.8), so the load spreads by
  itself. The pool is shared: handles, `Wait`, `TryGetResult` and callbacks
  stay as they are. A callback runs on the I/O thread that completed its
  request.
- **Waking:** a producer wakes an I/O thread only when *all* of them sleep,
  and then only one. An I/O thread with siblings takes at most
  `IORING_ENGINE_SHARE_SIZE` (16) requests per round; if more are waiting, it
  first wakes one sleeping sibling. So a light load stays on one thread (few
  wake-ups), and a single busy producer can still use all of them. Before an
  I/O thread sleeps with a full ring, it also wakes a sibling if requests are
  waiting.
- **Destroy:** every I/O thread cancels the requests in its own ring; the
  queued ones are cancelled by whichever thread takes them.
- `Stats` adds up the I/O threads; `IOThreadStats(AIndex)` gives one;
  `IOThreadCount`; `IsIOThread(AThreadId)` replaces `IOThreadId`.
- Left out: routing the requests of one file to one I/O thread – only Phase
  16's overlap rules would need it, so Phase 16 decides.

### 10.5 Lock-free hand-over between threads

Locks are used only on cold paths (start-up, registration changes,
shutdown). On the hot path:

| Where | Technique |
| --- | --- |
| Producers → I/O thread | **Bounded MPSC/MPMC array queue** with a sequence number per cell (Vyukov style): producers claim a cell with one CAS on the tail counter, the I/O thread reads without CAS. No allocation, fixed memory. **Built in Phase 12 as a full MPMC queue (the consumer uses one CAS too), with backoff; it beats an SRW-lock queue everywhere** (§10.8, [Benchmarks.md](Benchmarks.md#request-queue-phase-12)). |
| Request pool free list | **Lock-free stack** (Treiber) of slot indices. ABA problem solved with a tag/generation in the same word as the index, swapped with one CAS (64-bit CAS on Win32 = `CMPXCHG8B`). Optional per-thread small cache of free slots to avoid contention. **Built in Phase 11, with exponential backoff; it wins or ties against an SRW lock in every case measured** (§10.7, [Benchmarks.md](Benchmarks.md#engine-structures-phase-11)). The per-thread cache is not needed so far. |
| I/O thread → waiting producer | Per-request **state word**. The waiter spins briefly, then sleeps with `WaitOnAddress` (Windows) / `futex` (Linux). The I/O thread calls `WakeByAddressSingle` only if the "someone is waiting" bit is set – no syscall when nobody sleeps. |
| I/O thread sleeping | Waits on {request-queue signal, ring completion event}. Producers signal only when the I/O thread has announced it is going to sleep (a flag set with CAS), so a busy engine costs producers no syscall. **Built in Phase 13** (§10.9). |
| Counters / stats | Owned by one thread where possible; otherwise atomic increments on counters padded to their own **cache line** (64 bytes) to avoid false sharing. Queue head/tail counters are padded the same way. |

All atomics go through one small unit, `PIRUnit.Atomics` (CAS,
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

`PIRUnit.Atomics` has one type, `TAtomic`: a record with only static
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
Constants: `IORING_CACHE_LINE_SIZE = 64`, `IORING_INFINITE`.

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

Tests: `PIRUnit.Atomics.Tests` (DUnitX) and `Tests.FPC.Atomics` (FPCUnit), 20 each:
every method for every type (64-bit values have different upper and lower
halves); counters from 4 threads that must come out exact; the half-write
test; release/acquire hand-over of data 100 000 times; the spin-loop test;
wait timeout, wake one, wake all; ping-pong without lost wake-ups. They pass
with Delphi Debug and Release, and with FPC with and without `-O3`
(`Build-FPC.ps1 -Optimize`), Win32 and Win64.

### 10.7 Request pool – implementation notes (Phase 11)

`PIRUnit.RequestPool` has two managed records (copying one raises,
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
| `WaitFor(H, Timeout)` | Checks the state for `SpinMicroseconds` (default 4 µs, with CPU pauses; until Phase 15: 100 pauses – §10.11), then sets the waiting flag and sleeps on the state word (`TAtomic.WaitWhileEqual`). Timeout 0 only checks. |
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

Tests: `PIRUnit.RequestPool.Tests` (DUnitX) and `Tests.FPC.RequestPool` (FPCUnit),
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

`PIRUnit.RequestQueue` has one managed record, `TIORingRequestQueue`:
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

Also new in `PIRUnit.Atomics`: `TAtomic.BackOff` (moved from the free
list, now shared) and `IORingAllocCacheAligned` (cache-line aligned memory,
used by the pool, the free list and the queue).

Tests: `PIRUnit.RequestQueue.Tests` (DUnitX) and `Tests.FPC.RequestQueue` (FPCUnit),
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

### 10.9 Engine – implementation notes (Phase 13)

`PIRUnit.Engine` has `TIORingEngine` (a class, shared by threads), built
as decided in §10.4. Its parts: a request pool of `MaxRequests` slots (the
payload holds the operation, file, buffer, count, offset, the caller's
`UserData`, the callback and the result), a request queue of the same size
(a request is in it at most once, so it is never full), one ring, the I/O
thread, and an auto-reset "new requests" event. The unit re-exports
`TIORingRequestHandle`, so users need only `PIRUnit.IORing` and
`PIRUnit.Engine`.

**The I/O thread**, one round:

1. Take requests from the queue and prepare them on the ring. A request that
   does not fit (the ring is full) waits in a one-place "deferred" slot for
   the next round. A request the ring refuses at once (for example a bad file
   handle) completes at once, with the ring's error code.
2. If anything was prepared: one `Submit(0)` for all of it (no waiting
   inside `SubmitIoRing` – only the I/O thread submits, §2.1).
3. Pop all completions; store each result and mark the request Completed
   (this wakes its `Wait`), or call its callback and free its slot.
4. Only if nothing happened in the round: set the sleeping flag with
   `Exchange`, look at the queue once more, then sleep in
   `WaitForMultipleObjects` on {"new requests" event, ring completion
   event}.

**Waking without lost wake-ups.** A producer puts its request in the queue
(a compare-exchange: a full barrier) and then looks at the sleeping flag; it
sets the event only if it can `Exchange` the flag from 1 to 0. The I/O thread
sets the flag (also a full barrier) and then looks at the queue. With full
barriers on both sides, at least one of the two sees the other's write: the
request is never left sleeping in the queue. The ring's completion event is
auto-reset and fires when the completion queue goes from empty to non-empty;
the I/O thread always pops until the queue is empty before it sleeps.

**A full pool.** When all requests are in use, `ReadAsync` (etc.) sleeps on
a "slot released" counter (`WaitWhileEqual`); every release increments it and
wakes the sleepers only if there are any. Rule: `MaxRequests` must be more
than the sum, over all threads, of the requests a thread keeps (started, not
waited for) while it starts a new one – otherwise all threads can wait for
each other forever. The stress test ran into exactly that at first (8 threads
keeping 6 requests each with 32 slots), see below.

**Destroy**, in this order: (1) no new requests (`ReadAsync` raises), and
threads waiting for a free slot give up; (2) wait until no thread is half-way
through starting a request (a counter); (3) the I/O thread completes the
queued requests as cancelled without starting them, asks the ring to cancel
each request in it (`PrepareCancel`; the cancel operations use `UserData` 0),
waits until all have completed, and ends; (4) wait until the threads still in
`Wait` – woken by step 3 with "cancelled" – have left (another counter); only
then are the pool and the queue freed. Cancelled =
`IORING_RESULT_CANCELLED` (`HRESULT_FROM_WIN32(ERROR_OPERATION_ABORTED)`,
the same code the ring gives), `TIORingCompletion.IsCancelled`.

**Other details**

- The words that several threads write (sleeping flag, stopping flag, the
  two counters of Destroy, the slot-release counter) each have a cache line
  of their own.
- Callbacks run on the I/O thread; an exception in one is caught and counted
  (`Stats.CallbackErrors`), and the I/O thread goes on.
- `BeginBatch`/`EndBatch` use two thread variables (the engine and the
  depth): a thread can batch for one engine at a time.
- Stats are counted by the I/O thread alone (a plain add, stored whole with
  `StoreRelease`, so a 64-bit counter is never read half-written on Win32).
- Known limits: one `Wait` per request; no cancelling of single requests;
  plain file handles only (no registered files or buffers yet); if the ring
  itself fails (a system call error, not an I/O error) the I/O thread stops
  and requests in flight do not complete.

**Tests:** `PIRUnit.Engine.Tests` (DUnitX) and `Tests.FPC.Engine` (FPCUnit), 19 each –
a read with its data and `UserData`; 500 reads through a ring of 8 entries;
write + flush + read back; end of file (at and across); a bad file handle
(completes with an error, no exception); `Wait` with a timeout (the handle
stays valid), `TryGetResult`, a second `Wait` and an empty handle (raise);
callbacks (on the I/O thread; an exception is counted); a batch of 20 reads
goes to the ring in **one** submit; a full pool (the third start waits until
a request is freed); stats; `Destroy` with pending pipe reads (all complete as
cancelled), with a thread blocked in `Wait` (it wakes with "cancelled"), and
of an idle engine (quick, and the engine slept at most twice in 200 ms);
stress: 8 threads × 1500 random reads of up to 64 KiB with every byte
checked, and 4 threads mixing callbacks and waits. All pass with Delphi
Debug and Release and FPC with and without `-O3`, Win32 and Win64; the engine
tests also passed 100 repeated runs (Delphi Win64 and Win32) and 10 full FPC
runs.

**Findings:**

- **A pool that is too small can deadlock its users** (see "A full pool"
  above): the first version of the stress test hung, and `RunThreads` failed
  it after 60 s instead of hanging the run (Phase 12). Fixed in the test (5
  requests per thread, 36 slots: 8 × 4 < 36 guarantees progress, 8 × 5 > 36
  still fills the pool), and the rule is now in the unit's comments.
- **A busy engine does not sleep at all**: one thread starting requests one
  after another keeps the I/O thread awake – the next request is in the
  queue before the I/O thread would sleep. A test that expected at least one
  sleep failed now and then (5 of 40 runs) for exactly this reason; it now
  checks sleeping on an idle engine.
- Performance was measured in Phase 14, through the block reader (§10.10).

### 10.10 Block reader – implementation notes (Phase 14)

`PIRUnit.BlockReader` has `TIORingBlockReader`, built as decided in
§10.4 ("Phase 14 decisions"): a managed record used by one thread, reading
through a shared engine from a file handle; neither is owned by the reader.

**Buffers and slots.** One allocation (`AllocPages`) holds `ReadAhead`
buffers of `BufferSize` bytes. Each buffer has a slot that goes Free →
InFlight (its read is started) → Ready (the read is finished, its blocks are
being handed out) → Free. The slots are used as a ring: the head is the
oldest slot that still has blocks to hand out, and the next read goes to the
slot `Outstanding` places after it. So blocks come out in the provider's
order even when the reads finish in another order.

**One read, several blocks.** The reader keeps one block "in hand": taken
from the provider, not in a read yet. When a slot is free, a read starts with
that block, and the following blocks join it while they can (at or after the
read's end, at most `MaxGap` bytes after it, and the read still fits into the
buffer). The slot keeps the list of its blocks, so `TryGetBlock` can hand
them out one by one, each as a pointer into the buffer. The provider is asked
for a block only when there is room for it: at most one block more than the
reads in flight hold (the test `Provider_IsAskedLazily` checks this).

**Starting reads.** `StartReads` fills every free slot, and all the reads of
one round go inside one `BeginBatch`/`EndBatch` (one wake-up of the I/O
thread). It runs in `Open`, in `TryGetBlock`, and when `ReleaseBlock` frees a
buffer – so once the reader runs, that is one new read per freed buffer.

**Results.** `TryGetBlock` waits only for the head slot: `TryGetResult`
first; if the data is not there yet, it waits (`Wait`; counted as a stall,
with its time) or, with `AWait = False`, returns False. End of file counts as
success with fewer bytes; each block's length is cut where the read stopped
(0 for a block that lies wholly after the end). A failed read stays in its
slot: every block of that read raises `EIORingError` with the native code and
the read's offset – also when `TryGetBlock` is called again.

**Close** waits for every read in flight (the kernel still writes into the
buffers) before the memory is freed; a request that the engine no longer
knows (`EIORingError`) is skipped. The record calls `Close` when it goes out
of scope; copying a reader raises, as with the sequential reader.

**Tried and dropped: refilling in groups.** In the first full benchmark run
the reader was 2–4× slower than `ReadFile` on cached data, and one read per
freed buffer means one wake-up of the I/O thread per block. A version that
started new reads only when a quarter of the buffers were free (8 of 32: one
wake-up for 8 reads) made no measurable difference in a probe with 9 runs per
case (random 4 KiB blocks: 231 against 237 thousand blocks/s; sorted: 332
against 333), and the share of blocks that had to wait stayed the same. The
code stays simple.

**Where the time goes with cached data** (probe, Delphi Win64, 20 000 random
4 KiB blocks of a 4 GiB file, all in the cache, median of 9 runs; two
separate runs):

| Way of reading | Thousand blocks/s |
| --- | ---: |
| `ReadFile`, synchronous handle | 307–325 |
| `ReadFile`, overlapped handle, waiting for each read | 229–259 |
| Bare `TIORing` (no engine), 32 reads per submit | 257–272 |
| Block reader, read-ahead 32 | 231–245 |

- On the overlapped handle **every** read went the asynchronous way
  (`ERROR_IO_PENDING` for 100 % of them), although the data was in the cache
  (§2.1). That path costs about 20–25 % more per read than synchronous
  `ReadFile`, and IoRing reads take it too.
- The engine adds about 10 % to a bare ring.
- So with cached data the block reader cannot beat synchronous `ReadFile`.
  It wins when the data comes from the disk.
- **Fast and slow cores.** Cached-data numbers jumped between runs: the same
  test gave the block reader 220–250 or 75–90 thousand blocks/s. The cause is
  the hybrid CPU (8 P-cores and 12 E-cores): pinned to the P-cores, the probe
  gave 222–232 (4 % of the blocks had to wait); pinned to the E-cores, 90
  (half of the blocks had to wait), while `ReadFile` went from 303 to 176.
  Two threads that hand work to each other (reader ↔ I/O thread) suffer
  most from the slower cores, because every wait means a sleep and a
  wake-up.
- **Spinning before a wait sleeps:** a first measurement suggested that a
  much longer spin makes cached reads on the E-cores 49 % faster. Repeated
  measurements did not confirm it – E-core results move that much from run
  to run – so the spin stayed short (§10.11).

**Is one I/O thread the limit?** (the question for Phase 15; probe, Delphi
Win64, 4 GiB file, cold, random 4 KiB blocks, median of 5)

- **Buffered handle, data from the disk: no.** A bare ring in one thread,
  without the engine, reached 125–140 thousand reads/s even with 256 reads in
  flight; the block reader with read-ahead 128 got 103–119 in the probe (141
  in the full benchmark), and two readers on two engines (two I/O threads)
  129–133. The limit is Windows' cache path. (With *cached* data, more I/O
  threads do help – found in Phase 15, §10.12.)
- **Unbuffered handle** (`FILE_FLAG_NO_BUFFERING`; works with the block
  reader when every block's offset and length are multiples of the sector
  size): **yes.** In these first probes one engine stayed at about 70
  thousand reads/s, two engines reached 114–126. A closer look (§10.11)
  showed that the 70 came mostly from the E-cores; on the P-cores one engine
  is as fast as a bare ring (about 128), and the limit is the work Windows
  does inside the submit call – which only more submitting threads can
  share. Grouped refill did not help here either (63 → 66).
- Handing blocks out in order costs something by itself: a bare ring that
  frees its buffers only in order dropped from 103 to 85 thousand reads/s
  (128 in flight, unbuffered).

**Benchmark summary** (Benchmarks.md, "Blocks known in advance"): with data
from the disk, the block reader with read-ahead 128 is 7–10× faster than
`TFileStream` + `Seek` on random 4 KiB blocks and 1.2–2.1× faster than 8
threads with `ReadFile`; on sorted blocks with small gaps `MaxGap` makes it
17–22× faster than `TFileStream`. With cached data it reaches 85–92 % of
`ReadFile` on the P-cores and 43–50 % when it runs on the E-cores. On a
synchronous handle it is no faster than `ReadFile` (§2.1).

**Tests:** `PIRUnit.BlockReader.Tests` (DUnitX) and `Tests.FPC.BlockReader`
(FPCUnit), 15 each – blocks in order with their data; the provider asked
only when there is room; touching blocks merged (100 blocks → 2 reads);
`MaxGap` 0/99/100 bytes (20/20/1 reads); backward and overlapping blocks read
again; end of file (shortened and empty blocks); an empty list; not waiting
(a pipe that gets its data later); bad arguments and wrong call order raise;
a failed read raises every time; `Close` waits for reads in flight; stats
(5 blocks, 3 reads, 400 bytes); stress: 20 000 random blocks (read-ahead 64)
and 4 readers sharing one engine, all data checked. All pass with Delphi
Debug and Release and FPC with and without `-O3`, Win32 and Win64.

### 10.11 Where the I/O thread's time goes, and spinning (measured before Phase 15)

Probes with Delphi Win64, unbuffered random 4 KiB reads of a 4 GiB file,
the block reader with read-ahead 128 against a bare ring with 128 reads in
flight; the I/O thread's loop timed part by part (an instrumented copy of
the engine), the process pinned to one kind of core.

| Pinned to | Bare ring | Block reader | Time inside `SubmitIoRing`, per read | The engine's own work, per read |
| --- | ---: | ---: | ---: | ---: |
| P-cores | 125–132 | 126–128 | 7.5 µs | 0.2 µs |
| E-cores | 87–94 | 70–75 | 11 µs | 2–2.7 µs |

(thousand reads per second)

- **Windows does the work of a request inside `SubmitIoRing`**, in the
  submitting thread: about 7.5 µs per unbuffered 4 KiB read on a P-core.
  So one submitting thread – a bare ring or the engine's I/O thread – cannot
  go beyond about 130 thousand such reads per second. Only more submitting
  threads help (Phase 15).
- **The engine itself costs little:** taking requests from the queue and
  handing out the results took 0.2 µs per read on the P-cores. On the E-cores
  it was 2–2.7 µs – mostly waking the waiting reader.
- **Registered file and buffers** (`PrepareRegisterFiles`,
  `PrepareRegisterBuffers`) gave at most about 3 % in the bare ring, and no
  less time inside `SubmitIoRing`. Not added to the engine.
- **Basic costs:** a `PAUSE` takes 33 ns on a P-core and 17 ns on an E-core
  (on older CPUs much less); reading the clock
  (`TIORingPlatform.TimestampMicroseconds`) 22 ns and 33 ns.

**Spinning before a wait sleeps.** `WaitFor` checked the state 100 times
(with a `PAUSE`) before it slept. Tried, with cached data on P- and E-cores
and with data from the disk (random 4 KiB, the block reader with read-ahead
32, 5–9 runs each):

- *Longer fixed spins* (1 000 to 16 000 pauses, or 16 to 64 µs): no speed
  gain that held up in repeated runs, and 60–80 % more CPU time with data from
  the disk. (One early run showed +49 % on the E-cores; E-core results move
  that much between runs.)
- *A spin learned per thread* from its recent waits (about twice as long as
  they took, the minimum when they took longer than 64 µs): worse. With data
  from the disk the waits are often short – results arrive every few µs –
  so it learned to spin, which only cost CPU time (188 → 281 ms); on the
  E-cores it was slower too (91 → 67). A spin that ends in the result is not
  the same as a spin that helps.
- *Spinning only while the I/O thread is awake* (the classic adaptive-mutex
  rule: spin while the thread that will do the work runs): no better than a
  short fixed spin.
- *Short fixed spins* – 100 pauses, 2, 4 or 8 µs – were all equal within the
  noise, in every case.

**Decision:** a short spin, now given as a time: `WaitFor` spins
`SpinMicroseconds` (default 4 µs, `IORING_POOL_DEFAULT_SPIN_MICROSECONDS`),
reading the clock every 8 pauses, then sleeps. The same behaviour as before
on this PC, but the same wait on every CPU. No setting in the engine and no
compiler define: no use case was found where another spin is clearly
better.

### 10.12 Several I/O threads – implementation notes (Phase 15)

Built as decided in §10.4 ("Phase 15 decisions"). The I/O-thread code moved
into `TIORingIOThread` (in the implementation part of the unit): its own
ring, "new requests" event, sleeping flag (on a cache line of its own), list
of requests in flight, deferred request and stats. The engine keeps the
shared parts: pool, queue, the words of `Destroy`, and a count of the
sleeping I/O threads.

**Waking.** An I/O thread that goes to sleep sets its flag, adds itself to
the sleeping count (both full barriers) and then looks at the queue once
more. A producer, after putting a request in the queue (a full barrier),
reads the count: only if all I/O threads sleep does it wake one – the first
whose flag it can take from 1 to 0. So, as with one thread, a request is
never left in the queue with everyone asleep, and while any I/O thread is
awake, starting a request costs no system call. An I/O thread with siblings
takes at most 16 requests per round (`IORING_ENGINE_SHARE_SIZE`); if more are
waiting, it wakes one sleeping sibling before it submits, and that one does
the same. An I/O thread whose ring is full wakes a sibling before it sleeps,
if requests are waiting.

**Found on the way: `Destroy` could hang** – also with one I/O thread. When a
ring was full of requests that only a cancel ends (reads from pipes that get
no data), there was no room in it for the cancel operation, and `Destroy`
waited forever. The new test with 32 pipe reads on rings of 8 found it. Now
one place in each ring always stays free for a cancel.

**Tests** (DUnitX and FPCUnit, 6 new each): bad I/O thread counts raise; a
backlog of 2 000 reads in one batch is shared (at least 2 of 4 I/O threads
take requests; all data checked); one request at a time stays on the first
I/O thread (at least 90 %); `Destroy` with 32 pending pipe reads spread over
4 rings (all complete as cancelled); both stress tests again with 4 I/O
threads, and every callback must run on an I/O thread (`IsIOThread`). The
engine tests passed 30 repeated runs (Delphi Win64 Release).

**Benchmark** (Benchmarks.md, "Several I/O threads"; block reader with
read-ahead 128, Delphi Win64): with cached data, 4 I/O threads read 1.5–1.75×
as many blocks per second as one, and the reader now beats `ReadFile`
(1.3–1.6×); with unbuffered reads 2.7–3.2× as many – 28× `ReadFile` and
3.2× 8 threads with `ReadFile`. Data from the disk through the file cache
gains nothing. 2 I/O threads always helped in all four builds; 4 helped more
in most runs. The CPU time grows a little (109 → 156 ms for 20 000 cached
blocks). The default stays 1 I/O thread.

**Later found:** the test "a backlog is shared" failed now and then in the FPC
Win64 `-O3` build (3 of 25 full runs): with 2 000 *cached* reads, one I/O
thread sometimes finished them all before a woken sibling got the CPU. Not a
fault of the engine – the test's backlog now uses unbuffered reads, which
take far longer than a wake-up (0 of 25 since).

### 10.13 Overlap rule – implementation notes (Phase 16)

Built as decided in §11 ("Phase 16 decisions"), in `PIRUnit.Engine`.

**Routing.** With `orKeepOrder`, `StartRequest` puts a request into the own
queue of the I/O thread `(handle shr 2) mod IOThreadCount` (handles are
multiples of 4) and wakes exactly that thread if it sleeps (`TryWake`; the
same full-barrier handshake as before, now per thread). The shared queue is
not used. `EndBatch` wakes each sleeping I/O thread whose queue has
requests.

**Bookkeeping, on the I/O thread only.** A small hash table (buckets: a power
of 2; at most one entry per unfinished request) maps a file handle to its
entry: the oldest and newest unfinished request and the number held back.
The requests of a file form a doubly linked list in start order, linked
through their own slots (`FilePrev`, `FileNext` in the payload) – no
allocation per request.

- **A new request** is compared with every unfinished request of its file
  (all of them started earlier). `MustWaitFor`: a read waits for an earlier
  write of overlapping bytes; a write for an earlier read or write of
  overlapping bytes; a flush for any earlier write. It is appended to the
  list either way – held back, or ready to start.
- **When a request finishes**, it leaves its file's list *before* it is
  marked Completed (after that, its owner may free the slot at once). If
  the file has held-back requests, they are checked again in start order: a
  request starts when nothing earlier that is still unfinished (started or
  held back) makes it wait. A file entry with an empty list is freed.
- **Ready to start, but the ring is full:** the old one-place "deferred"
  slot became a small first-in-first-out list (`FReady`, MaxRequests
  places), which also takes the requests freed from being held back. Each
  round starts with it, in order.
- **Destroy:** the I/O thread stops releasing held-back requests, cancels
  the ready ones, the held-back ones and the queued ones without starting
  them, and then the ones in its ring as before.

**Cost** (probe, Delphi Win64 on the P-cores, one producer, 32 requests in
flight, random reads and writes of 1–8 KiB, median of 5):

| Region of the file | Held back | Rule off | `orKeepOrder` |
| --- | ---: | ---: | ---: |
| 64 KiB (many overlaps) | 64 % | 495 | 399 |
| 64 MiB (few overlaps) | 0.2 % | 259 | 251 |

(thousand requests per second). With many overlaps the rule costs 20 % –
and without it the data is wrong. With few overlaps it costs about 3 %. The
list scan stays: no need for the 64 KiB stripes yet.

**Tests:** `PIRUnit.EngineOverlap.Tests` / `Tests.FPC.EngineOverlap`, 13 each:

- **Order on a file**, 200 rounds each, started without waiting in between:
  write then read (the read sees the write), write then write (the later
  wins), read then write (the read sees the old data).
- **Exact cases with pipes** (a pending pipe read): a write of the same
  bytes is held back until the read completes; reads do not wait for reads;
  other bytes do not wait; a chain read → write → read → write starts and
  completes in exactly that order; a flush waits for an earlier pending
  write (an 8 KiB pipe write: more than the pipe's buffer); `Destroy`
  cancels held-back requests; rule off: nothing is held back.
- **Routing:** all requests of a handle go to one of 4 I/O threads.
- **Against a model:** 4 000 random reads and writes of 1–8 KiB in 64 KiB,
  32 in flight, started in batches of 24 (so that two I/O threads work at
  once without the rule); every read must return what an in-memory copy,
  updated in start order, held when the read was started. Once with one
  producer, once with 4 producers on one handle (each its own part).

**The tests were checked against the engine without the rule** (every engine
in the unit switched to `orNone`): 9 of 13 failed – both models (595 and
2 027 wrong reads), write-then-write, read-then-write, and the exact cases.
Without the batches, the one-producer model had not found the disorder: one
producer with a light load stays on one I/O thread, and Windows happened to
carry out its cached requests in submit order. (Write-then-read did not fail
without the rule either, for the same reason; it stays as a check of the
promise.)

All tests pass with Delphi Debug and Release and FPC with and without `-O3`,
Win32 and Win64; the engine and overlap tests passed 30 repeated runs
(Delphi Win64 Release), the whole FPC suite 25 (Win64, `-O3`).

**Benchmark** (Benchmarks.md, "Overlap rule"): with reads alone – nothing
overlaps, only the bookkeeping – the rule costs 0–6.5 % with one I/O
thread, the most with cached data. With 4 I/O threads, one file loses the
gain of more threads (unbuffered: 396 → 128 thousand reads/s), as decided.
If the read cost matters later: a file could count its unfinished writes,
and a read could skip the scan when there are none.

### 10.14 The engine on Linux (Phase 21)

What is Windows-only above the ring today: in the engine, the I/O thread's
wake event (`CreateEvent`, `SetEvent`, `CloseHandle`), its wait for two
events at once (`WaitForMultipleObjects`: the wake event and the ring's
completion event), the file hash (`handle shr 2`: Windows handles are
multiples of 4, Linux file descriptors are small numbers one after the
other) and one Windows-only constant. The writer, block reader and streams
have no Windows code. In the tests: the duplex named pipe (Linux `pipe()`
goes one way only), reading from the pipe, and the failed writes (a
Windows byte-range lock).

**Facts found before Phase 21** (WSL2, kernel 6.18, 2026-10-24):

- **[VERIFIED] Two ways for the I/O thread to sleep, measured** (a
  producer wakes the thread, the thread answers; 100 000 round trips, three
  tries each):
  - A – like Windows: the wake event is an `eventfd`, the ring's completion
    event too, and the thread waits for both with `poll`: **23–24 µs** per
    round trip.
  - B – the io_uring way: a read on the wake `eventfd` always waits inside
    the ring, so the thread sleeps only in `io_uring_enter` (and submits in
    the same call): **24 µs**.
  The time is the waking of the threads, not the system calls. A
  registered completion `eventfd` costs about 2 % on the cheapest operation
  (0.102 → 0.104 µs per 0-byte read), so nothing that real I/O would show.
- **[VERIFIED]** A Unix socket pair (`socketpair`) is the Linux duplex
  "pipe": a ring read on one end stays pending until the other end writes,
  data goes both ways, and a cancelled read ends with `-ECANCELED`.
- **[VERIFIED]** Failed writes without a lock: replacing the writer's file
  descriptor with a read-only one (`dup2`; the descriptor found through
  `/proc/self/fd`) makes every later ring write fail with `-EBADF`. Linux
  has no mandatory byte-range locks.
- **[VERIFIED] Cold reads in WSL2 are not disk reads:** after dropping a
  1 GiB file from the cache (`posix_fadvise(POSIX_FADV_DONTNEED)`) it still
  reads at 5.7 GB/s (warm 17.5 GB/s; `dd` with `O_DIRECT` 2.7 GB/s). WSL2
  sees a virtual disk, and the Windows host may serve it from its own cache.

**Phase 21 decisions (decided 2026-10-24):**

- **The I/O thread sleeps like on Windows (A).** `TIORingPlatform`
  gets a small event API – `CreateWakeEvent`, `SignalWakeEvent`,
  `CloseWakeEvent` and `WaitForEvents(AEvent1, AEvent2)` – an auto-reset
  event and `WaitForMultipleObjects` on Windows, an `eventfd` and `poll`
  (then reading the signalled `eventfd` to reset it) on Linux. The engine
  uses only that, so its code stays the same on both systems. B is the
  same speed in the measurement and needs more Linux-only code (a read that
  always waits in every ring, and its own handling in `Destroy`), so it is
  left out unless a benchmark later shows a gain.
- The engine's file hash per system: `handle shr 2` on Windows, the file
  descriptor itself on Linux (a small inline function in the engine).
- Tests: `OpenPipePair` is a socket pair on Linux; `ReadFromPipe` moves to
  `PIRUnit.Test.PlatformHelpers`; the failed writes use a helper,
  `MakeWritesFail(AFileName)`: the byte-range lock on Windows, the `dup2`
  on Linux. Then the engine, overlap rule, block reader, read stream and
  write stream suites run on Linux too – everything except the Windows API
  tests.
- **The benchmarks on Linux in this phase.** The four programs
  (reader, structures, blocks, writes) build and run on Linux:
  `Build-FPC.ps1 -Platform Linux64 -Project …`; the contenders with
  `pread`/`TFileStream` instead of `ReadFile`; the cache dropped with
  `posix_fadvise(POSIX_FADV_DONTNEED)`; CPU time with `getrusage`. The WSL2
  results go into Benchmarks.md as a first look, marked: cold in WSL2 is
  not the disk (above). Numbers from a real Linux machine come later.

**Phase 21 implementation notes** (2026-10-24):

- Built as decided. `TIORingPlatform` has the event API on both systems
  (Linux: `eventfd2` with `EFD_CLOEXEC or EFD_NONBLOCK`, `poll` that starts
  again after `EINTR`, then an 8-byte read of each signalled `eventfd`). The
  engine has no Windows calls left; the two things that differ are small
  inline functions with one line per system: `FileHash` (the hash of a file
  handle) and `IsFailure` (a negative result is a failure, except Windows'
  end of file).
- Tests: `BAD_HANDLE` for "not a valid handle" – handle 0 is valid on Linux
  (standard input). `OpenPipePair` is a socket pair on Linux,
  `MakeWritesFail` does the `dup2` (every descriptor of the file found in
  `/proc/self/fd`). Two overlap tests stay Windows-only, both need a
  Windows pipe: `OtherBytes_DoNotWait` uses offsets on a pipe (a socket
  gives `-ESPIPE`), `Flush_WaitsForAnEarlierWrite` needs a write that stays
  pending and a flush of a pipe (a large socket write does not wait, and
  `fsync` on a socket or pipe gives `-EINVAL`).
- **[VERIFIED] Rings that are closed quickly one after another can run out
  of locked memory (`ENOMEM`).** Registered buffers stay pinned, and count
  against `RLIMIT_MEMLOCK` (64 MiB in WSL2; the count is per user, over all
  processes), until the kernel frees the closed ring – later, in the
  background. The ring memory counts too. Measured: 1000 rings opened and
  closed in a row, each with 8 MiB registered: 996 setups failed; with the
  buffers unregistered before `close`: none. Found because the `-O3` test
  build failed now and then. Two changes:
  - `TLinuxIORing.Close` unregisters the buffers and the files before it
    closes the ring.
  - The sequential reader looks at the completions of its registrations at
    once: when one fails (for example `ENOMEM` under a low limit) it reads
    without registration, as it already does where the system has none.
    Tested with `RLIMIT_MEMLOCK` at 1 MiB: the reader falls back and reads
    32 MiB correctly.
- **[VERIFIED]** Registering the buffers helps more on Linux than on
  Windows: +8–10 % for cached reads (15.2 against 14.0 GiB/s in WSL2,
  Windows ~1–2 %); unbuffered no difference (~3.6 GiB/s both).
- **[VERIFIED] FPC 3.2.2 on Unix: `TThread.WaitFor` from the main thread
  waits in 100 ms steps.** It calls `CheckSynchronize(100)` until the thread
  has finished, and nothing wakes it earlier: a thread that ends after 1 ms
  takes 100 ms to wait for. If the thread has already finished, it returns
  at once. Found in the first WSL2 benchmark runs ("8 threads" took exactly
  0.1 or 0.3 s). It made every `TIORingEngine.Free` from the main thread take
  up to 100 ms on Linux – also every write stream's `Free`. Fixed: the I/O
  thread sets a flag (and wakes, with the futex) when its `Execute` ends;
  `Destroy` waits for that, then for `Finished`, and only then calls
  `WaitFor` (`TIORingIOThread.WaitUntilEnded`, Free Pascal on Unix only). New
  test `Destroy_TenEngines_AreQuick` (10 engines with 4 I/O threads freed in
  under 500 ms; without the fix 1005 ms); the Linux test run went from 19 to
  9 s. Programs that use `TThread.WaitFor` themselves on Linux meet the same
  thing.
- **[VERIFIED]** FPC 3.2.2's `TThread.ProcessorCount` is 1 on Linux. The
  library does not use it; the structures benchmark counts the processors
  with `sched_getaffinity`.
- **[VERIFIED] FPC 3.2.2's `clock_gettime` is a system call** (it does not
  use the vDSO): 94 ns in WSL2, the C library's 13 ns. The library reads the
  clock only on slow paths (a stall, a wait, the pool's spin), so it stays
  as it is for now; the benchmarks use the C library's (their busy-wait
  "work" would otherwise be mostly kernel time).
- The benchmarks on Linux: `PIRUnit.Benchmark.Common` has the file calls for both
  systems (`BenchOpenForReading`, `BenchRead`, `BenchReadAt`,
  `BenchFlushFile`, the platform name and the default folder); CPU time
  from the `getrusage` system call (FPC 3.2.2 has no function for it on
  Linux). Left out on Linux: the overlapped `ReadFile` contenders and the
  block reader on a synchronous handle (Windows-only ideas). The structures
  benchmark compares with a pthread mutex instead of the SRW lock.
- **Two Linux distributions:** `Build-FPC.ps1 -Distribution <name>` builds
  and runs in a chosen WSL distribution. Ubuntu 24.04 (glibc 2.39) and
  Ubuntu 26.04 (glibc 2.43), both with FPC 3.2.2, run the same WSL2 kernel,
  so io_uring is the same; the C library and the packages differ. Ubuntu
  26.04 has no gcc, so no `crtbegin.o`: the linker warns ("crtbegin.o not
  found, this will probably cause a linking failure"), but the programs
  link and work. Both use the same output folder (`Linux64`): run a program
  in the distribution that built it.
- Test counts: Linux 230 (WSL2, kernel 6.18; Ubuntu 24.04 and 26.04), with
  and without `-O3`.

---

## 11. Overlapping reads and writes – options and the decision (Phase 16)

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

**Decided** (Phase 16, 2026-10-23): A is fixed for the core ring. The engine
gets B as an option, C is not planned.

**Phase 16 decisions** (before coding) – the promise and how it is kept:

- **The promise (rule on):** for one file handle, requests that touch the
  same bytes take effect in the order they were started; requests that do
  not, run in parallel, in any order. Reads never wait for reads. "Started"
  = the `ReadAsync`/`WriteAsync`/`FlushAsync` call: for one thread its
  program order; across threads, the call that returned first is first.
- **Conflicts:** write–write, write–read and read–write on overlapping byte
  ranges (requests of 0 bytes touch nothing). A flush waits for the earlier
  unfinished writes of its handle; nothing waits for a flush.
- **How:** a request that conflicts with an earlier unfinished one (in the
  ring, or itself held back) is **held back**. When a request completes, the
  held-back requests of its file are checked again, in start order; each one
  starts as soon as nothing earlier conflicts with it any more. Works for any
  sizes and partial overlaps, because no data is merged. Answering a read
  from a write's buffer (only when one write covers the whole read) and
  joining duplicate reads are left for later, if a benchmark asks for them.
- **An option of the engine:** `TIORingEngine.Create(…, AIOThreads,
  AOverlapRule = orNone)`; `orKeepOrder` turns the rule on. Off: exactly as
  before, no cost. A program can have one engine of each kind.
- **Routing, rule on:** every request of a file handle goes to one I/O
  thread, chosen from the handle, into that thread's own queue (not the
  shared one). That thread alone sees all requests of the file in start
  order and keeps the bookkeeping – no locks. Different files still use
  different I/O threads; one file uses only one.
- **Per handle, not per file:** two handles to the same file are not
  recognised as the same file. (Later perhaps: the file's ID.)
- **Bookkeeping:** each I/O thread has a small hash table from file handle to
  the file's unfinished requests, a list in start order (linked through the
  requests' own slots). A new request scans that list. Simple first; if the
  benchmark shows the scan matters, a hash of 64 KiB file stripes.
- **Destroy** cancels held-back requests like queued ones.
- `Stats.HeldBack` counts the requests that had to wait.
- **Tests:** the cases of the table above, made exact with pipes (a pending
  pipe read holds back a write of the same handle); a model test – random
  reads and writes of random sizes, compared with an in-memory copy of the
  file updated in start order; the cost, rule on against off.

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
   Since Phase 19, Delphi and FPC run the same test units
   (`Source/UnitTests/Common`, §12.4); `Source/Build-FPC.ps1` builds the FPC
   runner (`-Optimize`: `-O3` and inlining; without it a debug build without
   inlining).
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
- `PIRUnit.Atomics` internals.
- The API unit's import mechanism (FPC has no `delayed`, §6.3).
- The raise helpers in `PIRUnit.Types`: `noreturn` for
  Delphi only (FPC's trunk refuses it on a routine that raises), and the
  caller's address (Delphi `ReturnAddress`, FPC `get_caller_addr`) –
  [CodingStyle.md](CodingStyle.md), "Raising".

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

- The coding style – layout, the 120-character margin, comments, empty
  lines, `inherited`, raising through the raise helpers, `const`/`var`
  parameters – is in [CodingStyle.md](CodingStyle.md) (2026-10-24).
- Every unit includes `PIRInclude.Compiler.inc` (holds `{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}`
  and shared switches).
- OS constants as typed constants, not enums.
- Parameter style matching the existing skeletons: `A`-prefixed, `const`
  where possible; locals `L`-prefixed, fields `F`-prefixed.
- **`inline` only works when all of these hold** (Delphi):
  1. Inlining is on. Release builds: yes, the default. **Debug builds: off on
     purpose** (2026-10-23), so the debugger can step into every routine.
     Delphi: the Debug configurations set "inlining off" (`--inline:off`).
     FPC: the define `IORING_NO_INLINE` switches `{$INLINE OFF}` on in
     `PIRInclude.Compiler.inc` (`-Si-` does not work: `{$MODE DELPHI}` turns
     inlining on again); `Build-FPC.ps1` sets it unless `-Optimize` is given,
     and the Lazarus test project sets it too. What depends on inlining is
     therefore tested in the Release / `-Optimize` builds – both are part of
     every full test run.
  2. The body comes **before** the first call in the same unit. Delphi
     compiles in one pass: a call it meets before the body becomes a normal
     call, **without any hint**. So implement inline routines (and the
     overloads they call) before the code that uses them.
  3. The caller's unit has the unit with the body in its `uses` (otherwise
     hint H2443). So no `inline` on methods of types that other units
     re-export under an alias (`TIORing`, `TIORingRequestHandle`): their
     users do not have the original unit in `uses`.

  Checked 2026-10-23 for all units (Atomics, RequestPool, the API unit):
  no inline routine is called before its body. Free Pascal inlines by
  default too (seen in its assembler output, §10.6).

### 12.4 One set of tests for Delphi, Free Pascal and Linux (Phase 19)

Today the same checks are written twice: DUnitX units for Delphi
(`Source/UnitTests/Tests.*.pas`, 249 tests) and FPCUnit units for Free
Pascal (`Source/UnitTests/FPC/Tests.FPC.*.pas`, 235 tests). Linux has a
third program (`Source/UnitTests/Linux`). The FPC units are near copies of
the Delphi ones, with the same tests and comments. They differ in three
ways:

- The test framework: DUnitX attributes and `Assert.AreEqual(Expected,
  Actual, Message)`, against FPCUnit `published` methods and
  `AssertEquals(Message, Expected, Actual)`.
- Thread bodies and `Assert.WillRaise`: anonymous methods in Delphi, methods
  of the test class in FPC (FPC 3.2.2 has no anonymous methods, §12.2).
- A few tests exist on one side only. Delphi only: 4 tests of the ref
  helpers (Windows API layout), `Assign_Raises` and
  `BufferInfo_HasLayoutOfIoRingBufferInfo` (ring), `ReadOverloads_Work`
  (stream). Some tests are split differently.

Found while looking (2026-10-23):

- DUnitX runs the `published` methods of a fixture as tests, without
  attributes, and calls `SetUp`/`TearDown` declared in a base class (its own
  DUnit compatibility class works that way). So one test class can serve
  both frameworks, if a small base class hides the difference.
- The FPC test units use only four calls of their framework: `AssertTrue`
  (326 times), `AssertEquals` (280), `AssertFalse` (62) and `Fail` (11). The
  rest are check helpers of their own.
- Outside the Windows API tests, the tests call Windows only a little:
  `Sleep` (in `SysUtils` on both compilers), a few file flags and error
  codes, pipes and one byte-range lock. Most of it is in
  `PIRUnit.Test.PlatformHelpers` already.

**Phase 19 decisions (decided 2026-10-23):**

- **One unit per test topic, in `Source/UnitTests/Common`**, used by all
  runners: `PIRUnit.IORing.Tests`, `PIRUnit.Engine.Tests`, … (the names without `.FPC`), plus
  the helpers (`PIRUnit.Test.FileHelpers`, `PIRUnit.Test.PlatformHelpers`) and a new
  `PIRUnit.Test.Support`. Each one starts from the FPC unit (it already has no
  anonymous methods) and gets the tests that only Delphi has, so no test is
  lost. The Windows API tests go there too: Delphi and FPC both run them;
  they are for Windows only.
- **`PIRUnit.Test.Support`: a base class `TIORingTestCase`.** With FPC it is an
  FPCUnit `TTestCase`; with Delphi a plain class for DUnitX whose
  `[Setup]`/`[TearDown]` methods call the virtual `SetUp`/`TearDown`. Both
  have the same check methods, with the **FPCUnit names**
  (`AssertEquals(Message, Expected, Actual)`, `AssertTrue`, `AssertFalse`,
  `Fail`), so the FPC tests move over almost unchanged; with Delphi they
  call DUnitX's `Assert`. Also in `PIRUnit.Test.Support`: the thread
  helpers (`RunThreads` with a method of the test, `TWorkerThread`), `Log`,
  `CheckPattern`, `CheckEqualsU64`, and `RegisterTests(Class)` (FPCUnit's
  `RegisterTest`, DUnitX's `RegisterTestFixture`). Every check counts as an
  assert for DUnitX (the Delphi runner fails tests without asserts).
- **`{$IFDEF}` only where the platform differs**, and as much as possible of
  it inside `PIRUnit.Test.PlatformHelpers` (files, pipes, page memory, the "end of
  file" result). A base class per platform is not needed: the differences
  are a few calls, not different tests. The Linux side of the helpers comes
  with `TLinuxIORing` (Phase 20).
- **Thin runners.** The Delphi program stays where it is
  (`Pascal.IOUring.UnitTests.dpr`: DUnitX, TestInsight). **One Free Pascal
  program for Windows and Linux:**
  `FPC/Pascal.IOUring.UnitTests.FPC.lpr`, with `{$IFDEF MSWINDOWS}` and
  `{$IFDEF LINUX}` in its `uses`; `Build-FPC.ps1 -Platform Linux64` builds
  it in WSL. `Source/UnitTests/Linux` keeps only what is for Linux only (the
  API tests and the layout generator).
- **The same tests everywhere.** After the phase, Delphi and FPC run the same
  tests on Windows (one test count). Linux runs its API tests now, and the
  shared suites from Phase 20 on (they need `TLinuxIORing`, and the atomics
  need the Linux futex for waiting).
- **On main, not a branch.** It moves a lot of test code (about 26 units
  become about 15) but changes no library code. One test topic at a time. After each step all Windows runs pass (Delphi Win32 and
  Win64, Debug and Release; FPC Win32 and Win64, with and without `-O3`),
  so you can commit between steps.

**Phase 19 implementation notes** (2026-10-23):

- Built as decided. `Source/UnitTests/Common` has the 13 test units, the
  helpers and `PIRUnit.Test.Support`; the Delphi runner and the one Free Pascal
  runner (`FPC/Pascal.IOUring.UnitTests.FPC.lpr`) use them. The old twins
  (`Tests.*.pas` for Delphi, `FPC/Tests.FPC.*.pas`) and the Delphi-only
  `TestThreadHelpers` are gone. Every unit was made from the FPC twin by a
  script (unit name, `uses` with `{$IFDEF FPC}`, registration), then the
  differences were fixed by hand.
- **One object per test with DUnitX too.** FPCUnit makes a new test object
  for every test; DUnitX runs all tests of a class on one object, so fields
  would carry over from one test to the next. The Delphi side of the base
  class therefore resets the object before each test (`CleanupInstance`,
  then `InitInstance`: fields zero, as after `Create`).
- **Every check counts as an assert** for DUnitX: the Delphi runner fails a
  test without one (`FailsOnNoAsserts`). Check helpers that only called
  `Fail` on a mismatch (`CheckResult` of the Windows API tests,
  `CheckPattern`) now count a passing check too. Three tests failed on this
  at first.
- Kept from the Delphi side: the tests the FPC side did not have (the
  layout of `TIORingBufferInfo`, the four ref-helper tests), the split of
  tests that FPC had joined (large file buffered / unbuffered, `Write` /
  `SetSize` raise), and 32 log lines with findings ("VERIFY: …") that the
  FPC twins had dropped.
- Delphi only: `ReadOverloads_Work` (`TStream.Read(TBytes, …)`, `Read64`,
  `ReadData`) and two `Write` checks – FPC 3.2.2's `TStream` does not have
  these overloads (`{$IFNDEF FPC}`).
- Fewer test entries in Delphi, the same checks: Delphi had 9 `[TestCase]`
  variants of 2 file-helper tests; the shared tests loop over the same
  cases.
- Differences between the RTLs, now in the shared code: `GetTickCount64` is
  `TThread.GetTickCount64` (Delphi's `SysUtils` has none); `constref` is
  `const [ref]` in Delphi (§12.2); `TStreamReader` is in FPC's `streamex`
  with other constructors; Delphi's `string` has 2-byte characters, so a
  test that compared file bytes with a `string` now compares `TBytes`.
- `PIRUnit.Test.Support` compiles on Linux too (no Windows calls outside
  `{$IFDEF MSWINDOWS}`; the RTL's interlocked calls instead of
  `PIRUnit.Atomics`, which is Windows-only until Phase 20). The FPC
  runner needs `cthreads` on Linux, which links the C library:
  `Build-FPC.ps1 -Platform Linux64` passes gcc's library folder (`-Fl`).
- Result: Delphi 242 tests (Win32 and Win64, Debug and Release), FPC 241 on
  Windows (Win32 and Win64, with and without `-O3`), FPC 32 on Linux (the
  25 Linux API tests and the 7 file-helper tests). Delphi has one test more:
  `ReadOverloads_Work`.

### 12.5 Tests in CI – GitHub Actions (Phase 23)

Today every test runs on one machine: Windows 11 and WSL2. Two things were
never run anywhere: the AArch64 code (§5.7, §6.4: no ARM machine, no cross
compiler here) and Linux outside WSL2 (where "cold" is not the disk,
§10.14). The repository is public on GitHub, so its hosted runners are free.

**Facts found before Phase 23** (GitHub's documentation and image release
notes, 2026-10-24):

- Free and without limit for public repositories, each 4 processors,
  16 GB memory, 14 GB SSD: `ubuntu-24.04` (x64), `ubuntu-24.04-arm`
  (ARM64; GitHub maintains the image), `windows-2025` (= `windows-latest`,
  Windows Server 2025 x64, build 26100 – the code base of Windows 11 24H2),
  `windows-11-arm`. `ubuntu-26.04-arm` is in public preview.
- PowerShell 7 is installed on the Linux images, x64 and ARM64, so
  `Build-FPC.ps1` can run there.
- Free Pascal: Ubuntu 24.04's `fpc` package is 3.2.2 for x64 and ARM64. On
  Windows, freepascal.org has one installer with both compilers,
  `fpc-3.2.2.win32.and.win64.exe` (i386 native, x86_64 cross). The usual
  GitHub action for Lazarus (`gcarreno/setup-lazarus`) is no longer
  maintained.
- **Not known yet:** whether io_uring is switched on in the Linux runners
  (`kernel.io_uring_disabled`, the kernel version), and whether Windows
  Server 2025 has IoRing version 4. No documentation says. The first run
  tells: the test program prints `IORingCapabilities.ToString` first (the
  reason too, when the ring is not available).
- Delphi cannot run there (the compiler needs an installed, licensed IDE).
- Workflows run when you push. Their results can be read on the
  repository's Actions page.

**Phase 23 proposal:**

- **[DECIDE] 1. What runs where.** Proposed:
  - `ubuntu-24.04` (x64) and `ubuntu-24.04-arm` (ARM64): the Free Pascal
    tests, debug build and `-O3`. On ARM also the layout generator
    (`Generate-LinuxApiLayout.sh`, gcc there): its output must equal the
    committed `.inc`, so the C header's layout is checked on AArch64 too.
  - `windows-2025`: the Free Pascal tests, Win32 and Win64, debug and
    `-O3` – if the runner has IoRing version 4; if not, build only, and the
    reason in the log.
  - On every runner the four benchmarks are built. They run only when
    started by hand (`workflow_dispatch`, with the sizes as input): about
    10 minutes, and a shared cloud disk – not for every push. Their output
    is kept as an artifact of the run.
  - When: on every push to `main` and on pull requests.
- **[DECIDE] 2. One build script.** Proposed: `Build-FPC.ps1` builds
  natively on Linux (on a Linux host `-Platform Linux64` calls `fpc`
  directly instead of WSL) and gets `-Platform LinuxArm64`; the RTL unit
  folder is found from the host instead of a fixed path. The same commands
  then work on your machine and in CI. Other choice: a separate shell
  script for Linux.
- **[DECIDE] 3. The test program reports the system first.** Proposed: the
  Free Pascal test program prints `IORingCapabilities.ToString` after its
  first line – in CI the log then says what each runner has (and on your
  machine too). Where the ring is not available, the tests fail as now
  (the library has nothing to do without the ring); the reason is in the
  log.
- Timing checks (for example "freed in under 500 ms", "slept at most 2
  times") may fail on a busy 4-processor runner. They stay as they are; if
  one fails in CI, it gets a looser limit then – not before.
- Steps: `Build-FPC.ps1` on Linux; the report in the test program;
  `.github/workflows/ci.yml`; you push, I read the first run and fix what
  fails (AArch64 is the most likely place); a CI badge and a "Tested on"
  list in the README.

**Phase 23 decisions (decided 2026-10-24):** all three as proposed – the
runners and jobs of 1, `Build-FPC.ps1` for Linux too (2), and the
capabilities report at the top of the test program's output (3).

**Phase 23 implementation notes** (2026-10-24):

- **[VERIFIED] The first run** (commit cb6e612): Linux x64 passed, Windows
  Server 2025 passed – it **has IoRing version 4**, Win32 and Win64 tested –
  and Linux ARM64 failed in 9 of 243 tests. The Linux runners allow
  io_uring (ARM64: Ubuntu 24.04.5, kernel 6.17 for Azure, SQPOLL allowed,
  63 opcodes): the test program's first lines said so.
- **[VERIFIED] AArch64 works**: the atomics with all their stress tests (the
  DMB barriers of §5.7), the ring, the engine, the layout tests, sockets
  and links passed on the first run on ARM.
- **Found: `O_DIRECT` was wrong on AArch64.** ARM64 has `fcntl.h` values of
  its own: there `040000` – `O_DIRECT` on x86-64 and in the generic header –
  is `O_DIRECTORY`, and `O_DIRECT` is `0200000`. FPC 3.2.2's
  `BaseUnix.O_DIRECT` is `040000` on every CPU, so every unbuffered open
  failed: `ENOTDIR` when opening, `EINVAL` when creating. Fixed with an
  own `O_DIRECT_FLAG` per CPU in `PIRUnit.Linux.Ring` (and in
  `PIRUnit.Test.PlatformHelpers`). The other open flags the library uses are the
  same on both CPUs.
- The logs of a run need a GitHub sign-in, the annotations do not (they
  can be read through the API). So the workflow's test steps go through a
  small script (`.github/scripts/Invoke-Tests.ps1`) that turns every failed
  test into an annotation with the test's name. On Linux the `-O3` tests and
  the layout check run also after a failed debug run, so one run shows
  everything.
- **[VERIFIED] The second run** (commit 8e46eac): with the `O_DIRECT` fix
  all 243 tests pass on ARM64, in the debug build and with `-O3`. Only the
  layout check failed, and only because the CI step compared whole files:
  the generated file's first lines name the header version and the CPU
  ("for AArch64"). The step now compares only the 373 checks, and reports a
  real difference as annotations.
- **[VERIFIED] The third run** (commit 2999f18) is green on all three
  runners, without warnings: Linux x64 and ARM64 (tests debug and `-O3`,
  the same layout checks on both CPUs, benchmarks built) and Windows Server
  2025 (Win32 and Win64, debug and `-O3`, benchmarks built). The whole run
  took 2.5 minutes (the three jobs run at the same time; FPC on Windows came
  from the cache).
- **The benchmarks on the runners** (run by hand, 2026-10-24; Benchmarks.md
  "GitHub's runners"): 19–38 minutes per runner with files of 1 and 4 GiB.
  Their disks are slow cloud disks (about 400 MiB/s, 20–27 thousand random
  reads per second), so the cold numbers are disk-bound. Artifacts, like
  logs, need a sign-in to download.
- **[VERIFIED] Found: on ARM64 the lock-free structures sometimes lose to a
  mutex** (queue with 2–3 producers in a tight loop 0.87–0.90, free list
  with 4 threads and work 0.88; on x86-64 they always win, Linux and
  Windows). Every atomic operation has full barriers around it on AArch64
  (§5.7), and FPC 3.2.2 does not inline its `ReadWriteBarrier` there – the
  compiler reports it 109 times for the structures benchmark. The rule of
  §10.5 asks for a look: planned as Phase 27.
- Two things not explained yet ([open], Benchmarks.md): on the Linux
  runners a block reader with 8 reads in flight beats 32 and 128 (27
  against 20 thousand blocks per second); on Windows unbuffered block reads
  gain nothing over `ReadFile` there (6.2 against 5.8 thousand). Parked in
  Phase 28 (§13).

### 12.6 Packages (Phase 24)

Today a program adds `Source/Units` to its search path. A package makes it
one step: the IDE knows the library, and the units are compiled once.

**Facts found before Phase 24** (trial packages in a scratch folder,
2026-10-24):

- **[VERIFIED] Delphi 13:** a runtime package named `Pascal.IOUring` – the
  same name as its main unit – builds without warnings for Win32 and Win64
  from the command line, with every unit except the two Linux ones. With
  `{$LIBSUFFIX AUTO}` the file is `Pascal.IOUring370.bpl` (the compiler
  version in the name, so packages of several Delphi versions can be
  installed side by side), the compiled interface `Pascal.IOUring.dcp`. A
  program that uses `Pascal.IOUring` with runtime packages (`rtl`,
  `Pascal.IOUring`) builds and runs (a 21 KB program).
- **[VERIFIED] Lazarus:** a package name must be an identifier, so
  `PascalIOUring`. A runtime-only package with all 14 units builds with
  `lazbuild` for Win64 and Win32 (Lazarus 5.0 RC1) and with the trunk
  Lazarus. The four backend units are not in the package's main unit
  (`AddToUsesPkgSection` False): each system then compiles only its own
  backend. Lazarus writes that main unit (`PascalIOUring.pas`, a plain
  `uses` list); compiled with FPC in WSL it takes the Linux backend.
- The library has no components, so no design-time package is needed.
- GitHub's runners have Free Pascal but no Lazarus; Delphi only runs here.

**Phase 24 proposal:**

- **[DECIDE] 1. Names and places.** Proposed:
  `Source/Packages/Delphi/Pascal.IOUring.dpk` (with its `.dproj`; Win32
  and Win64; runtime only; `{$LIBSUFFIX AUTO}`) and
  `Packages/Lazarus/PascalIOUring.lpk` (runtime only; all units, the
  backends kept out of the main unit as above; Lazarus's generated
  `PascalIOUring.pas` committed with it, as Lazarus packages usually are).
  Other choice: the plain name `PascalIOUring` for both.
- **[DECIDE] 2. Version and settings.** Proposed: both packages say version
  0.9 until the 1.0 release (Phase 25 sets it). The Delphi package's Debug
  configuration turns inlining off, like the test project; Release is
  optimized. Output folders: Delphi's defaults (the `Bpl` and `Dcp` folders
  of the Delphi version), Lazarus `lib/<cpu>-<os>` next to the package;
  both ignored by git.
- **[DECIDE] 3. How the packages are kept working.** Proposed: the local
  test run also builds the Delphi package (Win32 and Win64, Debug and
  Release) and the Lazarus package (`lazbuild`, Win32 and Win64); CI
  compiles the package's main unit with FPC on all three runners (no
  Lazarus needed there). The tests and benchmarks keep using
  `Source/Units` directly – nothing changes for them.
- Docs: the README tells how to install each package; GetIt, Lazarus's
  Online Package Manager or a `boss.json` for Boss come later (Phase 25 or
  after), once there is a version to point at.

**Phase 24 decisions (decided 2026-10-24):**

- **1 changed: no Delphi package.** In Delphi the library is compiled into
  the program from `Source/Units`; a package adds nothing there. Only the
  Lazarus package, in the place proposed:
  `Packages/Lazarus/PascalIOUring.lpk`, with its generated main unit.
- **2 changed: the version stays below 1.0 for a long time** – also when
  everything planned now is done. Once others use the library, suggestions
  (also for the API) are expected first. The package starts at **0.1**;
  Phase 25 tags a first version (0.x), not 1.0.
- **3 changed: local first.** The packages are checked in the local test
  run (`lazbuild`, and `Build-FPC.ps1 -Project Package`). CI keeps its tests
  on every push (about 2.5 minutes), compiles the package there too, and is
  looked at when a change needs it. **The benchmarks no longer run in CI**:
  they take a long time and resources on GitHub's side, and the slow cloud
  machines say little (the one run of Phase 23 stays in Benchmarks.md).

**Phase 24 implementation notes** (2026-10-24):

- `Packages/Lazarus/PascalIOUring.lpk`: runtime only, version 0.1,
  requires FCL, all 14 units and the include file; the four backend units
  with `AddToUsesPkgSection` False. Paths are relative (`../../Units`).
  `lazbuild` left the hand-written `.lpk` as it was.
- The generated main unit `PascalIOUring.pas` is committed. Lazarus writes
  it in its own format (ASCII, CRLF, no BOM) whenever the package is
  compiled, so `Normalize-SourceEncoding.ps1` skips it by default – the two
  would otherwise keep changing it back and forth.
- `Build-FPC.ps1 -Project Package` compiles that main unit with FPC, like
  Lazarus does: the same check on Windows, in WSL and on the CI runners,
  where there is no Lazarus. Each build takes its own backend (Windows on
  Win32/Win64, Linux on Linux).

### 12.7 Examples and the first tagged version (Phase 25)

Today the README has short snippets; there is no program a user can open
and run. And there is no version anyone can point at.

**Facts found before Phase 25** (a trial example in a scratch folder,
2026-10-24):

- **[VERIFIED] One program file serves every compiler.** A `.dpr` with
  `{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}` and `cthreads` under `{$IFDEF UNIX}`
  builds with Delphi through a `.dproj` made from the benchmarks' template
  (Win32 and Win64, Debug and Release), with Lazarus through an `.lpi`
  whose main file is the `.dpr` and which requires the `PascalIOUring`
  package (`lazbuild` finds it through a relative path), and with plain FPC.
  The programs run.
- The README's examples use only the library and the RTL – no Windows
  calls – so the same file works on Linux.

**Phase 25 proposal:**

- **[DECIDE] 1. The examples.** Proposed, in `Source/Examples/<Name>/`:
  - `Capabilities` – what the ring offers on this system (`ToString`).
  - `CopyFile` – the two streams as drop-in `TStream`s: copy a file,
    then compare.
  - `Checksum` – the zero-copy reader (`TryAcquireChunk` /
    `ReleaseChunk`): a checksum of a file and its MiB/s.
  - `ReadBlocks` – the block reader: blocks known in advance, read ahead
    and handed out in order.
  - `EngineCallbacks` – the engine: reads started from several threads,
    callbacks on the I/O thread, `Wait`, a batch.
  - `SocketEcho` – Linux only: an echo over TCP on loopback through
    `PrepareSqe` (accept, receive, send).

  Each one short and commented, and it runs without arguments (it makes a
  temporary file and deletes it) or takes a file name. Other choice: fewer
  examples, for example only the first three.
- **[DECIDE] 2. Project files and checks.** Proposed: each example is a
  `.dpr` with a `.dproj` (Delphi, Win32 and Win64; not for `SocketEcho`)
  and an `.lpi` (Lazarus, through the package). `Build-FPC.ps1 -Project
  Examples` builds all examples of a platform with plain FPC. The local
  test run builds them (Delphi, FPC, Linux) and runs each once without
  arguments – they take seconds; CI does the same on its runners.
- **[DECIDE] 3. The first tagged version, 0.1.0.** Proposed:
  - `CHANGELOG.md` with what 0.1.0 has (in short, by milestone);
  - a constant `IORING_LIBRARY_VERSION = '0.1.0'` in `PIRUnit.IORing`, and
    `IORingCapabilities.ToString` names it, so a log says which version
    ran;
  - the README links the examples and says how to get a version;
  - you make the tag `v0.1.0` (and, if you like, a GitHub release with the
    CHANGELOG text) – tags and releases are yours, like commits.

  Other choice: no version constant (the tag and the CHANGELOG only).

**Phase 25 decisions (decided 2026-10-24):**

- **1:** the six programs as proposed, but called **demos**, in
  `Source/Demos/<Name>/`.
- **2** as proposed.
- **3 changed: no tag yet** – and so no CHANGELOG yet either. The version
  constant `IORING_LIBRARY_VERSION = '0.1.0'` comes now: `ToString` names it
  on its last line, so a log says which version ran.

**Phase 25 implementation notes** (2026-10-24):

- Six demos and a small shared unit (`Demos/Common/PIRUnit.Demo.Common.pas`: a
  temporary file written with `TFileStream`, a clock; nothing from the
  library). Each demo compares its result with a plain way of doing the
  same – `CopyFile` the two files, `Checksum` an Adler-32 over
  `TFileStream`, `ReadBlocks` the sum of the same blocks read with `Seek` +
  `Read` – so running it is also a check.
- The `.dproj` files come from the benchmarks' template; the `.lpi` files
  require the package through a relative path (`lazbuild` finds it without
  a registered package).
- `SocketEcho` closes its sockets before it frees the client thread, and
  the client sends with `MSG_NOSIGNAL`: after an error neither a hang nor a
  `SIGPIPE` ends the program.
- `Build-FPC.ps1` builds a list of programs now (one, or every demo).
  The compiler's and the programs' output stays in the script's output –
  `Invoke-Tests.ps1` in CI reads the test program's lines from there – so
  the steps are in the loop itself, not in PowerShell functions (whose
  output would become their return value).
- `ToString` ends with the library line also when the ring is not
  available.

### 12.8 Big reads straight into the caller's buffer (Phase 26)

The read stream copies twice: the kernel copies into the reader's 1 MiB
buffers, and `Read` copies from there into the caller's memory. With data in
the file cache that is the gap to `TFileStream` (16–31 % in the benchmarks,
Benchmarks.md). §7, point 7 parked the idea: when one `Read` asks for more
than the buffers hold, read straight into the caller's memory.

**Facts found before Phase 26** (a measuring program in a scratch folder,
2026-10-24; a 4 GiB file read in `Read` calls of 64 MiB and of 8 MiB,
median of 3 runs, MiB/s). "Direct" is the upper limit of the idea: each call
done on a ring as 8 reads in flight straight into the caller's buffer, then
waited for – no reading ahead between calls:

| | 64 MiB calls, cold | warm | 8 MiB calls, cold | warm |
| --- | ---: | ---: | ---: | ---: |
| *Windows (this machine's NVMe disk)* | | | | |
| TFileStream | 3 349 | **7 199** | 4 279 | **8 726** |
| the stream now (copies) | **6 655** | 6 129 | **6 716** | 6 278 |
| direct | 5 523 | 6 951 | 5 285 | 8 466 |
| *Linux (WSL2; cold is not the disk)* | | | | |
| TFileStream | 3 931 | **11 759** | 4 117 | **15 387** |
| the stream now (copies) | **4 604** | 9 919 | **4 918** | 10 280 |
| direct | 3 878 | 11 663 | 4 069 | 15 253 |

- **[VERIFIED] Warm, reading straight into the caller's buffer closes the
  gap**: 97–99 % of `TFileStream`, where the stream now gets 67–85 %.
- **[VERIFIED] Cold, it loses 16–21 % to the stream now**, because each
  call waits for its own reads and nothing is read ahead for the next call:
  the disk stands still between calls. So the idea needs both – the call's
  own bytes straight into the caller's memory, and reading ahead after the
  end of the call as now.
- **Big calls are common:** Delphi's `TMemoryStream.LoadFromStream` and
  `TBytesStream` read the whole stream with one `ReadBuffer`;
  `TStrings.LoadFromStream` does so for files up to about 336 MB;
  `CopyFrom` works in 1 MiB pieces (the size of one buffer – no gain there).
  Small calls (64 KiB) cannot avoid the copy; the zero-copy reader is the
  tool for them (within 10 % of plain reads).
- **The Linux clock** (Phase 26 in the plan: the C library's
  `clock_gettime`, 13 instead of 94 ns): the library reads the clock only
  on slow paths – twice per stall, and in the request pool's spin. An
  unbuffered 1 GiB read has about 1 000 stalls: about 2 000 reads of the
  clock, 0.16 ms per GiB saved, less than 0.1 % of the time.

**Phase 26 proposal:**

- **[DECIDE] 1. Build it, and keep it only if it wins.** Proposed: in
  `TIORingSequentialReader.Read` (the stream uses it, so both get it), the
  part of a call that the read-ahead buffers do not cover is read straight
  into the caller's memory, in pieces of the buffer size, up to the
  read-ahead count in flight; meanwhile the reader's buffers read ahead
  after the end of the call. Kept only if, in the measurements above, it is
  as fast as `TFileStream` warm and not slower than now cold, and the
  64 KiB calls of the benchmark do not change. Other choice: do not build
  it, and say in the README that big reads are faster with the zero-copy
  reader.
- **[DECIDE] 2. When a call goes straight to the caller's memory.**
  Proposed: only the part of a call beyond what the buffers hold (by
  default 8 MiB), so calls up to that size work as now; unbuffered only
  when the caller's address and the part's length are multiples of the
  sector size – otherwise as now. Other choice: from a fixed call size
  (for example 2 MiB), with the buffers in flight drained first.
- **[DECIDE] 3. The Linux clock stays as it is** (measured: less than
  0.1 %); Phase 26 drops it. Other choice: change it anyway (one function,
  the C library's `clock_gettime`).

**Phase 26 decisions (decided 2026-10-24):** all three as proposed – build
it and keep it only if it wins (1), only the part beyond what the buffers
hold, unbuffered only when aligned (2), the Linux clock stays (3).

#### Implementation notes (Phase 26)

- **Where:** `TIORingSequentialReader.Read`. The stream calls it, so
  `TSequentialReadOnlyFileStream` and the RTL helpers on top of it
  (`LoadFromStream`, `ReadBuffer` …) get it too. `TryAcquireChunk` is
  unchanged.
- **Which part of a call:** from where the buffers' reads end
  (`FNextReadOffset`) to the end of the call or of the file, if that is at
  least one buffer. Unbuffered, the end is rounded down to a whole sector,
  and the caller's memory for that part must start on a sector boundary;
  otherwise the call goes through the buffers as before. Calls no bigger
  than what the buffers have asked for (64 KiB calls, for example) never
  read directly.
- **How:** in pieces of the buffer size, up to the buffer count in flight,
  each straight into the caller's memory (a plain pointer; the file stays
  registered). Meanwhile `Read` copies what the buffers hold before that
  part, then waits for the pieces and starts new ones as old ones finish.
- **Measured and changed – the buffers wait for the call's pieces.** In the
  first version the buffers began reading ahead after the end of the call
  at once – 64 MiB further on in the file – while the call's own pieces
  were still being read. Cold, with 64 MiB calls, that lost 6 % (6 300
  against 6 720 MiB/s): Windows reads ahead in its file cache when it sees
  reads in file order, and reads at two places at once spoil that. Now the
  buffers start reading ahead only when all of the call's pieces have
  started, so the file is read in order.
- **Tried and dropped (no gain measured):** letting a wait for the call's
  pieces also grow the buffers' read-ahead (as a wait for a buffer does);
  pieces of 2 MiB with 4 in flight instead of 1 MiB with 8. Registration
  explains only a small part of what is left: the old reader without
  registration lost 0.7 % in the same test.
- **No read in flight into the caller's memory after `Read`:** `Read`
  returns only when all its pieces are done. On an exception it starts no
  more pieces and waits for those in flight before it raises.
- **A failed big read:** a failed piece raises `EIORingError` once all the
  pieces are back, and every later call raises too – the buffers have
  already moved past the call, so going on would leave a gap in the data.
  The same for any other exception during a big read.
- **Short pieces:** the file got shorter after `Open`. The data ends at the
  first short piece; `Read` returns what is there and `Eof` becomes `True`,
  as with the buffers.
- **Ring size:** one entry per buffer and per piece, `2 × BufferCount + 2`.
- **Statistics:** `Stats.DirectReads` and `Stats.DirectBytes`;
  `BytesFromDisk` counts both kinds; a wait for the pieces counts as a stall.

**Results** (2026-10-24, the same measuring program as above; the reader
before and after Phase 26 built from the same sources and run in turns, two
runs each, each the median of 3; MiB/s):

| | 64 MiB calls, cold | warm | 8 MiB calls, cold | warm | 64 KiB calls, cold | warm |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| *Windows* | | | | | | |
| TFileStream | 3 280–3 320 | 7 160–7 360 | 4 060–4 200 | 8 720–9 020 | 1 410–1 610 | 8 000–8 130 |
| the stream before | 6 703 / 6 737 | 6 530 / 6 418 | 6 742 / 6 696 | 6 492 / 6 356 | 6 740 / 6 782 | 7 296 / 7 111 |
| the stream now | 6 601 / 6 568 | **6 879 / 7 061** | 6 716 / 6 724 | **7 685 / 7 744** | 6 755 / 6 735 | 7 205 / 7 208 |
| *Linux (WSL2; cold is not the disk)* | | | | | | |
| TFileStream | 3 040–4 670 | 11 090–11 740 | 3 430–4 030 | 13 740–15 130 | 3 510–5 560 | 14 550–16 290 |
| the stream before | 4 365 / 4 233 | 9 571 / 10 117 | 4 187 / 4 021 | 10 025 / 9 785 | 4 618 / 5 120 | 11 632 / 11 806 |
| the stream now | **5 249 / 5 155** | **11 154 / 11 439** | **4 651 / 4 772** | **12 065 / 12 405** | 3 256* / 5 445 | 10 227* / 11 963 |

\* A slow run: `TFileStream` was slower in it too. 64 KiB calls never read
directly.

- **[VERIFIED] Warm, big calls come close to `TFileStream`:** 64 MiB calls
  get 96–98 % of it on Windows (before: 89 %) and 97–101 % on Linux
  (before: 83–89 %). 8 MiB calls get 86 % on Windows (before: 72 %) and
  82–90 % on Linux (before: 65–68 %) – not all of it, because 2 of each
  8 MiB were already asked for by the buffers, and those are still copied
  (decision 2).
- **[VERIFIED] Cold:** 8 MiB and 64 KiB calls as before. 64 MiB calls are
  20–22 % faster on Linux, and **about 2 % slower on Windows** (the median of
  all runs of the final version: 6 574 against 6 735 MiB/s).
- **The process's CPU time** for 64 MiB calls, cold, on Windows: 125–188 ms
  against 297–406 ms – the copy is gone (the kernel's copy is not counted,
  Benchmarks.md "Known limits").

- **4. Keep it?** Against the rule of decision 1 it does not win
  everywhere: warm 8 MiB calls get 86 %, not all of `TFileStream`, and cold
  64 MiB calls on Windows lose about 2 %. Proposed: keep it – warm big calls
  gain 8–24 % on both systems, cold big calls gain 11–22 % on Linux, and a
  program that works on the data between calls saves the copy's CPU time
  (reasoning, not measured). Other choice: drop it (the code goes back; the
  measurements stay here).

**Phase 26 decision 4 (decided 2026-10-24):** keep it, as proposed. The
open point – why cold 64 MiB calls on Windows are about 2 % slower – is not
explained (§13).

### 12.9 The atomics on AArch64 (Phase 27)

On GitHub's ARM64 runner the lock-free structures sometimes lose to a mutex
(Benchmarks.md, "GitHub's runners"): the queue with 2–3 producers in a tight
loop gets 0.87–0.90 of the mutex queue, the free list with 4 threads and
work 0.88. On x86-64 they always win.

**Facts found before Phase 27** (`PIRUnit.Atomics` and the FPC
3.2.2 sources, 2026-10-25):

- FPC 3.2.2's `InterlockedCompareExchange`, `InterlockedExchange` and
  `InterlockedExchangeAdd` on AArch64 are `ldxr`/`stxr` loops **without any
  ordering**. So `TAtomic` puts `ReadWriteBarrier` (`dmb ish`, a full
  barrier) before and after each of them – and FPC 3.2.2 does not inline
  `ReadWriteBarrier` there. **One compare-exchange is three calls and two
  full barriers.**
- `LoadAcquire` is a load and a call to a full barrier; `StoreRelease` a
  call to a full barrier and a store. AArch64 has single instructions for
  both, weaker and cheaper: `ldar` (load-acquire) and `stlr`
  (store-release).
- **`CpuPause` is empty on AArch64** (marked [VERIFY] in the code): the
  back-off after a lost race spins without any hint to the CPU. On x86 it is
  `pause`. AArch64 has `yield`; some runtimes use `isb` instead, because
  `yield` does almost nothing on many ARM cores.
- FPC's trunk has single-instruction atomics (LSE, ARMv8.1: `casal`,
  `swpal`, `ldaddal`, under `CPUAARCH64_HAS_LSE`) and a `yield` intrinsic;
  FPC 3.2.2 – the version in CI – has neither. Its AArch64 instruction
  table (`compiler/aarch64/a64att.inc` of the 3.2.2 release) has `ldxr`,
  `stlxr`, `ldar`, `stlr`, `dmb`, `isb` and `yield`, but no LSE
  instructions (`cas`, `casal` …).
- The only AArch64 machine at hand is GitHub's ARM64 runner. The CI no
  longer runs benchmarks (§12.6, Phase 24).

**Phase 27 proposal:**

- **[DECIDE] 1. Where and how to measure.** Proposed: a second workflow,
  started only by hand (`.github/workflows/arm64-atomics.yml`,
  `workflow_dispatch`), on the ARM64 runner: the tests (debug and `-O3`),
  then the Structures benchmark built twice – the atomics as they are now and
  the new ones (a define picks them) – run in turns, as in Phase 26. The
  summary also goes out as annotations of the run, so it can be read without
  signing in; the full output as an artifact. The CI on every push stays
  without benchmarks. Other choice: an input of the existing CI workflow
  (removed in Phase 24).
- **[DECIDE] 2. What to build.** Proposed: small assembler routines for
  AArch64 (Free Pascal only) in `PIRUnit.Atomics`, with the same
  rules for callers as now (§10.6):
  - compare-exchange, exchange and fetch-add: one routine each – an
    `ldxr`/`stlxr` loop and one `dmb ish` after it (the fully ordered
    pattern of the Linux kernel): one call and one barrier instead of three
    calls and two;
  - `LoadAcquire` an `ldar`, `StoreRelease` an `stlr`;
  - `CpuPause` a `yield` – and `isb` measured as a second choice.

  Kept only where the benchmark shows a gain and the tests pass on ARM64.
  Other choice: LSE instructions (`casal` …) as well, picked at run time
  when the CPU has them (Linux `getauxval(AT_HWCAP)`) – more code; proposed
  only as a later step if the ARM64 numbers still lose.
- **[DECIDE] 3. If lock-free still loses on ARM64 after that.** The rule of
  §10.5 is "a lock-free structure stays only where it beats the lock".
  Proposed: one code path for all CPUs – no mutex just for AArch64 – unless
  it still loses by more than 10 % in the scenarios with work (the ones like
  real use); then a separate decision with the numbers. Other choice: switch
  to a mutex on AArch64 wherever it wins.

**Phase 27 decisions (decided 2026-10-25):** all three as proposed – a
hand-started ARM64 workflow that measures the old and the new atomics in
turns (1), assembler routines for AArch64, each kept only if it wins (2),
one code path for all CPUs unless lock-free still loses by more than 10 %
with work (3).

#### Implementation notes and results (Phase 27)

- **The routines:** private assembler methods of `TAtomic`
  (`A64CompareExchange32` …), called by the inline public methods, so each
  operation is one call. Read-modify-write: `ldxr`, `stlxr`, `dmb ish` – the
  compare-exchange always stores (the old value back when it does not
  match, as FPC's own routine does), so a failed one orders like the others
  and the rules for callers stay as they were. `LoadAcquire` = `ldar`,
  `StoreRelease` = `stlr`, `FullBarrier` = `dmb ish`, `CpuPause` = `isb`.
  FPC 3.2.2 accepted all of them (CI, 2026-10-25), and the tests pass on
  ARM64, debug and `-O3`.
- **For comparing:** `IORING_ATOMICS_AARCH64_RTL` builds the way before
  Phase 27, `IORING_ATOMICS_AARCH64_YIELD` the `yield` spin hint;
  `Build-FPC.ps1 -Define` passes them, and the ARM64 atomics workflow
  measures all three in turns.
- **Results** (ARM64 runner, 4 processors, run 40170491363; two rounds;
  lock-free Mops/s, in brackets lock-free ÷ mutex; raw output:
  [BenchmarkResults/2026-10-25-ci-arm64-atomics.txt](BenchmarkResults/2026-10-25-ci-arm64-atomics.txt)):

| | before (`rtl`) | assembler, `yield` | assembler, `isb` |
| --- | --- | --- | --- |
| Free list, tight, 1 thread | 27.4 / 27.4 | 41.7 / 41.8 | 41.6 / 41.8 |
| Free list, tight, 4 threads | 3.3 (0.47) / 6.2 (1.04) | 9.6 (1.66) / 8.3 (1.07) | 9.4 (1.75) / 21.6 (3.22) |
| Free list, work, 4 threads | 1.95 (1.00) / 1.32 (0.67) | 2.05 (1.06) / 2.22 (1.02) | 1.93 (1.02) / 2.25 (1.13) |
| Queue, tight, 1 producer | 24.1 / 22.2 | 29.2 / 30.5 | 31.1 / 31.6 |
| Queue, tight, 2 producers | 6.3 (1.24) / 4.4 (0.92) | 9.3 (1.59) / 8.9 (1.72) | 28.4 (6.67) / 32.8 (5.30) |
| Queue, tight, 3 producers | 3.7 (1.09) / 3.2 (1.01) | 3.8 (1.08) / 3.9 (1.15) | 26.7 (8.53) / 32.5 (8.76) |
| Queue, work, 3 producers | 2.98 (1.74) / 2.91 (1.65) | 2.94 (1.82) / 2.98 (1.59) | 2.97 (1.68) / 2.98 (1.77) |

- **[VERIFIED] The assembler routines** alone: +52 % for the free list and
  +30 % for the queue with one thread (one call and one barrier instead of
  three calls and two).
- **[VERIFIED] `isb` is what helps under contention:** with 2–3 producers
  the queue gets 7–9 times the speed of before; `yield` hardly helps (as
  other runtimes found on ARM cores). So `CpuPause` is `isb`.
- **[VERIFIED] Lock-free now beats the mutex everywhere on ARM64** (with
  work, 1.00–1.77). Decision 3 is not needed: one code path for all CPUs.
- Noise: the runner's numbers jump between rounds (free list, tight, 4
  threads: 9.4 and 21.6), so only differences seen in both rounds count.

### 12.10 Review before 0.1.0 (Phase 28)

A review of the code, its API and names, and its structure, 2026-10-25
(Plan, Milestone 7). The library is in good shape: one unit per job, one
backend unit per system, no unit over about 1 550 lines, one style. What
it found:

**Names and API** (all public; the version is 0.x, so changes are fine):

- Timeouts are `ATimeoutMs` in the rings and `ATimeoutMilliseconds` in the
  engine, the request pool and the atomics. "Wait forever" is
  `IORING_INFINITE` and, in `Delphi.IOUring.Atomics`, also
  `IORING_WAIT_INFINITE` (the same value).
- The statistics types do not match their owners:
  `TIORingSequentialReader` has `TIORingReaderStats`,
  `TIORingSequentialWriter` has `TIORingWriterStats` (the block reader's is
  `TIORingBlockReaderStats`). `TIORingEngine.Stats` is a function, the
  others are properties.
- `ReadAt` and `WriteAt` (`Delphi.IOUring`) have very general names; the
  other routines there start with `IORing`.
- The engine takes `AUserData: NativeUInt`, the rings `TIORingUserData`
  (the same type).
- Internal types are in the interface: the slot records of the readers and
  the writer, `TIORingQueueCell`, and `TCardinalArray`/`PCardinalArray` –
  a name general enough to clash with other code.

**Unit names and structure:**

- `Delphi.IOUring.Backend.Custom` holds the types shared by all systems;
  "Custom" says nothing about that. `Delphi.IOUring.Backend.Posix` and
  `….Posix.API` are Linux only (io_uring is Linux's), not POSIX.
- The two backend units are the largest (Linux 1 553 lines, Windows 1 076):
  each holds the ring and the platform helpers (`T…IORingPlatform`: files,
  memory, clock, events).
- The reader and the writer check their buffer arguments with the same
  code, written twice.

**Speed** (measurable, small):

- **The engine's wait spin reads the clock every 8 pauses**
  (`TIORingRequestPool.WaitFor`). On Linux that clock is FPC's
  `clock_gettime`, a system call: 94 ns, against 13 ns through the C
  library (§10.14). In the 4 µs spin that is about a third of the time in
  system calls. Phase 26 measured only the reader's stalls (less than
  0.1 %), not this spin.
- FPC x64 calls a small RTL routine for every atomic operation (Delphi
  inlines its own). Not changeable with FPC 3.2.2: assembler routines cannot
  be inlined there.

**Phase 28 proposal:**

- **[DECIDE] 1. Unit names.** Proposed: `Backend.Custom` →
  `Delphi.IOUring.Types`, `Backend.Posix` → `Backend.Linux`,
  `Backend.Posix.API` → `Backend.Linux.API` – together with the library's
  new name (Pascal.IOUring), in one step before the tag, since every unit
  name changes then anyway; asked before it is done. Other choice: rename
  the units now.
- **[DECIDE] 2. API names.** Proposed, all of them: one timeout name
  `ATimeoutMilliseconds` and one `IORING_INFINITE`;
  `TIORingSequentialReaderStats` and `TIORingSequentialWriterStats`, and
  `TIORingEngine.Stats` a property; `IORingReadAt` and `IORingWriteAt`;
  `TIORingUserData` in the engine.
- **[DECIDE] 3. Internal types.** Proposed: they become nested types of the
  record that uses them (both compilers have nested types in records), so
  the interface shows only what users need, and `TCardinalArray` cannot
  clash any more. Other choice: only rename them.
- **[DECIDE] 4. Smaller backend units.** Proposed: the platform helpers go
  to units of their own (`Backend.Windows.Platform`,
  `Backend.Linux.Platform`), the ring stays in the backend unit; one shared
  check for the buffer arguments of the reader and the writer. The engine
  stays as it is (its overlap bookkeeping belongs to the I/O thread).
- **[DECIDE] 5. The wait spin.** Proposed: on Linux, the clock through the
  C library (the programs link it already, for threads); measured with the
  engine (Blocks benchmark, cached blocks) in WSL2 and on the ARM64 runner,
  and kept only if it gains. Other choice: count the spin in pauses,
  measured once at start, so the spin reads no clock at all.
- **[DECIDE] 6. The small things.** Proposed: close §14 (keep the neutral
  `TIORingFileRef`/`TIORingBufferRef` records – the conversion never showed
  in a benchmark); remove the answered [VERIFY] markers (§5.7, §6.4); park
  the two unexplained findings of GitHub's runners (§13); write a plan for
  Linux sockets as a part of their own (§13, decided a.); run the Windows
  benchmarks again at the end, after the changes.

Last, the tag 0.1.0 (decided c.), after asking about the new name.

**Phase 28 decisions (decided 2026-10-25):** all six as proposed – the unit
names change together with the library's name, asked first (1); the API
names (2); nested internal types (3); platform units of their own and one
buffer check (4); the C library's clock on Linux, kept only if it gains (5);
the small things (6).

**Phase 28 implementation notes** (2026-10-25):

- **API names (2):** `ATimeoutMilliseconds` everywhere; only
  `IORING_INFINITE` (the atomics use it from `PIRUnit.Types`);
  `TIORingSequentialReaderStats` and `TIORingSequentialWriterStats`;
  `TIORingEngine.Stats` is a property; `IORingReadAt` and `IORingWriteAt`;
  the engine's user data is `TIORingUserData`.
- **Nested types (3):** the slots of the sequential reader (and its reads
  straight into the caller's memory), of the writer and of the block reader
  (`TSlot`, `PSlot`, `TSlotState`, `TDirectRead`), the queue's cells
  (`TCell`, `TCellArray`) and the free list's links (`TIndexArray`) are
  nested types of the records that use them. In the implementation the
  method headers name them with the record (`TIORingBlockReader.PSlot`);
  inside the methods the short name is enough. Both compilers accept this
  (Delphi 13, FPC 3.2.2 and trunk). The structures benchmark has its own
  `TCardinalArray` now.
- **Platform units (4):** `PIRUnit.Windows.Platform`
  (`TWindowsIORingPlatform`) and `PIRUnit.Linux.Platform`
  (`TLinuxIORingPlatform`, renamed with the other Linux units later);
  `PIRUnit.IORing` exports them as `TIORingPlatform` as before, so user code
  does not change. The ring units are now 827 (Windows) and 1 285 (Linux)
  lines, the platform units 270 and 326. The Lazarus package lists the two
  new units. Three constants are in both Linux units (`SYSCALL_EVENTFD2`,
  `O_CLOEXEC_FLAG`, `EFD_CLOEXEC`): the API unit translates only the
  io_uring header, and a shared unit for three constants is not worth it.
- **One buffer check (4):** `IORingCheckBufferArguments` (size a multiple
  of the unit, count in range, all buffers together not too big; returns
  the total size) and `IORingCheckSectorMultiple` in `PIRUnit.Types`, used
  by the reader and the writer. The unbuffered message now says
  "Unbuffered I/O needs …" for both.
- **The clock (5): [VERIFIED] no gain in WSL2, so FPC's clock stays.** The
  Blocks benchmark (new option `--cache warm`; 1 GiB file, 20 000 blocks,
  median of 5 runs) built with each clock, six rounds in turns, the order
  reversed after three. Thousand blocks per second, average of the rounds
  (raw output:
  [BenchmarkResults/2026-10-25-linux-wsl2-clock.txt](BenchmarkResults/2026-10-25-linux-wsl2-clock.txt)):

| Contender (warm cache) | FPC's (system call) | C library (vDSO) |
| --- | ---: | ---: |
| Random, block reader, read-ahead 1 | 44.3 | 45.5 (+2.6 %) |
| Random, block reader, read-ahead 8 | 463 | 471 (+1.6 %) |
| Random, block reader, read-ahead 32 | 1 472 | 1 406 (−4.5 %) |
| Random, block reader, read-ahead 128 | 1 555 | 1 553 |
| Sorted, block reader, read-ahead 1 | 52.4 | 52.7 |
| Sorted, block reader, read-ahead 8 | 737 | 602 (−18 %) |
| Sorted, block reader, read-ahead 32 | 1 617 | 1 594 (−1.4 %) |
| Random, `pread` (does not use the clock) | 1 822 | 1 814 |

  - Read-ahead 1, where the engine waits for every block, is within the
    noise, CPU time the same (446 against 460 ms). The spin ends after
    4 µs either way; a cheaper clock only lets it check more often.
  - Read-ahead 32 (random) and 8 (sorted) were slower with the C library's
    clock in nearly every round, in both orders; not explained. Either way
    nothing gains.
  - `IORING_CLOCK_LIBC` builds the C library's clock, for comparing. The
    hand-started ARM64 workflow (now "ARM64 benchmarks") can measure both
    clocks there (`benchmark: clock`) – not run yet.
- **[VERIFIED] A hang on Linux, found and fixed:** in the full test run a
  writer test hung for good. `/proc` showed one completion in the ring
  (CQ tail 1, head 0: a 4 KiB write, done) and the ring's eventfd at 0;
  the I/O thread slept in `poll`, the test waited for the request. The I/O
  thread asked for the ring's completion event only when it went to sleep
  the first time, and on Linux that first call registers the eventfd: a
  completion posted before it (here a write that the kernel had handed to
  its worker thread) never signals it. Since Phase 21; Windows creates its
  event in `Open`. Now the I/O thread takes the event right after opening
  its ring, before anything is submitted, and the comment of
  `TLinuxIORing.CompletionEventHandle` says so.
- **The small things (6):** §14 closed; the answered [VERIFY] and
  [DECIDE later] markers replaced by their answers (§2, §5.1, §5.7, §6.4);
  the two findings of GitHub's runners and a plan for Linux sockets in §13.
  The Windows benchmarks ran again (Benchmarks.md, "The Windows numbers
  again"): the same as before or better – nothing the library does got
  slower.
- **The new names (1),** after asking, in two steps:
  - The library is **Pascal.IOUring** (it is as much Free Pascal as Delphi):
    the projects (`Pascal.IOUring.UnitTests`, `Pascal.IOUring.Benchmarks…`),
    the Lazarus package `PascalIOUring`, the repository.
  - Units, forms and include files get the owner's naming scheme
    (CodingStyle.md, "Units and files"): the prefix `PIR`, the kind, then
    what the unit holds – not the library's name again. `PIRUnit.IORing`
    (the unit user code `uses`), `PIRUnit.Types`, `PIRUnit.Engine`, …; each
    system's three units are `PIRUnit.<System>.API` (the OS header),
    `….Ring` (the library's ring) and `….Platform` (files, memory, clock,
    events) – the word "Backend" said nothing the system's name does not.
    Tests are named after the tested unit (`PIRUnit.Engine.Tests`), their
    helpers `PIRUnit.Test.…`, benchmarks `PIRUnit.Benchmark.…`; the include
    files `PIRInclude.Compiler.inc` and `PIRInclude.Linux.API.Layout.inc`.
  - Folders: the Delphi test and benchmark projects in `Delphi/` (next to
    `FPC/` and `Linux/`), the package in `Packages/Lazarus` at the root.
  - The text of this design uses the new names everywhere except in the
    review above. The owner renamed the GitHub repository and the local
    folder.
- **No "local global variables"** (a new rule in CodingStyle.md): nested
  routines come before the routine's `var` section and get what they need
  as parameters. Six places did otherwise, five of them changing the
  outer routine's variables; all six were rewritten (none was on a hot
  path). `CheckAvailability` on Linux needed no nested function at all: the
  probe loop fills the set of the kernel's opcodes, and the checks look
  there.
- **Done (2026-10-25):** CI green on the renamed repository (Windows, Linux
  x64, Linux ARM64), and the owner tagged **0.1.0** on commit `766b35c`.
  Not run: the clock comparison on the ARM64 runner (optional).

---

## 13. Ideas parked for later

- Lighter record-based replacements for RTL containers, only if profiling
  asks for them (§4.2).
- Linux extras beyond Phase 22 (§5.8): typed socket methods (`PrepareSend`,
  `PrepareRecv` …) on top of `PrepareSqe`; multishot operations and
  zero-copy send (they need the CQE flags in the completion and a count
  that knows `IORING_CQE_F_MORE`); SQPOLL in `TLinuxIORing`, if a benchmark
  ever shows a gain.
- Why cold 64 MiB `Read` calls on Windows are about 2 % slower when read
  straight into the caller's memory than through the buffers (§12.8). Not
  explained: the memory not being registered explains 0.7 %; bigger pieces
  and more reading ahead did not help.
- Two findings on GitHub's runners (Phase 23, §12.5; Benchmarks.md): on the
  Linux runners a block reader with 8 reads in flight beats 32 and 128 (27
  against 20 thousand blocks per second); unbuffered on Windows, the block
  reader gets no more than `ReadFile` (6.2 against 5.8 thousand). Parked in
  Phase 28: slow, throttled cloud disks, not the machines the library is
  for. Looking into them needs benchmarks on the runners (a hand-started
  workflow, as in Phase 27).
- **Linux sockets – a plan** (Phase 28; Milestone 7: low priority, a part of
  the library of its own). Today sockets work through
  `TLinuxIORing.PrepareSqe` (§5.8, the `SocketEcho` demo). When a real
  program needs more:
  1. **Units of their own,** Linux only, on top of `TLinuxIORing`; the file
     part of the library does not change (Windows IoRing has no sockets).
  2. **Typed Prepare methods:** `PrepareAccept`, `PrepareConnect`,
     `PrepareSend`, `PrepareRecv`, `PrepareShutdown`, `PrepareClose` – a few
     lines each over `PrepareSqe`. Tests on a socket pair and on loopback,
     as in Phase 22; `SocketEcho` uses them.
  3. **A socket engine:** an I/O thread with its own ring, like the file
     engine, but for requests that wait for the network – a receive may
     never complete, so cancelling and time limits (a linked
     `IORING_OP_LINK_TIMEOUT`) are needed from the start. The overlap rules
     of files do not apply.
  4. **Only if a benchmark asks for it:** multishot accept and receive with
     provided buffers (the CQE flags in the completion, and a completion
     count that knows `IORING_CQE_F_MORE`), zero-copy send, SQPOLL.
  - Measured against a plain `epoll` server: an echo server with many
    clients, requests per second and CPU time.

---

## 14. Open questions

None at the moment. Answered earlier: overlap handling in the engine (Phase
16 – §11 and decision 15); the Linux backend: raw syscalls, no liburing
(Phase 18 – §6.4 and decision 17); neutral ref records against records with
the OS's layout: the neutral records stay (Phase 28 – §5.1 and §12.10).

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
| 13 | 2026-10-22 | Free Pascal tests are **separate FPCUnit test units** (`Source/UnitTests/FPC`), not a shared source with the DUnitX tests. *Replaced by decision 18 (Phase 19): one set of tests.* |
| 14 | 2026-10-22 | In FPC the IoRing functions are **looked up with `GetProcAddress` on first use** (no `delayed` in FPC 3.2.2); a missing function returns `E_NOTIMPL`. |
| 15 | 2026-10-23 | **Overlap rules in the engine: an option** (`orKeepOrder`, §11). For one file handle, requests that touch the same bytes take effect in start order; conflicting later requests are held back, and the requests of a handle are routed to one I/O thread. The core ring keeps no rules (A). |
| 16 | 2026-10-23 | **The write stream writes through an engine** (its own by default, or a shared one): Windows does buffered writes inside the submit call, so the submit must happen on another thread (§2.1, §8.2). A failed background write raises at the next call, and at `Free` if it was never raised. |
| 17 | 2026-10-23 | **Linux: raw system calls, no liburing**; the API unit translates the **kernel 6.8** `linux/io_uring.h` (Ubuntu 24.04 LTS), checked by layout tests generated from the C header; Linux tests are built and run in WSL through `Build-FPC.ps1 -Platform Linux64` (§6.4). |
| 18 | 2026-10-23 | **One set of tests** for Delphi, Free Pascal and Linux in `Source/UnitTests/Common`: a base class over DUnitX and FPCUnit with the FPCUnit check names; one Free Pascal test program for Windows and Linux; done on main (§12.4). |
| 19 | 2026-10-24 | **The Linux ring** (§5.7): Phase 20 is the ring, the platform record and the atomics on Linux, Phase 21 the engine on Linux; `NativeResult` is 0 or a negative error code on both systems (bytes in `BytesTransferred`); registration on Linux is a system call at `Prepare` with a completion of its own; minimum Linux 5.11. |
| 20 | 2026-10-24 | **The engine on Linux** (§10.14): the I/O thread sleeps as on Windows – a wake event and the ring's completion event, through a small event API in `TIORingPlatform` (`eventfd` and `poll` on Linux; the io_uring-only way measured no faster); the benchmarks run on Linux in this phase, WSL2 results marked as not disk numbers. |
| 21 | 2026-10-24 | **Linux extras** (§5.8): `TLinuxIORing.PrepareSqe` (any io_uring operation, for example sockets) and `LinkToNext` (linked operations) in the low-level ring, one completion per entry; SQPOLL and all other definitions stay in the API unit (measured: no gain for file I/O); the shared `TIORingCapabilities` describes either system – `SystemDescription`, `NotAvailableReason`, `NativeFeatures`, `NativeOps`, `Extras`, `ToString` – and `IORingCapabilities` in `PIRUnit.IORing`. |
| 22 | 2026-10-24 | **Big reads straight into the caller's memory** (§12.8): `TIORingSequentialReader.Read` (and so the read stream) reads the part of a call beyond what its buffers have asked for straight into the caller's memory, unbuffered only into sector-aligned memory; the buffers read ahead after the call once all of its reads have started. Kept although cold 64 MiB calls on Windows are about 2 % slower: warm big calls gain 8–24 %, cold ones 11–22 % on Linux. The Linux clock stays as it is (measured: less than 0.1 %). |
| 23 | 2026-10-25 | **Tidy up before 0.1.0** (§12.10): one name per idea in the API (`ATimeoutMilliseconds`, `IORING_INFINITE`, `TIORingSequential…Stats`, `IORingReadAt`/`IORingWriteAt`); internal types nested in their records; the platform helpers in units of their own and one buffer check; the neutral ref records stay; the Linux clock stays FPC's (the C library's measured no faster in the engine). The library is renamed **Pascal.IOUring**; units, forms and include files get the prefix `PIR` and say what they hold (`PIRUnit.IORing`, `PIRUnit.Types`, `PIRUnit.Windows.Ring` …; CodingStyle.md); nested routines get parameters instead of seeing their caller's variables. |
