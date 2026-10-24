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
Docs/                      Design.md, Plan.md, Benchmarks.md, BenchmarkResults/ (raw CSV)
Source/
  Units/
    Delphi.IOUring.inc                       shared compiler switches (FPC mode etc.)
    Delphi.IOUring.pas                       TIORing alias, availability, blocking helpers (new)
    Delphi.IOUring.Backend.Custom.pas        neutral types, errors, shared helpers
    Delphi.IOUring.Backend.Windows.API.pas   100 % IoRing API translation, standalone (new)
    Delphi.IOUring.Backend.Windows.pas       TWindowsIORing (record)
    Delphi.IOUring.Backend.Posix.API.pas     100 % io_uring API translation (Linux 6.8), standalone (new)
    Delphi.IOUring.Backend.Posix.pas         TLinuxIORing (Milestone 4)
    Delphi.IOUring.SequentialReader.pas      read-ahead engine (record)        (new)
    Delphi.IOUring.SequentialWriter.pas      write-behind through an engine (record) (new)
    Delphi.IOUring.Streams.pas               TStream descendants: read stream, write stream
    Delphi.IOUring.Atomics.pas               TAtomic: CAS / fences / wait-wake (new)
    Delphi.IOUring.RequestPool.pas           request slots, handles, lock-free free list (new)
    Delphi.IOUring.RequestQueue.pas          lock-free queue: producers -> I/O thread (new)
    Delphi.IOUring.Engine.pas                TIORingEngine: the I/O thread, Wait, callbacks (new)
    Delphi.IOUring.BlockReader.pas           TIORingBlockReader: known blocks, read-ahead, merging (new)
  Build-FPC.ps1                              builds/runs the FPC tests or benchmark (no fpc.exe/lazbuild needed; -Optimize; -Platform Linux64 in WSL)
  UnitTests/
    Delphi.IOUring.UnitTests.dpr/.dproj      Delphi runner (DUnitX console, TestInsight)
    Common/                                  the tests, the same for Delphi and Free Pascal (Design §12.4)
      Tests.Support.pas                      base class over DUnitX / FPCUnit, threads, shared pattern files
      Tests.Backend.Windows.API.Layout.pas   record layouts + helpers (Windows)
      Tests.Backend.Windows.API.pas          live API calls (Windows)
      Tests.Ring.pas                         the core ring (TIORing)
      Tests.SequentialReader.pas             the read-ahead reader
      Tests.Streams.pas                      TSequentialReadOnlyFileStream
      Tests.Atomics.pas                      TAtomic, incl. multi-thread stress
      Tests.RequestPool.pas                  free list and request pool, incl. an engine simulation
      Tests.RequestQueue.pas                 request queue, incl. wrap-around and producer/consumer stress
      Tests.Engine.pas                       the engine: results, waiting, callbacks, batches, Destroy, stress
      Tests.BlockReader.pas                  the block reader: order, merging, end of file, errors, shared engine
      Tests.EngineOverlap.pas                the overlap rule: order cases, pipes, model tests
      Tests.SequentialWriter.pas             the writer and the write stream: round trips, Flush, unbuffered, failed writes
      Tests.TestFileHelpers.pas              the test-file helpers themselves
      TestFileHelpers.pas                    generates deterministic test files
      TestPlatformHelpers.pas                files, pipes, page memory for tests (Windows; Linux in Phase 20)
    FPC/                                     the Free Pascal runner, for Windows and Linux
      Delphi.IOUring.UnitTests.FPC.lpr/.lpi  own small console runner on FPCUnit; Lazarus project (Windows)
    Linux/                                   the Linux-only tests (built and run in WSL by Build-FPC.ps1 -Platform Linux64)
      Tests.Linux.Backend.Posix.API.Layout.pas  sizes, offsets and constants against the C header
      Tests.Linux.Backend.Posix.API.Layout.inc  those checks, generated from the C header (do not edit)
      Tests.Linux.Backend.Posix.API.pas      live calls to the kernel
      PosixApiLayout.c, Generate-PosixApiLayout.sh  the generator of the .inc (gcc, on Linux)
  Benchmarks/
    Delphi.IOUring.Benchmarks.dpr/.dproj     console app, CSV output
    Bench.Common.pas                         consumer, timing, cache purge, test files (Delphi + FPC)
    Bench.Readers.pas                        reading routines shared with the FPC benchmark
    Bench.Contenders.pas                     the Delphi contender list (anonymous methods, threads)
    Bench.Structures.pas                     engine structures (free list, queue): lock-free vs lock (Delphi + FPC)
    Delphi.IOUring.Benchmarks.Structures.dpr/.dproj   runs Bench.Structures (Delphi)
    FPC/Delphi.IOUring.Benchmarks.FPC.lpr    Free Pascal benchmark: the main contenders
    FPC/Delphi.IOUring.Benchmarks.Structures.FPC.lpr  runs Bench.Structures (FPC)
    Bench.Blocks.pas                         blocks known in advance: block reader vs TFileStream/ReadFile (Delphi + FPC)
    Delphi.IOUring.Benchmarks.Blocks.dpr/.dproj       runs Bench.Blocks (Delphi)
    FPC/Delphi.IOUring.Benchmarks.Blocks.FPC.lpr      runs Bench.Blocks (FPC)
    Bench.Writes.pas                         writing a file: write stream vs TFileStream/TBufferedFileStream (Delphi + FPC)
    Delphi.IOUring.Benchmarks.Writes.dpr/.dproj       runs Bench.Writes (Delphi)
    FPC/Delphi.IOUring.Benchmarks.Writes.FPC.lpr      runs Bench.Writes (FPC)
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

