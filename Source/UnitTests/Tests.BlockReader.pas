unit Tests.BlockReader;

{
  Tests for TIORingBlockReader (Delphi.IOUring.BlockReader): blocks come out
  in the provider's order with the right data; the provider is asked lazily;
  neighbouring blocks are merged (touching, and with MaxGap); blocks that go
  backwards or overlap; the end of the file; TryGetBlock without waiting;
  errors (arguments, a failed read, wrong call order); Close with a read in
  flight; and several readers on their own threads sharing one engine.
}

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Delphi.IOUring,
  Delphi.IOUring.Engine,
  Delphi.IOUring.BlockReader,
  TestPlatformHelpers;

type
  [TestFixture]
  TBlockReaderTests = class
  private
    FPatternFileName: string;
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFile: THandle;
    // The provider: gives FProvided[FProvidedCount] and counts
    FProvided: TArray<TIORingBlock>;
    FProvidedCount: Integer;
    FFailures: Integer;
    function NextBlock(out ABlock: TIORingBlock): Boolean;
    // Random blocks of 1..AMaxLength bytes inside the pattern file
    function RandomBlocks(const ACount: Integer; const AMaxLength: Cardinal; const ASeed: Cardinal): TArray<TIORingBlock>;
    // Reads every block and checks order, length and data
    procedure ReadAndCheck(var AReader: TIORingBlockReader; const AExpected: array of TIORingBlock);
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure List_BlocksComeInOrderWithTheirData;
    [Test]
    procedure Provider_IsAskedLazily;
    [Test]
    procedure TouchingBlocks_AreMerged;
    [Test]
    procedure MaxGap_MergesAcrossSmallGaps;
    [Test]
    procedure BackwardAndOverlappingBlocks_AreReadAgain;
    [Test]
    procedure EndOfFile_ShortensBlocks;
    [Test]
    procedure EmptyList_IsFinishedAtOnce;
    [Test]
    procedure NoWait_ReturnsFalseUntilTheDataIsThere;
    [Test]
    procedure BadArguments_Raise;
    [Test]
    procedure WrongCallOrder_Raises;
    [Test]
    procedure FailedRead_RaisesEveryTime;
    [Test]
    procedure Close_WaitsForTheReadsInFlight;
    [Test]
    procedure Stats_CountBlocksReadsAndStalls;
    [Test]
    procedure Stress_ManyRandomBlocks;
    [Test]
    procedure Stress_SeveralReadersShareOneEngine;
  end;

implementation

uses
  Winapi.Windows,
  System.Diagnostics,
  Delphi.IOUring.Atomics,
  TestFileHelpers,
  TestThreadHelpers;

const
  PATTERN_FILE_SIZE = 4 * 1024 * 1024;

// Small random numbers (Random is not thread-safe)
function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);
  Result := AState;
end;

function BlockArray(const ABlocks: array of TIORingBlock): TArray<TIORingBlock>;
var
  LIndex: Integer;
begin
  SetLength(Result, Length(ABlocks));
  for LIndex := 0 to High(ABlocks) do
    Result[LIndex] := ABlocks[LIndex];
end;

{ TBlockReaderTests }

procedure TBlockReaderTests.SetupFixture;
begin
  FPatternFileName := TTestFileHelpers.CreatePatternFile(PATTERN_FILE_SIZE, 'BlockPattern');
end;

procedure TBlockReaderTests.TearDownFixture;
begin
  TTestFileHelpers.DeleteTestFile(FPatternFileName);
end;

procedure TBlockReaderTests.Setup;
begin
  FResources := TTestResources.Create;
  FFile := FResources.OpenFile(FPatternFileName);
  FEngine := TIORingEngine.Create;
  FProvided := nil;
  FProvidedCount := 0;
  FFailures := 0;
end;

procedure TBlockReaderTests.TearDown;
begin
  FreeAndNil(FEngine);
  FResources.Free;
  FResources := nil;
end;

function TBlockReaderTests.NextBlock(out ABlock: TIORingBlock): Boolean;
begin
  Result := FProvidedCount < Length(FProvided);
  if Result then
  begin
    ABlock := FProvided[FProvidedCount];
    Inc(FProvidedCount);
  end;
end;

function TBlockReaderTests.RandomBlocks(const ACount: Integer; const AMaxLength: Cardinal;
  const ASeed: Cardinal): TArray<TIORingBlock>;
var
  LIndex: Integer;
  LRandom: Cardinal;
begin
  LRandom := ASeed;
  SetLength(Result, ACount);
  for LIndex := 0 to ACount - 1 do
  begin
    Result[LIndex].Length := 1 + NextRandom(LRandom) mod AMaxLength;
    Result[LIndex].Offset := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - Result[LIndex].Length + 1);
  end;
end;

