unit Tests.Engine;

{
  Tests for TIORingEngine (Delphi.IOUring.Engine): reads, writes and flushes
  with their results; end of file and errors; Wait with a timeout,
  TryGetResult, WaitAll; callbacks on the I/O thread; batches; a full request
  pool; Destroy with requests in flight (they complete as cancelled, and a
  thread blocked in Wait wakes up); and stress with many producer threads
  doing random reads whose data is checked.

  Pipes give requests that stay pending until the test writes to the pipe.
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
  TIORingEngineTests = class
  private
    FPatternFileName: string;
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFile: THandle;                     // the pattern file
    // Filled by the callbacks
    FCallbackCount: Integer;
    FCallbackThreadId: TThreadID;
    FCallbackCompletion: TIORingCompletion;
    FCancelledCount: Integer;
    FFailures: Integer;
    // Pool-full test
    FThirdHandle: TIORingRequestHandle;
    FThirdStarted: Integer;
    FThirdBuffer: array[0..99] of Byte;
    // Callbacks
    procedure RecordCompletion(const ACompletion: TIORingCompletion);
    procedure RaiseInCallback(const ACompletion: TIORingCompletion);
    procedure CheckCallbackRead(const ACompletion: TIORingCompletion);
    procedure CheckData(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt);
    // Waits until ACondition is True (at most ATimeoutMilliseconds)
    function WaitUntil(const ACondition: TFunc<Boolean>; const ATimeoutMilliseconds: Cardinal = 5000): Boolean;
    // The stress tests, with AIOThreads I/O threads
    procedure RunManyProducers(const AIOThreads: Integer);
    procedure RunCallbacksAndWaits(const AIOThreads: Integer);
    // I/O threads that took at least one request
    function BusyIOThreads: Integer;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // Requests and results
    [Test]
    procedure Read_ReturnsDataAndUserData;
    [Test]
    procedure ManyReads_MoreThanTheRingHolds;
    [Test]
    procedure WriteFlushRead_RoundTrip;
    [Test]
    procedure EndOfFile_AtAndAcross;
    [Test]
    procedure BadFileHandle_CompletesWithError;

    // Waiting
    [Test]
    procedure Wait_Timeout_KeepsTheRequest;
    [Test]
    procedure TryGetResult_FalseUntilDone;
    [Test]
    procedure Wait_HandleNotValid_Raises;

    // Callbacks, batches, a full pool
    [Test]
    procedure Callback_RunsOnTheIOThread;
    [Test]
    procedure CallbackException_IsCaughtAndCounted;
    [Test]
    procedure Batch_GoesToTheRingInOneSubmit;
    [Test]
    procedure Batch_WithoutBegin_Raises;
    [Test]
    procedure FullPool_StartWaitsForAFreeRequest;
    [Test]
    procedure Stats_CountTheRequests;

    // Destroy
    [Test]
    procedure Destroy_CancelsRequestsInFlight;
    [Test]
    procedure Destroy_WakesAThreadInWait;
    [Test]
    procedure Destroy_IdleEngine_IsQuick;

    // Several I/O threads
    [Test]
    procedure IOThreads_BadCount_Raises;
    [Test]
    procedure IOThreads_ABacklogIsShared;
    [Test]
    procedure IOThreads_LightLoad_StaysOnOneThread;
    [Test]
    procedure IOThreads_Destroy_CancelsEverything;

    // Several producer threads
    [Test]
    procedure Stress_ManyProducers_RandomReads;
    [Test]
    procedure Stress_ManyProducers_FourIOThreads;
    [Test]
    procedure Stress_CallbacksAndWaitsMixed;
    [Test]
    procedure Stress_CallbacksAndWaitsMixed_FourIOThreads;
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
  MAX_READ_SIZE = 64 * 1024;

type
  // A callback read of the mixed stress test (UserData points to it)
  TCallbackRead = record
    Offset: UInt64;
    Count: Cardinal;
    Buffer: array[0..MAX_READ_SIZE - 1] of Byte;
  end;
  PCallbackRead = ^TCallbackRead;

// Waits for a read and checks it: success, all bytes, the right data
function ReadWasRight(const AEngine: TIORingEngine; const AHandle: TIORingRequestHandle;
  const AOffset: UInt64; const ABuffer: TBytes; const ACount: Cardinal): Boolean;
var
  LCompletion: TIORingCompletion;
  LBadOffset: UInt64;
begin
  Result := AEngine.Wait(AHandle, LCompletion) and LCompletion.Succeeded and
    (LCompletion.BytesTransferred = ACount) and
    TTestFileHelpers.CheckPattern(AOffset, ABuffer[0], ACount, LBadOffset);
end;

// Small random numbers per thread (Random is not thread-safe)
function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);
  Result := AState;
