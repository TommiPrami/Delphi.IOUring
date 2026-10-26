# Pascal.IOUring

[![CI](https://github.com/TommiPrami/Pascal.IOUring/actions/workflows/ci.yml/badge.svg)](https://github.com/TommiPrami/Pascal.IOUring/actions/workflows/ci.yml)

Fast file I/O for Delphi and Free Pascal with the operating system's I/O
rings: **IoRing** on Windows, and `io_uring` on Linux through Free Pascal.

*Formerly **Delphi.IOUring**: renamed before version 0.1.0, because the
library is as much Free Pascal as Delphi. The units now have the prefix
`PIR` (**P**ascal.**I**OU**R**ing): `uses PIRUnit.IORing` instead of
`Delphi.IOUring`, `PIRUnit.Engine` instead of `Delphi.IOUring.Engine`, and
so on ([Docs/CodingStyle.md](Docs/CodingStyle.md), "Units and files").*

The first ready part is a **read-only, sequential file stream with read-ahead**:
while your code works on one block, the next blocks are already being read.
It is a `TStream`, so it can replace `TFileStream` where a file is read from
start to end. Its counterpart writes in the background, and an I/O engine
serves many threads with many requests in flight.

On a fast NVMe disk, a 10 GiB file not in the file cache is read at the full
speed of the disk – **about 6.75 GiB/s, 2.7× faster than `TFileStream` with
1 MiB reads and about 4× faster than with 64 KiB reads** ([Benchmarks](Docs/Benchmarks.md)).

## Status

| Part | State |
| --- | --- |
| Complete Windows IoRing API translation (`PIRUnit.Windows.API`) | done, tested |
| Core ring `TIORing` (`PIRUnit.IORing`) | done, tested |
| Read-ahead reader `TIORingSequentialReader` | done, tested |
| `TSequentialReadOnlyFileStream` | done, tested, benchmarked |
| Free Pascal / Lazarus on Windows | done: FPC 3.2.2, Win32 and Win64, all tests pass, same speed as Delphi |
| Atomics for the engine (`PIRUnit.Atomics`: CAS, acquire/release, wait/wake) | done, tested (Delphi and FPC) |
| Request pool for the engine (`PIRUnit.RequestPool`: slots, handles, lock-free free list) | done, tested, benchmarked against a lock |
| Request queue for the engine (`PIRUnit.RequestQueue`: lock-free, producers → I/O thread) | done, tested, benchmarked against a lock |
| I/O engine `TIORingEngine` (`PIRUnit.Engine`: many threads, one or more I/O threads, many requests in flight) | done, tested, benchmarked through the block reader |
| Block reader `TIORingBlockReader` (`PIRUnit.BlockReader`: blocks known in advance, read ahead, neighbours merged, handed out in order) | done, tested, benchmarked |
| Overlap rule of the engine (`orKeepOrder`: per file handle, requests that touch the same bytes take effect in start order) | done, tested, measured |
| Write stream `TSequentialWriteOnlyFileStream` and writer `TIORingSequentialWriter` (writing in the background) | done, tested, benchmarked |
| Complete Linux io_uring API translation (`PIRUnit.Linux.API`, Linux 6.8 header, Free Pascal) | done, tested on x86-64 (WSL2) and ARM64 (CI) |
| Linux ring `TLinuxIORing` (`PIRUnit.Linux.Ring`; `TIORing` on Linux), the read-ahead reader and the atomics on Linux | done, tested on x86-64 (WSL2) and ARM64 (CI) |
| The engine, block reader, overlap rule and both streams on Linux | done, tested on x86-64 (WSL2) and ARM64 (CI); benchmarks run in WSL2 (a first look, not disk numbers) |
| Linux extras: any io_uring operation (sockets …) and linked operations on the ring; capabilities that describe the system | done, tested on x86-64 (WSL2) and ARM64 (CI) |
| Lazarus package `PascalIOUring` (version 0.1) | done, built with Lazarus 5.0 RC1 and trunk (Win32, Win64); its units compile on Linux too (CI) |
| Demos (`Source/Demos`: six small programs) | done, built and run with Delphi, Lazarus and Free Pascal (Windows, Linux) |

See [Docs/Plan.md](Docs/Plan.md) and [Docs/Design.md](Docs/Design.md).

## Requirements

- **Windows 11 24H2 or newer** (IoRing version 4), Win32 or Win64.
  On older Windows the programs still start; `IORingAvailable` returns False
  and creating a ring raises `EIORingNotSupported`.
- **Delphi 13**, or **Free Pascal 3.2.2** (Lazarus 5.0). Older Delphi versions
  may work but are not tested.
- Linux (Free Pascal only; everything except the Windows API unit):
  **Linux 5.11 or newer**, x86-64 or AArch64,
  with io_uring not switched off. Otherwise `IORingAvailable` returns False.
  Programs need `cthreads` as the first unit (the engine uses threads).

### Tested on

| Where | What |
| --- | --- |
| Windows 11 (build 26300), locally | Delphi 13 and Free Pascal 3.2.2, Win32 and Win64, debug and optimized; Free Pascal 3.3.1 (trunk), Win64 |
| WSL2, Ubuntu 24.04 and 26.04 (kernel 6.18), locally | Free Pascal 3.2.2, x86-64, debug and `-O3` |
| GitHub Actions, on every push ([CI](.github/workflows/ci.yml)) | Free Pascal 3.2.2 on Linux x86-64 and Linux ARM64 (Ubuntu 24.04), and on Windows Server 2025 (Win32 and Win64) |

The test program prints what the system offers first
(`IORingCapabilities.ToString`), so every CI log says what that runner has.

## Usage

- **Delphi:** add `Source\Units` to the project's search path. The library is
  compiled into the program; there is no Delphi package.
- **Lazarus:** open `Packages/Lazarus/PascalIOUring.lpk` once
  (Package → Open Package File) and compile it; then add it to a project
  (Project Inspector → Add → New Requirement → `PascalIOUring`). From the
  command line, `lazbuild --add-package-link=Packages/Lazarus/PascalIOUring.lpk`
  registers it. The package compiles only the backend of the system it is
  built for. (Plain Free Pascal: add `Source/Units` to the unit and include
  paths.)

The version is 0.1 (`IORING_LIBRARY_VERSION`), and it will stay below 1.0
for a while: the API may still change, especially once others have used it.

### Demos

Small programs in `Source/Demos`, each one source file (`.dpr`) for Delphi
(open the `.dproj`), Lazarus (open the `.lpi`; it uses the package) and plain
Free Pascal. Each runs without arguments – it makes a temporary file, checks
its own result and deletes the file – or takes a file name.

| Demo | Shows |
| --- | --- |
| `Capabilities` | what the ring offers on this system (`IORingCapabilities.ToString`) |
| `CopyFile` | the read and write streams as drop-in `TStream`s: copy, then compare |
| `Checksum` | the zero-copy reader: a checksum computed right in its buffers |
| `ReadBlocks` | the block reader: blocks known in advance, read ahead, in order |
| `EngineCallbacks` | the engine: start and wait, a batch with callbacks, several threads |
| `SocketEcho` | Linux only: an echo over TCP whose socket I/O goes through the ring |

All of them with Free Pascal, and each run once:
`Source\Build-FPC.ps1 -Project Demos -Platform Win64 -Run` (or `Win32`,
`Linux64`).

### Drop-in stream

```pascal
uses
  PIRUnit.Streams;

var
  LStream: TSequentialReadOnlyFileStream;
begin
  LStream := TSequentialReadOnlyFileStream.Create('big.dat');
  try
    // Read, ReadBuffer, CopyFrom, TStreamReader, LoadFromStream ... as with TFileStream
  finally
    LStream.Free;
  end;
end;
```

Read-only and forward-only: `Write`, setting `Size` and seeking anywhere other
than the current position raise `EIORingStreamError` (an `EStreamError`).
`Position` and `Size` work as usual. A file that cannot be opened raises
`EFOpenError`, like `TFileStream`.

Big `Read` calls – for example `TMemoryStream.LoadFromStream`, which reads
the whole file in one call – read most of the data straight into your
memory, without a copy through the stream's buffers. With cached data a
64 MiB call is then about as fast as with `TFileStream`
([Benchmarks](Docs/Benchmarks.md#big-read-calls-phase-26)).

### Zero-copy reader

```pascal
uses
  PIRUnit.SequentialReader;

var
  LReader: TIORingSequentialReader;   // a record: closed at the end of the scope
  LData: PByte;
  LLength: NativeInt;
begin
  LReader.Open('big.dat');            // default: 8 buffers of 1 MiB
  while LReader.TryAcquireChunk(LData, LLength) do
  begin
    Process(LData, LLength);          // the reader's own buffer, no copy
    LReader.ReleaseChunk;
  end;
end;
```

Several workers on one reader: each takes the next chunk, a buffer of its
own, and gives it back when done – in any order. The chunks come in file
order, with their file offset; these two calls are thread-safe. When every
buffer is out, `TryAcquireChunk` waits for one to come back.

```pascal
// On each worker thread, with one LReader shared by all of them
var
  LChunk: TIORingReaderChunk;
begin
  while LReader.TryAcquireChunk(LChunk) do
  begin
    Process(LChunk.Data, LChunk.Length, LChunk.FileOffset);
    LReader.ReleaseChunk(LChunk);
  end;
end;
```

### Writing in the background

```pascal
uses
  PIRUnit.Streams;

var
  LStream: TSequentialWriteOnlyFileStream;
begin
  LStream := TSequentialWriteOnlyFileStream.Create('out.dat');   // creates or empties the file
  try
    // Write, WriteBuffer, CopyFrom, SaveToStream ... as with TFileStream
    LStream.Flush;                    // optional: shows errors of earlier writes here
  finally
    LStream.Free;                     // waits for the writes
  end;
end;
```

`Write` copies into a buffer; full buffers (8 × 1 MiB) are written by an I/O
thread while your code goes on. That pays off when the program also works on
the data – then the writing happens meanwhile (a 1 GiB file was written
25–45 % sooner than with `TFileStream`,
[Benchmarks](Docs/Benchmarks.md#writing-phase-17)); for writing alone it is
as fast as `TFileStream`. Because a write fails after `Write` has returned, its
error comes later as `EWriteError`: at a later `Write`, at `Flush`, or at
`Free`. `[swoUnbuffered]` writes past the file cache. Write-only and
forward-only, like the read stream the other way round. Without a stream:
`TIORingSequentialWriter` (`PIRUnit.SequentialWriter`), also with a
zero-copy API.

### The engine (many threads)

```pascal
uses
  PIRUnit.IORing, PIRUnit.Engine;

var
  LEngine: TIORingEngine;             // one for the program, shared by all threads
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  LEngine := TIORingEngine.Create;    // starts the I/O thread
  try
    // From any thread: start, do other work, then wait
    LHandle := LEngine.ReadAsync(LFile, LBuffer, SizeOf(LBuffer), LOffset);
    ...
    LEngine.Wait(LHandle, LCompletion);
    LCompletion.RaiseIfFailed('Read');
  finally
    LEngine.Free;                     // cancels what is left and waits for it
  end;
end;
```

Requests can also report back through a callback on the I/O thread, and
`BeginBatch`/`EndBatch` sends many requests to the kernel with one call. The
buffer and the file handle must stay valid until the request has completed.

For many small requests of cached data, or unbuffered requests, give the
engine more I/O threads: `TIORingEngine.Create(1024, 256, 4)`. With 4 I/O
threads it carried out up to 3.2× as many 4 KiB reads per second
([Benchmarks](Docs/Benchmarks.md#several-io-threads-phase-15)).

Requests in flight at the same time run in any order – Windows gives none.
If requests of a file may touch the same bytes while they are in flight
(for example a write and then a read of the same block, without waiting in
between), create the engine with the overlap rule:
`TIORingEngine.Create(1024, 256, 1, orKeepOrder)`. For each file handle,
such requests then take effect in the order they were started (a later one
waits for the earlier ones); reads never wait for reads. It cost about 3 %
with few overlaps, and one file then uses one I/O thread
([Design §11](Docs/Design.md)).

### Blocks known in advance

```pascal
uses
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.BlockReader;

var
  LReader: TIORingBlockReader;        // a record: closed at the end of the scope
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  // LFile opened with FILE_FLAG_OVERLAPPED (TIORingPlatform.OpenFileForRead
  // does): on a handle without it, Windows reads one block at a time
  LReader.Open(LEngine, LFile, [TIORingBlock.Create(81920, 4096), TIORingBlock.Create(4096, 512)]);
  while LReader.TryGetBlock(LBlock, LData, LLength) do   // in the order given
  begin
    Process(LBlock, LData, LLength);  // zero-copy
    LReader.ReleaseBlock;
  end;
end;
```

Instead of a list, `Open` also takes a provider: a method that gives the next
block when the reader needs it. Up to `ReadAhead` reads (default 32) are in
flight; neighbouring blocks are read with one read (`MaxGap` lets small gaps
between them be read too).

With data from the disk, 20 000 random 4 KiB blocks are read **7–10× faster
than with `TFileStream` + `Seek`** ([Benchmarks](Docs/Benchmarks.md#blocks-known-in-advance-phase-14)).
For data that is already in the file cache, plain `ReadFile` is faster than
an engine with one I/O thread; with 2–4 I/O threads the block reader beats
it.

### The ring itself

```pascal
uses
  PIRUnit.IORing;

var
  LRing: TIORing;                     // a record: closed at the end of the scope
  LCompletion: TIORingCompletion;
begin
  LRing.Open;
  LRing.PrepareRead(TIORingFileRef.FromHandle(LFile), TIORingBufferRef.FromPointer(@LBuffer),
    SizeOf(LBuffer), 0, 1);
  LRing.Submit(1);                    // submit, and wait for one completion
  if LRing.TryPopCompletion(LCompletion) then
    LCompletion.RaiseIfFailed('Read');
end;
```

`PIRUnit.Windows.API` is a complete, standalone translation of
the Windows IoRing API (`ioringapi.h`) that other projects can use on its own.
`PIRUnit.Linux.API` is the same for Linux: the whole
`linux/io_uring.h` of Linux 6.8 and the three system calls, for Free Pascal
(no C library, no liburing).

### What this system offers

```pascal
Writeln(IORingCapabilities.ToString);   // for logs and bug reports
```

```
Linux io_uring, kernel 6.18
System: Ubuntu 24.04.5 LTS, Linux 6.18.54.1-microsoft-standard-WSL2
Queues: submission up to 32768, completion up to 65536
Operations: read, write, flush, cancel, register files, register buffers, read scatter, write gather
Native: 63 opcodes (highest 62), features $3FFFF
Extras: sockets, linked operations, SQPOLL, raw entries
```

The record also has the fields one by one: `NativeOps` (the system's
opcodes the kernel supports), `NativeFeatures`, `Extras` (what the system
offers beyond the common subset; none on Windows), `NotAvailableReason`.

### Linux extras

On Linux the ring can take any io_uring operation, for example sockets
(`PrepareSqe`, with the names of `PIRUnit.Linux.API`), and
link an entry to the next one (`LinkToNext`). This is Linux code: Windows
IoRing has neither.

```pascal
{$IFDEF LINUX}
LRing.PrepareSqe(1, LSqe);            // receive from a socket
LSqe^.opcode := IORING_OP_RECV;
LSqe^.fd := LSocket;
LSqe^.addr := UInt64(@LBuffer);
LSqe^.len := SizeOf(LBuffer);

LRing.PrepareWrite(LFileRef, LBufferRef, 4096, 0, 2);
LRing.LinkToNext;                     // the flush starts after the write,
LRing.PrepareFlush(LFileRef, rfmData, 3);  // and is cancelled if it fails
LRing.Submit;
{$ENDIF}
```

One entry must give one completion: no multishot operations, no zero-copy
send. SQPOLL (a kernel thread that takes the submissions) is in the API unit
only; measured, it gave no gain for file I/O and cost much more CPU time
([Benchmarks](Docs/Benchmarks.md#sqpoll-phase-22)).

## Building and testing

- The tests are one set for Delphi and Free Pascal (`Source\UnitTests\Common`);
  each compiler has its own runner.
- Tests, Delphi: `Source\UnitTests\Delphi\Pascal.IOUring.UnitTests.dproj` (DUnitX, Win32 and Win64).
- Tests, Free Pascal: `Source\Build-FPC.ps1 -Project Tests -Platform Win32 -Run`
  (FPCUnit; calls the compiler directly, no `fpc.exe` or `lazbuild` needed).
  Add `-Optimize` to build them with `-O3`; the multi-thread tests mean most
  that way (with Delphi: the Release configuration). Without it the build is
  for debugging: no inlining, like Delphi's Debug configuration.
  Lazarus project: `Source\UnitTests\FPC\Pascal.IOUring.UnitTests.FPC.lpi`.
- Tests, Linux: `Source\Build-FPC.ps1 -Project Tests -Platform Linux64 -Run`
  builds and runs them in WSL, with the FPC installed there (Ubuntu:
  `sudo apt install fpc`). On Linux all tests run except the Windows API
  tests, plus the Linux API tests. `-Distribution Ubuntu-26.04` picks another
  WSL distribution than the default one. On a Linux machine itself (x86-64
  or ARM64, with PowerShell 7): `pwsh Source/Build-FPC.ps1 -Project Tests -Run`.
- Benchmarks: `Source\Benchmarks\Delphi\Pascal.IOUring.Benchmarks.dproj`, and for Free
  Pascal `Source\Build-FPC.ps1 -Project Benchmarks` – see
  [Docs/Benchmarks.md](Docs/Benchmarks.md). The engine's data structures
  (lock-free against a lock): `Pascal.IOUring.Benchmarks.Structures.dproj`, or
  `Build-FPC.ps1 -Project Structures`. Blocks known in advance (the block
  reader and the engine): `Pascal.IOUring.Benchmarks.Blocks.dproj`, or
  `Build-FPC.ps1 -Project Blocks`. Writing (the write stream):
  `Pascal.IOUring.Benchmarks.Writes.dproj`, or `Build-FPC.ps1 -Project Writes`.
  With `-Platform Linux64` the four Free Pascal benchmarks build (and with
  `-Run` run) in WSL.
- How the code is written (layout, comments, empty lines, raising through
  the raise helpers, parameters): [Docs/CodingStyle.md](Docs/CodingStyle.md).

## License

MIT – see [LICENSE](LICENSE).