- [x] `TIORingSequentialReader` managed record per Design §7: options set, slot table (plain records), priming, re-queue batching, copying `Read`, zero-copy `TryAcquireChunk`/`ReleaseChunk`, `DataReady`, `Stats`.
- [x] Adaptive read-ahead distance (Design §7.6), switchable off for benchmarking (`sroFixedReadAhead`; also `sroNoRegistration`).
- [x] Unbuffered mode with sector-size query and page-aligned buffers.
- [x] Platform file/memory/clock helpers in the backend (`TIORingPlatform`), so the reader has no Windows code.
- [x] Tests (`Tests.SequentialReader`, 21 tests) – size × chunk matrix for buffered and unbuffered mode and for BufferCount 1, 2, 8 (plus a fixed/no-registration run):
  - [x] File sizes: 0, 1, BufferSize−1, BufferSize, BufferSize+1, BufferSize×BufferCount, ×BufferCount+1, 100 MB.
  - [x] Read chunk sizes: 1, 7, 4095, 4096, BufferSize, BufferSize+1, larger than file.
  - [x] Data verified against generator; total == file size; `Eof` correct; reads after EOF return 0.
  - [x] Zero-copy API delivers identical content; `Read` and chunks can be mixed.
  - [x] File appended to while reading: reader stops at the size taken at open.
  - [x] File shortened while reading: reader ends at the new end.
  - [x] `Close` in the middle of a file (in-flight reads) is clean; end of scope closes the file.

**Done 2026-10-22** – 98 tests pass on Win32 and Win64; the reader also compiles with FPC 3.2.2 (i386).

### Phase 4 – `TSequentialReadOnlyFileStream` (Layer 3)

- [x] `EIORingStreamError = class(EStreamError)`.
- [x] `TSequentialReadOnlyFileStream` per Design §8.1 (reader embedded as a record field); a file that cannot be opened raises `EFOpenError` like `TFileStream`.
- [x] Tests (`Tests.Streams`, 17 tests):
  - [x] Content equals `TFileStream` content for the file-size matrix above (and unbuffered).
  - [x] `Position` getter and `Size` work at all times.
  - [x] `Seek(0, soCurrent)`, seek to current position, `Position := Position` → no exception.
  - [x] Seek backward / forward / `soEnd`, `Position := 0` after reading, old 32-bit `Seek`, `Write` (all overloads), `WriteBuffer`, `Size := …` → `EIORingStreamError` (an `EStreamError`).
  - [x] Interop: `TMemoryStream.CopyFrom(Stream, 0)` and in parts, `TStreamReader` line reading over a text file, `TBytesStream.LoadFromStream`; `ReadBuffer` past the end raises `EReadError`.

**Done 2026-10-22** – 115 tests pass on Win32 and Win64; the stream unit also compiles with FPC 3.2.2 (i386). With this the code of Milestone 1 is complete; Phase 5 (benchmarks) remains.

### Phase 5 – Benchmarks

