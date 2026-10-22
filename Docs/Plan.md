# Delphi.IOUring – Implementation Plan

Companion to [Design.md](Design.md). Each phase ends in something that
compiles, has passing tests, and is committed.

Order of work (Design §12.1): **Delphi 13 on Windows → Free Pascal/Lazarus on
Windows → Linux through Free Pascal.**

| Milestone | Result |
| --- | --- |
| 1 | Complete Windows IoRing API unit + `TSequentialReadOnlyFileStream`, Delphi 13, Win32 + Win64, benchmarked |
| 2 | Milestone 1 compiles and passes tests with the latest FPC/Lazarus on Windows |
| 3 | I/O engine (threads, lock-free hand-over, read streams, overlap rules, write stream) – Delphi and FPC |
| 4 | Linux `io_uring` backend through FPC (x86-64, AArch64) |

The engine comes after the FPC port on purpose: porting is cheapest while
the code base is still small, and everything written afterwards is checked
against both compilers from day one.

## Target folder layout

```
Docs/                      Design.md, Plan.md, Benchmarks.md (later)
Source/
  Units/
    Delphi.IOUring.inc                       shared compiler switches (FPC mode etc.)
    Delphi.IOUring.pas                       TIORing alias, availability, blocking helpers (new)
    Delphi.IOUring.Backend.Custom.pas        neutral types, errors, shared helpers
    Delphi.IOUring.Backend.Windows.API.pas   100 % IoRing API translation, standalone (new)
    Delphi.IOUring.Backend.Windows.pas       TWindowsIORing (record)
    Delphi.IOUring.Backend.Posix.API.pas     100 % io_uring API translation (Milestone 4)
    Delphi.IOUring.Backend.Posix.pas         TLinuxIORing (Milestone 4)
    Delphi.IOUring.SequentialReader.pas      read-ahead engine (record)        (new)
    Delphi.IOUring.Streams.pas               TStream descendants
    Delphi.IOUring.Atomics.pas               CAS / fences / wait-on-address    (Milestone 3)
    Delphi.IOUring.Engine.pas                I/O thread(s), request pool       (Milestone 3)
  UnitTests/
    Delphi.IOUring.UnitTests.dpr/.dproj      DUnitX console runner (Delphi)
    Delphi.IOUring.UnitTests.FPC.lpi/.lpr    FPCUnit console runner (Milestone 2)
    Tests.Backend.Windows.API.Layout.pas     record layouts + helpers
    Tests.Backend.Windows.API.pas            live API calls
    Tests.Ring.pas                           the core ring (TIORing)
    Tests.SequentialReader.pas
    Tests.Streams.pas
    TestFileHelpers.pas                      generates deterministic test files
    TestPlatformHelpers.pas                  files, pipes, page memory for tests
  Benchmarks/
    Delphi.IOUring.Benchmarks.dpr            console app, CSV output
  3rdParty/DUnitX
```

---

## Milestone 1 – Delphi 13 on Windows

### Phase 0 – Groundwork

- [x] `Delphi.IOUring.inc` (`{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}`, shared switches) and include it in all units.
- [x] DUnitX console test project (Win32 + Win64 platforms), referencing `Source/3rdParty/DUnitX` by relative path.
- [x] `TestFileHelpers`: create temp files of given size where every 8-byte word is a hash of its word index (SplitMix64), so any read at any offset can be verified without keeping a copy.
- [x] Tests for the helpers themselves prove the runner works on both platforms (14 tests, Win32 + Win64).

**Done when:** test runner builds and runs for Win32 and Win64.

### Phase 1 – Complete Windows API unit (Layer 0)

`Delphi.IOUring.Backend.Windows.API` – everything in Design §6.2, standalone (Design §6.1):

