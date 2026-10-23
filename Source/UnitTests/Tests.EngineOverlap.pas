unit Tests.EngineOverlap;

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

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Delphi.IOUring,
  Delphi.IOUring.Engine,
  TestPlatformHelpers;

type
  [TestFixture]
  TEngineOverlapTests = class
  private
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFailures: Integer;
    // Filled by RecordCompletion: the UserData of the completed requests, in
    // the order they completed
    FOrder: TArray<NativeUInt>;
    FOrderCount: Integer;
    FCancelledCount: Integer;
    procedure RecordCompletion(const ACompletion: TIORingCompletion);
    function WaitUntil(const ACondition: TFunc<Boolean>; const ATimeoutMilliseconds: Cardinal = 5000): Boolean;
    function CompletedCount: Integer;
    // Random reads and writes in [ARegion, ARegion + MODEL_SIZE) of AFile,
    // checked against a model; returns the number of wrong results
    function RunModel(const AFile: THandle; const ARegion: UInt64; const ASeed: Cardinal): Integer;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // Order on a file
    [Test]
    procedure WriteThenRead_ReadSeesTheWrite;
    [Test]
    procedure WriteThenWrite_TheLaterOneWins;
    [Test]
    procedure ReadThenWrite_ReadSeesTheOldData;

    // Exact cases with pipes
    [Test]
    procedure PendingRead_HoldsBackAWriteOfTheSameBytes;
    [Test]
    procedure ReadsDoNotWaitForReads;
    [Test]
    procedure OtherBytes_DoNotWait;
    [Test]
    procedure HeldBackRequests_StartInOrder;
    [Test]
    procedure Flush_WaitsForAnEarlierWrite;
    [Test]
    procedure Destroy_CancelsHeldBackRequests;
    [Test]
    procedure RuleOff_NothingIsHeldBack;

    // Routing
    [Test]
    procedure OneHandle_UsesOneIOThread;

    // Against a model
    [Test]
    procedure Model_RandomReadsAndWrites;
    [Test]
    procedure Model_FourProducersOnOneHandle;
  end;

implementation

uses
  Winapi.Windows,
  System.Diagnostics,
  Delphi.IOUring.Atomics,
  TestThreadHelpers;

const
  MODEL_SIZE = 64 * 1024;
  MODEL_OPERATIONS = 4000;
  MODEL_IN_FLIGHT = 32;
  MODEL_BATCH = 24;
  MODEL_MAX_LENGTH = 8192;
  MODEL_PRODUCERS = 4;

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

// Reads ACount bytes from the server end of a pipe (waits for them)
procedure ReadFromPipe(const APipe: THandle; const ACount: Cardinal);
var
  LBuffer: TBytes;
  LRead: DWORD;
  LTotal: Cardinal;
  LOverlapped: TOverlapped;
begin
  SetLength(LBuffer, ACount);
  LTotal := 0;
  while LTotal < ACount do
  begin
    FillChar(LOverlapped, SizeOf(LOverlapped), 0);
    LOverlapped.hEvent := CreateEvent(nil, True, False, nil);
    try
      if not ReadFile(APipe, LBuffer[LTotal], ACount - LTotal, LRead, @LOverlapped) then
        if GetLastError <> ERROR_IO_PENDING then
          RaiseLastOSError;
      if not GetOverlappedResult(APipe, LOverlapped, LRead, True) then
        RaiseLastOSError;
    finally
      CloseHandle(LOverlapped.hEvent);
    end;
    Inc(LTotal, LRead);
  end;
end;

{ TEngineOverlapTests }

procedure TEngineOverlapTests.Setup;
begin
  FResources := TTestResources.Create;
  FEngine := nil;
  FFailures := 0;
  SetLength(FOrder, 64);
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

function TEngineOverlapTests.WaitUntil(const ACondition: TFunc<Boolean>;
  const ATimeoutMilliseconds: Cardinal): Boolean;
var
  LWatch: TStopwatch;