- [x] Console app; files of 1 GiB and 10 GiB (created in `%TEMP%`, deleted afterwards).
- [x] Contenders: `TFileStream` (64 KiB and 1 MiB reads), `TBufferedFileStream`, plain `ReadFile` with and without `FILE_FLAG_SEQUENTIAL_SCAN`, **overlapped `ReadFile` 1 MiB × 8** (classic async I/O, buffered and unbuffered – added as the fair async baseline), **4 threads doing synchronous `ReadFile` on separate ranges**, IoRing stream buffered/unbuffered, IoRing zero-copy reader (with/without hint, unbuffered).
- [x] Scenarios: (a) read-through, (b) read + 200 µs CPU work per MiB (stalls reported), (c) cold cache (purged before each run, checked) vs warm cache.
- [x] Measure **MiB/s and CPU time** (user + kernel) for each, Win32 and Win64. CSV output; results + machine description in `Docs/Benchmarks.md`, raw data in `Docs/BenchmarkResults/`.
- [x] Tune defaults (BufferSize, BufferCount, adaptive vs fixed read-ahead, registration) from the results: **defaults kept** (1 MiB × 8 is within 1 % of the best).

**Done 2026-10-22** – the IoRing stream reads a cold 10 GiB file at disk speed (~6.75 GiB/s): 2.7× `TFileStream` with 1 MiB reads, ~4× with 64 KiB reads; same speed as well-made overlapped I/O; no gain (−6 to −16 %) when the file is already in the cache; 14–18 % faster when the program does CPU work on the data. README has a usage + results section. **Milestone 1 is complete.**

---

## Milestone 2 – Free Pascal / Lazarus on Windows

