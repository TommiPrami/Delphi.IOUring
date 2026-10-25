unit PIRUnit.BlockReader.Tests;

{
  Tests for TIORingBlockReader (PIRUnit.BlockReader): blocks come out
  in the provider's order with the right data; the provider is asked lazily;
  neighbouring blocks are merged (touching, and with MaxGap); blocks that go
  backwards or overlap; the end of the file; TryGetBlock without waiting;
  errors (arguments, a failed read, wrong call order); Close with a read in
  flight; and several readers on their own threads sharing one engine.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.BlockReader, PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TBlockArray = array of TIORingBlock;

  TBlockReaderTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFile: THandle;
    // The provider: gives FProvided[FProvidedCount] and counts
    FProvided: TBlockArray;
    FProvidedCount: Integer;
    FFailures: Integer;
    function NextBlock(out ABlock: TIORingBlock): Boolean;
    procedure ReadAndCheck(var AReader: TIORingBlockReader; const AExpected: TBlockArray);
    procedure WorkReader(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure List_BlocksComeInOrderWithTheirData;
    procedure Provider_IsAskedLazily;
    procedure TouchingBlocks_AreMerged;
    procedure MaxGap_MergesAcrossSmallGaps;
    procedure BackwardAndOverlappingBlocks_AreReadAgain;
    procedure EndOfFile_ShortensBlocks;
    procedure EmptyList_IsFinishedAtOnce;
    procedure NoWait_ReturnsFalseUntilTheDataIsThere;
    procedure BadArguments_Raise;
    procedure WrongCallOrder_Raises;
    procedure FailedRead_RaisesEveryTime;
    procedure Close_WaitsForTheReadsInFlight;
    procedure Stats_CountBlocksReadsAndStalls;
    procedure Stress_ManyRandomBlocks;
    procedure Stress_SeveralReadersShareOneEngine;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.Atomics, PIRUnit.Test.FileHelpers;

const
  PATTERN_FILE_SIZE = 4 * 1024 * 1024;
  SHARED_READERS = 4;
  SHARED_BLOCKS = 3000;

// Small random numbers (Random is not thread-safe)
function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);

  Result := AState;
end;

// Random blocks of 1..AMaxLength bytes inside the pattern file
function RandomBlocks(const ACount: Integer; const AMaxLength: Cardinal; const ASeed: Cardinal): TBlockArray;
var
  LIndex: Integer;
  LRandom: Cardinal;
begin
  LRandom := ASeed;
  Result := nil;
  SetLength(Result, ACount);

  for LIndex := 0 to ACount - 1 do
  begin
    Result[LIndex].Length := 1 + NextRandom(LRandom) mod AMaxLength;
    Result[LIndex].Offset := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - Result[LIndex].Length + 1);
  end;
end;

function BlockArray(const ABlocks: array of TIORingBlock): TBlockArray;
var
  LIndex: Integer;
begin
  Result := nil;
  SetLength(Result, Length(ABlocks));

  for LIndex := 0 to High(ABlocks) do
    Result[LIndex] := ABlocks[LIndex];
end;

{ TBlockReaderTests }

procedure TBlockReaderTests.SetUp;
begin
  FResources := TTestResources.Create;
  FFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));
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
  end
  else
    ABlock := TIORingBlock.Create(0, 0);
end;

procedure TBlockReaderTests.ReadAndCheck(var AReader: TIORingBlockReader; const AExpected: TBlockArray);
var
  LIndex: Integer;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  for LIndex := 0 to High(AExpected) do
  begin
    AssertTrue(Format('Block %d', [LIndex]), AReader.TryGetBlock(LBlock, LData, LLength));
    CheckEqualsU64(Format('Block %d: offset (order)', [LIndex]), AExpected[LIndex].Offset, LBlock.Offset);
    AssertEquals(Format('Block %d: length', [LIndex]), Int64(AExpected[LIndex].Length), Int64(LBlock.Length));
    AssertEquals(Format('Block %d: bytes', [LIndex]), Int64(LBlock.Length), Int64(LLength));
    CheckPattern(LBlock.Offset, LData, LLength, Format('Block %d', [LIndex]));
    AReader.ReleaseBlock;
  end;

  AssertFalse('No more blocks', AReader.TryGetBlock(LBlock, LData, LLength));
  AssertTrue('Finished', AReader.Finished);