procedure TBlockReaderTests.ReadAndCheck(var AReader: TIORingBlockReader; const AExpected: array of TIORingBlock);
var
  LIndex: Integer;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LBadOffset: UInt64;
begin
  for LIndex := 0 to High(AExpected) do
  begin
    Assert.IsTrue(AReader.TryGetBlock(LBlock, LData, LLength), Format('Block %d', [LIndex]));
    Assert.AreEqual<UInt64>(AExpected[LIndex].Offset, LBlock.Offset, Format('Block %d: offset (order)', [LIndex]));
    Assert.AreEqual(AExpected[LIndex].Length, LBlock.Length, Format('Block %d: length', [LIndex]));
    Assert.AreEqual(LBlock.Length, LLength, Format('Block %d: bytes', [LIndex]));
    Assert.IsTrue(TTestFileHelpers.CheckPattern(LBlock.Offset, LData^, LLength, LBadOffset),
      Format('Block %d: wrong data at file offset %d', [LIndex, LBadOffset]));
    AReader.ReleaseBlock;
  end;
  Assert.IsFalse(AReader.TryGetBlock(LBlock, LData, LLength), 'No more blocks');
  Assert.IsTrue(AReader.Finished, 'Finished');
end;

procedure TBlockReaderTests.List_BlocksComeInOrderWithTheirData;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
begin
  LBlocks := RandomBlocks(300, 64 * 1024, 12345);
  LReader.Open(FEngine, FFile, LBlocks);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(300, LReader.Stats.Blocks, 'Blocks');
end;

procedure TBlockReaderTests.Provider_IsAskedLazily;
const
  READ_AHEAD = 8;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LDelivered: Integer;
  LBadOffset: UInt64;
begin
  // Random blocks: no merging, one read per block
  FProvided := RandomBlocks(200, 4096, 777);
  LReader.Open(FEngine, FFile, NextBlock, READ_AHEAD);
  Assert.AreEqual(READ_AHEAD + 1, FProvidedCount, 'Open asks for the read-ahead plus one block');
  LDelivered := 0;
  while LReader.TryGetBlock(LBlock, LData, LLength) do
  begin
    Assert.AreEqual<UInt64>(FProvided[LDelivered].Offset, LBlock.Offset, 'Order');
    Assert.IsTrue(TTestFileHelpers.CheckPattern(LBlock.Offset, LData^, LLength, LBadOffset), 'Data');
    Inc(LDelivered);
    Assert.IsTrue(FProvidedCount - LDelivered <= READ_AHEAD + 1,
      Format('Asked %d blocks ahead', [FProvidedCount - LDelivered]));
    LReader.ReleaseBlock;
  end;
  Assert.AreEqual(200, LDelivered, 'All blocks');
end;

procedure TBlockReaderTests.TouchingBlocks_AreMerged;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
  LIndex: Integer;
begin
  // 100 touching blocks of 1000 bytes; a 64 KiB buffer holds 65 of them
  SetLength(LBlocks, 100);
  for LIndex := 0 to 99 do
    LBlocks[LIndex] := TIORingBlock.Create(5000 + UInt64(LIndex) * 1000, 1000);
  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(2, LReader.Stats.Reads, 'Two reads for 100 blocks');
end;

procedure TBlockReaderTests.MaxGap_MergesAcrossSmallGaps;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
  LIndex: Integer;
begin
  // 20 blocks of 500 bytes with 100-byte gaps
  SetLength(LBlocks, 20);
  for LIndex := 0 to 19 do
    LBlocks[LIndex] := TIORingBlock.Create(UInt64(LIndex) * 600, 500);
  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 0);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(20, LReader.Stats.Reads, 'MaxGap 0: one read per block');
  LReader.Close;

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 100);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(1, LReader.Stats.Reads, 'MaxGap 100: one read for all');
  LReader.Close;

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 99);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(20, LReader.Stats.Reads, 'MaxGap 99: gaps too big');
end;

procedure TBlockReaderTests.BackwardAndOverlappingBlocks_AreReadAgain;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
begin
  LBlocks := BlockArray([TIORingBlock.Create(10000, 4000), TIORingBlock.Create(10000, 4000),
    TIORingBlock.Create(12000, 4000), TIORingBlock.Create(500, 100), TIORingBlock.Create(14000, 10)]);
  LReader.Open(FEngine, FFile, LBlocks, 4, 64 * 1024, 1000000);
  ReadAndCheck(LReader, LBlocks);
  Assert.AreEqual<UInt64>(4, LReader.Stats.Reads,
    'The same block again, an overlap and a step back each start a read; the last one joins the step back');
end;