end;

{ TIORingEngineTests }

procedure TIORingEngineTests.SetupFixture;
begin
  FPatternFileName := TTestFileHelpers.CreatePatternFile(PATTERN_FILE_SIZE, 'EnginePattern');
end;

procedure TIORingEngineTests.TearDownFixture;
begin
  TTestFileHelpers.DeleteTestFile(FPatternFileName);
end;

procedure TIORingEngineTests.Setup;
begin
  FResources := TTestResources.Create;
  FFile := FResources.OpenFile(FPatternFileName);
  FEngine := nil;
  FCallbackCount := 0;
  FCallbackThreadId := 0;
  FCancelledCount := 0;
  FFailures := 0;
  FThirdStarted := 0;
end;

procedure TIORingEngineTests.TearDown;
begin
  // The engine first: it finishes every request before the handles close
  FreeAndNil(FEngine);
  FResources.Free;
  FResources := nil;
end;

procedure TIORingEngineTests.RecordCompletion(const ACompletion: TIORingCompletion);
begin
  FCallbackThreadId := TThread.CurrentThread.ThreadID;
  FCallbackCompletion := ACompletion;
  if ACompletion.IsCancelled then
    TAtomic.Increment(FCancelledCount);
  TAtomic.Increment(FCallbackCount);
end;

procedure TIORingEngineTests.RaiseInCallback(const ACompletion: TIORingCompletion);
begin
  TAtomic.Increment(FCallbackCount);
  raise Exception.Create('A callback that fails');
end;

procedure TIORingEngineTests.CheckCallbackRead(const ACompletion: TIORingCompletion);
var
  LRead: PCallbackRead;
  LBadOffset: UInt64;
begin
  LRead := PCallbackRead(ACompletion.UserData);
  if not ACompletion.Succeeded or (ACompletion.BytesTransferred <> LRead^.Count) or
    not TTestFileHelpers.CheckPattern(LRead^.Offset, LRead^.Buffer, LRead^.Count, LBadOffset) or
    not FEngine.IsIOThread(TThread.CurrentThread.ThreadID) then
    TAtomic.Increment(FFailures);
  Dispose(LRead);
  TAtomic.Increment(FCallbackCount);
end;

procedure TIORingEngineTests.CheckData(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt);
var
  LBadOffset: UInt64;
begin
  Assert.IsTrue(TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset),
    Format('Wrong data at file offset %d', [LBadOffset]));
end;

function TIORingEngineTests.WaitUntil(const ACondition: TFunc<Boolean>; const ATimeoutMilliseconds: Cardinal): Boolean;
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

function TIORingEngineTests.BusyIOThreads: Integer;
var
  LIndex: Integer;
begin
  Result := 0;
  for LIndex := 0 to FEngine.IOThreadCount - 1 do
    if FEngine.IOThreadStats(LIndex).Requests > 0 then
      Inc(Result);
end;

{ Requests and results }

procedure TIORingEngineTests.Read_ReturnsDataAndUserData;
var
  LBuffer: TBytes;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  SetLength(LBuffer, 10000);
  LHandle := FEngine.ReadAsync(FFile, LBuffer[0], 10000, 123457, 4242);
  Assert.IsFalse(LHandle.IsEmpty, 'A request without callback has a handle');
  Assert.IsTrue(FEngine.Wait(LHandle, LCompletion), 'Wait');
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
  Assert.AreEqual<NativeUInt>(10000, LCompletion.BytesTransferred, 'Bytes');
  Assert.AreEqual<NativeUInt>(4242, LCompletion.UserData, 'UserData comes back');
  CheckData(123457, @LBuffer[0], 10000);
end;

procedure TIORingEngineTests.ManyReads_MoreThanTheRingHolds;
const
  READS = 500;
  READ_SIZE = 4096;
var
  LBuffers: TBytes;
  LHandles: array[0..READS - 1] of TIORingRequestHandle;
  LCompletions: array[0..READS - 1] of TIORingCompletion;
  LIndex: Integer;
