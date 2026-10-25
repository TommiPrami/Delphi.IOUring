# Pascal.IOUring – Benchmarks

Measured 2026-10-22 (Plan, Phase 5) with `Source/Benchmarks/Pascal.IOUring.Benchmarks`,
Release builds, Delphi 13. Raw data (every single run): [BenchmarkResults/](BenchmarkResults/).
The engine's data structures (Phase 11 and later) have a benchmark of their
own: [Engine structures](#engine-structures-phase-11), and so has the engine
with the block reader: [Blocks known in advance](#blocks-known-in-advance-phase-14),
[Several I/O threads](#several-io-threads-phase-15) and
[Overlap rule](#overlap-rule-phase-16); writing has its own:
[Writing](#writing-phase-17). A first look at Linux (in WSL2):
[Linux in WSL2](#linux-in-wsl2--a-first-look-phase-21); and GitHub's runners,
x64 and ARM64: [GitHub's runners](#githubs-runners-phase-23). All four
Windows benchmarks again after Phase 28:
[The Windows numbers again](#the-windows-numbers-again-phase-28).

## Short version

On this machine (fast NVMe disk, 64 GB RAM), reading a big file from start to end:

- **File not in the cache ("cold"):** `TSequentialReadOnlyFileStream` reads at
  the **full speed of the disk, ~6.75 GiB/s**. `TFileStream` gets 2.5 GiB/s with
  1 MiB reads and 1.5–1.7 GiB/s with 64 KiB reads. So the IoRing stream is
  **2.7× faster** than `TFileStream` with 1 MiB reads and **about 4× faster**
  than with 64 KiB reads – with no change to the code that uses the stream.
- **IoRing is not faster than classic overlapped `ReadFile`** with the same read-ahead
  (8 × 1 MiB in flight): both reach the disk limit. For one sequential reader
  the gain comes from **reading ahead**, not from IoRing as such. IoRing's
  extra strengths (one system call for many requests, registered buffers)
  should matter more for many small or random requests – the engine of
  Milestone 3.
- **File already in the cache ("warm"):** no gain. Everything is limited by copying
  memory (6–7.5 GiB/s). The IoRing reader is ~6 % slower than plain `ReadFile`,
  the IoRing stream ~16 % slower than `TFileStream` with 1 MiB reads (one
  more copy: cache → ring buffer → caller).
- **With CPU work on the data:** the reading happens in the background while
  the program works ("data for free"): **14–18 % less time** than synchronous
  reading with 1 MiB blocks (Win32–Win64), and the reader almost never had to
  wait (1–3 waits for 1024 buffers).
- **Defaults confirmed:** 1 MiB × 8 buffers is within 1 % of the best setting,
  buffered and unbuffered. The sequential-scan hint and adaptive read-ahead
  make no measurable difference here; registering the buffers gives ~1–2 %.
- **Engine structures (Phase 11):** the lock-free free list of the request
  pool is as fast as an SRW lock or faster in every case measured – 1.1–6.7×
  faster with several threads in a tight loop – but only with backoff;
  without it, the lock was up to 4.8× faster.
- **Request queue (Phase 12):** the lock-free queue from the producers to the
  I/O thread beats an SRW-lock queue everywhere: 4–23 % with few producers
  and real work, 3–290× under contention, where the lock starves the
  consumer.
- **Blocks known in advance (Phase 14):** 20 000 random 4 KiB blocks of a
  4 GiB file that is not in the cache: the block reader (the engine with 128
  reads in flight, one thread) is **7–10× faster than `TFileStream` +
  `Seek`** and 1.2–2.1× faster than 8 threads with `ReadFile`. For sorted
  blocks with small gaps, reading the gaps too (`MaxGap`) makes it
  **17–22× faster**. With the data already in the cache, plain `ReadFile`
  stays faster than one I/O thread (the reader gets 85–92 % of its speed on
  the fast cores of this CPU, 43–50 % on the slow ones).
- **Several I/O threads (Phase 15):** with cached data and with unbuffered
  reads, one I/O thread is the limit – Windows does the work of a request
  inside the submit call. With 4 I/O threads the block reader read **3.2×
  as many unbuffered 4 KiB blocks** as with one, and with cached data it is
  now **1.3–1.6× faster than `ReadFile`**. Data from the disk through the
  file cache gains nothing.
- **Overlap rule (Phase 16):** keeping the order of overlapping requests
  costs about 3 % when few requests overlap, 20 % when two thirds of them
  have to wait, and up to 6.5 % for reads alone. With the rule, one file uses
  one I/O thread.
- **Writing (Phase 17):** the write stream writes in the background. When
  the program also works on the data, a 1 GiB file is written **25–45 %
  sooner** than with `TFileStream` (10 GiB: 3–21 %, where the disk is the
  limit); for writing alone there is no gain. Unbuffered, the data is on the
  disk soonest and with a third of the CPU time.
- **Linux in WSL2 (Phase 21, a first look, not disk numbers):** Linux reads
  ahead by itself for buffered sequential reads, so the reader gains nothing
  there – but with CPU work, the unbuffered reader hides the reading
  completely (29 % less time than `TFileStream`). Random 4 KiB blocks: the
  block reader is **10–20× faster than `pread`**. The write stream with work:
  26–29 % less time. The lock-free structures beat a pthread mutex
  everywhere.
- **GitHub's runners (Phase 23; slow cloud disks):** the block reader reaches
  the disk's limit where plain reads do not – on Windows 3.6× `ReadFile`
  for random blocks, 7.5–12.6× for sorted ones. The write stream with work
  finished 24–42 % sooner. On ARM64 the lock-free structures sometimes lost
  to a mutex (0.87–0.90 for the queue under contention) – fixed in Phase 27.
- **The atomics on ARM64 (Phase 27):** assembler routines and an `isb` spin
  hint. With one thread the free list is 52 % faster, the queue 30 %; with
  2–3 producers the queue is 7–9 times as fast as before, and lock-free now
  beats the mutex everywhere on ARM64 (1.00–8.76×).
- **Big `Read` calls (Phase 26):** the part of a call beyond what the
  stream's buffers have asked for is read straight into the caller's
  memory. With cached data, 64 MiB calls now get **96–101 % of
  `TFileStream`** (before: 83–89 %), 8 MiB calls 82–90 % (before: 65–73 %).
  Cold, on Linux 11–22 % faster; on Windows as before, except 64 MiB calls
  about 2 % slower. Calls up to the buffers' size (64 KiB, 1 MiB) are
  unchanged.
- **The Windows numbers again (Phase 28):** after Phases 21–28 the four
  Windows benchmarks give the same results as before, or better; nothing
  the library does got slower.

## Machine

| | |
| --- | --- |
| CPU | Intel Core i7-14700 (20 cores, 28 logical processors: 8 fast P-cores with 2 threads each, 12 slower E-cores) |
| Memory | 64 GB |
| Disk | Samsung SSD 990 PRO 2 TB, NVMe (drive C:, NTFS) |
| Windows | Windows 11, build 26300, IoRing version 4 (kernel, not emulated) |
| Compiler | Delphi 13 (compiler 37.0), Release, Win32 and Win64 |

The computer was otherwise idle. (A first set of runs during a big database
backup was thrown away.)

## How it was measured

- **Files:** 1 GiB and 10 GiB of pseudo-random data, written without buffering
  (so not left in the cache), in `%TEMP%`, deleted afterwards.
- **Every contender reads the whole file** and gives the data, in file order, to
  the same consumer, which computes an XOR checksum of all 64-bit words. All
  runs had the same checksum and byte count (checked automatically).
- **Scenarios:**
  - *read-through* – only the checksum (light CPU work);
  - *work* – plus 200 µs of busy CPU work per MiB (1 GiB file only), to see
    whether reading overlaps with processing.
- **Cache states:**
  - *cold* – before each run the file is dropped from the Windows file cache
    (by opening it once with `FILE_FLAG_NO_BUFFERING`). The program checks
    that this works: a warm read of 1 GiB took 0.16 s, the same read after the
    purge 0.58 s.
  - *warm* – the file was read once before, so it is in the cache. Unbuffered
    contenders are not run warm (they bypass the cache).
- **3 runs** per contender and case; the tables show the **median**. Contenders
  take turns run by run, so slow drift affects all of them alike.
- **CPU time** = user + kernel time of the benchmark process (all its threads).

### Contenders

| Name | What it is |
| --- | --- |
| TFileStream 64 KiB / 1 MiB reads | `TFileStream.Read` with that block size |
| TBufferedFileStream | Delphi's buffered stream, 1 MiB buffer, 64 KiB reads |
| ReadFile 1 MiB | plain synchronous `ReadFile`, with / without `FILE_FLAG_SEQUENTIAL_SCAN` |
| Overlapped ReadFile 1 MiB × 8 | classic asynchronous I/O: 8 overlapped reads in flight, used in order (buffered / unbuffered) |
| 4 threads, ReadFile 1 MiB | 4 threads, each reading a quarter of the file synchronously (no ordered consumer, so read-through only) |
| IoRing stream | `TSequentialReadOnlyFileStream`, 64 KiB `Read` calls, defaults (1 MiB × 8) |
| IoRing reader, zero-copy | `TIORingSequentialReader` with `TryAcquireChunk`/`ReleaseChunk`, defaults |

## Results

### 10 GiB, read-through, cold cache

| Contender | Win64 MiB/s | Win32 MiB/s | Win64 CPU ms (user + kernel) |
| --- | ---: | ---: | ---: |
| TFileStream 64 KiB reads | 1 678 | 1 485 | 1 500 |
| TFileStream 1 MiB reads | 2 509 | 2 516 | 1 313 |
| TBufferedFileStream 1 MiB buffer, 64 KiB reads | 2 532 | 2 515 | 1 282 |
| ReadFile 1 MiB, sequential scan | 2 522 | 2 676 | 1 485 |
| ReadFile 1 MiB, no hint | 2 524 | 2 523 | 1 172 |
| Overlapped ReadFile 1 MiB × 8 | 6 757 | 6 758 | 609 |
| Overlapped ReadFile 1 MiB × 8, unbuffered | 6 766 | 6 785 | 563 |
| 4 threads, ReadFile 1 MiB | 6 459 | 6 454 | 1 656 |
| **IoRing stream, 64 KiB reads** | **6 757** | **6 747** | 704 |
| IoRing stream, unbuffered | 6 770 | 6 779 | 657 |
| **IoRing reader, zero-copy** | **6 759** | **6 736** | 515 |
| IoRing reader, zero-copy, no hint | 6 751 | 6 742 | 531 |
| IoRing reader, zero-copy, unbuffered | 6 779 | 6 776 | 485 |

All read-ahead contenders hit the same ceiling, ~6 780 MiB/s (7.1 GB/s) –
the disk. The synchronous ones wait for every block and get about 2.5 GiB/s.
Four threads also come close to the ceiling, but with about three times the
CPU time (see the note on CPU time below).

### 10 GiB, read-through, warm cache

| Contender | Win64 MiB/s | Win32 MiB/s |
| --- | ---: | ---: |
| TFileStream 64 KiB reads | 6 674 | 5 800 |
| TFileStream 1 MiB reads | 7 489 | 6 172 |
| TBufferedFileStream 1 MiB buffer, 64 KiB reads | 6 772 | 5 848 |
| ReadFile 1 MiB, sequential scan | 7 594 | 6 421 |
| ReadFile 1 MiB, no hint | 7 481 | 6 468 |
| Overlapped ReadFile 1 MiB × 8 | 7 227 | 6 262 |
| 4 threads, ReadFile 1 MiB | 19 309 | 17 750 |
| IoRing stream, 64 KiB reads | 6 258 | 5 431 |
| IoRing reader, zero-copy | 7 072 | 6 042 |
| IoRing reader, zero-copy, no hint | 7 034 | 6 130 |

With the data in memory, reading is copying memory. Single-threaded readers
are within ±10 % of each other; the IoRing stream pays for its extra copy.
Four threads copy in parallel. Win32 is 10–20 % slower than Win64 here (the
memory copy and the 64-bit checksum are slower in 32-bit code).

### 1 GiB with 200 µs CPU work per MiB

Seconds (lower is better). The work alone is 1024 × 200 µs = 0.205 s; with
the checksum the CPU part is about 0.26 s, so ~0.26 s is the best possible.

| Contender | cold, Win64 | cold, Win32 | warm, Win64 | warm, Win32 |
| --- | ---: | ---: | ---: | ---: |
| TFileStream 64 KiB reads | 0.838 | 0.744 | 0.361 | 0.383 |
| TFileStream 1 MiB reads | 0.330 | 0.343 | 0.344 | 0.368 |
| TBufferedFileStream 1 MiB buffer, 64 KiB reads | 0.333 | 0.350 | 0.358 | 0.380 |
| ReadFile 1 MiB, sequential scan | 0.322 | 0.339 | 0.344 | 0.367 |
| Overlapped ReadFile 1 MiB × 8 | 0.272 | 0.297 | 0.354 | 0.373 |
| Overlapped ReadFile 1 MiB × 8, unbuffered | 0.281 | 0.283 | – | – |
| **IoRing stream, 64 KiB reads** | **0.288** | **0.312** | 0.376 | 0.396 |
| IoRing stream, unbuffered | 0.280 | 0.293 | – | – |
| **IoRing reader, zero-copy** | **0.271** | **0.295** | 0.355 | 0.375 |
| IoRing reader, zero-copy, unbuffered | 0.265 | 0.274 | – | – |

Cold, the read-ahead contenders finish close to the CPU-only limit: the disk
work is hidden behind the processing (the reader's statistics show only 1–3
waits for data in 1024 buffers). Warm, there is nothing to hide.

### Tuning the reader (Win64, 10 GiB, cold, read-through)

`TIORingSequentialReader`, zero-copy, MiB/s for buffer size × buffer count:

| Buffered | × 2 | × 4 | × 8 | × 16 | × 32 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 2 836 | 3 725 | 6 227 | 6 362 | 6 158 |
| **1 MiB** | 4 047 | 6 559 | **6 694** | 6 761 | 6 604 |
| 4 MiB | 4 239 | 6 220 | 6 528 | 6 657 | 6 563 |

| Unbuffered | × 2 | × 4 | × 8 | × 16 | × 32 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 256 KiB | 2 826 | 4 874 | 6 780 | 6 754 | 6 777 |
| **1 MiB** | 6 030 | 6 786 | **6 772** | 6 784 | 6 759 |
| 4 MiB | 6 791 | 6 778 | 6 770 | 6 740 | 6 689 |

Other variants at 1 MiB × 8: fixed read-ahead 6 700 (buffered) / 6 762
(unbuffered); without registration 6 587 / 6 779. `TFileStream` with 64 KiB
reads in the same run: 1 456.

- Unbuffered reading needs about **4 reads and 2–4 MiB in flight** to keep this
  disk busy; buffered reading needs about **8 MiB** (the file cache adds its
  own copy and bookkeeping).
- **1 MiB × 8 (the default) is within 1 % of the best** in both modes, with
  8 MiB of buffer memory. 1 MiB × 16 is ~1 % faster buffered, for twice the
  memory – not worth it as a default.
- Adaptive read-ahead (start with 2, grow on waits) costs nothing measurable
  compared to fixed read-ahead, and keeps small files cheap. It stays the default.
- Registered buffers: ~1.6 % buffered, nothing measurable unbuffered.

**Decision: the defaults stay as they are** (1 MiB × 8, adaptive read-ahead,
sequential-scan hint on, registration on).

## Free Pascal

Measured 2026-10-22, later the same day (Milestone 2, Phase 9): Free Pascal
3.2.2 with `Source/Benchmarks/FPC` – the same files, consumer and reading
routines (`PIRUnit.Benchmark.Common`, `PIRUnit.Benchmark.Readers`) as the Delphi program, main
contenders only. Each Delphi/FPC pair was run **right after each other**,
1 GiB, 3 runs, median MiB/s.

**Win32:**

| Contender | read-through, cold: Delphi | FPC | read-through, warm: Delphi | FPC | work, cold: Delphi | FPC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TFileStream 64 KiB reads | 1 444 | 1 453 | 2 848 | 2 653 | 1 172 | 1 159 |
| TFileStream 1 MiB reads | 3 463 | 3 715 | 3 318 | 3 072 | 2 365 | 2 375 |
| ReadFile 1 MiB, sequential scan | 3 598 | 3 597 | 3 146 | 3 018 | 2 268 | 2 369 |
| Overlapped ReadFile 1 MiB × 8 | 6 477 | 6 501 | 3 319 | 3 268 | 3 067 | 3 091 |
| IoRing stream, 64 KiB reads | 6 009 | 6 497 | 2 782 | 2 761 | 2 972 | 3 043 |
| **IoRing reader, zero-copy** | **6 576** | **6 561** | **3 172** | **2 970** | **3 068** | **3 046** |

**Win64** (measured later, after the 64-bit FPC compiler was installed):

| Contender | read-through, cold: Delphi | FPC | read-through, warm: Delphi | FPC | work, cold: Delphi | FPC |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TFileStream 64 KiB reads | 1 348 | 1 427 | 6 471 | 6 468 | 1 198 | 1 171 |
| TFileStream 1 MiB reads | 3 494 | 3 621 | 4 445 | 7 191 | 3 295 | 3 249 |
| ReadFile 1 MiB, sequential scan | 3 391 | 3 630 | 7 017 | 7 236 | 3 287 | 3 277 |
| Overlapped ReadFile 1 MiB × 8 | 6 726 | 6 362 | 5 983 | 6 783 | 3 730 | 3 682 |
| IoRing stream, 64 KiB reads | 6 550 | 6 641 | 5 719 | 5 656 | 3 515 | 3 256 |
| **IoRing reader, zero-copy** | **6 616** | **6 696** | **6 521** | **6 677** | **3 700** | **3 637** |

**The library is as fast with Free Pascal as with Delphi**, on Win32 and on
Win64 – the differences are within the run-to-run noise (single values such
as Delphi's warm "TFileStream 1 MiB" jump around in both directions), and the
plain RTL/Windows contenders move by the same amounts.

Two things learned on the way:

- **Compare only numbers from the same session.** During the Win32 pair,
  memory-bound work on this machine was about half as fast as in the morning
  for *both* compilers (Delphi warm read-through 3.2 GiB/s instead of 6.2), so
  an FPC run compared with the morning's Delphi numbers looked 2× slower when
  it was not. Disk-bound cold reads were not affected. (During the Win64 pair
  the machine was back to its morning speed.)
- Free Pascal's `Move` is slower than Delphi's for large blocks (a memory-only
  test, 1 MiB blocks copied and checksummed: FPC 7.0 GiB/s, Delphi 11.1 GiB/s
  on Win32; the checksum loop alone is the same, 13.5 GiB/s). That matters for
  the stream's extra copy when the data comes from the cache, not for the
  zero-copy reader.

## Engine structures (Phase 11)

The free list (Phase 11) and the request queue (Phase 12). Measured 2026-10-22 with `Source/Benchmarks/Pascal.IOUring.Benchmarks.Structures`
(Delphi, Release) and its Free Pascal build (`Build-FPC.ps1 -Project Structures`,
`-O3`), on an Intel Core i7-14700: 8 performance cores with 2 threads each and
12 efficiency cores, 28 logical processors. Raw data:
[2026-10-22-structures.csv](BenchmarkResults/2026-10-22-structures.csv), backoff
tuning: [2026-10-22-structures-backoff.csv](BenchmarkResults/2026-10-22-structures-backoff.csv).

The rule (Design §10.5): a lock-free structure stays only if it beats the same
structure behind a lock. If the lock wins or ties, the lock stays.

### Free list of the request pool

Each thread takes one slot index, (works,) and gives it back, again and again.

- **lock-free**: `TIORingFreeList` – a Treiber stack: one 64-bit
  compare-exchange per take or give, with a tag against the ABA problem, and
  backoff (below).
- **SRW lock**: the same stack (an array) behind a Windows SRW lock, the
  lightest lock Windows has.
- **tight**: no work in between – the worst case: all threads fight for the
  stack all the time.
- **work 1 µs**: ~1 µs of busy work while holding the index – closer to real
  use, where a request is held while it is prepared and waited for.

Million take+give pairs per second, all threads together, median of 3 runs;
CPU = CPU time of all threads in one run. Delphi, Win64:

| Threads | tight: lock-free | tight: SRW lock | CPU (lock-free / SRW) | work 1 µs: lock-free | work 1 µs: SRW lock |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | **62.2** | 45.1 | 0.06 / 0.06 s | 0.97 | 0.97 |
| 2 | **47.7** | 42.8 | 0.14 / 0.17 s | 1.85 | 1.79 |
| 4 | **35.1** | 27.6 | 0.39 / 0.53 s | 3.54 | 3.56 |
| 8 | **27.7** | 14.4 | 0.9 / 2.2 s | **5.52** | 3.35 |
| 16 | **30.1** | 7.0 | 1.7 / 8.9 s | **3.78** | 2.34 |
| 28 | **13.1** | 2.8 | 6.3 / 31 s | **3.26** | 1.75 |

Lock-free ÷ SRW lock in all four builds:

| Build | tight, 1 thread | tight, 2–28 threads | work 1 µs, 1–4 threads | work 1 µs, 8–28 threads |
| --- | ---: | ---: | ---: | ---: |
| Delphi Win64 | 1.38 | 1.12–4.68 | 0.99–1.03 | 1.61–1.86 |
| FPC Win64 | 1.38 | 1.62–3.21 | 0.99–1.05 | 1.64–1.90 |
| Delphi Win32 | 1.19 | 1.37–6.72 | 1.00–1.03 | 1.61–2.00 |
| FPC Win32 | 1.21 | 1.32–4.29 | 0.99–1.04 | 1.61–1.86 |

**Result: the lock-free free list wins or ties everywhere, so it stays.**

What was learned on the way:

- **Without backoff, lock-free lost badly.** With 2 or more threads in the
  tight loop, all threads retried the same compare-exchange at once, the cache
  line jumped from core to core, and almost every try failed: the SRW lock was
  1.7–4.8× faster. *Backoff* fixes this: after a failed compare-exchange the
  thread waits 1, 2, 4, … CPU pauses (up to a limit) before it tries again.
- **The limit of the backoff** (Delphi Win64, tight, lock-free, million
  pairs/s, median of 3 runs; each limit was measured at a different moment,
  so allow ±20 % noise):

  | Threads | no backoff | 64 | 256 | **1024** | 4096 |
  | ---: | ---: | ---: | ---: | ---: | ---: |
  | 1 | 61.9 | 62.6 | 60.1 | 61.4 | 60.7 |
  | 2 | 9.1 | 42.3 | 49.7 | 52.2 | 55.9 |
  | 4 | 5.3 | 26.3 | 36.8 | 41.1 | 49.4 |
  | 8 | 3.5 | 14.4 | 22.4 | 27.3 | 42.0 |
  | 16 | 2.5 | 3.4 | 12.6 | 20.2 | 44.0 |
  | 28 | 2.4 | 2.5 | 3.2 | 15.9 | 40.5 |

  **1024 was chosen.** 4096 is faster still in this tight loop (the threads
  take turns, almost like with a lock), but then a single wait could take
  4096 pauses × 34 ns ≈ 140 µs on this CPU – longer than a whole NVMe read.
  With 1024 it is at most ≈ 35 µs, and only after 10 failed tries in a row.
  (One `PAUSE` takes ~34 ns on the performance cores and ~16 ns on the
  efficiency cores, measured; CPUs older than Intel Skylake pause much
  shorter, so there the same limit means less time.)
- **With real work, both are the same up to 4 threads**: the stack is then
  rarely contended, and a take+give costs ~16 ns (lock-free) or ~22 ns (SRW
  lock), lost in the 1 µs. The engine holds a request much longer than 1 µs,
  so in real use the free list will rarely be the limit either way.
- **The SRW lock is not cheap on CPU under contention**: it spins before it
  sleeps, so with 28 threads it used 31 s of CPU time against 6 s for the
  lock-free stack.

### Request queue (Phase 12)

N producer threads put values in, **one** consumer takes them all out – the
engine's case (many threads hand requests to one I/O thread). Raw data:
[2026-10-22-structures-queue.csv](BenchmarkResults/2026-10-22-structures-queue.csv).

- **lock-free**: `TIORingRequestQueue` – Vyukov's bounded queue: one
  compare-exchange per value on each side, with backoff.
- **SRW lock**: a ring buffer behind a Windows SRW lock. To give the lock a
  fair chance, it first looks at the count *without* the lock, so a full or
  empty queue is answered without taking the lock – what a careful lock-based
  queue does (the lock-free queue does it by itself).
- **tight**: producers put values in as fast as they can (when the queue is
  full, they pause and try again); **work 1 µs**: ~1 µs of work before each
  value, like preparing a request.
- 1024 cells. Threads = producers (plus the consumer, so at most 27 here).

Million values per second through the queue, median of 3 runs; CPU = CPU
time of all threads in one run. Delphi, Win64:

| Producers | tight: lock-free | tight: SRW lock | CPU (lock-free / SRW) | work 1 µs: lock-free | work 1 µs: SRW lock |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | **94.4** | 21.9 | 0.09 / 0.38 s | **0.99** | 0.93 |
| 2 | **72.5** | 15.4 | 0.17 / 0.80 s | **1.97** | 1.83 |
| 4 | **62.8** | 4.8 | 0.30 / 4.1 s | **3.94** | 3.20 |
| 8 | **55.3** | 4.9 | 0.55 / 7.2 s | **6.76** | 3.27 |
| 16 | **37.7** | 0.15 | 1.6 / 345 s | **4.79** | 0.19 |
| 27 | **18.3** | 0.07 | 4.4 / 1231 s | **4.67** | 0.07 |

Lock-free ÷ SRW lock in all four builds:

| Build | tight, 1 producer | tight, 2–27 producers | work 1 µs, 1–4 producers | work 1 µs, 8–27 producers |
| --- | ---: | ---: | ---: | ---: |
| Delphi Win64 | 4.3 | 4.7–276 | 1.07–1.23 | 2.1–65 |
| FPC Win64 | 3.0 | 5.7–266 | 1.06–1.19 | 2.0–52 |
| Delphi Win32 | 3.6 | 5.1–253 | 1.04–1.09 | 2.6–43 |
| FPC Win32 | 4.8 | 9.3–290 | 1.06–1.09 | 2.5–60 |

**Result: the lock-free queue wins everywhere, so it stays.**

Why the difference is so big:

- **With the lock, the consumer must win the same lock as every producer.**
  With many producers it seldom gets it, the queue stays full, and the
  producers spin – with 27 producers the SRW queue moved only 70 000 values
  per second and used about 20 minutes of CPU time in one run. In the
  lock-free queue the producers and the consumer use different counters; a
  busy enqueue side does not stop the consumer.
- **The "look first" trick made the lock worse with many producers, not
  better.** A first run without it (raw data:
  […-queue-lock-without-peek.csv](BenchmarkResults/2026-10-22-structures-queue-lock-without-peek.csv))
  gave the SRW queue 0.20 instead of 0.07 million values per second at 27
  producers: when the consumer frees one cell, all waiting producers see it at
  once and rush for the lock. Against that version, too, the lock-free queue
  won everywhere (1.05–118×).
- **With few producers and real work** (the usual case for the engine) the
  difference is small – 4–23 % – because the queue is then rarely
  contended. One value through the lock-free queue costs about 11 ns
  (94 million per second with one producer and one consumer).

## Blocks known in advance (Phase 14)

Many small reads at offsets that are known before reading starts – as a
program does that reads records found through an index. This is the first
benchmark of the engine (`TIORingEngine`), through the block reader
(`TIORingBlockReader`). Program: `Pascal.IOUring.Benchmarks.Blocks` (Delphi)
and `Pascal.IOUring.Benchmarks.Blocks.FPC` (Free Pascal). Measured
2026-10-23, same machine. Raw data:
[2026-10-23-blocks.csv](BenchmarkResults/2026-10-23-blocks.csv).

- **File:** 4 GiB of pseudo-random data. **Blocks:** 20 000 blocks of
  4 KiB (78 MiB in all), in two lists:
  - *random* – at random 4 KiB-aligned offsets, in random order;
  - *sorted, gaps* – in increasing order, 0–28 KiB apart (on average one
    block per 18 KiB of file).
- **Cache:** *cold* – the file is dropped from the cache before every run;
  *warm* – the blocks were read once before.
- Every contender hands every block, in list order, to the same checksum
  consumer (all checksums matched). 3 runs, median; contenders take turns.

| Contender | What it is |
| --- | --- |
| TFileStream | `Seek` + `ReadBuffer` per block |
| ReadFile | positioned `ReadFile` per block (no separate seek), synchronous handle |
| ReadFile, 8 threads | the same on 8 threads, each with its own handle and every 8th block (no ordered consumer) |
| Block reader, read-ahead N | `TIORingBlockReader` with N buffers of 256 KiB (N reads in flight), one shared engine, overlapped handle |
| … MaxGap 32 KiB | read-ahead 32; blocks up to 32 KiB apart become one read (sorted list only – random blocks have no near neighbours) |
| … synchronous handle | read-ahead 32 on a handle without `FILE_FLAG_OVERLAPPED` |

Thousand blocks per second, Delphi, Win64 (the other builds below):

| Contender | random, cold | random, warm | sorted, cold | sorted, warm |
| --- | ---: | ---: | ---: | ---: |
| TFileStream | 14.1 | 265.6 | 17.2 | 426.0 |
| ReadFile | 14.0 | 282.5 | 16.8 | 466.9 |
| ReadFile, 8 threads | 112.5 | 448.1 | 115.6 | 618.9 |
| Block reader, read-ahead 1 | 11.4 | 89.3 | 13.1 | 119.8 |
| Block reader, read-ahead 8 | 72.0 | 210.2 | 83.6 | 332.1 |
| Block reader, read-ahead 32 | 84.1 | 248.7 | 99.9 | 397.5 |
| Block reader, read-ahead 128 | **140.6** | 250.1 | 164.8 | 406.3 |
| … MaxGap 32 KiB | – | – | **363.6** | 381.7 |
| … synchronous handle | 14.2 | 252.3 | 16.3 | 304.6 |

Cold cache, all four builds:

| Build | random: read-ahead 128 ÷ TFileStream | random: read-ahead 128 ÷ 8 threads | sorted: read-ahead 128 ÷ TFileStream | sorted: MaxGap ÷ TFileStream |
| --- | ---: | ---: | ---: | ---: |
| Delphi Win64 | 10.0 | 1.25 | 9.6 | 21.1 |
| FPC Win64 | 9.7 | 1.22 | 7.2 | 16.6 |
| Delphi Win32 | 7.4 | 2.08 | 7.8 | 18.5 |
| FPC Win32 | 8.3 | 1.91 | 9.6 | 21.6 |

Warm cache, block reader with read-ahead 32 ÷ `ReadFile`:

| Build | random | sorted |
| --- | ---: | ---: |
| Delphi Win64 | 0.88 | 0.85 |
| FPC Win64 | 0.87 | 0.43 |
| Delphi Win32 | 0.50 | 0.43 |
| FPC Win32 | 0.45 | 0.92 |

What the numbers say:

- **Data from the disk: reading ahead is the gain.** One read at a time
  (read-ahead 1) is a little slower than `ReadFile` – each read goes to the
  I/O thread and back. With 8 reads in flight it is already 5× faster, with
  128 **7–10× faster than `TFileStream`**, and faster than 8 threads with
  `ReadFile` in every build (1.2–2.1×) – from one thread, with less CPU
  time (156 against 250 ms in the Delphi Win64 random case).
- **`MaxGap` for blocks that lie close together:** reading the gaps too
  turns 20 000 reads into about 1 500 with 256 KiB buffers, and reads about
  4.5× more bytes than the blocks hold (both computed from the list). It is
  17–22× faster than `TFileStream`, with almost no CPU time (31 ms): on an
  SSD the extra bytes cost little.
- **A synchronous handle throws the gain away:** Windows then runs the reads
  one at a time, and the reader is as fast as `ReadFile` (cold: 14.2 against
  14.0). With cached data it does not matter (252 against 249).
- **Cached data: the block reader does not beat `ReadFile`.** It reached
  85–92 % of `ReadFile` in some runs and 43–50 % in others. The two states
  come from the hybrid CPU: pinned to the P-cores, a probe gave the reader
  222–232 thousand blocks/s; pinned to the E-cores, 90 (and `ReadFile` 303
  against 176). The reader and the I/O thread hand work to each other, and
  every wait means a sleep and a wake-up, which costs much more on the slower
  cores. Windows chooses the cores, so a real program can see either.
  Even on the fast cores the reader stays below `ReadFile`: on an overlapped
  handle every read takes the asynchronous way, even when the data is in the
  cache, and that path costs more per read (Design §2.1, §10.10).
- **Where one engine stops:** with a buffered handle and data from the disk,
  a bare ring without the engine got no further either (about 125–140
  thousand reads per second), so Windows' cache path is the limit, not the
  engine. With cached data and with unbuffered reads, the one I/O thread is
  the limit – Phase 15 added more ([Several I/O threads](#several-io-threads-phase-15)).

## Several I/O threads (Phase 15)

The same benchmark (blocks known in advance, 20 000 blocks of 4 KiB from a
4 GiB file), now also with **unbuffered** reads (`FILE_FLAG_NO_BUFFERING`:
every read goes to the disk) and with the block reader on engines of **2 and
4 I/O threads**. Measured 2026-10-23, same machine. Raw data:
[2026-10-23-blocks-io-threads.csv](BenchmarkResults/2026-10-23-blocks-io-threads.csv)
(all four builds, all cases; the Phase 14 contenders were measured again).

Thousand blocks per second, Delphi, Win64, block reader with read-ahead 128:

| Case | 1 I/O thread | 2 I/O threads | 4 I/O threads | ReadFile | ReadFile, 8 threads |
| --- | ---: | ---: | ---: | ---: | ---: |
| random, cold | 142.0 | 136.3 | 137.9 | 14.1 | 113.9 |
| random, warm | 268.5 | 340.3 | **405.7** | 311.8 | 427.9 |
| random, unbuffered | 124.3 | 222.5 | **397.7** | 14.2 | 124.6 |
| sorted, cold | 139.6 | 129.9 | 131.6 | 17.8 | 114.4 |
| sorted, warm | 409.1 | 576.8 | **715.9** | 454.1 | 591.5 |
| sorted, unbuffered | 148.9 | 249.9 | **407.1** | 15.0 | 119.8 |

2 and 4 I/O threads ÷ 1 I/O thread, all four builds:

| Build | random, warm | random, unbuffered | sorted, warm | sorted, unbuffered |
| --- | ---: | ---: | ---: | ---: |
| Delphi Win64 | 1.27 / 1.51 | 1.79 / 3.20 | 1.41 / 1.75 | 1.68 / 2.73 |
| FPC Win64 | 1.31 / 1.56 | 1.75 / 2.98 | 1.11 / 1.05 | 2.10 / 1.53 |
| Delphi Win32 | 1.17 / 1.50 | 2.29 / 2.71 | 1.37 / 1.40 | 2.06 / 1.46 |
| FPC Win32 | 1.25 / 1.32 | 2.19 / 1.53 | 1.31 / 1.39 | 2.12 / 2.16 |

What the numbers say:

- **Cached data and unbuffered reads: more I/O threads help.** Windows does
  the work of a request inside the submit call, in the I/O thread (Design
  §10.11), so one I/O thread can submit only so many requests per second.
  With 4 I/O threads the block reader read **3.2× as many unbuffered
  blocks** as with one (Delphi Win64), 28× as many as `ReadFile` and 3.2×
  as many as 8 threads with `ReadFile`. With cached data it now **beats
  `ReadFile`** (1.3× on random, 1.6× on sorted blocks), which one I/O thread
  could not.
- **Data from the disk through the file cache (cold): no gain.** There the
  limit is Windows' cache path, not the I/O thread (Phase 14).
- **2 I/O threads always helped**; 4 helped more in most runs, but in some
  runs of the other builds less than 2. Those are the runs where the threads
  landed on the slower E-cores (see "Fast and slow cores" below).
- **The CPU time grows only a little:** 109 → 156 ms with 4 I/O threads
  (random, warm, Delphi Win64), 78 → 141 ms unbuffered.
- **The default stays 1 I/O thread**, because it costs nothing extra and is
  enough for data from the disk through the cache. For many small reads of
  cached data, or unbuffered reads, use 2–4 and measure.

## Overlap rule (Phase 16)

What the overlap rule `orKeepOrder` costs (Design §11, §10.13). Measured
2026-10-23, same machine.

**Reads only** (the blocks benchmark: nothing overlaps, nothing is held back –
this is the bookkeeping alone). Raw data:
[2026-10-23-blocks-overlap-rule.csv](BenchmarkResults/2026-10-23-blocks-overlap-rule.csv).
Block reader with read-ahead 128, thousand blocks per second, Delphi Win64:

| Case | Rule off, 1 I/O thread | Rule on, 1 I/O thread | Rule off, 4 I/O threads | Rule on, 4 I/O threads |
| --- | ---: | ---: | ---: | ---: |
| random, cold | 142.2 | 138.8 | 143.2 | 139.9 |
| random, warm | 263.7 | 253.9 | 433.1 | 249.0 |
| random, unbuffered | 128.9 | 128.2 | 395.6 | 128.1 |
| sorted, cold | 169.8 | 165.9 | 165.9 | 166.8 |
| sorted, warm | 421.2 | 396.7 | 850.4 | 376.8 |
| sorted, unbuffered | 150.0 | 147.9 | 476.4 | 147.0 |

- **One I/O thread:** the rule costs 0–6.5 % in all four builds, the most
  with cached data (4–6.5 %), where the I/O thread itself is the limit: each
  new read is compared with the up to 128 unfinished requests of its file.
- **Several I/O threads:** with the rule, all requests of a file go to one
  I/O thread, so one file gets nothing from more I/O threads (random,
  unbuffered: 396 → 128). Different files still use different I/O threads.

**Reads and writes** (probe, Delphi Win64 on the P-cores; one producer, 32
requests in flight, random reads and writes of 1–8 KiB, half each, median of
5; thousand requests per second):

| Region of the file | Held back | Rule off | Rule on |
| --- | ---: | ---: | ---: |
| 64 KiB (many overlaps) | 64 % | 495 | 399 |
| 64 MiB (few overlaps) | 0.2 % | 259 | 251 |

With many overlaps the rule costs 20 % – and without it, the data is wrong
(the model tests found hundreds of wrong reads without the rule). With few
overlaps it costs about 3 %.

**So:** use the rule when requests of a file can overlap while in flight;
for read-only work, or when the program keeps overlapping requests apart
itself, leave it off – it costs up to 6.5 %, and one file then uses one I/O
thread.

## Writing (Phase 17)

Writing a new file front to back, 1 GiB and 10 GiB: the write stream
`TSequentialWriteOnlyFileStream` (8 × 1 MiB buffers, its own engine, 64 KiB
writes; also unbuffered) against `TFileStream` (64 KiB and 1 MiB writes) and
`TBufferedFileStream` (1 MiB buffer, 64 KiB writes; Delphi only). Two
scenarios: *writing only*, and *with work* – 200 µs of CPU time per MiB
before it is written (the program computes the data). Two times per run:
**written** – until the stream is freed (buffered data may still be in the
file cache) – and **+ flush** – until the data is on the disk
(`FlushFileBuffers` afterwards). A new file every run. Median of 3 runs.
Measured 2026-10-23, same machine. Raw data:
[2026-10-23-writes.csv](BenchmarkResults/2026-10-23-writes.csv).

Seconds, Delphi, Win64:

| Contender | 1 GiB, written | + flush | 1 GiB with work, written | + flush | 10 GiB, written | + flush | 10 GiB with work, written | + flush |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TFileStream, 64 KiB writes | 0.29 | 0.62 | 0.71 | 1.08 | 5.30 | 7.26 | 7.40 | 8.73 |
| TFileStream, 1 MiB writes | 0.32 | 0.65 | 0.57 | 0.96 | 4.39 | 7.15 | 5.05 | 7.03 |
| TBufferedFileStream | 0.39 | 0.73 | 0.64 | 1.07 | 5.33 | 7.56 | 5.45 | 7.89 |
| Write stream | 0.37 | 0.70 | **0.43** | **0.85** | 5.27 | 7.64 | **4.49** | **6.82** |
| Write stream, unbuffered | **0.26** | **0.26** | **0.32** | **0.32** | 5.76 | **5.77** | 5.42 | **5.42** |

With work, time until written – the write stream against the better
`TFileStream` (1 MiB writes), all four builds:

| Build | 1 GiB | 10 GiB |
| --- | ---: | ---: |
| Delphi Win64 | 0.43 vs 0.57 s (–25 %) | 4.49 vs 5.05 s (–11 %) |
| FPC Win64 | 0.25 vs 0.44 s (–43 %) | 4.31 vs 5.42 s (–20 %) |
| Delphi Win32 | 0.31 vs 0.56 s (–45 %) | 5.38 vs 5.54 s (–3 %) |
| FPC Win32 | 0.24 vs 0.43 s (–44 %) | 4.67 vs 5.90 s (–21 %) |

What the numbers say:

- **Writing only: no gain**, as expected. Windows copies into the file cache
  in one thread either way (Design §2.1), and the stream's own copy costs a
  little: 1 GiB took 0.24–0.37 s, `TFileStream` 0.22–0.32 s.
- **With work: the writing happens meanwhile.** 1 GiB was written 25–45 %
  sooner than with `TFileStream`; with 10 GiB 3–21 % – there the disk is the
  limit, see the next point.
- **Big files: the disk sets the pace.** Windows cannot keep 10 GiB of
  unwritten data in the file cache; it slows every writer down to what the
  disk takes (about 2 GB/s here). And the disk itself writes fewer GB/s once
  its fast write cache is full – which also made the unbuffered 1 GiB runs
  slower (0.49–0.55 s) in the builds that ran after the first 10 GiB runs.
- **Unbuffered: on the disk soonest, with little CPU time.** The data is on
  the disk when `Free` returns: 1 GiB in 0.26–0.55 s against 0.62–0.96 s for
  buffered writing plus a flush; 10 GiB in 5.4–5.9 s against 6.3–7.6 s, with
  a third of the CPU time (1.0–1.8 s against 2.6–5.1 s) – no copy into the
  file cache. Use it for big files that are not read back soon.

## Linux in WSL2 – a first look (Phase 21)

The four Free Pascal benchmarks also run on Linux (`-Platform Linux64`).
These first numbers come from **WSL2** on the same machine (kernel 6.18,
ext4 on the WSL2 virtual disk, 28 logical processors, 31 GB memory given to
WSL2, Free Pascal 3.2.2), measured 2026-10-24, median of 3 runs. Raw output:
[2026-10-24-linux-wsl2-*.txt](BenchmarkResults/).

**Read these as a first look, not as disk numbers.** In WSL2 the disk is a
file on the Windows host: after the file is dropped from the Linux cache
(`posix_fadvise(POSIX_FADV_DONTNEED)`), the host may still serve it from its
own cache. "Cold" here means "not in the Linux cache", not "from the disk".
Numbers from a real Linux machine come later.

What is different on Linux: no overlapped `ReadFile` (the contenders are
left out), the plain read contender is `read`/`pread`, and the lock in the
structures benchmark is a pthread mutex.

### Reading a file front to back

MiB/s, FPC Linux64:

| Contender | 1 GiB, cold | 1 GiB, warm | 1 GiB with work, cold | 10 GiB, cold | 10 GiB, warm |
| --- | ---: | ---: | ---: | ---: | ---: |
| TFileStream 64 KiB reads | 3 671 | 11 277 | 2 301 | 3 164 | 11 022 |
| TFileStream 1 MiB reads | 5 158 | 11 130 | 2 743 | 5 491 | 11 060 |
| read 1 MiB, sequential hint | 5 168 | 11 909 | 2 726 | 4 684 | 11 488 |
| io_uring stream, 64 KiB reads | 4 897 | 9 158 | 2 552 | 3 717 | 9 174 |
| io_uring stream, unbuffered | 3 817 | – | 3 450 | 3 495 | – |
| io_uring reader, zero-copy | 5 290 | 11 629 | 2 693 | 5 404 | 11 575 |
| **io_uring reader, zero-copy, unbuffered** | 3 857 | – | **3 884** | 3 537 | – |

- **Buffered, cold: no gain over 1 MiB reads.** Linux reads ahead by itself
  for buffered sequential reads, so `TFileStream` with 1 MiB reads is
  already as fast as the reader (5.0–5.4 against 5.2–5.3 GiB/s). On Windows
  the reader was 2.7× faster than that.
- **Unbuffered is slower than buffered here** (3.4–3.8 GiB/s), because in
  WSL2 buffered "cold" reads can come from the host's cache.
- **With work, unbuffered: the reading is free.** 1 GiB with 200 µs of work
  per MiB took 0.264 s – as long as reading alone (0.265 s), and 29 % less
  than `TFileStream` with 1 MiB reads (0.373 s). The buffered contenders
  gain nothing here.
- **Warm:** the zero-copy reader is as fast as `read` (11.4 against
  11.6 GiB/s); the stream is about 20 % slower (one more copy).

### Blocks known in advance

20 000 blocks of 4 KiB from a 4 GiB file, thousand blocks per second, FPC
Linux64 (rows as in [Blocks known in advance](#blocks-known-in-advance-phase-14);
the block reader on a synchronous handle is Windows-only):

| Contender | random, cold | random, warm | random, unbuffered | sorted, cold | sorted, warm | sorted, unbuffered |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| TFileStream, Seek + Read | 12.7 | 1 329 | – | 289 | 1 571 | – |
| pread | 11.9 | 1 667 | 11.9 | **336** | 2 023 | 12.8 |
| pread, 8 threads | 76.2 | 904 | 73.1 | 75.8 | 648 | 67.5 |
| Block reader, read-ahead 32 | 116 | 1 220 | 120 | 134 | 1 912 | 134 |
| Block reader, read-ahead 128 | 114 | 1 444 | 111 | 131 | 1 949 | 130 |
| Block reader, 128, 2 I/O threads | 220 | **2 748** | 165 | 255 | **3 191** | 215 |
| Block reader, 128, 4 I/O threads | **239** | 2 393 | **257** | 245 | 2 413 | 243 |
| Block reader, 128, overlap rule | 175 | 1 150 | 180 | 203 | 1 452 | 205 |
| Block reader, 32, MaxGap 32 KiB | – | – | – | 192 | 772 | **344** |

- **Random blocks: 10–20× faster than `pread`.** Not in the cache, the
  block reader with one I/O thread got 9.6× as many blocks as `pread`, with
  4 I/O threads 20× (and 3.1× as many as 8 threads with `pread`).
  Unbuffered the same: 257 against 12 thousand blocks/s.
- **More I/O threads help on Linux too**, also unbuffered (one I/O thread:
  ~110 thousand blocks/s, four: ~250). In WSL2 every request goes through
  the virtual disk, which costs time per request.
- **Cached data:** one I/O thread gets 87 % of `pread`'s speed (Windows:
  85–92 %), two I/O threads 1.6× `pread`.
- **Sorted blocks with small gaps, buffered: plain `pread` is best here**
  (336 thousand blocks/s): Linux reads ahead by itself, gaps included. The
  block reader wins this case only unbuffered, with `MaxGap`: 27× `pread`.
- **The overlap rule** cost 20 % with cached random blocks (1 444 → 1 150);
  for the cold cases the noise is bigger than its cost.
- **Noise:** between two whole runs, single values moved by up to 30 %
  (cold random, read-ahead 128: 149, then 114 thousand blocks/s). The first
  run was also before the `WaitFor` fix (Design §10.14): "pread, 8 threads"
  then took exactly 0.1 or 0.3 s every time.

### Writing

Seconds, FPC Linux64:

| Contender | 1 GiB, written | + flush | 1 GiB with work, written | + flush | 10 GiB, written | + flush | 10 GiB with work, written | + flush |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| TFileStream, 64 KiB writes | 0.15 | 0.33 | 0.35 | 0.54 | 2.97 | 3.28 | 5.33 | 5.75 |
| TFileStream, 1 MiB writes | **0.13** | **0.29** | 0.52 | 0.70 | **1.83** | **2.26** | 4.06 | 4.44 |
| Write stream, 64 KiB writes | 0.15 | 0.32 | **0.25** | **0.44** | 2.30 | 2.72 | **3.01** | **3.43** |
| Write stream, unbuffered | 0.37 | 0.37 | 0.36 | 0.37 | 4.04 | 4.04 | 3.96 | 3.97 |

- **Writing only: no gain**, as on Windows.
- **With work, the writing happens meanwhile:** 1 GiB was written in
  0.25 s against 0.35–0.52 s, 10 GiB in 3.0 s against 4.1–5.3 s (26 % less
  than the better `TFileStream`).
- **Unbuffered is slower here**, and the flush is cheap: in WSL2 the host
  may keep the written data in its own cache, so "+ flush" does not prove
  that the data is on the disk.
- Before the `WaitFor` fix the write stream's `Free` took 0.1 s more
  (1 GiB, writing only: 0.25 s, now 0.15 s).
- Noise again: `TFileStream` with 1 MiB writes and work took 0.38 s for
  1 GiB in the first run, 0.52 s in the second.

### Engine structures

Lock-free against a pthread mutex, 28 logical processors: lock-free speed ÷
mutex speed (above 1: lock-free is faster):

| Threads | Free list, tight | Free list, work 1 µs | Queue, tight | Queue, work 1 µs |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 1.36 | 1.00 | 8.7 | 1.00 |
| 2 | 5.33 | 0.99 | 7.3 | 1.01 |
| 4 | 2.76 | 1.87 | 14.9 | 1.57 |
| 8 | 3.35 | 1.88 | 37.6 | 2.47 |
| 16 | 2.52 | 1.91 | 104 | 7.6 |
| 28 (queue: 27 producers) | 2.74 | 2.18 | 165 | 24.6 |

**The lock-free structures win on Linux too**, as against the SRW lock on
Windows: the free list ties with one thread and real work and is 1.4–5.3×
faster in a tight loop; the queue is 7–165× faster under contention, where
the mutex starves the consumer (with 27 producers it spent 752 s of CPU
time for what the lock-free queue did in 4.7 s).

### SQPOLL (Phase 22)

With SQPOLL a kernel thread takes the submissions from the ring, so
submitting needs no system call. Measured before deciding whether
`TLinuxIORing` should offer it (Design §5.8), with a ring of its own in a
test program, 4 KiB reads, WSL2, 2026-10-24. Time per read and CPU time per
read (all threads, the polling thread included):

| Ring | Cached, one at a time | CPU | Cached, 32 at a time | CPU |
| --- | ---: | ---: | ---: | ---: |
| Normal | **0.51 µs** | **0.51 µs** | **0.35 µs** | **0.35 µs** |
| SQPOLL, waiting in `io_uring_enter` | 12.0 µs | 13.6 µs | 0.81 µs | 0.95 µs |
| SQPOLL, spinning on the completion queue | 0.64 µs | 1.33 µs | 0.44 µs | 1.02 µs |
| `SINGLE_ISSUER` + `DEFER_TASKRUN` | 0.49 µs | 0.59 µs | 0.34 µs | 0.44 µs |

Unbuffered (`O_DIRECT`) random reads of a 1 GiB file, two runs each,
thousand reads per second and CPU time per read:

| Ring | 32 in flight | CPU | 128 in flight | CPU |
| --- | ---: | ---: | ---: | ---: |
| Normal | 125 / 173 | 1.5–1.7 µs | 160 / 180 | 1.5 µs |
| SQPOLL, waiting in `io_uring_enter` | 151 / 171 | 6.6–7.4 µs | 176 / 179 | 6.3 µs |
| SQPOLL, spinning | 125 / 159 | 12.7–16.2 µs | 168 / 164 | 12.1–12.3 µs |
| `SINGLE_ISSUER` + `DEFER_TASKRUN` | 122 / 172 | 1.7–2.0 µs | 176 / 180 | 1.7–1.8 µs |

**SQPOLL gave no gain for file I/O, and cost 2.6–27× the CPU time per
read** (unbuffered: 4–10×). With
cached data the reading happens inside the submit call anyway; with
unbuffered reads the virtual disk is the limit. So `TLinuxIORing` does not
offer it; it stays in the API unit (`IORING_SETUP_SQPOLL`) for programs that
want it – for example network servers with very high rates, not measured
here.

## GitHub's runners (Phase 23)

The first numbers from other machines: the four Free Pascal benchmarks on
GitHub's hosted runners, run once by hand, 2026-10-24, files of 1 and 4
GiB, median of 3 runs. Raw output: [2026-10-24-ci-*.txt](BenchmarkResults/).
(The workflow no longer runs the benchmarks: the runs took 19–38 minutes per
runner on slow cloud machines – Design §12.6.) Each runner has 4
processors, 16 GB of memory and a cloud disk:

| Runner | System |
| --- | --- |
| Linux x64 | Ubuntu 24.04, x86-64 |
| Linux ARM64 | Ubuntu 24.04, kernel 6.17 (Azure), ARM64 |
| Windows | Windows Server 2025, x64 (Win64 build) |

**The disks set the pace:** about 400 MiB/s for sequential reading, 20–27
thousand random 4 KiB reads per second, and about 120–330 MiB/s for writing
with a flush – on all three. "Cold" here is a real, slow, throttled cloud disk:
neither the NVMe disk of this machine nor WSL2's host cache.

### Blocks known in advance, cold

Thousand blocks per second, 20 000 blocks of 4 KiB from a 4 GiB file:

| Contender | Linux x64 | Linux ARM64 | Windows |
| --- | ---: | ---: | ---: |
| *Random 4 KiB* | | | |
| TFileStream, Seek + Read | 7.9 | 8.4 | 5.5 |
| pread / ReadFile at offset | 7.7 | 8.8 | 5.6 |
| … 8 threads | 27.2 | 26.9 | 6.5 |
| Block reader, read-ahead 8 | **27.1** | **27.4** | 19.1 |
| Block reader, read-ahead 128 | 20.3 | 20.3 | **20.0** |
| Block reader, 128, 4 I/O threads | 20.1 | 20.3 | **20.3** |
| *Sorted, with gaps* | | | |
| pread / ReadFile at offset | 22.5 | 22.4 | 3.0 |
| Block reader, read-ahead 128 | 22.5 | 22.5 | 22.6 |
| Block reader, 32, MaxGap 32 KiB | **33.3** | **36.0** | **37.8** |

- **The block reader reaches the disk's limit; plain reads do not.** On
  Windows 3.6× as many random blocks as `ReadFile`, 7.5× for sorted blocks,
  12.6× with `MaxGap`. On Linux 2.3–3.5× `pread` for random blocks; for
  sorted blocks Linux reads ahead by itself, so there only `MaxGap` gains
  (1.5–1.6×).
- **[open] On Linux, read-ahead 8 beats 32 and 128** (27 against 20
  thousand blocks per second, on both CPUs; `pread` on 8 threads also gets
  27). Not on Windows. Not explained yet – maybe the cloud disk slows down
  deep queues. Parked in Phase 28 (Design §13).
- **[open] Unbuffered on Windows** the block reader got no more than
  `ReadFile` (6.2 against 5.8 thousand random blocks per second), while
  buffered it got 20. Not explained yet either. Parked in Phase 28 (Design
  §13).

### Blocks known in advance, cached

| Contender | Linux x64 | Linux ARM64 | Windows |
| --- | ---: | ---: | ---: |
| pread / ReadFile at offset | 656 | 656 | **233** |
| … 8 threads | **1 648** | **2 066** | 201 |
| Block reader, read-ahead 128 | 703 | 577 | 197 |
| Block reader, 128, 2 I/O threads | 1 134 | 1 136 | 180 |

On Linux two I/O threads read 1.7× as many cached blocks as `pread` (WSL2:
1.6×). On Windows with 4 processors, one I/O thread gets 85 % of
`ReadFile`, and more I/O threads do not help.

### Reading front to back, writing

- **Cold, everything reads at the disk's speed** (about 395 MiB/s), except
  `TFileStream` with 64 KiB reads on Windows (159 MiB/s).
- **Cached, the read stream pays for its extra copy:** 18–31 % slower than
  `TFileStream` with 1 MiB reads (Linux x64 7 196 against 10 499 MiB/s,
  ARM64 5 231 against 7 145, Windows 4 062 against 4 980); the zero-copy
  reader is within 10 % of the plain reads. Phase 26 is about this copy.
- **Writing 1 GiB with work, the write stream finished writing 24–42 %
  sooner** than `TFileStream` with 1 MiB writes (Linux x64 0.26 against
  0.38 s, ARM64 0.26 against 0.34 s, Windows 0.28 against 0.48 s).

### Engine structures: lock-free ÷ lock

Above 1: the lock-free structure is faster (Linux: a pthread mutex,
Windows: the SRW lock; the queue has one thread less for the consumer):

| | Linux x64 | Linux ARM64 | Windows |
| --- | ---: | ---: | ---: |
| Free list, tight, 1 / 2 / 4 threads | 1.65 / 7.02 / 4.94 | 1.00 / 2.74 / 1.05 | 2.02 / 2.68 / 3.43 |
| Free list, work 1 µs, 1 / 2 / 4 | 1.00 / 1.19 / 1.81 | 1.00 / 1.01 / **0.88** | 1.00 / 1.00 / 1.29 |
| Queue, tight, 1 / 2 / 3 producers | 8.96 / 15.2 / 18.6 | 4.96 / **0.87** / **0.90** | 3.42 / 5.33 / 6.84 |
| Queue, work 1 µs, 1 / 2 / 3 | 1.00 / 1.19 / 1.41 | 1.00 / 1.44 / 1.79 | 1.00 / 1.04 / 1.28 |

**On ARM64 the lock-free structures do not always win.** With 2–3
producers in a tight loop the mutex queue is faster, and so is the mutex
free list with 4 threads and work. Design §10.5's rule – a lock-free
structure stays only where it beats the lock – holds on x86-64, not
everywhere on ARM64. The likely cause: on AArch64 every atomic operation
has full barriers (DMB) around it, and FPC 3.2.2 does not inline its
`ReadWriteBarrier` there (the compiler says so 109 times), so every
operation makes two calls. **Fixed in Phase 27** (next section).

### The atomics on ARM64 (Phase 27)

The Structures benchmark on the ARM64 runner (4 processors), 2026-10-25,
built three ways and run in turns, two rounds (the hand-started "ARM64
atomics" workflow; raw output:
[2026-10-25-ci-arm64-atomics.txt](BenchmarkResults/2026-10-25-ci-arm64-atomics.txt)).
Lock-free Mops/s, in brackets lock-free ÷ mutex:

| | before | assembler, `yield` | assembler, `isb` (kept) |
| --- | --- | --- | --- |
| Free list, tight, 1 thread | 27.4 / 27.4 | 41.7 / 41.8 | 41.6 / 41.8 |
| Free list, tight, 4 threads | 3.3 (0.47) / 6.2 (1.04) | 9.6 (1.66) / 8.3 (1.07) | 9.4 (1.75) / 21.6 (3.22) |
| Free list, work 1 µs, 4 threads | 1.95 (1.00) / 1.32 (0.67) | 2.05 (1.06) / 2.22 (1.02) | 1.93 (1.02) / 2.25 (1.13) |
| Queue, tight, 1 producer | 24.1 / 22.2 | 29.2 / 30.5 | 31.1 / 31.6 |
| Queue, tight, 2 producers | 6.3 (1.24) / 4.4 (0.92) | 9.3 (1.59) / 8.9 (1.72) | 28.4 (6.67) / 32.8 (5.30) |
| Queue, tight, 3 producers | 3.7 (1.09) / 3.2 (1.01) | 3.8 (1.08) / 3.9 (1.15) | 26.7 (8.53) / 32.5 (8.76) |
| Queue, work 1 µs, 3 producers | 2.98 (1.74) / 2.91 (1.65) | 2.94 (1.82) / 2.98 (1.59) | 2.97 (1.68) / 2.98 (1.77) |

- **One call and one barrier instead of three calls and two:** 52 % more
  for the free list and 30 % for the queue with one thread.
- **The spin hint matters most under contention:** `isb` makes the queue
  with 2–3 producers 7–9 times as fast as before; `yield` hardly helps.
- With work, all three are close – the structures are not the limit there –
  but lock-free never loses any more.

## Big Read calls (Phase 26)

A 4 GiB file read with `Read` calls of 64 MiB, 8 MiB and 64 KiB into
page-aligned memory, cold and warm, 2026-10-24. A small measuring program
outside the repository (Free Pascal, Win64 and Linux64 in WSL2): the reader
before and after Phase 26 built from the same sources and run in turns, two
runs each, each the median of 3. MiB/s:

| | 64 MiB calls, cold | warm | 8 MiB calls, cold | warm | 64 KiB calls, cold | warm |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| *Windows (NVMe)* | | | | | | |
| TFileStream | 3 280–3 320 | 7 160–7 360 | 4 060–4 200 | 8 720–9 020 | 1 410–1 610 | 8 000–8 130 |
| IoRing stream before | 6 703 / 6 737 | 6 530 / 6 418 | 6 742 / 6 696 | 6 492 / 6 356 | 6 740 / 6 782 | 7 296 / 7 111 |
| IoRing stream now | 6 601 / 6 568 | **6 879 / 7 061** | 6 716 / 6 724 | **7 685 / 7 744** | 6 755 / 6 735 | 7 205 / 7 208 |
| *Linux (WSL2; cold is not the disk)* | | | | | | |
| TFileStream | 3 040–4 670 | 11 090–11 740 | 3 430–4 030 | 13 740–15 130 | 3 510–5 560 | 14 550–16 290 |
| IoRing stream before | 4 365 / 4 233 | 9 571 / 10 117 | 4 187 / 4 021 | 10 025 / 9 785 | 4 618 / 5 120 | 11 632 / 11 806 |
| IoRing stream now | **5 249 / 5 155** | **11 154 / 11 439** | **4 651 / 4 772** | **12 065 / 12 405** | 3 256* / 5 445 | 10 227* / 11 963 |

\* A slow run: `TFileStream` was slower in it too.

- **Warm, the extra copy is mostly gone for big calls:** 64 MiB calls get
  96–98 % of `TFileStream` on Windows and 97–101 % on Linux. 8 MiB calls
  get 82–90 %: the buffers had already asked for 2 MiB of each call, and
  those 2 MiB are still copied.
- **Cold:** on Linux 11–22 % faster. On Windows 8 MiB and 64 KiB calls are
  as before, and 64 MiB calls about 2 % slower (median of all runs: 6 574
  against 6 735) – not explained; registering the memory explains a small
  part only (Design §12.8).
- **One version measured on the way lost 6 %** cold with 64 MiB calls on
  Windows: the buffers read ahead 64 MiB further on while the call's own
  reads were still running. Windows reads ahead in its file cache when the
  reads come in file order; now the buffers wait until all of the call's
  reads have started.
- `TMemoryStream.LoadFromStream` and `TBytesStream` read the whole stream
  in one call, so they get this; `CopyFrom` reads 1 MiB at a time (one
  buffer), so it does not.

## The Windows numbers again (Phase 28)

The shared benchmark code and the library changed in Phases 21–28, so the
four benchmarks ran again on this machine, 2026-10-25: Delphi 13, Win64
Release, the same options as before, one after the other (raw output:
[2026-10-25-windows-win64.txt](BenchmarkResults/2026-10-25-windows-win64.txt)).
Before = the Win64 numbers in the sections above.

| Benchmark, case | Before | Now |
| --- | ---: | ---: |
| *Reading a file, MiB/s* | | |
| 10 GiB cold, IoRing stream | 6 757 | 6 676 |
| 10 GiB cold, IoRing reader, zero-copy | 6 759 | 6 715 |
| 10 GiB cold, IoRing reader, unbuffered | 6 779 | 6 787 |
| 10 GiB cold, `TFileStream` 1 MiB reads | 2 509 | 2 485 |
| 10 GiB warm, IoRing stream | 6 258 | 6 084 |
| 10 GiB warm, `TFileStream` 1 MiB reads | 7 489 | 7 408 |
| 1 GiB with work, cold, IoRing stream (s) | 0.288 | 0.289 |
| 1 GiB with work, cold, IoRing reader (s) | 0.271 | 0.273 |
| *Engine structures, lock-free, Mops/s* | | |
| Free list, tight, 1 / 8 / 28 threads | 62.2 / 27.7 / 13.1 | 64.9 / 44.4 / 16.3 |
| Free list, work 1 µs, 8 / 28 threads | 5.52 / 3.26 | 4.30 / 2.90 |
| Queue, tight, 1 / 8 / 27 producers | 94.4 / 55.3 / 18.3 | 94.1 / 47.4 / 18.9 |
| Queue, work 1 µs, 8 / 27 producers | 6.76 / 4.67 | 5.57 / 3.81 |
| *Blocks known in advance, thousand blocks/s* | | |
| Random, cold, block reader 128 | 140.6 | 142.5 |
| Random, warm, block reader 128 / `ReadFile` | 250.1 / 282.5 | 274.1 / 326.4 |
| Random, warm, 4 I/O threads | 405.7 | 439.7 |
| Random, unbuffered, 1 / 4 I/O threads | 124.3 / 397.7 | 129.9 / 407.9 |
| Sorted, cold, block reader 128 | 164.8 | 171.0 |
| Sorted, cold, `MaxGap` 32 KiB | 363.6 | 337.7 |
| Sorted, warm, 4 I/O threads | 715.9 | 805.4 |
| *Writing, seconds until written* | | |
| 1 GiB with work, write stream / `TFileStream` 1 MiB | 0.43 / 0.57 | 0.23 / 0.40 |
| 10 GiB with work, write stream / `TFileStream` 1 MiB | 4.49 / 5.05 | 4.90 / 5.45 |
| 1 GiB, unbuffered write stream, + flush | 0.26 | 0.25 |

- **Nothing got slower that the library does.** Reading from the disk is at
  the disk's limit as before (±1 %); warm, everything is 1–4 % lower,
  `ReadFile` and `TFileStream` too – the machine, not the library. The
  block reader is the same or faster everywhere except `MaxGap` on sorted
  cold blocks (−7 %, one run of 3; `ReadFile` there −2 %).
- **The lock-free structures still win everywhere** (free list 1.00–7.3×
  the SRW lock, queue 1.00–255×). Tight loops with several threads are
  faster than in Phase 11, work loops with 8 or more threads 4–22 % slower,
  for the lock too: which threads land on the E-cores changes such numbers
  (see "Fast and slow cores" below).
- **The write stream with work** finished 1 GiB 42 % sooner than
  `TFileStream` (before: 25 %), 10 GiB 10 % sooner (before: 11 %).

## Known limits of these measurements

- **One machine, one very fast disk.** The NVMe drive has low latency, so
  synchronous reading already gets 2.5 GiB/s. On slower or higher-latency
  storage (USB disks, network shares, cloud disks) read-ahead should help even
  more – PostgreSQL reports 2–3× on cold reads there – but that was not measured.
- **CPU time is rough.** Windows counts it in 15.6 ms steps, and work done for
  asynchronous I/O in system threads (for example copying data out of the file
  cache for buffered overlapped/IoRing reads) is **not** charged to the
  benchmark process. So buffered asynchronous reads look cheaper in CPU time
  than they are. The unbuffered numbers (no cache copy) are the fairer
  comparison: IoRing reader unbuffered 485 ms vs. 4 threads 1 656 ms for 10 GiB.
- **Unbuffered reads right after buffered reads of the same file are slower.**
  In the first runs, every unbuffered contender lost 0.1–0.6 s when it ran
  right after a buffered one (the tuning run, where unbuffered variants mostly
  follow each other, reached disk speed with the same settings). The benchmark
  now runs the unbuffered contenders after the buffered ones, with an untimed
  unbuffered read in between. That fixed the 10 GiB results (all unbuffered at
  disk speed) but not fully the short 1 GiB runs: the 1 GiB cold read-through
  results of the unbuffered contenders (0.25–0.28 s on Win64 instead of
  ~0.15 s) are still affected, so the 1 GiB read-through results are not shown
  above (they are in the raw data). The likely cause is that Windows keeps a
  file's cache structures for a while after a buffered reader closes it, and
  unbuffered reads pay for cache coherency in that time. Worth knowing in real
  programs too: **unbuffered reading of a file that was just read buffered can
  be slower for a short while.**
- **Fast and slow cores.** Windows decides whether a thread runs on a P-core
  or an E-core, and the results of threads that hand work to each other (the
  engine) can change by 2× between runs because of it (seen with cached data
  in Phase 14). For probes, pin the process to one kind of core (in
  PowerShell: `[Diagnostics.Process]::GetCurrentProcess().ProcessorAffinity`;
  child processes inherit it – here 0xFFFF = P-cores, 0xFFF0000 = E-cores).
- `FILE_FLAG_SEQUENTIAL_SCAN` made no measurable difference, cold or warm. (A
  single early test run suggested it halves warm-cache speed; the repeated
  runs did not confirm that.)

## How to run

```
Source\Benchmarks\Delphi\Win64\Release\Pascal.IOUring.Benchmarks.exe --sizes 1,10 --runs 3 --csv results.csv
Source\Benchmarks\Delphi\Win64\Release\Pascal.IOUring.Benchmarks.exe --tune --sizes 10 --runs 3
```

Free Pascal (`-Platform Win32` or `Win64`):

```
Source\Build-FPC.ps1 -Project Benchmarks -Platform Win64 -Run -RunArguments '--sizes','1,10','--runs','3'
```

Options: `--dir` (where the test files go; default `%TEMP%\Pascal.IOUring.Bench`),
`--sizes` (GiB, comma separated), `--runs`, `--work-us` (CPU work per MiB in the
work scenario, default 200), `--threads` (default 4), `--csv`, `--tune`,
`--keep` (keep the test files). The 10 GiB set takes about 10 minutes per
platform. Close other programs first – background disk or CPU work changes
the results a lot.

Engine structures (free list about 30 s, queue about 5 min per build; options
`--only freelist|queue`, `--runs`, `--threads`, `--csv`):

```
Source\Benchmarks\Delphi\Win64\Release\Pascal.IOUring.Benchmarks.Structures.exe --runs 3 --csv structures.csv
Source\Build-FPC.ps1 -Project Structures -Platform Win64 -Run
```

Blocks known in advance (about 1.5 minutes per build; options `--dir`,
`--size-gib` (default 4), `--blocks` (default 20 000), `--runs`, `--csv`,
`--cache cold|warm|unbuffered` (only that cache state; may be given more
than once), `--keep`):

```
Source\Benchmarks\Delphi\Win64\Release\Pascal.IOUring.Benchmarks.Blocks.exe --runs 3 --csv blocks.csv
Source\Build-FPC.ps1 -Project Blocks -Platform Win64 -Run
```

Writing a file (options `--dir`, `--sizes` (GiB, default 1,10), `--runs`,
`--work-us` (default 200), `--csv`; it needs as much free space as the
largest size):

```
Source\Benchmarks\Delphi\Win64\Release\Pascal.IOUring.Benchmarks.Writes.exe --sizes 1,10 --runs 3 --csv writes.csv
Source\Build-FPC.ps1 -Project Writes -Platform Win64 -Run
```

Linux: the same four Free Pascal programs with `-Platform Linux64`; they are
built and run in WSL (`-Distribution Ubuntu-26.04` picks a distribution, the
default is WSL's default one). The test files go to
`/tmp/Pascal.IOUring.Bench`. The whole set (reader 1 and 10 GiB, blocks,
writes 1 and 10 GiB, structures) took about 10 minutes in WSL2.

```
Source\Build-FPC.ps1 -Project Benchmarks -Platform Linux64 -Run -RunArguments '--sizes','1,10','--runs','3'
Source\Build-FPC.ps1 -Project Blocks -Platform Linux64 -Run
Source\Build-FPC.ps1 -Project Writes -Platform Linux64 -Run
Source\Build-FPC.ps1 -Project Structures -Platform Linux64 -Run
```