begin
  LWatch := TStopwatch.StartNew;
  repeat
    if ACondition() then
      Exit(True);
    Sleep(1);
  until LWatch.ElapsedMilliseconds > ATimeoutMilliseconds;
  Result := ACondition();
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
    Assert.IsTrue(FEngine.Wait(LRead, LCompletion) and LCompletion.Succeeded, 'Read');
    Assert.IsTrue(FEngine.Wait(LWrite, LCompletion) and LCompletion.Succeeded, 'Write');
    Assert.IsTrue(CompareMem(@LOut[0], @LIn[0], SIZE), Format('Round %d: the read missed the write', [LRound]));
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
    Assert.IsTrue(LCompletions[0].Succeeded and LCompletions[1].Succeeded, 'Writes');
    Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(LFile, LIn[0], Length(LIn), 0), LCompletion) and
      LCompletion.Succeeded, 'Read');
    for LIndex := 0 to High(LIn) do
      if (LIndex < SIZE div 2) and (LIn[LIndex] <> Byte(LRound)) or
        (LIndex >= SIZE div 2) and (LIn[LIndex] <> Byte(LRound + 100)) then
        Assert.Fail(Format('Round %d: wrong byte at %d', [LRound, LIndex]));
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
  Assert.IsTrue(FEngine.Wait(FEngine.WriteAsync(LFile, LOut[0], SIZE, 0), LCompletion), 'First write');
  for LRound := 1 to ROUNDS do
  begin
    // The file holds Byte(LRound - 1); the read is started before the write
    FillChar(LOut[0], SIZE, Byte(LRound));
    LRead := FEngine.ReadAsync(LFile, LIn[0], SIZE, 0);
    LWrite := FEngine.WriteAsync(LFile, LOut[0], SIZE, 0);
    Assert.IsTrue(FEngine.Wait(LRead, LCompletion) and LCompletion.Succeeded, 'Read');
    Assert.IsTrue(FEngine.Wait(LWrite, LCompletion) and LCompletion.Succeeded, 'Write');
    for LIndex := 0 to SIZE - 1 do
      if LIn[LIndex] <> Byte(LRound - 1) then
        Assert.Fail(Format('Round %d: the read saw the later write at %d', [LRound, LIndex]));
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
  LOut := 7;
  LRead := FEngine.ReadAsync(LClient, LIn, 1, 0);          // pending: no data yet
  LWrite := FEngine.WriteAsync(LClient, LOut, 1, 0);       // same bytes: must wait
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.HeldBack = 1;
    end), 'The write is held back');
  Sleep(50);
  Assert.IsFalse(FEngine.TryGetResult(LWrite, LCompletion), 'The write waits for the read');

  WriteByteToPipe(LServer, 42);
  Assert.IsTrue(FEngine.Wait(LRead, LCompletion, 5000) and LCompletion.Succeeded, 'Read');
  Assert.AreEqual<Byte>(42, LIn, 'Read data');
  Assert.IsTrue(FEngine.Wait(LWrite, LCompletion, 5000) and LCompletion.Succeeded, 'Then the write');
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
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.Requests = 2;
    end), 'Both taken');
  Assert.AreEqual<UInt64>(0, FEngine.Stats.HeldBack, 'Nothing held back');
  WriteByteToPipe(LServer, 1);
  WriteByteToPipe(LServer, 2);
  FEngine.WaitAll(LHandles, LCompletions);
  Assert.IsTrue(LCompletions[0].Succeeded and LCompletions[1].Succeeded, 'Both reads');
end;

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
  Assert.IsTrue(FEngine.Wait(FEngine.WriteAsync(LClient, LOut, 1, 100), LCompletion, 5000) and
    LCompletion.Succeeded, 'The write runs while the read is pending');
  Assert.AreEqual<UInt64>(0, FEngine.Stats.HeldBack, 'Nothing held back');
  Assert.IsFalse(FEngine.TryGetResult(LRead, LCompletion), 'The read is still pending');
  WriteByteToPipe(LServer, 1);
  Assert.IsTrue(FEngine.Wait(LRead, LCompletion, 5000), 'Read');
end;

procedure TEngineOverlapTests.HeldBackRequests_StartInOrder;
var
  LServer: THandle;
  LClient: THandle;
  LIn: array[0..1] of Byte;
  LOut: array[0..1] of Byte;
begin
  // Read 1 (pending) < write 2 (waits for 1) < read 3 (waits for 2) <
  // write 4 (waits for 2 and 3); all on bytes 0..0 of one handle
  FEngine := TIORingEngine.Create(16, 8, 1, orKeepOrder);
  FResources.OpenPipePair(LServer, LClient);
  LOut[0] := 2;
  LOut[1] := 4;
  FEngine.ReadAsync(LClient, LIn[0], 1, 0, 1, RecordCompletion);
  FEngine.WriteAsync(LClient, LOut[0], 1, 0, 2, RecordCompletion);
  FEngine.ReadAsync(LClient, LIn[1], 1, 0, 3, RecordCompletion);
  FEngine.WriteAsync(LClient, LOut[1], 1, 0, 4, RecordCompletion);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.HeldBack = 3;
    end), 'Three held back');
  Assert.AreEqual(0, CompletedCount, 'Nothing completed yet');

  // Read 1 completes; write 2 starts and completes; read 3 starts (pending)
  WriteByteToPipe(LServer, 10);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := CompletedCount = 2;
    end), 'Read 1 and write 2');
  Sleep(50);
  Assert.AreEqual(2, CompletedCount, 'Write 4 waits for read 3');
  // Read 3 completes; then write 4
  WriteByteToPipe(LServer, 30);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := CompletedCount = 4;
    end), 'All four');
  Assert.AreEqual<NativeUInt>(1, FOrder[0], 'First');
  Assert.AreEqual<NativeUInt>(2, FOrder[1], 'Second');
  Assert.AreEqual<NativeUInt>(3, FOrder[2], 'Third');
  Assert.AreEqual<NativeUInt>(4, FOrder[3], 'Fourth');
  Assert.AreEqual<Byte>(10, LIn[0], 'Read 1 data');
  Assert.AreEqual<Byte>(30, LIn[1], 'Read 3 data');