- [x] All types, constants (incl. the 8 `IORING_E_*` codes), records, `P…` pointer types.
- [x] All 16 functions as `stdcall; external kernel32 … delayed` (`delayed` only for Delphi: FPC 3.2.2 does not support it).
- [x] The 4 helper functions (`IoRingHandleRefFromHandle`, …) as `inline` functions.
- [x] Each declaration commented with minimum IoRing version (+ Microsoft Learn link where a page exists).
- [x] Tests (`Tests.Backend.Windows.API.Layout` and `Tests.Backend.Windows.API`, 35 tests) – the unit is tested on its own, without the rest of the library:
  - [x] `SizeOf` and field offsets of every record on Win32 and Win64 equal the C layout.
  - [x] Helpers produce the right `Kind` and values.
  - [x] `QueryIoRingCapabilities` succeeds; log version/sizes/flags.
  - [x] `CreateIoRing(V4)` → `GetIoRingInfo` (check power-of-two rounding and CQ ≥ 2 × SQ) → `CloseIoRing`.
  - [x] `IsIoRingOpSupported` for every `IORING_OP_CODE`.
  - [x] `SetIoRingCompletionEvent`: event signalled on empty → non-empty; `NULL` clears it.
  - [x] Round-trip: one small read → `SubmitIoRing(wait 1)` → `PopIoRingCompletion` returns our `UserData`; then `S_FALSE` on empty queue.
  - [x] **Raw read spike**: read known test file at several offsets with a raw buffer ref, verify bytes. Run on **Win32** too – this is the by-value record ABI proof (Design §6.3 risk 2).
  - [x] Same with `BuildIoRingRegisterFileHandles` + `BuildIoRingRegisterBuffers`; sparse entries.
  - [x] `BuildIoRingWriteFile` + `BuildIoRingFlushFile` + read-back.
  - [x] `BuildIoRingReadFileScatter` / `BuildIoRingWriteFileGather`: record the actual restrictions (buffered vs unbuffered, segment size) (Design §2.1 [VERIFY]).
  - [x] `BuildIoRingCancelRequest` on a long-running read; observe both completions.
  - [x] Error codes: SQ full → `IORING_E_SUBMISSION_QUEUE_FULL`; oversubmit → `IORING_E_COMPLETION_QUEUE_TOO_FULL`; wait timeout → record the real HRESULT (Design §2.1 [VERIFY]); concurrent submit from two threads → `IORING_E_SUBMIT_IN_PROGRESS`.
  - [x] Read at EOF / across EOF: record the exact HRESULT and `Information` values (Design §5.5 [VERIFY]).
  - [x] File opened with and without `FILE_FLAG_OVERLAPPED` – does IoRing require it? Record result.

**Done when:** all tests pass on Win32 and Win64. Answers to the [VERIFY] items are written back into Design.md. **Done 2026-10-22** – 49 tests pass on Win32 and Win64; the API unit also compiles with FPC 3.2.2 (i386) with identical record layouts.

### Phase 2 – Core abstraction (Layer 1)

- [x] `Delphi.IOUring.Backend.Custom`: neutral plain records, `EIORingError` (readable texts for `IORING_E_*`), `EIORingNotSupported`, `TIORingCompletion` helpers.
- [x] `TWindowsIORing` **custom managed record** per Design §5.2: `Open`/`Close`, not copyable, ref conversion, all `Prepare*`, `Submit` with CQ-space guard, `TryPopCompletion`, `PopCompletions`, `WaitForCompletions`, completion event (pop-until-empty rule), pending-count tracking. `Close` **waits** for in-flight I/O (`CloseIoRing` does not cancel it – found in this phase).
- [x] `Delphi.IOUring`: `TIORing` alias, `Available`, `QueryCapabilities`, blocking `ReadAt` / `WriteAt`.
- [x] Check generated code (Design §4.1 [VERIFY]): cost of a managed-record local (+2.3 ns Win32, +1.2 ns Win64), `const` passing by reference (yes), inlining of the public methods (dropped, Design §4).
- [x] Tests (`Tests.Ring`, 26 tests, written against `TIORing`, so they can later run on Linux; files/pipes come from the new shared `TestPlatformHelpers`):
  - [x] Assigning one ring to another raises; ring is closed automatically at end of scope.
  - [x] Prepare until SQ full → `PrepareRead` returns False, no exception.
  - [x] 1000 random-offset reads in batches; every completion's data verified; all `UserData` values seen exactly once (out-of-order handling).
  - [x] Never triggers `IORING_E_COMPLETION_QUEUE_TOO_FULL`, even when the caller prepares more than the CQ can hold.
  - [x] Cancel of an in-flight read.
  - [x] `Close` with I/O in flight waits for it (buffer written before `Close` returns).
  - [x] Error path: read on a write-only handle gives a failed completion (`E_ACCESSDENIED`), not an exception.
  - [x] Write + flush + read-back; drain flag orders a read after a write.