begin
  // A ring of 8 entries for 500 requests: most wait in the queue
  FEngine := TIORingEngine.Create(1024, 8);
  SetLength(LBuffers, READS * READ_SIZE);
  for LIndex := 0 to READS - 1 do
    LHandles[LIndex] := FEngine.ReadAsync(FFile, LBuffers[LIndex * READ_SIZE], READ_SIZE,
      UInt64(LIndex) * 7919, NativeUInt(LIndex));
  FEngine.WaitAll(LHandles, LCompletions);
  for LIndex := 0 to READS - 1 do
  begin
    Assert.IsTrue(LCompletions[LIndex].Succeeded, LCompletions[LIndex].ErrorMessage);
    Assert.AreEqual<NativeUInt>(READ_SIZE, LCompletions[LIndex].BytesTransferred);
    Assert.AreEqual<NativeUInt>(NativeUInt(LIndex), LCompletions[LIndex].UserData, 'UserData');
    CheckData(UInt64(LIndex) * 7919, @LBuffers[LIndex * READ_SIZE], READ_SIZE);
  end;
end;

procedure TIORingEngineTests.WriteFlushRead_RoundTrip;
const
  BLOCK = 4096;
var
  LFile: THandle;
  LOut: TBytes;
  LIn: TBytes;
  LHandles: array[0..2] of TIORingRequestHandle;
  LCompletions: array[0..2] of TIORingCompletion;
  LIndex: Integer;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  LFile := FResources.CreateNewFile;
  SetLength(LOut, 3 * BLOCK);
  TTestFileHelpers.FillPattern(0, LOut[0], Length(LOut));
  for LIndex := 0 to 2 do
    LHandles[LIndex] := FEngine.WriteAsync(LFile, LOut[LIndex * BLOCK], BLOCK, UInt64(LIndex) * BLOCK);
  FEngine.WaitAll(LHandles, LCompletions);
  for LIndex := 0 to 2 do
  begin
    Assert.IsTrue(LCompletions[LIndex].Succeeded, 'Write: ' + LCompletions[LIndex].ErrorMessage);
    Assert.AreEqual<NativeUInt>(BLOCK, LCompletions[LIndex].BytesTransferred, 'Written');
  end;

  Assert.IsTrue(FEngine.Wait(FEngine.FlushAsync(LFile), LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, 'Flush: ' + LCompletion.ErrorMessage);

  SetLength(LIn, 3 * BLOCK);
  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(LFile, LIn[0], Length(LIn), 0), LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, 'Read back: ' + LCompletion.ErrorMessage);
  Assert.AreEqual<NativeUInt>(3 * BLOCK, LCompletion.BytesTransferred, 'Read back');
  Assert.IsTrue(CompareMem(@LOut[0], @LIn[0], Length(LOut)), 'Same data');
end;

procedure TIORingEngineTests.EndOfFile_AtAndAcross;
var
  LBuffer: TBytes;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  SetLength(LBuffer, 4096);
  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer[0], 4096, PATTERN_FILE_SIZE), LCompletion));
  Assert.IsTrue(LCompletion.IsEndOfFile, 'At the end: ' + LCompletion.ErrorMessage);

  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer[0], 4096, PATTERN_FILE_SIZE - 100), LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, 'Across the end: ' + LCompletion.ErrorMessage);
  Assert.AreEqual<NativeUInt>(100, LCompletion.BytesTransferred, 'Only the rest of the file');
  CheckData(PATTERN_FILE_SIZE - 100, @LBuffer[0], 100);
  Assert.AreEqual<UInt64>(0, FEngine.Stats.Failed, 'End of file is not a failure');
end;

procedure TIORingEngineTests.BadFileHandle_CompletesWithError;
var
  LBuffer: array[0..99] of Byte;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  // No exception: the request completes, with the error
  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(0, LBuffer, SizeOf(LBuffer), 0, 9), LCompletion));
  Assert.IsFalse(LCompletion.Succeeded, 'Failed');
  Assert.AreEqual<NativeUInt>(9, LCompletion.UserData, 'UserData');
  Assert.AreEqual<UInt64>(1, FEngine.Stats.Failed, 'Counted as failed');
  // The engine goes on working
  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0), LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
end;

{ Waiting }