procedure TBlockReaderTests.EndOfFile_ShortensBlocks;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LBadOffset: UInt64;
begin
  LReader.Open(FEngine, FFile, [TIORingBlock.Create(PATTERN_FILE_SIZE - 100, 300),
    TIORingBlock.Create(PATTERN_FILE_SIZE, 10), TIORingBlock.Create(PATTERN_FILE_SIZE + 5000, 10),
    TIORingBlock.Create(PATTERN_FILE_SIZE - 50, 20)], 4, 4096);
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  Assert.AreEqual(Cardinal(100), LLength, 'Across the end: the rest of the file');
  Assert.IsTrue(TTestFileHelpers.CheckPattern(LBlock.Offset, LData^, LLength, LBadOffset), 'Data');
  LReader.ReleaseBlock;
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  Assert.AreEqual(Cardinal(0), LLength, 'At the end: nothing');
  LReader.ReleaseBlock;
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  Assert.AreEqual(Cardinal(0), LLength, 'After the end: nothing');
  LReader.ReleaseBlock;
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  Assert.AreEqual(Cardinal(20), LLength, 'Before the end: all');
  LReader.ReleaseBlock;
  Assert.IsTrue(LReader.Finished);
end;

procedure TBlockReaderTests.EmptyList_IsFinishedAtOnce;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LNoBlocks: array of TIORingBlock;
begin
  LNoBlocks := nil;
  LReader.Open(FEngine, FFile, LNoBlocks);
  Assert.IsTrue(LReader.Finished, 'Finished');
  Assert.IsFalse(LReader.TryGetBlock(LBlock, LData, LLength), 'No block');
  Assert.AreEqual<UInt64>(0, LReader.Stats.Reads, 'No reads');
end;

procedure TBlockReaderTests.NoWait_ReturnsFalseUntilTheDataIsThere;
var
  LServer: THandle;
  LClient: THandle;
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  // A pipe read stays pending until the test writes
  FResources.OpenPipePair(LServer, LClient);
  LReader.Open(FEngine, LClient, [TIORingBlock.Create(0, 1)], 4, 4096);
  Assert.IsFalse(LReader.TryGetBlock(LBlock, LData, LLength, False), 'Not there yet');
  Assert.IsFalse(LReader.Finished, 'Not finished');
  WriteByteToPipe(LServer, 99);
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength), 'Waits for it');
  Assert.AreEqual(Cardinal(1), LLength);
  Assert.AreEqual(Byte(99), LData^);
  LReader.ReleaseBlock;
  Assert.IsTrue(LReader.Finished);
end;

procedure TBlockReaderTests.BadArguments_Raise;
var
  LReader: TIORingBlockReader;
  LSmall: TIORingEngine;
begin
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
    begin
      LOther.Open(nil, FFile, [TIORingBlock.Create(0, 1)]);
    end, EIORingError, 'No engine');
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
    begin
      LOther.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)], 0);
    end, EIORingError, 'Read-ahead 0');
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
    begin
      LOther.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)], 8, 0);
    end, EIORingError, 'Buffer size 0');
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
    begin
      LOther.Open(FEngine, FFile, [TIORingBlock.Create(0, 5000)], 8, 4096);
    end, EIORingError, 'Block longer than the buffer');
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
    begin
      LOther.Open(FEngine, FFile, [TIORingBlock.Create(0, 0)], 8, 4096);
    end, EIORingError, 'Block of 0 bytes');

  LSmall := TIORingEngine.Create(4, 4);
  try
    Assert.WillRaise(
      procedure
      var
        LOther: TIORingBlockReader;
      begin
        LOther.Open(LSmall, FFile, [TIORingBlock.Create(0, 1)], 8);
      end, EIORingError, 'More read-ahead than the engine has requests');
  finally
    LSmall.Free;
  end;

  LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)]);
  Assert.WillRaise(
    procedure
    begin
      LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)]);
    end, EIORingError, 'Opened twice');
end;

procedure TBlockReaderTests.WrongCallOrder_Raises;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  Assert.WillRaise(
    procedure
    var
      LOther: TIORingBlockReader;
      LOtherBlock: TIORingBlock;
      LOtherData: PByte;
      LOtherLength: Cardinal;
    begin
      LOther.TryGetBlock(LOtherBlock, LOtherData, LOtherLength);
    end, EIORingError, 'Not open');

  LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 10), TIORingBlock.Create(100, 10)]);
  Assert.WillRaise(
    procedure
    begin
      LReader.ReleaseBlock;
    end, EIORingError, 'ReleaseBlock before TryGetBlock');
  Assert.IsTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  Assert.WillRaise(
    procedure
    var
      LOtherBlock: TIORingBlock;
      LOtherData: PByte;
      LOtherLength: Cardinal;
    begin
      LReader.TryGetBlock(LOtherBlock, LOtherData, LOtherLength);
    end, EIORingError, 'TryGetBlock twice without ReleaseBlock');
  LReader.ReleaseBlock;
