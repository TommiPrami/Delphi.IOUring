# Pascal.IOUring – Implementation Plan

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
Docs/                                   Design.md, Plan.md, Benchmarks.md, CodingStyle.md, BenchmarkResults/ (raw data)
Packages/
  Lazarus/PascalIOUring.lpk             the Lazarus package (runtime; each system compiles only its own units)
Source/
  Build-FPC.ps1                         builds/runs with FPC: tests, benchmarks, demos, package (Win32, Win64, Linux)
  Units/
    PIRInclude.Compiler.inc             shared compiler switches (FPC mode etc.)
    PIRUnit.IORing.pas                  the unit user code uses: TIORing, TIORingPlatform, availability, blocking helpers
    PIRUnit.Types.pas                   neutral types, errors, raise helpers, shared checks
    PIRUnit.Windows.API.pas             100 % IoRing API translation, standalone
    PIRUnit.Windows.Ring.pas            TWindowsIORing (record)
    PIRUnit.Windows.Platform.pas        TWindowsIORingPlatform: files, memory, clock, wake event
    PIRUnit.Linux.API.pas               100 % io_uring API translation (Linux 6.8), standalone
    PIRUnit.Linux.Ring.pas              TLinuxIORing (record)
    PIRUnit.Linux.Platform.pas          TLinuxIORingPlatform: files, memory, clock, wake event
    PIRUnit.SequentialReader.pas        read-ahead reader (record)
    PIRUnit.SequentialWriter.pas        write-behind through an engine (record)
    PIRUnit.Streams.pas                 TStream descendants: read stream, write stream
    PIRUnit.Atomics.pas                 TAtomic: CAS / fences / wait-wake
    PIRUnit.RequestPool.pas             request slots, handles, lock-free free list
    PIRUnit.RequestQueue.pas            lock-free queue: producers -> I/O thread
    PIRUnit.Engine.pas                  TIORingEngine: I/O threads, Wait, callbacks, batches
    PIRUnit.BlockReader.pas             TIORingBlockReader: known blocks, read-ahead, merging
  UnitTests/
    Delphi/                             Pascal.IOUring.UnitTests.dpr/.dproj: the Delphi runner (DUnitX console, TestInsight)
    FPC/                                Pascal.IOUring.UnitTests.FPC.lpr/.lpi: the Free Pascal runner, Windows and Linux
    Common/                             the tests, the same for Delphi and Free Pascal (Design §12.4)
      PIRUnit.Test.Support.pas          base class over DUnitX / FPCUnit, threads, shared pattern files
      PIRUnit.Test.FileHelpers.pas      deterministic test files
      PIRUnit.Test.PlatformHelpers.pas  files, pipes, page memory for tests (Windows and Linux)
      PIRUnit.<Tested>.Tests.pas        the tests of one unit: IORing, Windows.API, Windows.API.Layout, SequentialReader,
                                        SequentialWriter, Streams, Atomics, RequestPool, RequestQueue, Engine,
                                        EngineOverlap, BlockReader, Test.FileHelpers
    Linux/                              the Linux-only tests (Build-FPC.ps1 -Platform Linux64)
      PIRUnit.Linux.API.Tests.pas       live calls to the kernel
      PIRUnit.Linux.API.Layout.Tests.pas  sizes, offsets and constants against the C header
      PIRInclude.Linux.API.Layout.inc   those checks, generated from the C header (do not edit)
      PIRUnit.Linux.Extras.Tests.pas    PrepareSqe, linked operations, capabilities
      LinuxApiLayout.c, Generate-LinuxApiLayout.sh  the generator of the .inc (gcc, on Linux)
  Benchmarks/
    PIRUnit.Benchmark.*.pas             shared by Delphi and FPC: Common, Readers, Contenders (Delphi only),
                                        Structures, Blocks, Writes
    Delphi/                             Pascal.IOUring.Benchmarks[.Structures|.Blocks|.Writes].dpr/.dproj
    FPC/                                Pascal.IOUring.Benchmarks[.Structures|.Blocks|.Writes].FPC.lpr
  Demos/
    <Name>/<Name>.dpr/.dproj/.lpi       Capabilities, CopyFile, Checksum, ReadBlocks, EngineCallbacks, SocketEcho (Linux)
    Common/PIRUnit.Demo.Common.pas      shared helpers of the demos
  3rdParty/DUnitX