end;

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
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.HeldBack = 1;
    end), 'The flush is held back');
  Sleep(50);
  Assert.AreEqual(0, CompletedCount, 'The write is pending, the flush waits');

  ReadFromPipe(LServer, SIZE);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := CompletedCount = 2;
    end), 'Write, then flush');
  Assert.AreEqual<NativeUInt>(1, FOrder[0], 'The write first');
  Assert.AreEqual<NativeUInt>(2, FOrder[1], 'Then the flush');
end;

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
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.HeldBack = 3;
    end), 'Three held back');

  FreeAndNil(FEngine);    // returns only when all have completed
  Assert.AreEqual(4, CompletedCount, 'Every request completed');
  Assert.AreEqual(4, FCancelledCount, 'As cancelled');
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
  Assert.IsTrue(FEngine.Wait(FEngine.WriteAsync(LClient, LOut, 1, 0), LCompletion, 5000) and
    LCompletion.Succeeded, 'Without the rule the write does not wait');
  Assert.AreEqual<UInt64>(0, FEngine.Stats.HeldBack, 'Nothing held back');
  WriteByteToPipe(LServer, 1);
  Assert.IsTrue(FEngine.Wait(LRead, LCompletion, 5000), 'Read');
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
    Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(LFile, LBuffer, SizeOf(LBuffer), UInt64(LIndex) * SizeOf(LBuffer)),
      LCompletion) and LCompletion.Succeeded, 'Read');
  LBusy := 0;
  for LIndex := 0 to FEngine.IOThreadCount - 1 do
    if FEngine.IOThreadStats(LIndex).Requests > 0 then
      Inc(LBusy);
  Assert.AreEqual(1, LBusy, 'All requests of the handle on one I/O thread');
end;

{ Against a model }

function TEngineOverlapTests.RunModel(const AFile: THandle; const ARegion: UInt64; const ASeed: Cardinal): Integer;
var
  LModel: TBytes;
  LOperations: array[0..MODEL_IN_FLIGHT - 1] of TModelOperation;
  LRandom: Cardinal;
  LIndex: Integer;
  LSlot: Integer;
  LByte: Integer;
  LCompletion: TIORingCompletion;
  LWrong: Integer;

  procedure Finish(var AOperation: TModelOperation);
  begin
    if not FEngine.Wait(AOperation.Handle, LCompletion) or not LCompletion.Succeeded or
      (LCompletion.BytesTransferred <> AOperation.Count) then
      Inc(LWrong)
    else if not AOperation.IsWrite and not CompareMem(@AOperation.Data[0], @AOperation.Expected[0],
      AOperation.Count) then
      Inc(LWrong);
  end;

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
    // In batches of MODEL_BATCH: more than an I/O thread's share, so that
    // a sibling helps and requests run on two threads at once. (The request
    // waited for below is MODEL_IN_FLIGHT > MODEL_BATCH older: never in the
    // open batch.)
    if (LIndex mod MODEL_BATCH = 0) and (LIndex < MODEL_OPERATIONS) then
      FEngine.BeginBatch;
    LSlot := LIndex mod MODEL_IN_FLIGHT;
    if LIndex >= MODEL_IN_FLIGHT then
      Finish(LOperations[LSlot]);
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

procedure TEngineOverlapTests.Model_RandomReadsAndWrites;
begin
  FEngine := TIORingEngine.Create(64, 32, 4, orKeepOrder);
  Assert.AreEqual(0, RunModel(FResources.CreateNewFile, 0, 20261023), 'Requests with wrong results or data');
  Assert.IsTrue(FEngine.Stats.HeldBack > 0, 'Some requests had to wait');
end;

procedure TEngineOverlapTests.Model_FourProducersOnOneHandle;
var
  LFile: THandle;
begin
  // Each producer has its own part of the file and its own model; all go
  // through one handle, so through one I/O thread and one list
  FEngine := TIORingEngine.Create(MODEL_PRODUCERS * MODEL_IN_FLIGHT + 8, 64, 4, orKeepOrder);
  LFile := FResources.CreateNewFile;
  RunThreads(MODEL_PRODUCERS,
    procedure(AThread: Integer)
    begin
      TAtomic.FetchAdd(FFailures, RunModel(LFile, UInt64(AThread) * MODEL_SIZE, Cardinal(AThread + 1) * 7919));
    end);
  Assert.AreEqual(0, FFailures, 'Requests with wrong results or data');
end;

initialization
  TDUnitX.RegisterTestFixture(TEngineOverlapTests);

end.