end;

procedure TBlockReaderTests.FailedRead_RaisesEveryTime;
var
  LReader: TIORingBlockReader;
begin
  // File handle 0: the read fails
  LReader.Open(FEngine, 0, [TIORingBlock.Create(0, 10)]);
  Assert.WillRaise(
    procedure
    var
      LBlock: TIORingBlock;
      LData: PByte;
      LLength: Cardinal;
    begin
      LReader.TryGetBlock(LBlock, LData, LLength);
    end, EIORingError, 'First try');
  Assert.WillRaise(
    procedure
    var
      LBlock: TIORingBlock;
      LData: PByte;
      LLength: Cardinal;
    begin
      LReader.TryGetBlock(LBlock, LData, LLength);
    end, EIORingError, 'Second try: the error stays');
end;

procedure TBlockReaderTests.Close_WaitsForTheReadsInFlight;
var
  LServer: THandle;
  LClient: THandle;
  LReader: TIORingBlockReader;
  LWriter: TThread;
  LWatch: TStopwatch;
begin
  FResources.OpenPipePair(LServer, LClient);
  LReader.Open(FEngine, LClient, [TIORingBlock.Create(0, 1)], 4, 4096);
  LWriter := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(100);
      WriteByteToPipe(LServer, 1);
    end);
  LWriter.FreeOnTerminate := False;
  try
    LWriter.Start;
    LWatch := TStopwatch.StartNew;
    LReader.Close;    // the pipe read writes into the reader's buffer: Close waits for it
    Assert.IsTrue(LWatch.ElapsedMilliseconds >= 80, Format('Closed after only %d ms', [LWatch.ElapsedMilliseconds]));
    LWriter.WaitFor;
  finally
    LWriter.Free;
  end;
  Assert.IsFalse(LReader.IsOpen, 'Closed');
end;

procedure TBlockReaderTests.Stats_CountBlocksReadsAndStalls;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  // 3 touching blocks (one read) and 2 far apart (two reads)
  LBlocks := BlockArray([TIORingBlock.Create(0, 100), TIORingBlock.Create(100, 100), TIORingBlock.Create(200, 100),
    TIORingBlock.Create(100000, 50), TIORingBlock.Create(300000, 50)]);
  LReader.Open(FEngine, FFile, LBlocks, 8, 4096);
  while LReader.TryGetBlock(LBlock, LData, LLength) do
    LReader.ReleaseBlock;
  Assert.AreEqual<UInt64>(5, LReader.Stats.Blocks, 'Blocks');
  Assert.AreEqual<UInt64>(3, LReader.Stats.Reads, 'Reads');
  Assert.AreEqual<UInt64>(400, LReader.Stats.BytesRead, 'Bytes');
  Assert.IsTrue(LReader.Stats.Stalls <= 3, 'At most one stall per read');
end;

procedure TBlockReaderTests.Stress_ManyRandomBlocks;
var
  LReader: TIORingBlockReader;
  LBlocks: TArray<TIORingBlock>;
begin
  LBlocks := RandomBlocks(20000, 16 * 1024, 4242);
  LReader.Open(FEngine, FFile, LBlocks, 64, 16 * 1024);
  ReadAndCheck(LReader, LBlocks);
end;

procedure TBlockReaderTests.Stress_SeveralReadersShareOneEngine;
const
  READERS = 4;
  BLOCKS = 3000;
begin
  // Each thread has its own reader; all share the engine of the fixture
  RunThreads(READERS,
    procedure(AThread: Integer)
    var
      LReader: TIORingBlockReader;
      LBlocks: TArray<TIORingBlock>;
      LIndex: Integer;
      LBlock: TIORingBlock;
      LData: PByte;
      LLength: Cardinal;
      LBadOffset: UInt64;
    begin
      LBlocks := RandomBlocks(BLOCKS, 32 * 1024, Cardinal(AThread + 1) * 2654435761);
      LReader.Open(FEngine, FFile, LBlocks, 32, 32 * 1024);
      for LIndex := 0 to BLOCKS - 1 do
      begin
        if not LReader.TryGetBlock(LBlock, LData, LLength) or (LBlock.Offset <> LBlocks[LIndex].Offset) or
          (LLength <> LBlocks[LIndex].Length) or
          not TTestFileHelpers.CheckPattern(LBlock.Offset, LData^, LLength, LBadOffset) then
        begin
          TAtomic.Increment(FFailures);
          Exit;
        end;
        LReader.ReleaseBlock;
      end;
      if not LReader.Finished then
        TAtomic.Increment(FFailures);
    end);
  Assert.AreEqual(0, FFailures, 'Readers with wrong blocks or data');
end;

initialization
  TDUnitX.RegisterTestFixture(TBlockReaderTests);

end.