procedure TIORingEngineTests.Wait_Timeout_KeepsTheRequest;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LWatch: TStopwatch;
begin
  FEngine := TIORingEngine.Create;
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;
  LHandle := FEngine.ReadAsync(LClient, LByte, 1, 0);
  LWatch := TStopwatch.StartNew;
  Assert.IsFalse(FEngine.Wait(LHandle, LCompletion, 50), 'Times out');
  Assert.IsTrue(LWatch.ElapsedMilliseconds >= 45, Format('Waited only %d ms', [LWatch.ElapsedMilliseconds]));

  WriteByteToPipe(LServer, 42);
  Assert.IsTrue(FEngine.Wait(LHandle, LCompletion, 5000), 'Still valid, completes');
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
  Assert.AreEqual<NativeUInt>(1, LCompletion.BytesTransferred);
  Assert.AreEqual(Byte(42), LByte);
end;

procedure TIORingEngineTests.TryGetResult_FalseUntilDone;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;
  LHandle := FEngine.ReadAsync(LClient, LByte, 1, 0);
  Assert.IsFalse(FEngine.TryGetResult(LHandle, LCompletion), 'Pending');
  WriteByteToPipe(LServer, 7);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.TryGetResult(LHandle, LCompletion);
    end), 'Done after the write');
  Assert.AreEqual(Byte(7), LByte);
end;

procedure TIORingEngineTests.Wait_HandleNotValid_Raises;
var
  LBuffer: array[0..9] of Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  LHandle := FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0);
  Assert.IsTrue(FEngine.Wait(LHandle, LCompletion));
  Assert.WillRaise(
    procedure
    var
      LAgain: TIORingCompletion;
    begin
      FEngine.Wait(LHandle, LAgain);
    end, EIORingError, 'Second Wait for the same request');
  LHandle.Value := 0;
  Assert.WillRaise(
    procedure
    var
      LAgain: TIORingCompletion;
    begin
      FEngine.Wait(LHandle, LAgain);
    end, EIORingError, 'Empty handle');
end;

{ Callbacks, batches, a full pool }

procedure TIORingEngineTests.Callback_RunsOnTheIOThread;
var
  LBuffer: array[0..999] of Byte;
  LHandle: TIORingRequestHandle;
begin
  FEngine := TIORingEngine.Create;
  LHandle := FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 5000, 31, RecordCompletion);
  Assert.IsTrue(LHandle.IsEmpty, 'A request with a callback has no handle');
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := TAtomic.LoadAcquire(FCallbackCount) = 1;
    end), 'Callback called');
  Assert.IsTrue(FEngine.IsIOThread(FCallbackThreadId), 'On the I/O thread');
  Assert.IsTrue(FCallbackThreadId <> MainThreadID, 'Not on the main thread');
  Assert.IsTrue(FCallbackCompletion.Succeeded, FCallbackCompletion.ErrorMessage);
  Assert.AreEqual<NativeUInt>(31, FCallbackCompletion.UserData, 'UserData');
  Assert.AreEqual<NativeUInt>(SizeOf(LBuffer), FCallbackCompletion.BytesTransferred, 'Bytes');
  CheckData(5000, @LBuffer[0], SizeOf(LBuffer));
end;

procedure TIORingEngineTests.CallbackException_IsCaughtAndCounted;
var
  LBuffer: array[0..99] of Byte;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0, 0, RaiseInCallback);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.CallbackErrors = 1;
    end), 'Counted');
  // The I/O thread survived
  Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0), LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
end;

procedure TIORingEngineTests.Batch_GoesToTheRingInOneSubmit;
const
  READS = 20;
  READ_SIZE = 4096;