end;

procedure TBlockReaderTests.List_BlocksComeInOrderWithTheirData;
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
begin
  LBlocks := RandomBlocks(300, 64 * 1024, 12345);
  LReader.Open(FEngine, FFile, LBlocks);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('Blocks', 300, LReader.Stats.Blocks);
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
begin
  // Random blocks: no merging, one read per block
  FProvided := RandomBlocks(200, 4096, 777);
  LReader.Open(FEngine, FFile, NextBlock, READ_AHEAD);
  AssertEquals('Open asks for the read-ahead plus one block', READ_AHEAD + 1, FProvidedCount);
  LDelivered := 0;

  while LReader.TryGetBlock(LBlock, LData, LLength) do
  begin
    CheckEqualsU64('Order', FProvided[LDelivered].Offset, LBlock.Offset);
    CheckPattern(LBlock.Offset, LData, LLength, 'Data');
    Inc(LDelivered);
    AssertTrue(Format('Asked %d blocks ahead', [FProvidedCount - LDelivered]),
      FProvidedCount - LDelivered <= READ_AHEAD + 1);
    LReader.ReleaseBlock;
  end;

  AssertEquals('All blocks', 200, LDelivered);
end;

procedure TBlockReaderTests.TouchingBlocks_AreMerged;
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
  LIndex: Integer;
begin
  // 100 touching blocks of 1000 bytes; a 64 KiB buffer holds 65 of them
  LBlocks := nil;
  SetLength(LBlocks, 100);

  for LIndex := 0 to 99 do
    LBlocks[LIndex] := TIORingBlock.Create(5000 + UInt64(LIndex) * 1000, 1000);

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('Two reads for 100 blocks', 2, LReader.Stats.Reads);
end;

procedure TBlockReaderTests.MaxGap_MergesAcrossSmallGaps;
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
  LIndex: Integer;
begin
  // 20 blocks of 500 bytes with 100-byte gaps
  LBlocks := nil;
  SetLength(LBlocks, 20);

  for LIndex := 0 to 19 do
    LBlocks[LIndex] := TIORingBlock.Create(UInt64(LIndex) * 600, 500);

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 0);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('MaxGap 0: one read per block', 20, LReader.Stats.Reads);
  LReader.Close;

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 100);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('MaxGap 100: one read for all', 1, LReader.Stats.Reads);
  LReader.Close;

  LReader.Open(FEngine, FFile, LBlocks, 8, 64 * 1024, 99);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('MaxGap 99: gaps too big', 20, LReader.Stats.Reads);
end;

procedure TBlockReaderTests.BackwardAndOverlappingBlocks_AreReadAgain;
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
begin
  LBlocks := BlockArray([TIORingBlock.Create(10000, 4000), TIORingBlock.Create(10000, 4000),
    TIORingBlock.Create(12000, 4000), TIORingBlock.Create(500, 100), TIORingBlock.Create(14000, 10)]);
  LReader.Open(FEngine, FFile, LBlocks, 4, 64 * 1024, 1000000);
  ReadAndCheck(LReader, LBlocks);
  CheckEqualsU64('The same block again, an overlap and a step back each start a read', 4, LReader.Stats.Reads);
end;