```

---

## Milestone 1 – Delphi 13 on Windows

### Phase 0 – Groundwork

- [x] `PIRInclude.Compiler.inc` (`{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}`, shared switches) and include it in all units.
- [x] DUnitX console test project (Win32 + Win64 platforms), referencing `Source/3rdParty/DUnitX` by relative path.
- [x] `PIRUnit.Test.FileHelpers`: create temp files of given size where every 8-byte word is a hash of its word index (SplitMix64), so any read at any offset can be verified without keeping a copy.
- [x] Tests for the helpers themselves prove the runner works on both platforms (14 tests, Win32 + Win64).

**Done when:** test runner builds and runs for Win32 and Win64.

### Phase 1 – Complete Windows API unit (Layer 0)

`PIRUnit.Windows.API` – everything in Design §6.2, standalone (Design §6.1):

- [x] All types, constants (incl. the 8 `IORING_E_*` codes), records, `P…` pointer types.
- [x] All 16 functions as `stdcall; external kernel32 … delayed` (`delayed` only for Delphi: FPC 3.2.2 does not support it).
- [x] The 4 helper functions (`IoRingHandleRefFromHandle`, …) as `inline` functions.
- [x] Each declaration commented with minimum IoRing version (+ Microsoft Learn link where a page exists).
- [x] Tests (`PIRUnit.Windows.API.Layout.Tests` and `PIRUnit.Windows.API.Tests`, 35 tests) – the unit is tested on its own, without the rest of the library:
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

- [x] `PIRUnit.Types`: neutral plain records, `EIORingError` (readable texts for `IORING_E_*`), `EIORingNotSupported`, `TIORingCompletion` helpers.
- [x] `TWindowsIORing` **custom managed record** per Design §5.2: `Open`/`Close`, not copyable, ref conversion, all `Prepare*`, `Submit` with CQ-space guard, `TryPopCompletion`, `PopCompletions`, `WaitForCompletions`, completion event (pop-until-empty rule), pending-count tracking. `Close` **waits** for in-flight I/O (`CloseIoRing` does not cancel it – found in this phase).
- [x] `PIRUnit.IORing`: `TIORing` alias, `Available`, `QueryCapabilities`, blocking `IORingReadAt` / `IORingWriteAt`.
- [x] Check generated code (Design §4.1 [VERIFY]): cost of a managed-record local (+2.3 ns Win32, +1.2 ns Win64), `const` passing by reference (yes), inlining of the public methods (dropped, Design §4).
- [x] Tests (`PIRUnit.IORing.Tests`, 26 tests, written against `TIORing`, so they can later run on Linux; files/pipes come from the new shared `PIRUnit.Test.PlatformHelpers`):
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
- [x] Tests (`PIRUnit.SequentialReader.Tests`, 21 tests) – size × chunk matrix for buffered and unbuffered mode and for BufferCount 1, 2, 8 (plus a fixed/no-registration run):
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
- [x] Tests (`PIRUnit.Streams.Tests`, 17 tests):
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
  - [x] Lazarus project file for the tests (`Pascal.IOUring.UnitTests.FPC.lpi`): builds with `lazbuild` for `i386-win32` and `x86_64-win64` (output in `bin\` and `lib\`), all tests pass.
  - [x] **Win64:** the repaired Lazarus 5.0 RC1 install (FPC 3.2.2) has `ppcx64.exe`, `fpc.exe` and `lazbuild.exe`.
- **Phase 7 – Test runner for FPC**: **decided 2026-10-22: separate FPCUnit tests** (`Source/UnitTests/FPC/Tests.FPC.*`), the same checks as the Delphi test units. The shared helpers (`PIRUnit.Test.FileHelpers`, `PIRUnit.Test.PlatformHelpers`) are used by both. A small own console runner on FPCUnit sets the exit code.
  - [x] 101 FPC tests (Delphi has 115 because DUnitX counts each `[TestCase]` separately; the FPC tests loop over the same cases).
- **Phase 8 – Port**: compile Milestone 1 with FPC; fix only with the allowed `{$IFDEF FPC}` places (Design §12.2).
  - [x] `delayed` replaced for FPC by functions that look themselves up with `GetProcAddress` on first use (Design §6.3), so FPC programs start on Windows without IoRing.
  - [x] FPC [VERIFY]s answered on Win32 and Win64: record layouts, records passed by value (stdcall), managed-record operators (`Initialize`/`Finalize`/`Copy`), `const`/`constref` passing without copy – all tested.
  - [x] **All 101 FPC tests pass on Win32 and Win64** (FPC 3.2.2), with `Build-FPC.ps1` and with `lazbuild`.
- **Phase 9 – FPC benchmarks**:
  - [x] Reading routines moved to `PIRUnit.Benchmark.Readers` (Delphi and FPC); separate small FPC program with the main contenders (the Delphi contender list uses anonymous methods).
  - [x] Win32 and Win64, Delphi and FPC run back to back: **the same speed within noise** ([Benchmarks.md](Benchmarks.md#free-pascal)).

**Done when:** all tests pass with Delphi and FPC on Win32 and Win64. **Done 2026-10-22 – Milestone 2 is complete.** Open small item: FPC shows 15 hints (no warnings) for the library units, all harmless (unused parameters of methods that only raise, variables first set by an API call).

---

## Milestone 3 – I/O engine (Design §10, §11) – Delphi and FPC

- **Phase 10 – Atomics unit**: `PIRUnit.Atomics` (CAS 32/64 incl. Win32 64-bit CAS, exchange, add, load-acquire/store-release, pause, wait/wake on address), tests incl. multi-thread stress.
  - [x] `TAtomic` (record, static methods): `CompareExchange`, `TryCompareExchange`, `Exchange`, `FetchAdd`, `Increment`, `Decrement`, `LoadAcquire`, `StoreRelease` for `Integer`, `Cardinal`, `Int64`, `UInt64` (and `Pointer`); `FullBarrier`, `CpuPause`; `WaitWhileEqual` / `WakeOne` / `WakeAll` on 32-bit values (Design §10.6).
  - [x] Win32: 64-bit CAS is `LOCK CMPXCHG8B` (own assembler for FPC; Delphi's intrinsic does it itself); 64-bit load/store is one SSE move.
  - [x] Tests `PIRUnit.Atomics.Tests` / `Tests.FPC.Atomics` (20 each): every method and type; exact counters from 4 threads; no half-written 64-bit values; release/acquire hand-over; a spin loop sees another thread's write; wait timeout, wake one / all, ping-pong without lost wake-ups.
  - [x] Also run with optimization on: Delphi Release, FPC `-O3` (new switch `Build-FPC.ps1 -Optimize`). This found a real FPC x64 problem – a 64-bit constant written as two 32-bit stores – now fixed (Design §10.6).

  **Done 2026-10-22** – Delphi 135 tests and FPC 121 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 11 – Request pool**: fixed array of plain records, states, `NativeUInt` handle packing (index + generation, Win32 layout), lock-free free list with ABA tag. Stale-handle tests, multi-thread stress.
  - [x] `PIRUnit.RequestPool`: `TIORingFreeList` (Treiber stack, 64-bit tag + index, exponential backoff) and `TIORingRequestPool` (cache-line slots with a 32-bit state word and the engine's payload; handles = index + generation, index bits follow the capacity; `TryAcquire`, `TryChangeState`, `WaitFor` with a waiting flag, `Release`) (Design §10.7).
  - [x] Tests `PIRUnit.RequestPool.Tests` / `Tests.FPC.RequestPool` (23 each): stale and out-of-range handles, state rules, payloads, generation wrap-around (Win32), waiting and waking, no slot held twice by 4 threads, an engine simulation (4 producers + 1 I/O thread, 80 000 requests, with and without spinning).
  - [x] The thread helpers of the tests moved to shared units (`TestThreadHelpers` for Delphi, `Tests.FPC.Support` for FPC).
  - [x] Benchmark against an SRW lock (decision #10): new program `Pascal.IOUring.Benchmarks.Structures` (Delphi and FPC, `Build-FPC.ps1 -Project Structures`). Without backoff the lock won by up to 4.8×; with backoff (limit 1024 pauses) **the lock-free stack wins or ties in every case** – it stays ([Benchmarks.md](Benchmarks.md#engine-structures-phase-11)).

  **Done 2026-10-22** – Delphi 158 tests and FPC 144 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 12 – Lock-free request queue**: bounded array queue with per-cell sequence numbers, cache-line padding. Benchmark against an SRW-lock queue; keep whichever wins (Design §10.5).
  - [x] `PIRUnit.RequestQueue`: `TIORingRequestQueue` – Vyukov's bounded MPMC queue of pointer-sized values; positions on their own cache lines, `NativeUInt` positions that may wrap around (signed differences), backoff (Design §10.8).
  - [x] `TAtomic.BackOff` and `IORingAllocCacheAligned` moved to `PIRUnit.Atomics` (shared by the free list, the pool and the queue).
  - [x] Tests `PIRUnit.RequestQueue.Tests` / `Tests.FPC.RequestQueue` (12 each): order, full/empty, capacity, laps, wrap-around of the positions (also under load), many producers with one or many consumers (every value once, in order per producer with one consumer). The tests themselves were checked by breaking the queue on purpose (Design §10.8).
  - [x] `RunThreads` (Delphi and FPC test helpers) fails a test whose threads still run after 60 s, so a broken lock-free structure fails the run instead of hanging it.
  - [x] Benchmark against an SRW-lock queue (`PIRUnit.Benchmark.Structures`, `--only queue`): **the lock-free queue wins everywhere** – 4–23 % with few producers and real work, up to 290× under contention ([Benchmarks.md](Benchmarks.md#request-queue-phase-12)). It stays.

  **Done 2026-10-22** – Delphi 171 tests and FPC 157 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 13 – Engine with one I/O thread**: I/O thread loop (drain → prepare → one submit → reap → notify), sleep/wake protocol without syscalls when busy, `WaitOnAddress` waiting, `BeginBatch`/`EndBatch`, clean shutdown with requests in flight (every request completes: ok / error / cancelled). Stress test: many producer threads, random reads, all data verified. Stats counters.
  - [x] API decided first (Design §10.4) and built as decided: `PIRUnit.Engine` – `TIORingEngine` with `ReadAsync`/`WriteAsync`/`FlushAsync`, `Wait`/`TryGetResult`/`WaitAll`, callbacks on the I/O thread, `BeginBatch`/`EndBatch`, `Stats` (Design §10.9).
  - [x] I/O thread: drain → prepare (one request may wait for room) → one submit → pop all → sleep only after an idle round; producers wake it only when it sleeps.
  - [x] A full pool makes starting a request sleep until one is freed; `Destroy` cancels queued and in-flight requests, waits for all, and lets threads blocked in `Wait` leave first.
  - [x] New in the core: `IORING_RESULT_CANCELLED`, `TIORingCompletion.IsCancelled`; `PIRUnit.IORing` re-exports both result codes.
  - [x] Tests `PIRUnit.Engine.Tests` / `Tests.FPC.Engine` (19 each), incl. the shutdown cases and stress (8 threads × 1500 random reads, data checked; callbacks and waits mixed). Repeated 100× (Delphi) and 10× (FPC) to find flaky tests: one found and fixed (a busy engine never sleeps – Design §10.9).
  - [x] Found on the way: a request pool that is too small for what the threads keep can deadlock them – rule written into the unit and Design §10.9.

  **Done 2026-10-22** – Delphi 190 tests and FPC 176 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets. Not measured yet: the engine's speed (Phase 14's benchmark).
- **Phase 14 – Read stream with block provider**: look-ahead distance, merging adjacent requests (contiguous buffer or scatter), in-order delivery. Benchmark: many small "known in advance" random reads vs `TFileStream` + seek.
  - [x] API decided first (Design §10.4): both a provider (a method that gives the next block) and a plain list. `PIRUnit.BlockReader` – `TIORingBlockReader`, a managed record: `TryGetBlock`/`ReleaseBlock`, zero-copy, blocks in the provider's order (Design §10.10).
  - [x] Look-ahead: `ReadAhead` buffers (default 32 × 256 KiB), one read in flight per buffer, all new reads of a round in one engine batch. Neighbouring blocks become one read; `MaxGap` lets small gaps be read too. Scatter reads left out: they need unbuffered handles and page-aligned blocks (Design §2.1).
  - [x] Tests `PIRUnit.BlockReader.Tests` / `Tests.FPC.BlockReader` (15 each): order and data, the provider asked only when needed, merging, `MaxGap`, backward and overlapping blocks, end of file, empty list, not waiting, bad arguments, wrong call order, failed reads, `Close` with reads in flight, stats, stress (20 000 random blocks; 4 readers sharing one engine).
  - [x] Benchmark: new program `Pascal.IOUring.Benchmarks.Blocks` (Delphi and FPC, `Build-FPC.ps1 -Project Blocks`) – 20 000 blocks of 4 KiB from a 4 GiB file, random and sorted, cold and warm, against `TFileStream` + `Seek` and positioned `ReadFile` (1 and 8 threads). Not in the cache: **7–10× faster than `TFileStream`** with read-ahead 128 and faster than 8 `ReadFile` threads; 17–22× for sorted blocks with `MaxGap`. In the cache, `ReadFile` stays faster ([Benchmarks.md](Benchmarks.md#blocks-known-in-advance-phase-14)).
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
  - [x] Tests (6 new in `PIRUnit.Engine.Tests` / `Tests.FPC.Engine`): bad thread counts, a backlog is shared, a light load stays on one thread, `Destroy` cancels over 4 rings, both stress tests with 4 I/O threads; 30 repeated runs without a failure.
  - [x] Benchmark (`Pascal.IOUring.Benchmarks.Blocks`, now also unbuffered and with 2 and 4 I/O threads): with 4 I/O threads the block reader read **3.2× as many unbuffered 4 KiB blocks** as with one, and with cached data it is now **1.3–1.6× faster than `ReadFile`**; data from the disk through the file cache gains nothing ([Benchmarks.md](Benchmarks.md#several-io-threads-phase-15)). The default stays 1 I/O thread.

  **Done 2026-10-23** – Delphi 211 tests and FPC 197 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 16 – Overlap handling (decision first, Design §11)**: decide A only vs B opt-in. If B: in-flight range table per file on the I/O thread; write-after-read/write ordering, read-after-write ordering or serve-from-buffer, attach duplicate reads. Tests for each case in the Design §11 table.
  - [x] Decided (Design §11, decision 15): B as an option of the engine, `orKeepOrder`. For one file handle, requests that touch the same bytes take effect in the order they were started; reads never wait for reads; a flush waits for the earlier writes. The core ring keeps no rules (A).
  - [x] Built (Design §10.13): every request of a file handle goes to one I/O thread (its own queue); that thread keeps the file's unfinished requests in start order (a hash table of handles, a list linked through the request slots); a conflicting request is held back and starts when the earlier ones have completed. Works for any sizes and partial overlaps. Left for later: answering a read from a write's buffer, joining duplicate reads.
  - [x] Tests `PIRUnit.EngineOverlap.Tests` / `Tests.FPC.EngineOverlap` (13 each): the order cases on a file, exact cases with pipes (held back, not held back, a chain in order, flush after write, `Destroy`), routing, and two model tests (random reads and writes against an in-memory copy). Checked by switching the rule off: 9 of 13 fail then.
  - [x] Cost (probe): 20 % with many overlaps (64 % of the requests held back), about 3 % with few. Blocks benchmark (reads only, with the rule on 1 and 4 I/O threads): 0–6.5 %, and one file uses one I/O thread ([Benchmarks.md](Benchmarks.md#overlap-rule-phase-16)).
  - [x] Found on the way: a Phase 15 test failed now and then in FPC Win64 `-O3` (timing, not the engine); its backlog now uses unbuffered reads.

  **Done 2026-10-23** – Delphi 224 tests and FPC 210 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets.
- **Phase 17 – `TSequentialWriteOnlyFileStream`** (write-behind; can use the engine or its own ring).
  - [x] Measured first (Design §2.1): Windows does buffered writes, and unbuffered writes that extend a file, inside the submit call. So the writes go through an engine – its I/O thread does the submit – and not through a ring of the caller's thread.
  - [x] Decided and built (Design §8.2): `PIRUnit.SequentialWriter` – `TIORingSequentialWriter`, a managed record with its own engine by default or a shared one; copying `Write` and zero-copy `AcquireBuffer`/`CommitBuffer`; `Flush(AToDisk)`; unbuffered option with a cut last buffer. `TSequentialWriteOnlyFileStream` in `PIRUnit.Streams`. A failed background write raises at the next call (`EWriteError` in the stream), and at `Free` if it was never raised.
  - [x] New platform calls: `CreateFileForWrite`, `SetFileSize`.
  - [x] Tests `PIRUnit.SequentialWriter.Tests` / `Tests.FPC.SequentialWriter` (25 each): round trips around the buffer size and with pieces of every size, zero-copy, `Flush`, unbuffered, failed writes (made with a byte-range lock), bad arguments, wrong call order, end of scope, stats, a shared engine with 4 writers, and the stream with `CopyFrom`, `SaveToStream`, `Seek` rules and errors.
  - [x] Benchmark: new program `Pascal.IOUring.Benchmarks.Writes` (Delphi and FPC, `Build-FPC.ps1 -Project Writes`) – 1 and 10 GiB against `TFileStream` and `TBufferedFileStream`, writing only and with CPU work. With work, 1 GiB was written **25–45 % sooner** (10 GiB: 3–21 %, the disk is the limit); writing alone gains nothing; unbuffered gets the data onto the disk soonest with a third of the CPU time ([Benchmarks.md](Benchmarks.md#writing-phase-17)).

  **Done 2026-10-23** – Delphi 249 tests and FPC 235 tests pass on Win32 and Win64 (Delphi Debug and Release, FPC with and without `-O3`); `lazbuild` builds the FPC test project for both targets. **Milestone 3 is complete.**

---

## Milestone 4 – Linux through Free Pascal

- **Phase 18** – `PIRUnit.Linux.API`: complete `linux/io_uring.h` translation (Design §6.4) + syscall wrappers, layout tests on x86-64 and AArch64.
  - [x] Decided first (Design §6.4, decision 17): raw system calls, no liburing; the header of Linux 6.8 (Ubuntu 24.04 LTS); layout tests generated from the C header; the Linux tests run in WSL.
  - [x] `PIRUnit.Linux.API`: every constant, enum, flag and record of the header with its C name, the mmap offsets, `__kernel_timespec`, the system call numbers, and `io_uring_setup`, `io_uring_enter`, `io_uring_enter2`, `io_uring_register` (they return `-errno` and raise nothing). Standalone: RTL only.
  - [x] Layout tests generated: `Generate-LinuxApiLayout.sh` first checks that `LinuxApiLayout.c` names everything in the header (200 constants, 20 records, 147 fields), then builds it with gcc; it writes 373 checks into `PIRInclude.Linux.API.Layout.inc`. A name the Pascal unit does not have does not compile.
  - [x] Live tests (22): setup and its errors, the ring memory, no-ops, reads and writes through the ring, end of file, errors in the completion, registered files and buffers, the probe, `io_uring_enter` errors, timeouts.
  - [x] New test program `Pascal.IOUring.UnitTests.Linux.lpr`; `Build-FPC.ps1 -Platform Linux64` builds and runs it inside WSL.
  - [x] Found on the way: FPC aligns a variant part (a C union) to the largest field in it – also the fields after the union. In the SQE the flags union moved from offset 28 to 32. Fixed with `packed` for the two records concerned (Design §6.4); the generated layout tests caught it on their first run.
  - [x] AArch64: tested in CI on GitHub's ARM64 runner (Phase 23): the layout tests pass, and the generator gives the same checks there (Design §6.4).

  **Done 2026-10-23** – Linux: 25 tests pass in WSL2 (kernel 6.18, x86-64), with and without `-O3`. Windows: no code changes; the FPC tests (235) still pass on Win32 and Win64 with the changed `Build-FPC.ps1`.
- **Phase 19** – One set of tests for Delphi, Free Pascal and Linux (Design §12.4): one shared unit per test topic in `Source/UnitTests/Common`, a base class over DUnitX and FPCUnit, the tests that only Delphi has ported, one Free Pascal test program for Windows and Linux. Ends with Delphi and FPC running the same tests on Windows.
  - [x] Decided first (Design §12.4, decision 18): FPCUnit names for the checks, one Free Pascal runner for Windows and Linux, on main.
  - [x] `PIRUnit.Test.Support`: the base class `TIORingTestCase` (FPCUnit's `TTestCase`, or a DUnitX fixture that resets itself before each test), `RegisterTests`, `RunThreads`, `Log`, `CheckPattern`, shared pattern files. Compiles on Linux too.
  - [x] The 13 test topics moved to `Source/UnitTests/Common`, one unit each, made from the FPC twins; the tests and log lines that only Delphi had were ported. Old twins and `TestThreadHelpers` removed.
  - [x] One Free Pascal runner (`FPC/Pascal.IOUring.UnitTests.FPC.lpr`) for Windows and Linux; the Linux tests use the same base class; `Build-FPC.ps1 -Platform Linux64` builds it in WSL.
  - [x] Found on the way: DUnitX runs all tests of a class on one object (FPCUnit: one object per test); three tests had no counted check; RTL differences (`GetTickCount64`, `constref`, `TStreamReader`, `string` size) – Design §12.4.

  **Done 2026-10-23** – Delphi 242 tests (Win32 and Win64, Debug and Release), FPC 241 on Windows (Win32 and Win64, with and without `-O3`), FPC 32 on Linux (WSL2, with and without `-O3`); `lazbuild` builds the Lazarus test project. Delphi has one test more (`ReadOverloads_Work`: overloads FPC 3.2.2's `TStream` lacks).
- **Phase 20** – `TLinuxIORing` record in `PIRUnit.Linux.Ring` and the platform record `TLinuxIORingPlatform`; `Atomics` on Linux (futex; AArch64 acquire/release); the Linux side of the test helpers; the shared suites that need no engine (atomics, request pool and queue, ring, sequential reader) run on Linux (WSL2 is enough for x86-64 development). Decided: Design §5.7, decision 19.
  - [x] `TLinuxIORing`: the same methods as `TWindowsIORing`; one `mmap` for both rings; `Submit` repeats `io_uring_enter` until every prepared entry is in; timeouts with `IORING_ENTER_EXT_ARG`; registration as a system call with its own completion; scatter/gather segments copied and cut to the byte count; the `eventfd` only when `CompletionEventHandle` is asked for.
  - [x] `TLinuxIORingPlatform` (`O_DIRECT`, `posix_fadvise`, `statx` for the alignment, `mmap`, `AT_PAGESZ`, `clock_gettime`); `FreePages` got a size parameter on both systems. `NativeResult` is 0 or a negative error code on both systems.
  - [x] Atomics on Linux: the futex; AArch64 barriers (tested on ARM64 in CI, Phase 23).
  - [x] `PIRUnit.Test.PlatformHelpers` for Linux: neutral open flags, `pipe()`, `mmap`, waiting on an event, `RESULT_ACCESS_DENIED`. The ring and reader tests run on both systems; new: `Flush_AllModes`, `WriteThrough_UnbufferedFile`, and two Linux-only ring tests (registration at once, scatter cut to the byte count).
  - [x] Changed plan: the read stream suite moves to Phase 21 – the stream unit also holds the write stream, which needs the engine.
  - [x] Found on the way: on Windows, write-through needs an unbuffered file (`0x800701FD` on a cached one; Design §2.1).
  - [x] AArch64: compiled and run in CI (Phase 23); it found one bug, `O_DIRECT` (Design §12.5).

  **Done 2026-10-24** – Linux: 137 tests pass in WSL2 (kernel 6.18), with and without `-O3`. Windows: Delphi 244 tests (Win32 and Win64, Debug and Release), FPC 243 (Win32 and Win64, with and without `-O3`); `lazbuild` builds the test project; the benchmarks compile.
- **Phase 21** – The engine on Linux (how its I/O thread sleeps and is woken); the block reader, overlap rule, read stream and write stream suites on Linux; the benchmarks on Linux. Decided: Design §10.14, decision 20.
  - [x] `TIORingPlatform` event API on both systems (Windows event and `WaitForMultipleObjects`; Linux `eventfd` and `poll`); the engine has no Windows calls left (`FileHash`, `IsFailure`).
  - [x] Tests: `OpenPipePair` (socket pair on Linux), `MakeWritesFail` (`dup2` on Linux), `BAD_HANDLE`; the engine, overlap rule, block reader, read stream and write stream suites run on Linux. Two overlap tests stay Windows-only (they need a Windows pipe).
  - [x] Found on the way: closed rings keep their registered buffers locked for a while, and quick open/close runs out of locked memory (`ENOMEM`). `Close` now unregisters first; the sequential reader reads without registration when a registration fails (Design §10.14).
  - [x] Found on the way: Free Pascal's `TThread.WaitFor` on Unix waits in 100 ms steps when called from the main thread, so freeing an engine took up to 100 ms. The engine now waits for the end of its I/O threads itself first; new test `Destroy_TenEngines_AreQuick` (Design §10.14).
  - [x] The four benchmarks build and run on Linux (`Build-FPC.ps1 -Platform Linux64 -Project …`); first WSL2 results in Benchmarks.md, marked: cold in WSL2 is not the disk.
  - [x] `Build-FPC.ps1 -Distribution`: the tests also pass in Ubuntu 26.04 (no gcc there; the linker warns about `crtbegin.o` but works).
  - [ ] Benchmarks on a real Linux machine (not WSL2), and on AArch64 (planned on the CI runners, Phase 23).

  **Done 2026-10-24** – Linux: 230 tests pass in WSL2 (kernel 6.18; Ubuntu 24.04 and 26.04), with and without `-O3`. Windows: Delphi 245 tests (Win32 and Win64, Debug and Release), FPC 244 (Win32 and Win64, with and without `-O3`; also FPC trunk 3.3.1, Win64); `lazbuild` builds the test project; the benchmarks compile with Delphi and FPC, and the FPC ones also on Linux.
- **Phase 22** – Linux extras: sockets, linked operations, SQPOLL – exposed through the API unit and capabilities only. Decided: Design §5.8, decision 21.
  - [x] Measured first (WSL2): SQPOLL gives no gain for file I/O and costs much more CPU time; links and socket operations work through the ring.
  - [x] `TLinuxIORing.PrepareSqe` (any io_uring operation, one completion per entry) and `LinkToNext` (linked operations), in the low-level ring.
  - [x] SQPOLL and all other definitions stay in the API unit; an API test with a SQPOLL ring.
  - [x] Shared capabilities for both systems: `SystemDescription`, `NotAvailableReason`, `NativeFeatures`, `NativeOps`, `Extras`, `ToString`; `IORingCapabilities` in `PIRUnit.IORing`.
  - [x] Tests: 11 Linux-only (`PIRUnit.Linux.Extras.Tests`: sockets, links), the SQPOLL API test, a shared capabilities test.

  **Done 2026-10-24** – Linux: 243 tests pass in WSL2 (Ubuntu 24.04 and 26.04), with and without `-O3`. Windows: Delphi 246 tests (Win32 and Win64, Debug and Release), FPC 245 (Win32 and Win64, with and without `-O3`; also FPC trunk 3.3.1, Win64); `lazbuild` builds the test project; the benchmarks compile with Delphi and FPC, and the FPC ones also on Linux.

---

## Milestone 5 – Ready for others to use

All goals of Design §1 are met; this milestone makes the library easy to
take and keeps it checked on more systems than one machine. (Planned
2026-10-24; the repository is public on GitHub, so its hosted runners are
free, ARM64 included.)

- **Phase 23** – Tests in CI (GitHub Actions): the Free Pascal tests on Linux x86-64, Linux ARM64 (the first AArch64 run: closes the [VERIFY] points of Phases 18 and 20) and Windows, on every push; the benchmarks built there, and run on demand (first Linux numbers that are not WSL2). Delphi stays local (license). Decided: Design §12.5.
  - [x] `Build-FPC.ps1` builds natively on Linux (`Linux64`, new `LinuxArm64`; the RTL unit folder found from the installed fpc); on Windows unchanged, Linux64 through WSL.
  - [x] The test program prints `IORingCapabilities.ToString` first; `ToString` names the reason first when the ring is not available.
  - [x] `.github/workflows/ci.yml`: Linux x64 and ARM64 (tests debug and `-O3`, the layout generator against the committed file, benchmarks built), Windows Server 2025 (FPC 3.2.2 installer, cached; tests Win32 and Win64 debug and `-O3`, or built only with a warning when IoRing 4 is missing; benchmarks built); the benchmarks run when started by hand, output kept as an artifact.
  - [x] The first run: Linux x64 and Windows Server 2025 (it has IoRing 4) passed; Linux ARM64 found that FPC 3.2.2's `O_DIRECT` is the x86 value on AArch64 (there it means `O_DIRECTORY`): fixed with an own flag per CPU. Failed tests now also become annotations (readable without signing in).
  - [x] Second run: all tests pass on ARM64 too (debug and `-O3`) – AArch64 verified. The layout check compared whole files, whose first lines name the CPU; it now compares the checks only.
  - [x] A green run on all three runners (third run, commit 2999f18): Linux x64 and ARM64 (tests debug and `-O3`, layout check, benchmarks built), Windows Server 2025 (Win32 and Win64, debug and `-O3`, benchmarks built).
  - [x] The benchmarks once on the runners (2026-10-24, Benchmarks.md "GitHub's runners"): slow cloud disks (about 400 MiB/s, 20–27 thousand random reads per second); the block reader reaches the disk's limit where plain reads do not (Windows 3.6× `ReadFile` random, 7.5–12.6× sorted); the write stream with work 24–42 % sooner. Found: on ARM64 the lock-free structures sometimes lose to a mutex (Phase 27).

  **Done 2026-10-24** – CI green on Linux x64, Linux ARM64 and Windows Server 2025 (Free Pascal 3.2.2: tests debug and `-O3`, layout check, benchmarks built); AArch64 verified, one AArch64 bug found and fixed (`O_DIRECT`); failed tests become annotations. Locally unchanged: Delphi 246 tests, FPC 245 on Windows, 243 on Linux (WSL2).
- **Phase 24** – A Lazarus package (`.lpk`), so a Lazarus project adds the library in one step. No Delphi package: Delphi compiles the library into the program from `Source/Units`. Decided: Design §12.6.
  - [x] `Packages/Lazarus/PascalIOUring.lpk`, version 0.1, runtime only; the four backend units are not in its main unit, so each system compiles only its own. Lazarus's generated `PascalIOUring.pas` committed with it (the normalize script leaves it alone).
  - [x] `Build-FPC.ps1 -Project Package` compiles the package's main unit with FPC (Win32, Win64, Linux64; on Linux machines also LinuxArm64); CI does it on all three runners.
  - [x] CI no longer runs the benchmarks (the workflow's inputs and artifacts are gone); the tests stay on every push.
  - [x] README: how to use the library from Delphi (search path) and Lazarus (the package).

  **Done 2026-10-24** – The package builds with `lazbuild` (Lazarus 5.0 RC1: Win32 and Win64; trunk: Win64) and through `Build-FPC.ps1` (Win32, Win64, Linux64 in WSL; Win64 also with FPC trunk). Library code unchanged.
- **Phase 25** – Demos: small programs in `Source/Demos` (`IORingCapabilities`, the two streams, the zero-copy reader, the block reader, the engine with callbacks, a socket echo on Linux), each one source for Delphi, Lazarus and FPC; the version constant 0.1.0 (the version stays below 1.0 for a long time, Design §12.6). No tag yet. Decided: Design §12.7.
  - [x] `Source/Demos`: `Capabilities`, `CopyFile`, `Checksum`, `ReadBlocks`, `EngineCallbacks`, `SocketEcho` (Linux only), and `Common/PIRUnit.Demo.Common.pas` (a temporary file, a clock). Each runs without arguments and checks its own result, or takes a file name.
  - [x] Each demo: one `.dpr`, a `.dproj` (Delphi, Win32 and Win64; not `SocketEcho`) and an `.lpi` (Lazarus, through the package).
  - [x] `Build-FPC.ps1 -Project Demos [-Run]`; CI builds and runs the demos on all three runners.
  - [x] `IORING_LIBRARY_VERSION = '0.1.0'`; `IORingCapabilities.ToString` ends with "Library: Pascal.IOUring 0.1.0".

  **Done 2026-10-24** – The demos build and run with FPC (Win32, Win64, Ubuntu 24.04 and 26.04), Delphi (Win32 and Win64, Debug and Release) and Lazarus (Win32, Win64). Tests: Delphi 246, FPC 245 on Windows, 243 on Linux.

## Milestone 6 – Faster where it still loses

Only what a benchmark has already shown:

- **Phase 26** – Read straight into the caller's buffer for big aligned reads (Design §7, point 7): with cached data the read stream is 16–31 % slower than `TFileStream`, on every system measured, because of one more copy. On Linux also the clock through the C library (13 ns instead of 94 ns; Design §10.14). Decided: Design §12.8 – build it and keep it only if it wins; the Linux clock stays.
  - [x] `TIORingSequentialReader.Read`: the part of a call beyond what the buffers have asked for is read straight into the caller's memory (pieces of the buffer size, up to the buffer count in flight); the buffers read ahead after the end of the call once all of its pieces have started. Unbuffered only into sector-aligned memory, in whole sectors. The stream gets it through the reader.
  - [x] Never a read in flight into the caller's memory when `Read` returns or raises; a failed big read makes every later call fail (going on would leave a gap).
  - [x] `Stats.DirectReads` and `Stats.DirectBytes`; `BytesFromDisk` counts both kinds.
  - [x] Tests: 6 new (big reads buffered and unbuffered, aligned and not, small reads use only the buffers, mixed with small reads and chunks, a file shortened during big reads, `TMemoryStream.LoadFromStream`); the stream's statistics test updated.
  - [x] Measured, the reader before and after in turns (Design §12.8): warm big calls 8–24 % faster on Windows and Linux (64 MiB calls 96–101 % of `TFileStream`, 8 MiB calls 82–90 %); cold 8 MiB and 64 KiB calls as before; cold 64 MiB calls 20–22 % faster on Linux, about 2 % slower on Windows. Changed on the way: the buffers wait with their reading ahead until all of a call's pieces have started (cold 64 MiB calls on Windows lost 6 % before that).
  - [x] Kept (Design §12.8, decision 4; decisions log 22), although the rule of decision 1 is not met everywhere. Why cold 64 MiB calls on Windows are about 2 % slower is parked (Design §13).
  - [x] README (the stream section) and Benchmarks.md ("Big Read calls") describe it.

  **Done 2026-10-24** – Tests: Delphi 252 (Win32 and Win64, Debug and Release), FPC 251 (Win32 and Win64, with and without `-O3`), Linux 249 (WSL2, with and without `-O3`); the demos run on Win64 and Linux; the benchmarks and the Lazarus package compile. The Linux clock stays as it is (measured: less than 0.1 %).
- **Phase 27** – The atomics on AArch64: on GitHub's ARM64 runner the lock-free structures sometimes lose to a mutex (queue with 2–3 producers in a tight loop 0.87–0.90; free list with 4 threads and work 0.88), while on x86-64 they always win. Every atomic operation there has full barriers around it, and FPC 3.2.2 does not inline its `ReadWriteBarrier` on AArch64. Measure inline barriers and lighter ordering (acquire/release instructions); keep the lock-free structures only where they win (Design §10.5). Decided: Design §12.9 – measure in a hand-started ARM64 workflow; assembler routines, each kept only if it wins; one code path for all CPUs.
  - [x] `PIRUnit.Atomics` on AArch64: small assembler routines – compare-exchange, exchange and fetch-add as `ldxr`/`stlxr` loops with one `dmb ish` after them; `LoadAcquire` = `ldar`, `StoreRelease` = `stlr`; `CpuPause` = `yield` (`IORING_ATOMICS_AARCH64_ISB`: `isb`). `IORING_ATOMICS_AARCH64_RTL` keeps the way before, for comparing.
  - [x] `.github/workflows/arm64-atomics.yml` (started by hand) and `.github/scripts/Measure-Atomics.ps1`: tests, then the Structures benchmark as `rtl`, `yield` and `isb`, in turns; tables as annotations and in the job summary. `Build-FPC.ps1 -Define`.
  - [x] First run on the ARM64 runner (2026-10-25): FPC 3.2.2 accepts the instructions; the tests pass (debug and `-O3`); Structures benchmark in Design §12.9.
  - [x] Kept: the assembler routines (+52 % free list, +30 % queue with one thread) with `CpuPause` = `isb` (queue with 2–3 producers 7–9× faster than before; `yield` hardly helps). Lock-free now beats the mutex everywhere on ARM64: decision 3 not needed.

  **Done 2026-10-25** – ARM64: lock-free 1.00–8.76× the mutex (before: down to 0.67). x86 unchanged: Delphi 252 tests (Win32, Win64), FPC 251 (Win64), Linux 249 (WSL2).

## Milestone 7 – Tidy up and the first version, 0.1.0 (2026-10-25)

Everything planned so far is built, tested on three systems and measured.
What comes next depends most on how the library will be used, so this
proposal has one tidy-up phase that is worth doing in any case, and then a
choice.

- **Phase 28 – Tidy up** (small things, collected; with the review, the
  proposal is in Design §12.10 and waits for the decisions marked [DECIDE]):
  - Old [VERIFY] markers that are answered: the AArch64 atomics and the
    Linux API unit on ARM (Design §5.7, Phase 20 notes, and §6.4) –
    verified in CI in Phases 23 and 27.
  - The last open question of Design §14 (neutral `TIORingFileRef` /
    `TIORingBufferRef` records against records with the OS's layout).
    Proposed: close it – keep the neutral records; the conversion is a few
    register moves and never showed in a benchmark.
  - Run the Windows benchmarks again, locally (the shared benchmark code
    changed in Phases 21–27), and bring Benchmarks.md up to date. (The
    Linux build files are already out of git.)
  - Coding style rule 3 (parameter records): look for groups of
    parameters passed through many routines on the hot paths; change one
    only where a benchmark shows a gain.

- **[DECIDE] 1. The main direction after Phase 28** (one or more, in
  order):
  - a. **Linux sockets with typed methods** (Design §13): `PrepareSend`,
    `PrepareRecv`, `PrepareAccept`, `PrepareConnect` on `TLinuxIORing`,
    maybe through the engine – for servers on Linux. Linux only: Windows
    IoRing has no socket operations.
  - b. **Delphi for Linux** (Delphi's Linux64 compiler): the Linux backend
    is Free Pascal only today (its units, its assembler). Needs Delphi
    Enterprise and a Linux machine with PAServer – a bigger port.
  - c. **A first tagged version, 0.1.0**, with a change log and an API
    overview – you said not yet; perhaps when someone else starts to use it.
  - d. **A real program of yours first:** take what a program you have in
    mind needs from the library, build that, and measure there.

  Proposed: Phase 28 first, then d. if you have such a program, otherwise a.

  **Decided (2026-10-25):** Phase 28 first, with a wider scope: besides
  the small things, a review of code quality, the API and its names, code
  structure (easier to read), and small measurable gains in the atomics.
  The review's findings come as a proposal first. Then **d.**: the library
  goes into a real program of the owner's, to see whether the API fits or
  needs more – after Phase 28. **a.** Linux sockets: low priority, a part of
  the library of its own – a plan for it is enough for now. **b.** Delphi for
  Linux: not now (no license here; open to someone who contributes it).
  **c.** Tag 0.1.0 as the last step of Phase 28. The library may be renamed
  **Pascal.IOUring** before that tag (it is as much Free Pascal as Delphi
  now) – to be asked before it is done; GitHub keeps redirects from the old
  name.
- **[DECIDE] 2. The two unexplained findings on GitHub's runners**
  (Benchmarks.md, [open]: on Linux read-ahead 8 beats 128; unbuffered, the
  block reader on Windows is no faster than `ReadFile`). They can only be
  looked into with benchmarks on the runners. Proposed: park them (Design
  §13) – slow cloud disks, not the machines the library is for. Other choice:
  look into them with a hand-started workflow, as in Phase 27.

- **Phase 28** – Tidy up before 0.1.0: review of code, API, names and structure. Decided: Design §12.10 – all six points as proposed.
  - [x] API names (2): `ATimeoutMilliseconds`, only `IORING_INFINITE`, `TIORingSequentialReaderStats` / `TIORingSequentialWriterStats`, `TIORingEngine.Stats` a property, `IORingReadAt` / `IORingWriteAt`, `TIORingUserData` in the engine.
  - [x] Internal types nested in the records that use them (3): slots of the readers and the writer, the queue's cells, the free list's links.
  - [x] Platform units of their own (4): `PIRUnit.Windows.Platform`, `PIRUnit.Linux.Platform` (in the Lazarus package); one buffer check for the reader and the writer (`IORingCheckBufferArguments`, `IORingCheckSectorMultiple`).
  - [x] The Linux clock (5): measured in WSL2 with the Blocks benchmark (new option `--cache`), six rounds – no gain, FPC's clock stays; `IORING_CLOCK_LIBC` for comparing. The ARM64 workflow ("ARM64 benchmarks") can measure it on the runner (`benchmark: clock`).
  - [x] Found on the way: a rare hang of the engine on Linux (a completion before the ring's eventfd was registered) – fixed; the Linux tests then passed 10 runs in a row.
  - [x] Small things (6): §14 closed (neutral ref records stay); answered [VERIFY] and [DECIDE later] markers removed; the two findings of GitHub's runners parked (§13); a plan for Linux sockets (§13).
  - [x] The Windows benchmarks again, locally (Delphi Win64; Benchmarks.md, "The Windows numbers again"): the same as before or better; nothing the library does got slower.
  - [x] Tests (2026-10-25): Delphi 252 (Win32 and Win64, Debug and Release), FPC 251 (Win32 and Win64, with and without `-O3`; trunk on Win64), Linux 249 (WSL2, debug and `-O3`, 10 runs in a row after the fix); the demos run on Win64 and Linux; the benchmarks and the Lazarus package compile.
  - [x] The library's new name (1), after asking (2026-10-25): Delphi.IOUring → **Pascal.IOUring** (projects, the Lazarus package `PascalIOUring`, the test and benchmark folders, the layout generator `Generate-LinuxApiLayout.sh`).
  - [x] The owner's naming scheme for units and files (CodingStyle.md, "Units and files"): prefix `PIR` + kind + what it holds – `PIRUnit.IORing`, `PIRUnit.Types`, `PIRUnit.Engine` …; `PIRUnit.<System>.API` / `.Ring` / `.Platform` instead of `Backend.…`; tests `PIRUnit.<Tested>.Tests`, helpers `PIRUnit.Test.…`, benchmarks `PIRUnit.Benchmark.…`; `PIRInclude.Compiler.inc`. The Delphi test and benchmark projects moved to `Delphi/` folders, the package to `Packages/Lazarus`. Files moved with `git mv`.
  - [x] No "local global variables" (new CodingStyle rule): the six nested routines that saw their caller's variables now get parameters.
  - [x] The GitHub repository renamed to Pascal.IOUring, and the local folder (by the owner); CI green on the renamed repository (Windows, Linux x64, Linux ARM64, two runs).
  - [x] Tag **0.1.0** (by the owner, 2026-10-25), on commit `766b35c`.

  **Done 2026-10-25** – Tagged 0.1.0. Tests: Delphi 252 (Win32 and Win64, Debug and Release), FPC 251 (Win32 and Win64, with and without `-O3`; trunk on Win64), Linux 249 (WSL2, debug and `-O3`); CI green on all three runners. Not run: the clock comparison on the ARM64 runner (optional, `benchmark: clock`).

---

## Immediate next step

Phase 28 is done and the first version, **0.1.0**, is tagged. Next, as
decided for Milestone 7 (d.): the library goes into a real program of the
owner's, to see whether the API fits or needs more. What that program needs
decides the next phase. Later, and only when needed: Linux sockets (the plan
in Design §13).