var
  LBuffers: TBytes;
  LHandles: array[0..READS - 1] of TIORingRequestHandle;
  LCompletions: array[0..READS - 1] of TIORingCompletion;
  LIndex: Integer;
  LSubmitsBefore: UInt64;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create(64, 64);
  SetLength(LBuffers, READS * READ_SIZE);
  Sleep(20);    // the I/O thread has fallen asleep
  LSubmitsBefore := FEngine.Stats.Submits;

  FEngine.BeginBatch;
  try
    for LIndex := 0 to READS - 1 do
      LHandles[LIndex] := FEngine.ReadAsync(FFile, LBuffers[LIndex * READ_SIZE], READ_SIZE,
        UInt64(LIndex) * READ_SIZE);
    Sleep(50);
    Assert.IsFalse(FEngine.TryGetResult(LHandles[0], LCompletion), 'Not started before EndBatch');
  finally
    FEngine.EndBatch;
  end;

  FEngine.WaitAll(LHandles, LCompletions);
  for LIndex := 0 to READS - 1 do
  begin
    Assert.IsTrue(LCompletions[LIndex].Succeeded, LCompletions[LIndex].ErrorMessage);
    CheckData(UInt64(LIndex) * READ_SIZE, @LBuffers[LIndex * READ_SIZE], READ_SIZE);
  end;
  Assert.AreEqual<UInt64>(1, FEngine.Stats.Submits - LSubmitsBefore, 'All 20 in one submit');
end;

procedure TIORingEngineTests.Batch_WithoutBegin_Raises;
var
  LOther: TIORingEngine;
begin
  FEngine := TIORingEngine.Create(16, 8);
  Assert.WillRaise(
    procedure
    begin
      FEngine.EndBatch;
    end, EIORingError, 'EndBatch without BeginBatch');

  LOther := TIORingEngine.Create(16, 8);
  try
    FEngine.BeginBatch;
    FEngine.BeginBatch;    // nested: fine
    Assert.WillRaise(
      procedure
      begin
        LOther.BeginBatch;
      end, EIORingError, 'Batch of another engine');
    FEngine.EndBatch;
    FEngine.EndBatch;
    LOther.BeginBatch;     // now fine
    LOther.EndBatch;
  finally
    LOther.Free;
  end;
end;

procedure TIORingEngineTests.FullPool_StartWaitsForAFreeRequest;
var
  LServer: array[0..1] of THandle;
  LClient: array[0..1] of THandle;
  LBytes: array[0..1] of Byte;
  LHandles: array[0..1] of TIORingRequestHandle;
  LThread: TThread;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
begin
  // Two requests at most, both pending on pipes
  FEngine := TIORingEngine.Create(2, 8);
  for LIndex := 0 to 1 do
  begin
    FResources.OpenPipePair(LServer[LIndex], LClient[LIndex]);
    LHandles[LIndex] := FEngine.ReadAsync(LClient[LIndex], LBytes[LIndex], 1, 0);
  end;

  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      FThirdHandle := FEngine.ReadAsync(FFile, FThirdBuffer, SizeOf(FThirdBuffer), 0);
      TAtomic.Exchange(FThirdStarted, 1);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(100);
    Assert.AreEqual(0, TAtomic.LoadAcquire(FThirdStarted), 'The third request waits for a free one');

    WriteByteToPipe(LServer[0], 1);
    Assert.IsTrue(FEngine.Wait(LHandles[0], LCompletion, 5000), 'First pipe read');
    // Its request is free now: the third one starts
    Assert.IsTrue(WaitUntil(
      function: Boolean
      begin
        Result := TAtomic.LoadAcquire(FThirdStarted) = 1;
      end), 'The third request started');
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.IsTrue(FEngine.Wait(FThirdHandle, LCompletion, 5000), 'Third request');
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
  CheckData(0, @FThirdBuffer[0], SizeOf(FThirdBuffer));
  // The second pipe read is still pending: TearDown's Destroy cancels it
end;

procedure TIORingEngineTests.Stats_CountTheRequests;
var
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
  LStats: TIORingEngineStats;
begin
  FEngine := TIORingEngine.Create;
  // An idle engine sleeps. (While requests keep coming it may never sleep:
  // the next one is there before it would - so Sleeps is checked here.)
  Sleep(20);
  Assert.IsTrue(FEngine.Stats.Sleeps >= 1, 'Sleeps when idle');
  for LIndex := 1 to 10 do
    FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), LIndex * 1000), LCompletion);
  FEngine.Wait(FEngine.ReadAsync(0, LBuffer, SizeOf(LBuffer), 0), LCompletion);   // fails
  LStats := FEngine.Stats;
  Assert.AreEqual<UInt64>(11, LStats.Requests, 'Requests');
  Assert.AreEqual<UInt64>(11, LStats.Completed, 'Completed');
  Assert.AreEqual<UInt64>(1, LStats.Failed, 'Failed');
  Assert.AreEqual<UInt64>(0, LStats.Cancelled, 'Cancelled');
  Assert.IsTrue(LStats.Submits >= 1, 'Submits');
  Assert.AreEqual<UInt64>(0, LStats.CallbackErrors, 'Callback errors');
