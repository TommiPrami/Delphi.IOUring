unit PIRUnit.EngineOverlap.Tests;

{
  Tests for the overlap rule of TIORingEngine (orKeepOrder, Docs/Design.md
  §11): for one file handle, requests that touch the same bytes take effect
  in the order they were started.

  Pipes make the cases exact: a read from a pipe stays pending until the test
  writes to the other end, so a later write of the same handle and bytes must
  stay held back meanwhile. (Pipes ignore offsets; the rule does not.)

  The model tests start random reads and writes of random sizes without
  waiting for them, and keep an in-memory copy of the file updated in start
  order: every read must return what the copy held when the read was started.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils,
{$ELSE}
  System.Classes, System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TEngineOverlapTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFailures: Integer;
    // Filled by RecordCompletion: the UserData of the completed requests, in the order they completed
    FOrder: array[0..63] of NativeUInt;
    FOrderCount: Integer;
    FCancelledCount: Integer;
    FModelFile: THandle;
    procedure RecordCompletion(const ACompletion: TIORingCompletion);
    function CompletedCount: Integer;
    // Wait at most 5 s for a value
    function WaitForHeldBack(const AExpected: UInt64): Boolean;
    function WaitForRequests(const AExpected: UInt64): Boolean;
    function WaitForCompleted(const AExpected: Integer): Boolean;
    { Random reads and writes in [ARegion, ARegion + MODEL_SIZE) of AFile, checked against a model; returns
      the number of wrong results }
    function RunModel(const AFile: THandle; const ARegion: UInt64; const ASeed: Cardinal): Integer;
    procedure WorkModel(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // Order on a file
    procedure WriteThenRead_ReadSeesTheWrite;
    procedure WriteThenWrite_TheLaterOneWins;
    procedure ReadThenWrite_ReadSeesTheOldData;
    // Exact cases with pipes
    procedure PendingRead_HoldsBackAWriteOfTheSameBytes;
    procedure ReadsDoNotWaitForReads;
{$IFDEF MSWINDOWS}
    // Windows only: a pipe with offsets (Linux: ESPIPE on a socket)
    procedure OtherBytes_DoNotWait;
{$ENDIF}
    procedure HeldBackRequests_StartInOrder;
{$IFDEF MSWINDOWS}
    { Windows only: a pending pipe write and a flush of a pipe (Linux: a large socket write does not wait,
      and a flush there is EINVAL) }
    procedure Flush_WaitsForAnEarlierWrite;
{$ENDIF}
    procedure Destroy_CancelsHeldBackRequests;
    procedure RuleOff_NothingIsHeldBack;
    // Routing
    procedure OneHandle_UsesOneIOThread;
    // Against a model
    procedure Model_RandomReadsAndWrites;
    procedure Model_FourProducersOnOneHandle;
  end;

implementation

uses
  PIRUnit.Atomics;

const
  MODEL_SIZE = 64 * 1024;
  MODEL_OPERATIONS = 4000;
  MODEL_IN_FLIGHT = 32;
  MODEL_BATCH = 24;
  MODEL_MAX_LENGTH = 8192;
  MODEL_PRODUCERS = 4;
  WAIT_MILLISECONDS = 5000;

type
  TModelOperation = record
    Handle: TIORingRequestHandle;
    IsWrite: Boolean;
    Offset: Cardinal;
    Count: Cardinal;
    Data: TBytes;        // a write: what it writes; a read: its buffer
    Expected: TBytes;    // a read: the model's bytes when it was started
  end;

function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);

  Result := AState;
end;

{ TEngineOverlapTests }

procedure TEngineOverlapTests.SetUp;
begin
  FResources := TTestResources.Create;
  FEngine := nil;
  FFailures := 0;
  FOrderCount := 0;
  FCancelledCount := 0;
end;

procedure TEngineOverlapTests.TearDown;
begin
  // The engine first: it finishes every request before the handles close
  FreeAndNil(FEngine);
  FResources.Free;
  FResources := nil;
end;

procedure TEngineOverlapTests.RecordCompletion(const ACompletion: TIORingCompletion);
var
  LIndex: Integer;
begin
  // Callbacks of one file handle all run on its I/O thread, one at a time
  if ACompletion.IsCancelled then
    TAtomic.Increment(FCancelledCount);

  LIndex := FOrderCount;
  FOrder[LIndex] := ACompletion.UserData;
  TAtomic.StoreRelease(FOrderCount, LIndex + 1);
end;

function TEngineOverlapTests.CompletedCount: Integer;
begin
  Result := TAtomic.LoadAcquire(FOrderCount);
end;

function TEngineOverlapTests.WaitForHeldBack(const AExpected: UInt64): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + WAIT_MILLISECONDS;

  while (FEngine.Stats.HeldBack <> AExpected) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  Result := FEngine.Stats.HeldBack = AExpected;
end;

function TEngineOverlapTests.WaitForRequests(const AExpected: UInt64): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + WAIT_MILLISECONDS;

  while (FEngine.Stats.Requests <> AExpected) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  Result := FEngine.Stats.Requests = AExpected;
end;

function TEngineOverlapTests.WaitForCompleted(const AExpected: Integer): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + WAIT_MILLISECONDS;

  while (CompletedCount <> AExpected) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  Result := CompletedCount = AExpected;
end;

{ Order on a file }

procedure TEngineOverlapTests.WriteThenRead_ReadSeesTheWrite;
const
  ROUNDS = 200;
  SIZE = 4096;
var
  LFile: THandle;
  LOut: TBytes;
  LIn: TBytes;
  LWrite: TIORingRequestHandle;
  LRead: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LRound: Integer;
begin
  FEngine := TIORingEngine.Create(64, 16, 2, orKeepOrder);
  LFile := FResources.CreateNewFile;
  SetLength(LOut, SIZE);
  SetLength(LIn, SIZE);

  for LRound := 1 to ROUNDS do
  begin
    // Started together, not waited for in between
    FillChar(LOut[0], SIZE, Byte(LRound));
    LWrite := FEngine.WriteAsync(LFile, LOut[0], SIZE, 0);
    LRead := FEngine.ReadAsync(LFile, LIn[0], SIZE, 0);
    AssertTrue('Read', FEngine.Wait(LRead, LCompletion) and LCompletion.Succeeded);
    AssertTrue('Write', FEngine.Wait(LWrite, LCompletion) and LCompletion.Succeeded);
    AssertTrue(Format('Round %d: the read missed the write', [LRound]), CompareMem(@LOut[0], @LIn[0], SIZE));
  end;
end;

procedure TEngineOverlapTests.WriteThenWrite_TheLaterOneWins;
const
  ROUNDS = 200;
  SIZE = 8192;
var
  LFile: THandle;
  LFirst: TBytes;
  LSecond: TBytes;
  LIn: TBytes;
  LHandles: array[0..1] of TIORingRequestHandle;
  LCompletions: array[0..1] of TIORingCompletion;
  LCompletion: TIORingCompletion;
  LRound: Integer;
  LIndex: Integer;
begin
  FEngine := TIORingEngine.Create(64, 16, 2, orKeepOrder);
  LFile := FResources.CreateNewFile;
  SetLength(LFirst, SIZE);
  SetLength(LSecond, SIZE);
  SetLength(LIn, SIZE + SIZE div 2);

  for LRound := 1 to ROUNDS do
  begin
    // The second write covers the second half of the first one
    FillChar(LFirst[0], SIZE, Byte(LRound));
    FillChar(LSecond[0], SIZE, Byte(LRound + 100));
    LHandles[0] := FEngine.WriteAsync(LFile, LFirst[0], SIZE, 0);
    LHandles[1] := FEngine.WriteAsync(LFile, LSecond[0], SIZE, SIZE div 2);
    FEngine.WaitAll(LHandles, LCompletions);
    AssertTrue('Writes', LCompletions[0].Succeeded and LCompletions[1].Succeeded);
    AssertTrue('Read', FEngine.Wait(FEngine.ReadAsync(LFile, LIn[0], Length(LIn), 0), LCompletion) and
      LCompletion.Succeeded);

    for LIndex := 0 to High(LIn) do
      if (LIndex < SIZE div 2) and (LIn[LIndex] <> Byte(LRound)) or
        (LIndex >= SIZE div 2) and (LIn[LIndex] <> Byte(LRound + 100)) then
        Fail(Format('Round %d: wrong byte at %d', [LRound, LIndex]));
  end;
end;

procedure TEngineOverlapTests.ReadThenWrite_ReadSeesTheOldData;
const
  ROUNDS = 200;
  SIZE = 4096;
var
  LFile: THandle;
  LOut: TBytes;
  LIn: TBytes;
  LRead: TIORingRequestHandle;
  LWrite: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LRound: Integer;
  LIndex: Integer;
begin
  FEngine := TIORingEngine.Create(64, 16, 2, orKeepOrder);
  LFile := FResources.CreateNewFile;
  SetLength(LOut, SIZE);
  SetLength(LIn, SIZE);
  FillChar(LOut[0], SIZE, 0);
  AssertTrue('First write', FEngine.Wait(FEngine.WriteAsync(LFile, LOut[0], SIZE, 0), LCompletion));

  for LRound := 1 to ROUNDS do
  begin
    // The file holds Byte(LRound - 1); the read is started before the write
    FillChar(LOut[0], SIZE, Byte(LRound));
    LRead := FEngine.ReadAsync(LFile, LIn[0], SIZE, 0);
    LWrite := FEngine.WriteAsync(LFile, LOut[0], SIZE, 0);
    AssertTrue('Read', FEngine.Wait(LRead, LCompletion) and LCompletion.Succeeded);
    AssertTrue('Write', FEngine.Wait(LWrite, LCompletion) and LCompletion.Succeeded);

    for LIndex := 0 to SIZE - 1 do
      if LIn[LIndex] <> Byte(LRound - 1) then
        Fail(Format('Round %d: the read saw the later write at %d', [LRound, LIndex]));
  end;
end;

{ Exact cases with pipes }

procedure TEngineOverlapTests.PendingRead_HoldsBackAWriteOfTheSameBytes;
var
  LServer: THandle;
  LClient: THandle;
  LIn: Byte;
  LOut: Byte;
  LRead: TIORingRequestHandle;
  LWrite: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  LIn := 0;
  LOut := 7;
  LRead := FEngine.ReadAsync(LClient, LIn, 1, 0);          // pending: no data yet
  LWrite := FEngine.WriteAsync(LClient, LOut, 1, 0);       // same bytes: must wait
  AssertTrue('The write is held back', WaitForHeldBack(1));
  Sleep(50);
  AssertFalse('The write waits for the read', FEngine.TryGetResult(LWrite, LCompletion));

  WriteByteToPipe(LServer, 42);
  AssertTrue('Read', FEngine.Wait(LRead, LCompletion, 5000) and LCompletion.Succeeded);
  AssertEquals('Read data', 42, LIn);
  AssertTrue('Then the write', FEngine.Wait(LWrite, LCompletion, 5000) and LCompletion.Succeeded);
end;

procedure TEngineOverlapTests.ReadsDoNotWaitForReads;
var
  LServer: THandle;
  LClient: THandle;
  LIn: array[0..1] of Byte;
  LHandles: array[0..1] of TIORingRequestHandle;
  LCompletions: array[0..1] of TIORingCompletion;
begin
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  LHandles[0] := FEngine.ReadAsync(LClient, LIn[0], 1, 0);
  LHandles[1] := FEngine.ReadAsync(LClient, LIn[1], 1, 0);
  AssertTrue('Both taken', WaitForRequests(2));
  CheckEqualsU64('Nothing held back', 0, FEngine.Stats.HeldBack);
  WriteByteToPipe(LServer, 1);
  WriteByteToPipe(LServer, 2);
  FEngine.WaitAll(LHandles, LCompletions);
  AssertTrue('Both reads', LCompletions[0].Succeeded and LCompletions[1].Succeeded);
end;

{$IFDEF MSWINDOWS}
procedure TEngineOverlapTests.OtherBytes_DoNotWait;
var
  LServer: THandle;
  LClient: THandle;
  LIn: Byte;
  LOut: Byte;
  LRead: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  LOut := 5;
  LRead := FEngine.ReadAsync(LClient, LIn, 1, 0);
  // Bytes 100..100: not the read's
  AssertTrue('The write runs while the read is pending',
    FEngine.Wait(FEngine.WriteAsync(LClient, LOut, 1, 100), LCompletion, 5000) and LCompletion.Succeeded);
  CheckEqualsU64('Nothing held back', 0, FEngine.Stats.HeldBack);
  AssertFalse('The read is still pending', FEngine.TryGetResult(LRead, LCompletion));
  WriteByteToPipe(LServer, 1);
  AssertTrue('Read', FEngine.Wait(LRead, LCompletion, 5000));
end;
{$ENDIF}

procedure TEngineOverlapTests.HeldBackRequests_StartInOrder;
var
  LServer: THandle;
  LClient: THandle;
  LIn: array[0..1] of Byte;
  LOut: array[0..1] of Byte;
begin
  { Read 1 (pending) < write 2 (waits for 1) < read 3 (waits for 2) < write 4 (waits for 2 and 3); all
    on bytes 0..0 of one handle }
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  LOut[0] := 2;
  LOut[1] := 4;
  FEngine.ReadAsync(LClient, LIn[0], 1, 0, 1, RecordCompletion);
  FEngine.WriteAsync(LClient, LOut[0], 1, 0, 2, RecordCompletion);
  FEngine.ReadAsync(LClient, LIn[1], 1, 0, 3, RecordCompletion);
  FEngine.WriteAsync(LClient, LOut[1], 1, 0, 4, RecordCompletion);
  AssertTrue('Three held back', WaitForHeldBack(3));
  AssertEquals('Nothing completed yet', 0, CompletedCount);

  // Read 1 completes; write 2 starts and completes; read 3 starts (pending)
  WriteByteToPipe(LServer, 10);
  AssertTrue('Read 1 and write 2', WaitForCompleted(2));
  Sleep(50);
  AssertEquals('Write 4 waits for read 3', 2, CompletedCount);
  // Read 3 completes; then write 4
  WriteByteToPipe(LServer, 30);
  AssertTrue('All four', WaitForCompleted(4));
  CheckEqualsU64('First', 1, FOrder[0]);
  CheckEqualsU64('Second', 2, FOrder[1]);
  CheckEqualsU64('Third', 3, FOrder[2]);
  CheckEqualsU64('Fourth', 4, FOrder[3]);
  AssertEquals('Read 1 data', 10, LIn[0]);
  AssertEquals('Read 3 data', 30, LIn[1]);
end;

{$IFDEF MSWINDOWS}
procedure TEngineOverlapTests.Flush_WaitsForAnEarlierWrite;
const
  SIZE = 8192;    // more than the pipe's buffer of 4 KiB: the write stays pending
var
  LServer: THandle;
  LClient: THandle;
  LOut: TBytes;
begin
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  SetLength(LOut, SIZE);
  FEngine.WriteAsync(LClient, LOut[0], SIZE, 0, 1, RecordCompletion);
  FEngine.FlushAsync(LClient, rfmDefault, 2, RecordCompletion);
  AssertTrue('The flush is held back', WaitForHeldBack(1));
  Sleep(50);
  AssertEquals('The write is pending, the flush waits', 0, CompletedCount);

  ReadFromPipe(LServer, SIZE);
  AssertTrue('Write, then flush', WaitForCompleted(2));
  CheckEqualsU64('The write first', 1, FOrder[0]);
  CheckEqualsU64('Then the flush', 2, FOrder[1]);
end;
{$ENDIF}

procedure TEngineOverlapTests.Destroy_CancelsHeldBackRequests;
var
  LServer: THandle;
  LClient: THandle;
  LIn: Byte;
  LOut: array[0..2] of Byte;
  LIndex: Integer;
begin
  FEngine := TIORingEngine.Create(16, 8, 2, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  FillChar(LOut, SizeOf(LOut), 3);
  FEngine.ReadAsync(LClient, LIn, 1, 0, 100, RecordCompletion);

  for LIndex := 0 to 2 do
    FEngine.WriteAsync(LClient, LOut[LIndex], 1, 0, LIndex, RecordCompletion);

  AssertTrue('Three held back', WaitForHeldBack(3));

  FreeAndNil(FEngine);    // returns only when all have completed
  AssertEquals('Every request completed', 4, CompletedCount);
  AssertEquals('As cancelled', 4, FCancelledCount);
end;

procedure TEngineOverlapTests.RuleOff_NothingIsHeldBack;
var
  LServer: THandle;
  LClient: THandle;
  LIn: Byte;
  LOut: Byte;
  LRead: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create(16, 8, 1, orNone);
  FResources.OpenPipePair(LServer, LClient);
  LOut := 9;
  LRead := FEngine.ReadAsync(LClient, LIn, 1, 0);
  AssertTrue('Without the rule the write does not wait',
    FEngine.Wait(FEngine.WriteAsync(LClient, LOut, 1, 0), LCompletion, 5000) and LCompletion.Succeeded);
  CheckEqualsU64('Nothing held back', 0, FEngine.Stats.HeldBack);
  WriteByteToPipe(LServer, 1);
  AssertTrue('Read', FEngine.Wait(LRead, LCompletion, 5000));
end;

{ Routing }

procedure TEngineOverlapTests.OneHandle_UsesOneIOThread;
var
  LFile: THandle;
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
  LBusy: Integer;
begin
  FEngine := TIORingEngine.Create(64, 16, 4, orKeepOrder);
  LFile := FResources.CreateNewFile;
  FillChar(LBuffer, SizeOf(LBuffer), 1);
  FEngine.BeginBatch;

  try
    for LIndex := 0 to 49 do
      FEngine.WriteAsync(LFile, LBuffer, SizeOf(LBuffer), UInt64(LIndex) * SizeOf(LBuffer), 0, RecordCompletion);
  finally
    FEngine.EndBatch;
  end;

  for LIndex := 0 to 49 do
    AssertTrue('Read', FEngine.Wait(FEngine.ReadAsync(LFile, LBuffer, SizeOf(LBuffer),
      UInt64(LIndex) * SizeOf(LBuffer)), LCompletion) and LCompletion.Succeeded);

  LBusy := 0;

  for LIndex := 0 to FEngine.IOThreadCount - 1 do
    if FEngine.IOThreadStats(LIndex).Requests > 0 then
      Inc(LBusy);

  AssertEquals('All requests of the handle on one I/O thread', 1, LBusy);
end;

{ Against a model }

function TEngineOverlapTests.RunModel(const AFile: THandle; const ARegion: UInt64; const ASeed: Cardinal): Integer;

  // Waits for the request; True if it completed with the right result (and a read with the model's data)
  function FinishedRight(var AOperation: TModelOperation): Boolean;
  var
    LCompletion: TIORingCompletion;
  begin
    Result := FEngine.Wait(AOperation.Handle, LCompletion) and LCompletion.Succeeded
      and (LCompletion.BytesTransferred = AOperation.Count)
      and (AOperation.IsWrite or CompareMem(@AOperation.Data[0], @AOperation.Expected[0], AOperation.Count));
  end;

var
  LModel: TBytes;
  LOperations: array[0..MODEL_IN_FLIGHT - 1] of TModelOperation;
  LRandom: Cardinal;
  LIndex: Integer;
  LSlot: Integer;
  LByte: Integer;
  LCompletion: TIORingCompletion;
  LWrong: Integer;
begin
  LWrong := 0;
  LRandom := ASeed;
  SetLength(LModel, MODEL_SIZE);
  FillChar(LModel[0], MODEL_SIZE, 0);

  if not FEngine.Wait(FEngine.WriteAsync(AFile, LModel[0], MODEL_SIZE, ARegion), LCompletion) or
    not LCompletion.Succeeded then

    Exit(1);

  for LIndex := 0 to MODEL_OPERATIONS + MODEL_IN_FLIGHT - 1 do
  begin
    { In batches of MODEL_BATCH: more than an I/O thread's share, so that a sibling helps and requests run on two
      threads at once. (The request waited for below is MODEL_IN_FLIGHT > MODEL_BATCH older: never in the open batch.) }
    if (LIndex mod MODEL_BATCH = 0) and (LIndex < MODEL_OPERATIONS) then
      FEngine.BeginBatch;

    LSlot := LIndex mod MODEL_IN_FLIGHT;

    if (LIndex >= MODEL_IN_FLIGHT) and not FinishedRight(LOperations[LSlot]) then
      Inc(LWrong);

    if LIndex >= MODEL_OPERATIONS then
      Continue;

    // A new request, never waited for before the next ones start
    LOperations[LSlot].IsWrite := Odd(NextRandom(LRandom));
    LOperations[LSlot].Offset := NextRandom(LRandom) mod MODEL_SIZE;
    LOperations[LSlot].Count := 1 + NextRandom(LRandom) mod MODEL_MAX_LENGTH;

    if LOperations[LSlot].Count > MODEL_SIZE - LOperations[LSlot].Offset then
      LOperations[LSlot].Count := MODEL_SIZE - LOperations[LSlot].Offset;

    SetLength(LOperations[LSlot].Data, LOperations[LSlot].Count);

    if LOperations[LSlot].IsWrite then
    begin
      for LByte := 0 to LOperations[LSlot].Count - 1 do
        LOperations[LSlot].Data[LByte] := Byte(NextRandom(LRandom));

      Move(LOperations[LSlot].Data[0], LModel[LOperations[LSlot].Offset], LOperations[LSlot].Count);
      LOperations[LSlot].Handle := FEngine.WriteAsync(AFile, LOperations[LSlot].Data[0], LOperations[LSlot].Count,
        ARegion + LOperations[LSlot].Offset);
    end
    else
    begin
      LOperations[LSlot].Expected := Copy(LModel, LOperations[LSlot].Offset, LOperations[LSlot].Count);
      LOperations[LSlot].Handle := FEngine.ReadAsync(AFile, LOperations[LSlot].Data[0], LOperations[LSlot].Count,
        ARegion + LOperations[LSlot].Offset);
    end;

    if (LIndex mod MODEL_BATCH = MODEL_BATCH - 1) or (LIndex = MODEL_OPERATIONS - 1) then
      FEngine.EndBatch;
  end;

  Result := LWrong;
end;

procedure TEngineOverlapTests.WorkModel(AIndex: Integer);
begin
  TAtomic.FetchAdd(FFailures, RunModel(FModelFile, UInt64(AIndex) * MODEL_SIZE, Cardinal(AIndex + 1) * 7919));
end;

procedure TEngineOverlapTests.Model_RandomReadsAndWrites;
begin
  FEngine := TIORingEngine.Create(64, 32, 4, orKeepOrder);
  AssertEquals('Requests with wrong results or data', 0, RunModel(FResources.CreateNewFile, 0, 20261023));
  AssertTrue('Some requests had to wait', FEngine.Stats.HeldBack > 0);
end;

procedure TEngineOverlapTests.Model_FourProducersOnOneHandle;
begin
  { Each producer has its own part of the file and its own model; all go through one handle, so through
    one I/O thread and one list }
  FEngine := TIORingEngine.Create(MODEL_PRODUCERS * MODEL_IN_FLIGHT + 8, 64, 4, orKeepOrder);
  FModelFile := FResources.CreateNewFile;
  RunThreads(MODEL_PRODUCERS, WorkModel);
  AssertEquals('Requests with wrong results or data', 0, FFailures);
end;

initialization
  RegisterTests(TEngineOverlapTests);

end.