- **Phase 6 – Tool set-up**: working FPC/Lazarus with Win64 and Win32 compilers; build scripts for the library and tests.
  - [x] `Source\Build-FPC.ps1 -Project Tests|Benchmarks -Platform Win32|Win64 [-Run]`: calls the compiler binary directly, so it needs no `fpc.exe`, `fpc.cfg` or `lazbuild`.
  - [x] Lazarus project file for the tests (`Delphi.IOUring.UnitTests.FPC.lpi`): builds with `lazbuild` for `i386-win32` and `x86_64-win64` (output in `bin\` and `lib\`), all tests pass.
  - [x] **Win64:** the repaired Lazarus 5.0 RC1 install (FPC 3.2.2) has `ppcx64.exe`, `fpc.exe` and `lazbuild.exe`.
- **Phase 7 – Test runner for FPC**: **decided 2026-10-22: separate FPCUnit tests** (`Source/UnitTests/FPC/Tests.FPC.*`), the same checks as the Delphi test units. The shared helpers (`TestFileHelpers`, `TestPlatformHelpers`) are used by both. A small own console runner on FPCUnit sets the exit code.
  - [x] 101 FPC tests (Delphi has 115 because DUnitX counts each `[TestCase]` separately; the FPC tests loop over the same cases).
- **Phase 8 – Port**: compile Milestone 1 with FPC; fix only with the allowed `{$IFDEF FPC}` places (Design §12.2).
  - [x] `delayed` replaced for FPC by functions that look themselves up with `GetProcAddress` on first use (Design §6.3), so FPC programs start on Windows without IoRing.
  - [x] FPC [VERIFY]s answered on Win32 and Win64: record layouts, records passed by value (stdcall), managed-record operators (`Initialize`/`Finalize`/`Copy`), `const`/`constref` passing without copy – all tested.
  - [x] **All 101 FPC tests pass on Win32 and Win64** (FPC 3.2.2), with `Build-FPC.ps1` and with `lazbuild`.
- **Phase 9 – FPC benchmarks**:
  - [x] Reading routines moved to `Bench.Readers` (Delphi and FPC); separate small FPC program with the main contenders (the Delphi contender list uses anonymous methods).
  - [x] Win32 and Win64, Delphi and FPC run back to back: **the same speed within noise** ([Benchmarks.md](Benchmarks.md#free-pascal)).

**Done when:** all tests pass with Delphi and FPC on Win32 and Win64. **Done 2026-10-22 – Milestone 2 is complete.** Open small item: FPC shows 15 hints (no warnings) for the library units, all harmless (unused parameters of methods that only raise, variables first set by an API call).

---

## Milestone 3 – I/O engine (Design §10, §11) – Delphi and FPC

- **Phase 10 – Atomics unit**: `Delphi.IOUring.Atomics` (CAS 32/64 incl. Win32 64-bit CAS, exchange, add, load-acquire/store-release, pause, wait/wake on address), tests incl. multi-thread stress.
  - [x] `TAtomic` (record, static methods): `CompareExchange`, `TryCompareExchange`, `Exchange`, `FetchAdd`, `Increment`, `Decrement`, `LoadAcquire`, `StoreRelease` for `Integer`, `Cardinal`, `Int64`, `UInt64` (and `Pointer`); `FullBarrier`, `CpuPause`; `WaitWhileEqual` / `WakeOne` / `WakeAll` on 32-bit values (Design §10.6).
  - [x] Win32: 64-bit CAS is `LOCK CMPXCHG8B` (own assembler for FPC; Delphi's intrinsic does it itself); 64-bit load/store is one SSE move.
  - [x] Tests `Tests.Atomics` / `Tests.FPC.Atomics` (20 each): every method and type; exact counters from 4 threads; no half-written 64-bit values; release/acquire hand-over; a spin loop sees another thread's write; wait timeout, wake one / all, ping-pong without lost wake-ups.
  - [x] Also run with optimization on: Delphi Release, FPC `-O3` (new switch `Build-FPC.ps1 -Optimize`). This found a real FPC x64 problem – a 64-bit constant written as two 32-bit stores – now fixed (Design §10.6).

  **Done 2026-10-22** – Delphi 135 tests and FPC 121 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 11 – Request pool**: fixed array of plain records, states, `NativeUInt` handle packing (index + generation, Win32 layout), lock-free free list with ABA tag. Stale-handle tests, multi-thread stress.
  - [x] `Delphi.IOUring.RequestPool`: `TIORingFreeList` (Treiber stack, 64-bit tag + index, exponential backoff) and `TIORingRequestPool` (cache-line slots with a 32-bit state word and the engine's payload; handles = index + generation, index bits follow the capacity; `TryAcquire`, `TryChangeState`, `WaitFor` with a waiting flag, `Release`) (Design §10.7).
  - [x] Tests `Tests.RequestPool` / `Tests.FPC.RequestPool` (23 each): stale and out-of-range handles, state rules, payloads, generation wrap-around (Win32), waiting and waking, no slot held twice by 4 threads, an engine simulation (4 producers + 1 I/O thread, 80 000 requests, with and without spinning).
  - [x] The thread helpers of the tests moved to shared units (`TestThreadHelpers` for Delphi, `Tests.FPC.Support` for FPC).
  - [x] Benchmark against an SRW lock (decision #10): new program `Delphi.IOUring.Benchmarks.Structures` (Delphi and FPC, `Build-FPC.ps1 -Project Structures`). Without backoff the lock won by up to 4.8×; with backoff (limit 1024 pauses) **the lock-free stack wins or ties in every case** – it stays ([Benchmarks.md](Benchmarks.md#engine-structures-phase-11)).

  **Done 2026-10-22** – Delphi 158 tests and FPC 144 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 12 – Lock-free request queue**: bounded array queue with per-cell sequence numbers, cache-line padding. Benchmark against an SRW-lock queue; keep whichever wins (Design §10.5).
  - [x] `Delphi.IOUring.RequestQueue`: `TIORingRequestQueue` – Vyukov's bounded MPMC queue of pointer-sized values; positions on their own cache lines, `NativeUInt` positions that may wrap around (signed differences), backoff (Design §10.8).
  - [x] `TAtomic.BackOff` and `IORingAllocCacheAligned` moved to `Delphi.IOUring.Atomics` (shared by the free list, the pool and the queue).
  - [x] Tests `Tests.RequestQueue` / `Tests.FPC.RequestQueue` (12 each): order, full/empty, capacity, laps, wrap-around of the positions (also under load), many producers with one or many consumers (every value once, in order per producer with one consumer). The tests themselves were checked by breaking the queue on purpose (Design §10.8).
  - [x] `RunThreads` (Delphi and FPC test helpers) fails a test whose threads still run after 60 s, so a broken lock-free structure fails the run instead of hanging it.
  - [x] Benchmark against an SRW-lock queue (`Bench.Structures`, `--only queue`): **the lock-free queue wins everywhere** – 4–23 % with few producers and real work, up to 290× under contention ([Benchmarks.md](Benchmarks.md#request-queue-phase-12)). It stays.

  **Done 2026-10-22** – Delphi 171 tests and FPC 157 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 13 – Engine with one I/O thread**: I/O thread loop (drain → prepare → one submit → reap → notify), sleep/wake protocol without syscalls when busy, `WaitOnAddress` waiting, `BeginBatch`/`EndBatch`, clean shutdown with requests in flight (every request completes: ok / error / cancelled). Stress test: many producer threads, random reads, all data verified. Stats counters.
  - [x] API decided first (Design §10.4) and built as decided: `Delphi.IOUring.Engine` – `TIORingEngine` with `ReadAsync`/`WriteAsync`/`FlushAsync`, `Wait`/`TryGetResult`/`WaitAll`, callbacks on the I/O thread, `BeginBatch`/`EndBatch`, `Stats` (Design §10.9).
  - [x] I/O thread: drain → prepare (one request may wait for room) → one submit → pop all → sleep only after an idle round; producers wake it only when it sleeps.
  - [x] A full pool makes starting a request sleep until one is freed; `Destroy` cancels queued and in-flight requests, waits for all, and lets threads blocked in `Wait` leave first.
  - [x] New in the core: `IORING_RESULT_CANCELLED`, `TIORingCompletion.IsCancelled`; `Delphi.IOUring` re-exports both result codes.
  - [x] Tests `Tests.Engine` / `Tests.FPC.Engine` (19 each), incl. the shutdown cases and stress (8 threads × 1500 random reads, data checked; callbacks and waits mixed). Repeated 100× (Delphi) and 10× (FPC) to find flaky tests: one found and fixed (a busy engine never sleeps – Design §10.9).
  - [x] Found on the way: a request pool that is too small for what the threads keep can deadlock them – rule written into the unit and Design §10.9.

  **Done 2026-10-22** – Delphi 190 tests and FPC 176 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets. Not measured yet: the engine's speed (Phase 14's benchmark).
- **Phase 14 – Read stream with block provider**: look-ahead distance, merging adjacent requests (contiguous buffer or scatter), in-order delivery. Benchmark: many small "known in advance" random reads vs `TFileStream` + seek.
  - [x] API decided first (Design §10.4): both a provider (a method that gives the next block) and a plain list. `Delphi.IOUring.BlockReader` – `TIORingBlockReader`, a managed record: `TryGetBlock`/`ReleaseBlock`, zero-copy, blocks in the provider's order (Design §10.10).
  - [x] Look-ahead: `ReadAhead` buffers (default 32 × 256 KiB), one read in flight per buffer, all new reads of a round in one engine batch. Neighbouring blocks become one read; `MaxGap` lets small gaps be read too. Scatter reads left out: they need unbuffered handles and page-aligned blocks (Design §2.1).
  - [x] Tests `Tests.BlockReader` / `Tests.FPC.BlockReader` (15 each): order and data, the provider asked only when needed, merging, `MaxGap`, backward and overlapping blocks, end of file, empty list, not waiting, bad arguments, wrong call order, failed reads, `Close` with reads in flight, stats, stress (20 000 random blocks; 4 readers sharing one engine).
  - [x] Benchmark: new program `Delphi.IOUring.Benchmarks.Blocks` (Delphi and FPC, `Build-FPC.ps1 -Project Blocks`) – 20 000 blocks of 4 KiB from a 4 GiB file, random and sorted, cold and warm, against `TFileStream` + `Seek` and positioned `ReadFile` (1 and 8 threads). Not in the cache: **7–10× faster than `TFileStream`** with read-ahead 128 and faster than 8 `ReadFile` threads; 17–22× for sorted blocks with `MaxGap`. In the cache, `ReadFile` stays faster ([Benchmarks.md](Benchmarks.md#blocks-known-in-advance-phase-14)).
  - [x] Probes of the engine (Design §10.10): it adds about 10 % to a bare ring; one I/O thread is the limit only with unbuffered reads (about 70 thousand reads/s, two engines 114–126); results with cached data depend on whether Windows runs the threads on P- or E-cores; spinning longer before a wait sleeps helps cached reads but costs CPU time with reads from the disk.
  - [x] Found: on a handle without `FILE_FLAG_OVERLAPPED`, Windows runs the reads one at a time, also through IoRing; and on an overlapped handle every read takes the slower asynchronous way, even for cached data (Design §2.1).
  - [x] Tried and dropped: starting new reads in groups instead of one per freed buffer – no measurable gain (Design §10.10).

  **Done 2026-10-23** – Delphi 205 tests and FPC 191 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 15 – Several I/O threads** (only if Phase 13 benchmarks show one thread is the limit): per-file routing, wake-up policy that avoids thundering herd. Phase 14 found one such case: unbuffered small reads (Design §10.10).
  - [x] First measured where the I/O thread's time goes (Design §10.11): Windows does the work of a request inside `SubmitIoRing` (about 7.5 µs per unbuffered 4 KiB read), the engine's own work is about 0.2 µs. So only more submitting threads help.
  - [x] Tried and left out: registered file and buffers (at most about 3 %); a longer spin, a spin learned per thread, and spinning only while the I/O thread is awake (none better than a short spin). `WaitFor` now spins 4 µs (a time, not a number of pauses) instead of 100 pauses (Design §10.11).
  - [x] API decided first (Design §10.4, "Phase 15 decisions"): `TIORingEngine.Create(…, AIOThreads = 1)`; the engine owns its I/O threads, each with its own ring, all taking requests from the shared queue; `IOThreadCount`, `IOThreadStats`, `IsIOThread` (replaces `IOThreadId`). Per-file routing left to Phase 16.
  - [x] Waking: a producer wakes an I/O thread only when all sleep; an I/O thread takes at most 16 requests per round and wakes a sleeping sibling when more are waiting (Design §10.12).
  - [x] Found and fixed: `Destroy` could hang when a ring was full of requests that only a cancel ends (also with one I/O thread). One place in each ring now stays free for a cancel.
  - [x] Tests (6 new in `Tests.Engine` / `Tests.FPC.Engine`): bad thread counts, a backlog is shared, a light load stays on one thread, `Destroy` cancels over 4 rings, both stress tests with 4 I/O threads; 30 repeated runs without a failure.
  - [x] Benchmark (`Delphi.IOUring.Benchmarks.Blocks`, now also unbuffered and with 2 and 4 I/O threads): with 4 I/O threads the block reader read **3.2× as many unbuffered 4 KiB blocks** as with one, and with cached data it is now **1.3–1.6× faster than `ReadFile`**; data from the disk through the file cache gains nothing ([Benchmarks.md](Benchmarks.md#several-io-threads-phase-15)). The default stays 1 I/O thread.

  **Done 2026-10-23** – Delphi 211 tests and FPC 197 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 16 – Overlap handling (decision first, Design §11)**: decide A only vs B opt-in. If B: in-flight range table per file on the I/O thread; write-after-read/write ordering, read-after-write ordering or serve-from-buffer, attach duplicate reads. Tests for each case in the Design §11 table.
  - [x] Decided (Design §11, decision 15): B as an option of the engine, `orKeepOrder`. For one file handle, requests that touch the same bytes take effect in the order they were started; reads never wait for reads; a flush waits for the earlier writes. The core ring keeps no rules (A).
  - [x] Built (Design §10.13): every request of a file handle goes to one I/O thread (its own queue); that thread keeps the file's unfinished requests in start order (a hash table of handles, a list linked through the request slots); a conflicting request is held back and starts when the earlier ones have completed. Works for any sizes and partial overlaps. Left for later: answering a read from a write's buffer, joining duplicate reads.
  - [x] Tests `Tests.EngineOverlap` / `Tests.FPC.EngineOverlap` (13 each): the order cases on a file, exact cases with pipes (held back, not held back, a chain in order, flush after write, `Destroy`), routing, and two model tests (random reads and writes against an in-memory copy). Checked by switching the rule off: 9 of 13 fail then.
  - [x] Cost (probe): 20 % with many overlaps (64 % of the requests held back), about 3 % with few. Blocks benchmark (reads only, with the rule on 1 and 4 I/O threads): 0–6.5 %, and one file uses one I/O thread ([Benchmarks.md](Benchmarks.md#overlap-rule-phase-16)).
  - [x] Found on the way: a Phase 15 test failed now and then in FPC Win64 `-O3` (timing, not the engine); its backlog now uses unbuffered reads.

  **Done 2026-10-23** – Delphi 224 tests and FPC 210 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 17 – `TSequentialWriteOnlyFileStream`** (write-behind; can use the engine or its own ring).
  - [x] Measured first (Design §2.1): Windows does buffered writes, and unbuffered writes that extend a file, inside the submit call. So the writes go through an engine – its I/O thread does the submit – and not through a ring of the caller's thread.
  - [x] Decided and built (Design §8.2): `Delphi.IOUring.SequentialWriter` – `TIORingSequentialWriter`, a managed record with its own engine by default or a shared one; copying `Write` and zero-copy `AcquireBuffer`/`CommitBuffer`; `Flush(AToDisk)`; unbuffered option with a cut last buffer. `TSequentialWriteOnlyFileStream` in `Delphi.IOUring.Streams`. A failed background write raises at the next call (`EWriteError` in the stream), and at `Free` if it was never raised.
  - [x] New platform calls: `CreateFileForWrite`, `SetFileSize`.
  - [x] Tests `Tests.SequentialWriter` / `Tests.FPC.SequentialWriter` (25 each): round trips around the buffer size and with pieces of every size, zero-copy, `Flush`, unbuffered, failed writes (made with a byte-range lock), bad arguments, wrong call order, end of scope, stats, a shared engine with 4 writers, and the stream with `CopyFrom`, `SaveToStream`, `Seek` rules and errors.
  - [x] Benchmark: new program `Delphi.IOUring.Benchmarks.Writes` (Delphi and FPC, `Build-FPC.ps1 -Project Writes`) – 1 and 10 GiB against `TFileStream` and `TBufferedFileStream`, writing only and with CPU work. With work, 1 GiB was written **25–45 % sooner** (10 GiB: 3–21 %, the disk is the limit); writing alone gains nothing; unbuffered gets the data onto the disk soonest with a third of the CPU time ([Benchmarks.md](Benchmarks.md#writing-phase-17)).

  **Done 2026-10-23** – Delphi 249 tests and FPC 235 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets. **Milestone 3 is complete.**

---

## Milestone 4 – Linux through Free Pascal

- **Phase 18** – `Delphi.IOUring.Backend.Posix.API`: complete `linux/io_uring.h` translation (Design §6.4) + syscall wrappers, layout tests on x86-64 and AArch64.
  - [x] Decided first (Design §6.4, decision 17): raw system calls, no liburing; the header of Linux 6.8 (Ubuntu 24.04 LTS); layout tests generated from the C header; the Linux tests run in WSL.
  - [x] `Delphi.IOUring.Backend.Posix.API`: every constant, enum, flag and record of the header with its C name, the mmap offsets, `__kernel_timespec`, the system call numbers, and `io_uring_setup`, `io_uring_enter`, `io_uring_enter2`, `io_uring_register` (they return `-errno` and raise nothing). Standalone: RTL only.
  - [x] Layout tests generated: `Generate-PosixApiLayout.sh` first checks that `PosixApiLayout.c` names everything in the header (200 constants, 20 records, 147 fields), then builds it with gcc; it writes 373 checks into `Tests.Linux.Backend.Posix.API.Layout.inc`. A name the Pascal unit does not have does not compile.
  - [x] Live tests (22): setup and its errors, the ring memory, no-ops, reads and writes through the ring, end of file, errors in the completion, registered files and buffers, the probe, `io_uring_enter` errors, timeouts.
  - [x] New test program `Delphi.IOUring.UnitTests.Linux.lpr`; `Build-FPC.ps1 -Platform Linux64` builds and runs it inside WSL.
  - [x] Found on the way: FPC aligns a variant part (a C union) to the largest field in it – also the fields after the union. In the SQE the flags union moved from offset 28 to 32. Fixed with `packed` for the two records concerned (Design §6.4); the generated layout tests caught it on their first run.
  - [ ] AArch64: written for it, not tested yet – needs an ARM machine ([VERIFY], Design §6.4).

  **Done 2026-10-23** – Linux: 25 tests pass in WSL2 (kernel 6.18, x86-64), with and without `-O3`. Windows: no code changes; the FPC tests (235) still pass on Win32 and Win64 with the changed `Build-FPC.ps1`.
- **Phase 19** – One set of tests for Delphi, Free Pascal and Linux (Design §12.4): one shared unit per test topic in `Source/UnitTests/Common`, a base class over DUnitX and FPCUnit, the tests that only Delphi has ported, one Free Pascal test program for Windows and Linux. Ends with Delphi and FPC running the same tests on Windows.
  - [x] Decided first (Design §12.4, decision 18): FPCUnit names for the checks, one Free Pascal runner for Windows and Linux, on main.
  - [x] `Tests.Support`: the base class `TIORingTestCase` (FPCUnit's `TTestCase`, or a DUnitX fixture that resets itself before each test), `RegisterTests`, `RunThreads`, `Log`, `CheckPattern`, shared pattern files. Compiles on Linux too.
  - [x] The 13 test topics moved to `Source/UnitTests/Common`, one unit each, made from the FPC twins; the tests and log lines that only Delphi had were ported. Old twins and `TestThreadHelpers` removed.
  - [x] One Free Pascal runner (`FPC/Delphi.IOUring.UnitTests.FPC.lpr`) for Windows and Linux; the Linux tests use the same base class; `Build-FPC.ps1 -Platform Linux64` builds it in WSL.
  - [x] Found on the way: DUnitX runs all tests of a class on one object (FPCUnit: one object per test); three tests had no counted check; RTL differences (`GetTickCount64`, `constref`, `TStreamReader`, `string` size) – Design §12.4.

  **Done 2026-10-23** – Delphi 242 tests (Win32 and Win64, Debug and Release), FPC 241 on Windows (Win32 and Win64, with and without `-O3`), FPC 32 on Linux (WSL2, with and without `-O3`); `lazbuild` builds the Lazarus test project. Delphi has one test more (`ReadOverloads_Work`: overloads FPC 3.2.2's `TStream` lacks).
- **Phase 20** – `TLinuxIORing` record in `Delphi.IOUring.Backend.Posix` and the platform record `TLinuxIORingPlatform`; `Atomics` on Linux (futex; AArch64 acquire/release); the Linux side of the test helpers; the shared suites that need no engine (atomics, request pool and queue, ring, sequential reader) run on Linux (WSL2 is enough for x86-64 development). Decided: Design §5.7, decision 19.
  - [x] `TLinuxIORing`: the same methods as `TWindowsIORing`; one `mmap` for both rings; `Submit` repeats `io_uring_enter` until every prepared entry is in; timeouts with `IORING_ENTER_EXT_ARG`; registration as a system call with its own completion; scatter/gather segments copied and cut to the byte count; the `eventfd` only when `CompletionEventHandle` is asked for.
  - [x] `TLinuxIORingPlatform` (`O_DIRECT`, `posix_fadvise`, `statx` for the alignment, `mmap`, `AT_PAGESZ`, `clock_gettime`); `FreePages` got a size parameter on both systems. `NativeResult` is 0 or a negative error code on both systems.
  - [x] Atomics on Linux: the futex; AArch64 barriers written ([VERIFY], no ARM machine and no cross compiler here).
  - [x] `TestPlatformHelpers` for Linux: neutral open flags, `pipe()`, `mmap`, waiting on an event, `RESULT_ACCESS_DENIED`. The ring and reader tests run on both systems; new: `Flush_AllModes`, `WriteThrough_UnbufferedFile`, and two Linux-only ring tests (registration at once, scatter cut to the byte count).
  - [x] Changed plan: the read stream suite moves to Phase 21 – the stream unit also holds the write stream, which needs the engine.
  - [x] Found on the way: on Windows, write-through needs an unbuffered file (`0x800701FD` on a cached one; Design §2.1).
  - [ ] AArch64: not compiled or run yet ([VERIFY], Design §5.7).

  **Done 2026-10-24** – Linux: 137 tests pass in WSL2 (kernel 6.18), with and without `-O3`. Windows: Delphi 244 tests (Win32 and Win64, Debug and Release), FPC 243 (Win32 and Win64, with and without `-O3`); `lazbuild` builds the test project; the benchmarks compile.
- **Phase 21** – The engine on Linux (how its I/O thread sleeps and is woken); the block reader, overlap rule, read stream and write stream suites on Linux; the benchmarks on Linux. Decided: Design §10.14, decision 20.
  - [x] `TIORingPlatform` event API on both systems (Windows event and `WaitForMultipleObjects`; Linux `eventfd` and `poll`); the engine has no Windows calls left (`FileHash`, `IsFailure`).
  - [x] Tests: `OpenPipePair` (socket pair on Linux), `MakeWritesFail` (`dup2` on Linux), `BAD_HANDLE`; the engine, overlap rule, block reader, read stream and write stream suites run on Linux. Two overlap tests stay Windows-only (they need a Windows pipe).
  - [x] Found on the way: closed rings keep their registered buffers locked for a while, and quick open/close runs out of locked memory (`ENOMEM`). `Close` now unregisters first; the sequential reader reads without registration when a registration fails (Design §10.14).
  - [x] Found on the way: Free Pascal's `TThread.WaitFor` on Unix waits in 100 ms steps when called from the main thread, so freeing an engine took up to 100 ms. The engine now waits for the end of its I/O threads itself first; new test `Destroy_TenEngines_AreQuick` (Design §10.14).
  - [x] The four benchmarks build and run on Linux (`Build-FPC.ps1 -Platform Linux64 -Project …`); first WSL2 results in Benchmarks.md, marked: cold in WSL2 is not the disk.
  - [ ] Benchmarks on a real Linux machine (not WSL2), and AArch64.

  **Done 2026-10-24** – Linux: 230 tests pass in WSL2 (kernel 6.18), with and without `-O3`. Windows: WINDOWS_COUNTS.
- **Phase 22** – Linux extras: sockets, linked operations, SQPOLL – exposed through the API unit and capabilities only.

---

## Immediate next step

Phase 21 is done: the engine, the block reader and both streams run on Linux,
and so do the four benchmarks (a first look in WSL2). Next: **Phase 22 – Linux
extras** (sockets, linked operations, SQPOLL). It starts with a proposal and
its decisions, as before.