end;

{ Destroy }

procedure TIORingEngineTests.Destroy_CancelsRequestsInFlight;
var
  LServer: array[0..2] of THandle;
  LClient: array[0..2] of THandle;
  LBytes: array[0..2] of Byte;
  LIndex: Integer;
begin
  FEngine := TIORingEngine.Create(16, 8);
  for LIndex := 0 to 2 do
  begin
    FResources.OpenPipePair(LServer[LIndex], LClient[LIndex]);
    FEngine.ReadAsync(LClient[LIndex], LBytes[LIndex], 1, 0, LIndex, RecordCompletion);
  end;
  Sleep(50);    // they are in the ring now
  Assert.AreEqual(0, TAtomic.LoadAcquire(FCallbackCount), 'Pending');

  FreeAndNil(FEngine);    // returns only when all three have completed
  Assert.AreEqual(3, FCallbackCount, 'Every request completed');
  Assert.AreEqual(3, FCancelledCount, 'As cancelled');
end;

procedure TIORingEngineTests.Destroy_WakesAThreadInWait;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LHandle: TIORingRequestHandle;
  LThread: TThread;
  LResult: TIORingCompletion;
  LWaited: Boolean;
begin
  FEngine := TIORingEngine.Create(16, 8);
  FResources.OpenPipePair(LServer, LClient);
  LHandle := FEngine.ReadAsync(LClient, LByte, 1, 0, 55);
  LWaited := False;
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      LWaited := FEngine.Wait(LHandle, LResult);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(50);    // it sleeps in Wait now
    FreeAndNil(FEngine);
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.IsTrue(LWaited, 'Wait returned with a result');
  Assert.IsTrue(LResult.IsCancelled, 'Cancelled: ' + LResult.ErrorMessage);
  Assert.AreEqual<NativeUInt>(55, LResult.UserData, 'UserData');
end;

procedure TIORingEngineTests.Destroy_IdleEngine_IsQuick;
var
  LWatch: TStopwatch;
begin
  FEngine := TIORingEngine.Create;
  Sleep(200);
  // Asleep, and it stays asleep: nothing wakes it without a reason
  Assert.IsTrue(FEngine.Stats.Sleeps <= 2, Format('Slept %d times when idle', [FEngine.Stats.Sleeps]));
  LWatch := TStopwatch.StartNew;
  FreeAndNil(FEngine);
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 1000, Format('Took %d ms', [LWatch.ElapsedMilliseconds]));
end;

{ Several I/O threads }

procedure TIORingEngineTests.IOThreads_BadCount_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TIORingEngine.Create(16, 8, 0).Free;
    end, EIORingError, '0 I/O threads');
  Assert.WillRaise(
    procedure
    begin
      TIORingEngine.Create(16, 8, IORING_ENGINE_MAX_IO_THREADS + 1).Free;
    end, EIORingError, 'Too many I/O threads');
  FEngine := TIORingEngine.Create(16, 8, 4);
  Assert.AreEqual(4, FEngine.IOThreadCount, 'IOThreadCount');
  Assert.WillRaise(
    procedure
    begin
      FEngine.IOThreadStats(4);
    end, EIORingError, 'No I/O thread 4');
end;

procedure TIORingEngineTests.IOThreads_ABacklogIsShared;
const
  READS = 2000;
  READ_SIZE = 4096;
  BLOCKS_IN_FILE = PATTERN_FILE_SIZE div READ_SIZE;
var
  LFile: THandle;
  LBuffers: PByte;
  LHandles: TArray<TIORingRequestHandle>;
  LCompletions: TArray<TIORingCompletion>;
  LIndex: Integer;