procedure TBlockReaderTests.EndOfFile_ShortensBlocks;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  LReader.Open(FEngine, FFile, [TIORingBlock.Create(PATTERN_FILE_SIZE - 100, 300),
    TIORingBlock.Create(PATTERN_FILE_SIZE, 10), TIORingBlock.Create(PATTERN_FILE_SIZE + 5000, 10),
    TIORingBlock.Create(PATTERN_FILE_SIZE - 50, 20)], 4, 4096);
  AssertTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  AssertEquals('Across the end: the rest of the file', 100, Int64(LLength));
  CheckPattern(LBlock.Offset, LData, LLength, 'Data');
  LReader.ReleaseBlock;
  AssertTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  AssertEquals('At the end: nothing', 0, Int64(LLength));
  LReader.ReleaseBlock;
  AssertTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  AssertEquals('After the end: nothing', 0, Int64(LLength));
  LReader.ReleaseBlock;
  AssertTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  AssertEquals('Before the end: all', 20, Int64(LLength));
  LReader.ReleaseBlock;
  AssertTrue(LReader.Finished);
end;

procedure TBlockReaderTests.EmptyList_IsFinishedAtOnce;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LNoBlocks: TBlockArray;
begin
  LNoBlocks := nil;
  LReader.Open(FEngine, FFile, LNoBlocks);
  AssertTrue('Finished', LReader.Finished);
  AssertFalse('No block', LReader.TryGetBlock(LBlock, LData, LLength));
  CheckEqualsU64('No reads', 0, LReader.Stats.Reads);
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
  AssertFalse('Not there yet', LReader.TryGetBlock(LBlock, LData, LLength, False));
  AssertFalse('Not finished', LReader.Finished);
  WriteByteToPipe(LServer, 99);
  AssertTrue('Waits for it', LReader.TryGetBlock(LBlock, LData, LLength));
  AssertEquals('Bytes', 1, Int64(LLength));
  AssertEquals('Data', 99, LData^);
  LReader.ReleaseBlock;
  AssertTrue(LReader.Finished);
end;

procedure TBlockReaderTests.BadArguments_Raise;

  procedure CheckOpenRaises(const AMessage: string; const AEngine: TIORingEngine;
    const ABlock: TIORingBlock; const AReadAhead, ABufferSize: Cardinal);
  var
    LReader: TIORingBlockReader;
    LRaised: Boolean;
  begin
    LRaised := False;

    try
      LReader.Open(AEngine, FFile, [ABlock], AReadAhead, ABufferSize);
    except
      on EIORingError do
        LRaised := True;
    end;

    AssertTrue(AMessage, LRaised);
  end;

var
  LReader: TIORingBlockReader;
  LSmall: TIORingEngine;
  LRaised: Boolean;
begin
  CheckOpenRaises('No engine', nil, TIORingBlock.Create(0, 1), 8, 4096);
  CheckOpenRaises('Read-ahead 0', FEngine, TIORingBlock.Create(0, 1), 0, 4096);
  CheckOpenRaises('Buffer size 0', FEngine, TIORingBlock.Create(0, 1), 8, 0);
  CheckOpenRaises('Block longer than the buffer', FEngine, TIORingBlock.Create(0, 5000), 8, 4096);
  CheckOpenRaises('Block of 0 bytes', FEngine, TIORingBlock.Create(0, 0), 8, 4096);
  LSmall := TIORingEngine.Create(4, 4);
  try
    CheckOpenRaises('More read-ahead than the engine has requests', LSmall, TIORingBlock.Create(0, 1), 8, 4096);
  finally
    LSmall.Free;
  end;

  LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)]);
  LRaised := False;

  try
    LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 1)]);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Opened twice', LRaised);
end;

procedure TBlockReaderTests.WrongCallOrder_Raises;
var
  LReader: TIORingBlockReader;
  LOther: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LRaised: Boolean;
begin
  LRaised := False;

  try
    LOther.TryGetBlock(LBlock, LData, LLength);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Not open', LRaised);

  LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 10), TIORingBlock.Create(100, 10)]);
  LRaised := False;

  try
    LReader.ReleaseBlock;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('ReleaseBlock before TryGetBlock', LRaised);

  AssertTrue(LReader.TryGetBlock(LBlock, LData, LLength));
  LRaised := False;

  try
    LReader.TryGetBlock(LBlock, LData, LLength);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('TryGetBlock twice without ReleaseBlock', LRaised);
  LReader.ReleaseBlock;
