# Delphi.IOUring – Benchmarks

Measured 2026-10-22 (Plan, Phase 5) with `Source/Benchmarks/Delphi.IOUring.Benchmarks`,
Release builds, Delphi 13. Raw data (every single run): [BenchmarkResults/](BenchmarkResults/).

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

## Machine

| | |
| --- | --- |
| CPU | Intel Core i7-14700 (20 cores, 28 logical processors) |
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
routines (`Bench.Common`, `Bench.Readers`) as the Delphi program, main
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
- `FILE_FLAG_SEQUENTIAL_SCAN` made no measurable difference, cold or warm. (A
  single early test run suggested it halves warm-cache speed; the repeated
  runs did not confirm that.)

## How to run

```
Source\Benchmarks\Win64\Release\Delphi.IOUring.Benchmarks.exe --sizes 1,10 --runs 3 --csv results.csv
Source\Benchmarks\Win64\Release\Delphi.IOUring.Benchmarks.exe --tune --sizes 10 --runs 3
```

Free Pascal (`-Platform Win32` or `Win64`):

```
Source\Build-FPC.ps1 -Project Benchmarks -Platform Win64 -Run -RunArguments '--sizes','1,10','--runs','3'
```

Options: `--dir` (where the test files go; default `%TEMP%\Delphi.IOUring.Bench`),
`--sizes` (GiB, comma separated), `--runs`, `--work-us` (CPU work per MiB in the
work scenario, default 200), `--threads` (default 4), `--csv`, `--tune`,
`--keep` (keep the test files). The 10 GiB set takes about 10 minutes per
platform. Close other programs first – background disk or CPU work changes
the results a lot.