begin
  // Unbuffered reads: each costs the I/O thread several µs inside the submit
  // call, plus the disk's time. With cached reads one I/O thread sometimes
  // finished all of them before a woken sibling got the CPU (FPC, 3 of 25
  // runs), and the test failed for no fault of the engine.
  LFile := FResources.OpenFile(FPatternFileName, FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING);
  LBuffers := FResources.AllocPages(READS * READ_SIZE);
  FEngine := TIORingEngine.Create(READS, 64, 4);
  SetLength(LHandles, READS);
  SetLength(LCompletions, READS);
  Sleep(20);    // all I/O threads asleep
  // EndBatch wakes one I/O thread; it takes a share and wakes the next one,
  // which does the same
  FEngine.BeginBatch;
  try
    for LIndex := 0 to READS - 1 do
      LHandles[LIndex] := FEngine.ReadAsync(LFile, LBuffers[LIndex * READ_SIZE], READ_SIZE,
        UInt64(LIndex mod BLOCKS_IN_FILE) * READ_SIZE);
  finally
    FEngine.EndBatch;
  end;
  FEngine.WaitAll(LHandles, LCompletions);
  for LIndex := 0 to READS - 1 do
  begin
    Assert.IsTrue(LCompletions[LIndex].Succeeded, LCompletions[LIndex].ErrorMessage);
    CheckData(UInt64(LIndex mod BLOCKS_IN_FILE) * READ_SIZE, @LBuffers[LIndex * READ_SIZE], READ_SIZE);
  end;
  Assert.AreEqual<UInt64>(READS, FEngine.Stats.Requests, 'Requests of all I/O threads');
  Assert.IsTrue(BusyIOThreads >= 2, Format('%d I/O threads took requests', [BusyIOThreads]));
end;

procedure TIORingEngineTests.IOThreads_LightLoad_StaysOnOneThread;
const
  READS = 200;
var
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
begin
  FEngine := TIORingEngine.Create(16, 8, 4);
  Sleep(20);
  // One request at a time: the first I/O thread is enough, and the others
  // are not woken. (Rarely one is: a producer can come just while the first
  // one wakes up.)
  for LIndex := 1 to READS do
  begin
    Assert.IsTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), LIndex * 1000), LCompletion));
    Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
  end;
  Assert.IsTrue(FEngine.IOThreadStats(0).Requests >= READS * 9 div 10,
    Format('The first I/O thread took %d of %d', [FEngine.IOThreadStats(0).Requests, READS]));
end;

procedure TIORingEngineTests.IOThreads_Destroy_CancelsEverything;
const
  PIPES = 32;
var
  LServer: array[0..PIPES - 1] of THandle;
  LClient: array[0..PIPES - 1] of THandle;
  LBytes: array[0..PIPES - 1] of Byte;
  LIndex: Integer;
begin
  // Rings of 8: one ring cannot hold them all, so they spread over the I/O
  // threads (a thread with a full ring wakes a sibling)
  FEngine := TIORingEngine.Create(64, 8, 4);
  for LIndex := 0 to PIPES - 1 do
  begin
    FResources.OpenPipePair(LServer[LIndex], LClient[LIndex]);
    FEngine.ReadAsync(LClient[LIndex], LBytes[LIndex], 1, 0, LIndex, RecordCompletion);
  end;
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := FEngine.Stats.Requests = PIPES;
    end), 'All taken by the I/O threads');
  Assert.IsTrue(BusyIOThreads >= 2, Format('%d I/O threads took requests', [BusyIOThreads]));
  Assert.AreEqual(0, TAtomic.LoadAcquire(FCallbackCount), 'Pending');

  FreeAndNil(FEngine);    // returns only when all have completed
  Assert.AreEqual(PIPES, FCallbackCount, 'Every request completed');
  Assert.AreEqual(PIPES, FCancelledCount, 'As cancelled');
end;

{ Several producer threads }

procedure TIORingEngineTests.Stress_ManyProducers_RandomReads;
begin
  RunManyProducers(1);
end;

procedure TIORingEngineTests.Stress_ManyProducers_FourIOThreads;
begin
  RunManyProducers(4);
end;

procedure TIORingEngineTests.Stress_CallbacksAndWaitsMixed;
begin
  RunCallbacksAndWaits(1);
end;

procedure TIORingEngineTests.Stress_CallbacksAndWaitsMixed_FourIOThreads;
begin
  RunCallbacksAndWaits(4);
end;

procedure TIORingEngineTests.RunManyProducers(const AIOThreads: Integer);
const
  PRODUCERS = 8;
  READS_PER_PRODUCER = 1500;
  // Requests each producer keeps: 8 x 5 = 40 > 36 in the pool, so the pool
  // runs full and producers wait for a free request. But a producer keeps at
  // most 4 while it waits, and 8 x 4 < 36: one of them always gets a request.
  // (With 6 each it deadlocked: every request held by a producer that waited
  // for a new one.)
  IN_FLIGHT = 5;