end;

procedure TBlockReaderTests.FailedRead_RaisesEveryTime;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LTry: Integer;
  LRaised: Boolean;
begin
  // A handle that is not open: the read fails
  LReader.Open(FEngine, BAD_HANDLE, [TIORingBlock.Create(0, 10)]);

  for LTry := 1 to 2 do
  begin
    LRaised := False;

    try
      LReader.TryGetBlock(LBlock, LData, LLength);
    except
      on EIORingError do
        LRaised := True;
    end;

    AssertTrue(Format('Try %d: the error stays', [LTry]), LRaised);
  end;
end;

procedure TBlockReaderTests.Close_WaitsForTheReadsInFlight;
var
  LServer: THandle;
  LClient: THandle;
  LReader: TIORingBlockReader;
  LWriter: TDelayedPipeWriter;
  LStart: UInt64;
begin
  FResources.OpenPipePair(LServer, LClient);
  LReader.Open(FEngine, LClient, [TIORingBlock.Create(0, 1)], 4, 4096);
  LWriter := TDelayedPipeWriter.Create(LServer, 100, 1);
  try
    LWriter.Start;
    LStart := TThread.GetTickCount64;
    LReader.Close;    // the pipe read writes into the reader's buffer: Close waits for it
    // GetTickCount64 moves in steps of about 16 ms
    AssertTrue(Format('Closed after only %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart >= 75);
    LWriter.WaitFor;
  finally
    LWriter.Free;
  end;

  AssertFalse('Closed', LReader.IsOpen);
end;

procedure TBlockReaderTests.Stats_CountBlocksReadsAndStalls;
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  // 3 touching blocks (one read) and 2 far apart (two reads)
  LReader.Open(FEngine, FFile, [TIORingBlock.Create(0, 100), TIORingBlock.Create(100, 100),
    TIORingBlock.Create(200, 100), TIORingBlock.Create(100000, 50), TIORingBlock.Create(300000, 50)], 8, 4096);

  while LReader.TryGetBlock(LBlock, LData, LLength) do
    LReader.ReleaseBlock;

  CheckEqualsU64('Blocks', 5, LReader.Stats.Blocks);
  CheckEqualsU64('Reads', 3, LReader.Stats.Reads);
  CheckEqualsU64('Bytes', 400, LReader.Stats.BytesRead);
  AssertTrue('At most one stall per read', LReader.Stats.Stalls <= 3);
end;

procedure TBlockReaderTests.Stress_ManyRandomBlocks;
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
begin
  LBlocks := RandomBlocks(20000, 16 * 1024, 4242);
  LReader.Open(FEngine, FFile, LBlocks, 64, 16 * 1024);
  ReadAndCheck(LReader, LBlocks);
end;

procedure TBlockReaderTests.WorkReader(AIndex: Integer);
var
  LReader: TIORingBlockReader;
  LBlocks: TBlockArray;
  LIndex: Integer;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
  LBadOffset: UInt64;
begin
  LBlocks := RandomBlocks(SHARED_BLOCKS, 32 * 1024, Cardinal(AIndex + 1) * 2654435761);
  LReader.Open(FEngine, FFile, LBlocks, 32, 32 * 1024);

  for LIndex := 0 to SHARED_BLOCKS - 1 do
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
end;

procedure TBlockReaderTests.Stress_SeveralReadersShareOneEngine;
begin
  // Each thread has its own reader; all share the engine of the test
  RunThreads(SHARED_READERS, WorkReader);
  AssertEquals('Readers with wrong blocks or data', 0, FFailures);
end;

initialization
  RegisterTests(TBlockReaderTests);

end.