**Done when:** tests green on Win32 and Win64. **Done 2026-10-22** – 77 tests pass on Win32 and Win64 (2 more API tests: `CloseIoRing` and `CancelIoEx` behaviour); the core units also compile with FPC 3.2.2 (i386).

### Phase 3 – Sequential reader (Layer 2)

- [ ] `TIORingSequentialReader` managed record per Design §7: options set, slot table (plain records), priming, re-queue batching, copying `Read`, zero-copy `TryAcquireChunk`/`ReleaseChunk`, `DataReady`, `Stats`.
- [ ] Adaptive read-ahead distance (Design §7.6), switchable off for benchmarking.
- [ ] Unbuffered mode with sector-size query and page-aligned buffers.
- [ ] Tests (`Tests.SequentialReader`) – each run for buffered and unbuffered mode and for BufferCount 1, 2, 8:
  - [ ] File sizes: 0, 1, BufferSize−1, BufferSize, BufferSize+1, BufferSize×BufferCount, ×BufferCount+1, ~100 MB.
  - [ ] Read chunk sizes: 1, 7, 4095, 4096, BufferSize, BufferSize+1, larger than file.
  - [ ] Data verified against generator; total == file size; `Eof` correct; reads after EOF return 0.
  - [ ] Zero-copy API delivers identical content.
  - [ ] File appended to while reading: reader stops at the size taken at open.
  - [ ] `Close` in the middle of a file (in-flight reads) is clean.

### Phase 4 – `TSequentialReadOnlyFileStream` (Layer 3)

- [ ] `EIORingStreamError = class(EStreamError)`.
- [ ] `TSequentialReadOnlyFileStream` per Design §8.1 (reader embedded as a record field).
- [ ] Tests (`Tests.Streams`):
  - [ ] Content equals `TFileStream` content for the file-size matrix above.
  - [ ] `Position` getter and `Size` work at all times.
  - [ ] `Seek(0, soCurrent)`, seek to current position, `Position := Position` → no exception.
  - [ ] Seek backward / forward / `soEnd`, `Position := 0` after reading, `Write`, `WriteBuffer`, `Size := …` → `EIORingStreamError`.
  - [ ] Interop: `TMemoryStream.CopyFrom(Stream, 0)`, `TStreamReader` line reading over a text file, `TBytesStream.LoadFromStream`.

### Phase 5 – Benchmarks

- [ ] Console app; files of 1 GB and 10 GB (generated once, outside the repo).
- [ ] Contenders: `TFileStream` (various `Read` sizes), `TBufferedFileStream`, plain `ReadFile` with `FILE_FLAG_SEQUENTIAL_SCAN`, **N threads doing synchronous `ReadFile` on separate ranges** (the PostgreSQL "sync + more workers" baseline), IoRing stream buffered, IoRing stream unbuffered, IoRing zero-copy API.
- [ ] Scenarios: (a) pure read-through (I/O bound), (b) read + simulated CPU work per MB (shows "data for free" overlap; report `Stats.Stalls`), (c) cold cache vs warm cache.
- [ ] Measure **MB/s and CPU time** (user + kernel) for each, Win32 and Win64. Output CSV; write results + machine description to `Docs/Benchmarks.md`.
- [ ] Tune defaults (BufferSize, BufferCount, adaptive vs fixed read-ahead) from the results.

**Done when:** we know where the IoRing stream wins and loses; defaults updated; README gets a short usage + results section.