begin
  FEngine := TIORingEngine.Create(36, 16, AIOThreads);
  RunThreads(PRODUCERS,
    procedure(AThread: Integer)
    var
      LBuffers: array[0..IN_FLIGHT - 1] of TBytes;
      LHandles: array[0..IN_FLIGHT - 1] of TIORingRequestHandle;
      LOffsets: array[0..IN_FLIGHT - 1] of UInt64;
      LCounts: array[0..IN_FLIGHT - 1] of Cardinal;
      LSlot: Integer;
      LRead: Integer;
      LRandom: Cardinal;
    begin
      LRandom := Cardinal(AThread + 1) * 2654435761;
      for LSlot := 0 to IN_FLIGHT - 1 do
        SetLength(LBuffers[LSlot], MAX_READ_SIZE);
      for LRead := 0 to READS_PER_PRODUCER - 1 do
      begin
        LSlot := LRead mod IN_FLIGHT;
        if (LRead >= IN_FLIGHT) and
          not ReadWasRight(FEngine, LHandles[LSlot], LOffsets[LSlot], LBuffers[LSlot], LCounts[LSlot]) then
          TAtomic.Increment(FFailures);
        LCounts[LSlot] := 1 + NextRandom(LRandom) mod MAX_READ_SIZE;
        LOffsets[LSlot] := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - LCounts[LSlot] + 1);
        LHandles[LSlot] := FEngine.ReadAsync(FFile, LBuffers[LSlot][0], LCounts[LSlot], LOffsets[LSlot]);
      end;
      for LSlot := 0 to IN_FLIGHT - 1 do
        if not ReadWasRight(FEngine, LHandles[LSlot], LOffsets[LSlot], LBuffers[LSlot], LCounts[LSlot]) then
          TAtomic.Increment(FFailures);
    end);
  Assert.AreEqual(0, FFailures, 'Reads with wrong results or data');
  Assert.AreEqual<UInt64>(PRODUCERS * READS_PER_PRODUCER, FEngine.Stats.Completed, 'Completed');
  Assert.AreEqual<UInt64>(0, FEngine.Stats.Failed, 'Failed');
end;

procedure TIORingEngineTests.RunCallbacksAndWaits(const AIOThreads: Integer);
const
  PRODUCERS = 4;
  READS_PER_PRODUCER = 2000;
begin
  // Every second request has a callback, which checks the data (and that it
  // runs on an I/O thread); the others are waited for by the producer
  FEngine := TIORingEngine.Create(16, 8, AIOThreads);
  RunThreads(PRODUCERS,
    procedure(AThread: Integer)
    var
      LRead: Integer;
      LRandom: Cardinal;
      LCallbackRead: PCallbackRead;
      LBuffer: TBytes;
      LOffset: UInt64;
      LCount: Cardinal;
    begin
      LRandom := Cardinal(AThread + 7) * 2654435761;
      SetLength(LBuffer, MAX_READ_SIZE);
      for LRead := 0 to READS_PER_PRODUCER - 1 do
      begin
        LCount := 1 + NextRandom(LRandom) mod MAX_READ_SIZE;
        LOffset := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - LCount + 1);
        if Odd(LRead) then
        begin
          New(LCallbackRead);
          LCallbackRead^.Offset := LOffset;
          LCallbackRead^.Count := LCount;
          FEngine.ReadAsync(FFile, LCallbackRead^.Buffer, LCount, LOffset, NativeUInt(LCallbackRead),
            CheckCallbackRead);
        end
        else if not ReadWasRight(FEngine, FEngine.ReadAsync(FFile, LBuffer[0], LCount, LOffset), LOffset,
          LBuffer, LCount) then
          TAtomic.Increment(FFailures);
      end;
    end);
  Assert.IsTrue(WaitUntil(
    function: Boolean
    begin
      Result := TAtomic.LoadAcquire(FCallbackCount) = PRODUCERS * READS_PER_PRODUCER div 2;
    end), 'All callbacks ran');
  Assert.AreEqual(0, FFailures, 'Reads with wrong results or data');
  Assert.AreEqual<UInt64>(0, FEngine.Stats.CallbackErrors, 'Callback errors');
end;

initialization
  TDUnitX.RegisterTestFixture(TIORingEngineTests);

end.
