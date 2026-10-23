# Delphi.IOUring

Fast file I/O for Delphi with the operating system's I/O rings: **IoRing** on
Windows (and later `io_uring` on Linux through Free Pascal).

The first ready part is a **read-only, sequential file stream with read-ahead**:
while your code works on one block, the next blocks are already being read.
It is a `TStream`, so it can replace `TFileStream` where a file is read from
start to end.

On a fast NVMe disk, a 10 GiB file not in the file cache is read at the full
speed of the disk – **about 6.75 GiB/s, 2.7× faster than `TFileStream` with
1 MiB reads and about 4× faster than with 64 KiB reads** ([Benchmarks](Docs/Benchmarks.md)).

## Status

| Part | State |
| --- | --- |
| Complete Windows IoRing API translation (`Delphi.IOUring.Backend.Windows.API`) | done, tested |
| Core ring `TIORing` (`Delphi.IOUring`) | done, tested |
| Read-ahead reader `TIORingSequentialReader` | done, tested |
| `TSequentialReadOnlyFileStream` | done, tested, benchmarked |
| Free Pascal / Lazarus on Windows | done: FPC 3.2.2, Win32 and Win64, all tests pass, same speed as Delphi |
| Atomics for the engine (`Delphi.IOUring.Atomics`: CAS, acquire/release, wait/wake) | done, tested (Delphi and FPC) |
| Request pool for the engine (`Delphi.IOUring.RequestPool`: slots, handles, lock-free free list) | done, tested, benchmarked against a lock |
| Request queue for the engine (`Delphi.IOUring.RequestQueue`: lock-free, producers → I/O thread) | done, tested, benchmarked against a lock |
| I/O engine `TIORingEngine` (`Delphi.IOUring.Engine`: many threads, one or more I/O threads, many requests in flight) | done, tested, benchmarked through the block reader |
| Block reader `TIORingBlockReader` (`Delphi.IOUring.BlockReader`: blocks known in advance, read ahead, neighbours merged, handed out in order) | done, tested, benchmarked |
| Overlap rules, write stream | planned |
| Linux `io_uring` through Free Pascal | planned |

See [Docs/Plan.md](Docs/Plan.md) and [Docs/Design.md](Docs/Design.md).

## Requirements

- **Windows 11 24H2 or newer** (IoRing version 4), Win32 or Win64.
  On older Windows the programs still start; `IORingAvailable` returns False
  and creating a ring raises `EIORingNotSupported`.
- **Delphi 13**, or **Free Pascal 3.2.2** (Lazarus 5.0). Older Delphi versions
  may work but are not tested.

## Usage

Add `Source\Units` to the search path.

### Drop-in stream

```pascal
uses
  Delphi.IOUring.Streams;

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

### Zero-copy reader

```pascal
uses
  Delphi.IOUring.SequentialReader;

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

### The engine (many threads)

```pascal
uses
  Delphi.IOUring, Delphi.IOUring.Engine;

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

### Blocks known in advance

```pascal
uses
  Delphi.IOUring, Delphi.IOUring.Engine, Delphi.IOUring.BlockReader;

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
  Delphi.IOUring;

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

`Delphi.IOUring.Backend.Windows.API` is a complete, standalone translation of
the Windows IoRing API (`ioringapi.h`) that other projects can use on its own.

## Building and testing

- Tests, Delphi: `Source\UnitTests\Delphi.IOUring.UnitTests.dproj` (DUnitX, Win32 and Win64).
- Tests, Free Pascal: `Source\Build-FPC.ps1 -Project Tests -Platform Win32 -Run`
  (FPCUnit; calls the compiler directly, no `fpc.exe` or `lazbuild` needed).
  Add `-Optimize` to build them with `-O3`; the multi-thread tests mean most
  that way (with Delphi: the Release configuration). Without it the build is
  for debugging: no inlining, like Delphi's Debug configuration.
  Lazarus project: `Source\UnitTests\FPC\Delphi.IOUring.UnitTests.FPC.lpi`.
- Benchmarks: `Source\Benchmarks\Delphi.IOUring.Benchmarks.dproj`, and for Free
  Pascal `Source\Build-FPC.ps1 -Project Benchmarks` – see
  [Docs/Benchmarks.md](Docs/Benchmarks.md). The engine's data structures
  (lock-free against a lock): `Delphi.IOUring.Benchmarks.Structures.dproj`, or
  `Build-FPC.ps1 -Project Structures`. Blocks known in advance (the block
  reader and the engine): `Delphi.IOUring.Benchmarks.Blocks.dproj`, or
  `Build-FPC.ps1 -Project Blocks`.

## License

MIT – see [LICENSE](LICENSE).