---

## Milestone 2 – Free Pascal / Lazarus on Windows

- **Phase 6 – Tool set-up**: working FPC/Lazarus with Win64 and Win32 compilers (see note below); build scripts (`lazbuild` / `fpc` command lines) for the library and tests.
- **Phase 7 – Test runner for FPC**: DUnitX is Delphi-only. **[DECIDE]** either (a) write the test bodies as plain shared routines and add thin DUnitX + FPCUnit wrappers, or (b) keep separate FPCUnit tests. Proposal: (a), so the same checks run on both compilers.
- **Phase 8 – Port**: compile Milestone 1 with FPC; fix only with the allowed `{$IFDEF FPC}` places (Design §12.2). Answer the FPC [VERIFY]s: `delayed` support, record layouts, by-value records on Win32, managed-record operators.
- **Phase 9 – FPC benchmarks**: same benchmark app compiled with FPC; compare against Delphi numbers.

**Done when:** all tests pass with Delphi and FPC on Win32 and Win64.

Note (2026-10-22): Lazarus 5.0 RC1 is registered as installed in `C:\lazarus`
with FPC 3.2.2, but only the i386 cross-compiler (`ppc386.exe`) was found
there; `fpc.exe`, `ppcx64.exe` and `lazarus.exe` are missing. The
installation may need repairing before Phase 6.

---

## Milestone 3 – I/O engine (Design §10, §11) – Delphi and FPC

- **Phase 10 – Atomics unit**: `Delphi.IOUring.Atomics` (CAS 32/64 incl. Win32 64-bit CAS, exchange, add, load-acquire/store-release, pause, wait/wake on address), tests incl. multi-thread stress.
- **Phase 11 – Request pool**: fixed array of plain records, states, `NativeUInt` handle packing (index + generation, Win32 layout), lock-free free list with ABA tag. Stale-handle tests, multi-thread stress.
- **Phase 12 – Lock-free request queue**: bounded array queue with per-cell sequence numbers, cache-line padding. Benchmark against an SRW-lock queue; keep whichever wins (Design §10.5).
- **Phase 13 – Engine with one I/O thread**: I/O thread loop (drain → prepare → one submit → reap → notify), sleep/wake protocol without syscalls when busy, `WaitOnAddress` waiting, `BeginBatch`/`EndBatch`, clean shutdown with requests in flight (every request completes: ok / error / cancelled). Stress test: many producer threads, random reads, all data verified. Stats counters.
- **Phase 14 – Read stream with block provider**: look-ahead distance, merging adjacent requests (contiguous buffer or scatter), in-order delivery. Benchmark: many small "known in advance" random reads vs `TFileStream` + seek.
- **Phase 15 – Several I/O threads** (only if Phase 13 benchmarks show one thread is the limit): per-file routing, wake-up policy that avoids thundering herd.
- **Phase 16 – Overlap handling (decision first, Design §11)**: decide A only vs B opt-in. If B: in-flight range table per file on the I/O thread; write-after-read/write ordering, read-after-write ordering or serve-from-buffer, attach duplicate reads. Tests for each case in the Design §11 table.
- **Phase 17 – `TSequentialWriteOnlyFileStream`** (write-behind; can use the engine or its own ring).

---

## Milestone 4 – Linux through Free Pascal

- **Phase 18** – `Delphi.IOUring.Backend.Posix.API`: complete `linux/io_uring.h` translation (Design §6.4) + syscall wrappers, layout tests on x86-64 and AArch64.
- **Phase 19** – `TLinuxIORing` record in `Delphi.IOUring.Backend.Posix`; `Atomics` gets AArch64-correct acquire/release; same `Tests.Ring` / reader / stream / engine suites run on Linux (WSL2 is enough for x86-64 development).
- **Phase 20** – Linux extras: sockets, linked operations, SQPOLL – exposed through the API unit and capabilities only.

---

## Immediate next step

Start Phase 0 + Phase 1. The Win32 by-value ABI spike in Phase 1 is the first
real risk and decides some details in Design §6.3.
