unit PIRUnit.Engine.Tests;

{
  Tests for TIORingEngine (PIRUnit.Engine): reads, writes and flushes
  with their results; end of file and errors; Wait with a timeout,
  TryGetResult, WaitAll; callbacks on the I/O thread; batches; a full request
  pool; Destroy with requests in flight (they complete as cancelled, and a
  thread blocked in Wait wakes up); and stress with many producer threads
  doing random reads whose data is checked.

  Pipes give requests that stay pending until the test writes to the pipe.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TIORingEngineTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    FEngine: TIORingEngine;
    FFile: THandle;                     // the pattern file
    // Filled by the callbacks
    FCallbackCount: Integer;
    FCallbackThreadId: TThreadID;
    FCallbackCompletion: TIORingCompletion;
    FCancelledCount: Integer;
    FFailures: Integer;
    // Background threads of single tests
    FThirdHandle: TIORingRequestHandle;
    FThirdStarted: Integer;
    FThirdBuffer: array[0..99] of Byte;
    FWaitHandle: TIORingRequestHandle;
    FWaitResult: TIORingCompletion;
    FWaited: Boolean;
    // Callbacks
    procedure RecordCompletion(const ACompletion: TIORingCompletion);
    procedure RaiseInCallback(const ACompletion: TIORingCompletion);
    procedure CheckCallbackRead(const ACompletion: TIORingCompletion);
    procedure CheckData(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt);
    // Waits until AValue reaches AExpected (at most 5 s)
    function WaitForCount(var AValue: Integer; const AExpected: Integer): Boolean;
    // The stress tests, with AIOThreads I/O threads
    procedure RunManyProducers(const AIOThreads: Integer);
    procedure RunCallbacksAndWaits(const AIOThreads: Integer);
    // I/O threads that took at least one request
    function BusyIOThreads: Integer;
    // Thread bodies
    procedure WorkStartThirdRead(AIndex: Integer);
    procedure WorkWait(AIndex: Integer);
    procedure WorkRandomReads(AIndex: Integer);
    procedure WorkMixed(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // Requests and results
    procedure Read_ReturnsDataAndUserData;
    procedure ManyReads_MoreThanTheRingHolds;
    procedure WriteFlushRead_RoundTrip;
    procedure EndOfFile_AtAndAcross;
    procedure BadFileHandle_CompletesWithError;
    // Waiting
    procedure Wait_Timeout_KeepsTheRequest;
    procedure TryGetResult_FalseUntilDone;
    procedure Wait_HandleNotValid_Raises;
    // Callbacks, batches, a full pool
    procedure Callback_RunsOnTheIOThread;
    procedure CallbackException_IsCaughtAndCounted;
    procedure Batch_GoesToTheRingInOneSubmit;
    procedure Batch_WithoutBegin_Raises;
    procedure FullPool_StartWaitsForAFreeRequest;
    procedure Stats_CountTheRequests;
    // Destroy
    procedure Destroy_CancelsRequestsInFlight;
    procedure Destroy_WakesAThreadInWait;
    procedure Destroy_IdleEngine_IsQuick;
    procedure Destroy_TenEngines_AreQuick;
    // Several I/O threads
    procedure IOThreads_BadCount_Raises;
    procedure IOThreads_ABacklogIsShared;
    procedure IOThreads_LightLoad_StaysOnOneThread;
    procedure IOThreads_Destroy_CancelsEverything;
    // Several producer threads
    procedure Stress_ManyProducers_RandomReads;
    procedure Stress_ManyProducers_FourIOThreads;
    procedure Stress_CallbacksAndWaitsMixed;
    procedure Stress_CallbacksAndWaitsMixed_FourIOThreads;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.Atomics, PIRUnit.Types, PIRUnit.Test.FileHelpers;

const
  PATTERN_FILE_SIZE = 4 * 1024 * 1024;
  MAX_READ_SIZE = 64 * 1024;

  { Stress: requests each producer keeps - 8 x 5 = 40 > 36 in the pool, so the pool runs full; but a producer keeps at
    most 4 while it waits for a new one, and 8 x 4 < 36, so one of them always gets one (PIRUnit.Engine.Tests) }
  STRESS_PRODUCERS = 8;
  STRESS_READS = 1500;
  STRESS_IN_FLIGHT = 5;
  STRESS_POOL = 36;
  MIXED_PRODUCERS = 4;
  MIXED_READS = 2000;

type
  // A callback read of the mixed stress test (UserData points to it)
  TCallbackRead = record
    Offset: UInt64;
    Count: Cardinal;
    Buffer: array[0..MAX_READ_SIZE - 1] of Byte;
  end;
  PCallbackRead = ^TCallbackRead;

// Small random numbers per thread (Random is not thread-safe)
function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);

  Result := AState;
end;

// Waits for a read and checks it: success, all bytes, the right data
function ReadWasRight(const AEngine: TIORingEngine; const AHandle: TIORingRequestHandle;
  const AOffset: UInt64; const ABuffer: Pointer; const ACount: Cardinal): Boolean;
var
  LCompletion: TIORingCompletion;
  LBadOffset: UInt64;
begin
  Result := AEngine.Wait(AHandle, LCompletion) and LCompletion.Succeeded and
    (LCompletion.BytesTransferred = ACount) and
    TTestFileHelpers.CheckPattern(AOffset, ABuffer^, ACount, LBadOffset);
end;

{ TIORingEngineTests }

procedure TIORingEngineTests.SetUp;
begin
  FResources := TTestResources.Create;
  FFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));
  FEngine := nil;
  FCallbackCount := 0;
  FCallbackThreadId := 0;
  FCancelledCount := 0;
  FFailures := 0;
  FThirdStarted := 0;
  FWaited := False;
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
  RaiseError(Exception, 'A callback that fails');
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
begin
  CheckPattern(AFileOffset, ABuffer, ACount, 'Data');
end;

function TIORingEngineTests.WaitForCount(var AValue: Integer; const AExpected: Integer): Boolean;
var
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + 5000;

  while (TAtomic.LoadAcquire(AValue) <> AExpected) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  Result := TAtomic.LoadAcquire(AValue) = AExpected;
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
  AssertFalse('A request without callback has a handle', LHandle.IsEmpty);
  AssertTrue('Wait', FEngine.Wait(LHandle, LCompletion));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
  CheckEqualsU64('Bytes', 10000, LCompletion.BytesTransferred);
  CheckEqualsU64('UserData comes back', 4242, LCompletion.UserData);
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
    AssertTrue(LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
    CheckEqualsU64('Bytes', READ_SIZE, LCompletions[LIndex].BytesTransferred);
    CheckEqualsU64('UserData', LIndex, LCompletions[LIndex].UserData);
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
    AssertTrue('Write: ' + LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
    CheckEqualsU64('Written', BLOCK, LCompletions[LIndex].BytesTransferred);
  end;

  AssertTrue(FEngine.Wait(FEngine.FlushAsync(LFile), LCompletion));
  AssertTrue('Flush: ' + LCompletion.ErrorMessage, LCompletion.Succeeded);

  SetLength(LIn, 3 * BLOCK);
  AssertTrue(FEngine.Wait(FEngine.ReadAsync(LFile, LIn[0], Length(LIn), 0), LCompletion));
  AssertTrue('Read back: ' + LCompletion.ErrorMessage, LCompletion.Succeeded);
  CheckEqualsU64('Read back', 3 * BLOCK, LCompletion.BytesTransferred);
  AssertTrue('Same data', CompareMem(@LOut[0], @LIn[0], Length(LOut)));
end;

procedure TIORingEngineTests.EndOfFile_AtAndAcross;
var
  LBuffer: TBytes;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  SetLength(LBuffer, 4096);
  AssertTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer[0], 4096, PATTERN_FILE_SIZE), LCompletion));
  AssertTrue('At the end: ' + LCompletion.ErrorMessage, LCompletion.IsEndOfFile);

  AssertTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer[0], 4096, PATTERN_FILE_SIZE - 100), LCompletion));
  AssertTrue('Across the end: ' + LCompletion.ErrorMessage, LCompletion.Succeeded);
  CheckEqualsU64('Only the rest of the file', 100, LCompletion.BytesTransferred);
  CheckData(PATTERN_FILE_SIZE - 100, @LBuffer[0], 100);
  CheckEqualsU64('End of file is not a failure', 0, FEngine.Stats.Failed);
end;

procedure TIORingEngineTests.BadFileHandle_CompletesWithError;
var
  LBuffer: array[0..99] of Byte;
  LCompletion: TIORingCompletion;
begin
  FEngine := TIORingEngine.Create;
  // No exception: the request completes, with the error
  AssertTrue(FEngine.Wait(FEngine.ReadAsync(BAD_HANDLE, LBuffer, SizeOf(LBuffer), 0, 9), LCompletion));
  AssertFalse('Failed', LCompletion.Succeeded);
  CheckEqualsU64('UserData', 9, LCompletion.UserData);
  CheckEqualsU64('Counted as failed', 1, FEngine.Stats.Failed);
  // The engine goes on working
  AssertTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0), LCompletion));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
end;

{ Waiting }

procedure TIORingEngineTests.Wait_Timeout_KeepsTheRequest;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LStart: UInt64;
begin
  FEngine := TIORingEngine.Create;
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;
  LHandle := FEngine.ReadAsync(LClient, LByte, 1, 0);
  LStart := TThread.GetTickCount64;
  AssertFalse('Times out', FEngine.Wait(LHandle, LCompletion, 50));
  // GetTickCount64 moves in steps of about 16 ms: 50 ms show as 46 or more
  AssertTrue(Format('Waited only %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart >= 45);

  WriteByteToPipe(LServer, 42);
  AssertTrue('Still valid, completes', FEngine.Wait(LHandle, LCompletion, 5000));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
  CheckEqualsU64('Bytes', 1, LCompletion.BytesTransferred);
  AssertEquals('Byte', 42, LByte);
end;

procedure TIORingEngineTests.TryGetResult_FalseUntilDone;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LDeadline: UInt64;
  LDone: Boolean;
begin
  FEngine := TIORingEngine.Create;
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;
  LHandle := FEngine.ReadAsync(LClient, LByte, 1, 0);
  AssertFalse('Pending', FEngine.TryGetResult(LHandle, LCompletion));
  WriteByteToPipe(LServer, 7);
  LDeadline := TThread.GetTickCount64 + 5000;

  repeat
    LDone := FEngine.TryGetResult(LHandle, LCompletion);

    if not LDone then
      Sleep(1);
  until LDone or (TThread.GetTickCount64 > LDeadline);

  AssertTrue('Done after the write', LDone);
  AssertEquals('Byte', 7, LByte);
end;

procedure TIORingEngineTests.Wait_HandleNotValid_Raises;
var
  LBuffer: array[0..9] of Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LRaised: Boolean;
begin
  FEngine := TIORingEngine.Create;
  LHandle := FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0);
  AssertTrue(FEngine.Wait(LHandle, LCompletion));

  LRaised := False;

  try
    FEngine.Wait(LHandle, LCompletion);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Second Wait for the same request', LRaised);

  LHandle.Value := 0;
  LRaised := False;

  try
    FEngine.Wait(LHandle, LCompletion);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Empty handle', LRaised);
end;

{ Callbacks, batches, a full pool }

procedure TIORingEngineTests.Callback_RunsOnTheIOThread;
var
  LBuffer: array[0..999] of Byte;
  LHandle: TIORingRequestHandle;
begin
  FEngine := TIORingEngine.Create;
  LHandle := FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 5000, 31, RecordCompletion);
  AssertTrue('A request with a callback has no handle', LHandle.IsEmpty);
  AssertTrue('Callback called', WaitForCount(FCallbackCount, 1));
  AssertTrue('On the I/O thread', FEngine.IsIOThread(FCallbackThreadId));
  AssertTrue('Not on the main thread', FCallbackThreadId <> MainThreadID);
  AssertTrue(FCallbackCompletion.ErrorMessage, FCallbackCompletion.Succeeded);
  CheckEqualsU64('UserData', 31, FCallbackCompletion.UserData);
  CheckEqualsU64('Bytes', SizeOf(LBuffer), FCallbackCompletion.BytesTransferred);
  CheckData(5000, @LBuffer[0], SizeOf(LBuffer));
end;

procedure TIORingEngineTests.CallbackException_IsCaughtAndCounted;
var
  LBuffer: array[0..99] of Byte;
  LCompletion: TIORingCompletion;
  LDeadline: UInt64;
begin
  FEngine := TIORingEngine.Create;
  FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0, 0, RaiseInCallback);
  LDeadline := TThread.GetTickCount64 + 5000;

  while (FEngine.Stats.CallbackErrors = 0) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  CheckEqualsU64('Counted', 1, FEngine.Stats.CallbackErrors);
  // The I/O thread survived
  AssertTrue(FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), 0), LCompletion));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
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
      LHandles[LIndex] := FEngine.ReadAsync(FFile, LBuffers[LIndex * READ_SIZE], READ_SIZE, UInt64(LIndex) * READ_SIZE);

    Sleep(50);
    AssertFalse('Not started before EndBatch', FEngine.TryGetResult(LHandles[0], LCompletion));
  finally
    FEngine.EndBatch;
  end;

  FEngine.WaitAll(LHandles, LCompletions);

  for LIndex := 0 to READS - 1 do
  begin
    AssertTrue(LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
    CheckData(UInt64(LIndex) * READ_SIZE, @LBuffers[LIndex * READ_SIZE], READ_SIZE);
  end;

  CheckEqualsU64('All 20 in one submit', 1, FEngine.Stats.Submits - LSubmitsBefore);
end;

procedure TIORingEngineTests.Batch_WithoutBegin_Raises;
var
  LOther: TIORingEngine;
  LRaised: Boolean;
begin
  FEngine := TIORingEngine.Create(16, 8);
  LRaised := False;

  try
    FEngine.EndBatch;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('EndBatch without BeginBatch', LRaised);

  LOther := TIORingEngine.Create(16, 8);
  try
    FEngine.BeginBatch;
    FEngine.BeginBatch;    // nested: fine
    LRaised := False;

    try
      LOther.BeginBatch;
    except
      on EIORingError do
        LRaised := True;
    end;

    AssertTrue('Batch of another engine', LRaised);
    FEngine.EndBatch;
    FEngine.EndBatch;
    LOther.BeginBatch;     // now fine
    LOther.EndBatch;
  finally
    LOther.Free;
  end;
end;

procedure TIORingEngineTests.WorkStartThirdRead(AIndex: Integer);
begin
  FThirdHandle := FEngine.ReadAsync(FFile, FThirdBuffer, SizeOf(FThirdBuffer), 0);
  TAtomic.Exchange(FThirdStarted, 1);
end;

procedure TIORingEngineTests.FullPool_StartWaitsForAFreeRequest;
var
  LServer: array[0..1] of THandle;
  LClient: array[0..1] of THandle;
  LBytes: array[0..1] of Byte;
  LHandles: array[0..1] of TIORingRequestHandle;
  LThread: TWorkerThread;
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

  LThread := TWorkerThread.Create(0, 1, nil, WorkStartThirdRead);
  try
    LThread.Start;
    Sleep(100);
    AssertEquals('The third request waits for a free one', 0, TAtomic.LoadAcquire(FThirdStarted));

    WriteByteToPipe(LServer[0], 1);
    AssertTrue('First pipe read', FEngine.Wait(LHandles[0], LCompletion, 5000));
    // Its request is free now: the third one starts
    AssertTrue('The third request started', WaitForCount(FThirdStarted, 1));
    LThread.WaitFor;
  finally
    LThread.Free;
  end;

  AssertTrue('Third request', FEngine.Wait(FThirdHandle, LCompletion, 5000));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
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
  { An idle engine sleeps. (While requests keep coming it may never sleep: the next one is there before it would -
    so Sleeps is checked here.) }
  Sleep(20);
  AssertTrue('Sleeps when idle', FEngine.Stats.Sleeps >= 1);

  for LIndex := 1 to 10 do
    FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), LIndex * 1000), LCompletion);

  FEngine.Wait(FEngine.ReadAsync(BAD_HANDLE, LBuffer, SizeOf(LBuffer), 0), LCompletion);   // fails
  LStats := FEngine.Stats;
  CheckEqualsU64('Requests', 11, LStats.Requests);
  CheckEqualsU64('Completed', 11, LStats.Completed);
  CheckEqualsU64('Failed', 1, LStats.Failed);
  CheckEqualsU64('Cancelled', 0, LStats.Cancelled);
  AssertTrue('Submits', LStats.Submits >= 1);
  CheckEqualsU64('Callback errors', 0, LStats.CallbackErrors);
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
  AssertEquals('Pending', 0, TAtomic.LoadAcquire(FCallbackCount));

  FreeAndNil(FEngine);    // returns only when all three have completed
  AssertEquals('Every request completed', 3, FCallbackCount);
  AssertEquals('As cancelled', 3, FCancelledCount);
end;

procedure TIORingEngineTests.WorkWait(AIndex: Integer);
begin
  FWaited := FEngine.Wait(FWaitHandle, FWaitResult);
end;

procedure TIORingEngineTests.Destroy_WakesAThreadInWait;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LThread: TWorkerThread;
begin
  FEngine := TIORingEngine.Create(16, 8);
  FResources.OpenPipePair(LServer, LClient);
  FWaitHandle := FEngine.ReadAsync(LClient, LByte, 1, 0, 55);
  LThread := TWorkerThread.Create(0, 1, nil, WorkWait);
  try
    LThread.Start;
    Sleep(50);    // it sleeps in Wait now
    FreeAndNil(FEngine);
    LThread.WaitFor;
  finally
    LThread.Free;
  end;

  AssertTrue('Wait returned with a result', FWaited);
  AssertTrue('Cancelled: ' + FWaitResult.ErrorMessage, FWaitResult.IsCancelled);
  CheckEqualsU64('UserData', 55, FWaitResult.UserData);
end;

procedure TIORingEngineTests.Destroy_IdleEngine_IsQuick;
var
  LStart: UInt64;
begin
  FEngine := TIORingEngine.Create;
  Sleep(200);
  // Asleep, and it stays asleep: nothing wakes it without a reason
  AssertTrue(Format('Slept %d times when idle', [FEngine.Stats.Sleeps]), FEngine.Stats.Sleeps <= 2);
  LStart := TThread.GetTickCount64;
  FreeAndNil(FEngine);
  AssertTrue(Format('Took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 1000);
end;

procedure TIORingEngineTests.Destroy_TenEngines_AreQuick;
var
  LStart: UInt64;
  LIndex: Integer;
begin
  { Free Pascal on Unix: TThread.WaitFor from the main thread waits in 100 ms steps, so this took at least 1 s before
    the engine waited on its own (TIORingIOThread.WaitUntilEnded) }
  LStart := TThread.GetTickCount64;

  for LIndex := 1 to 10 do
  begin
    FEngine := TIORingEngine.Create(IORING_ENGINE_DEFAULT_MAX_REQUESTS, IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE, 4);
    FreeAndNil(FEngine);
  end;

  AssertTrue(Format('Took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 500);
end;

{ Several I/O threads }

procedure TIORingEngineTests.IOThreads_BadCount_Raises;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    TIORingEngine.Create(16, 8, 0).Free;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('0 I/O threads', LRaised);
  LRaised := False;

  try
    TIORingEngine.Create(16, 8, IORING_ENGINE_MAX_IO_THREADS + 1).Free;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Too many I/O threads', LRaised);
  FEngine := TIORingEngine.Create(16, 8, 4);
  AssertEquals('IOThreadCount', 4, FEngine.IOThreadCount);
  LRaised := False;

  try
    FEngine.IOThreadStats(4);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('No I/O thread 4', LRaised);
end;

procedure TIORingEngineTests.IOThreads_ABacklogIsShared;
const
  READS = 2000;
  READ_SIZE = 4096;
  BLOCKS_IN_FILE = PATTERN_FILE_SIZE div READ_SIZE;
var
  LFile: THandle;
  LBuffers: PByte;
  LHandles: array of TIORingRequestHandle;
  LCompletions: array of TIORingCompletion;
  LIndex: Integer;
begin
  {
    Unbuffered reads: each costs the I/O thread several µs inside the submit call, plus the disk's time. With cached
    reads one I/O thread sometimes finished all of them before a woken sibling got the CPU (3 of 25 runs), and the test
    failed for no fault of the engine.
  }
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE), [tofUnbuffered]);
  LBuffers := FResources.AllocPages(READS * READ_SIZE);
  FEngine := TIORingEngine.Create(READS, 64, 4);
  SetLength(LHandles, READS);
  SetLength(LCompletions, READS);
  Sleep(20);    // all I/O threads asleep
  // EndBatch wakes one I/O thread; it takes a share and wakes the next one, which does the same
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
    AssertTrue(LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
    CheckData(UInt64(LIndex mod BLOCKS_IN_FILE) * READ_SIZE, @LBuffers[LIndex * READ_SIZE], READ_SIZE);
  end;

  CheckEqualsU64('Requests of all I/O threads', READS, FEngine.Stats.Requests);
  AssertTrue(Format('%d I/O threads took requests', [BusyIOThreads]), BusyIOThreads >= 2);
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

  { One request at a time: the first I/O thread is enough, and the others are not woken. (Rarely one is: a producer can
    come just while the first one wakes up.) }
  for LIndex := 1 to READS do
  begin
    AssertTrue('Wait', FEngine.Wait(FEngine.ReadAsync(FFile, LBuffer, SizeOf(LBuffer), LIndex * 1000), LCompletion));
    AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
  end;

  AssertTrue(Format('The first I/O thread took %d of %d', [FEngine.IOThreadStats(0).Requests, READS]),
    FEngine.IOThreadStats(0).Requests >= READS * 9 div 10);
end;

procedure TIORingEngineTests.IOThreads_Destroy_CancelsEverything;
const
  PIPES = 32;
var
  LServer: array[0..PIPES - 1] of THandle;
  LClient: array[0..PIPES - 1] of THandle;
  LBytes: array[0..PIPES - 1] of Byte;
  LIndex: Integer;
  LDeadline: UInt64;
begin
  { Rings of 8: one ring cannot hold them all, so they spread over the I/O threads (a thread with a
    full ring wakes a sibling) }
  FEngine := TIORingEngine.Create(64, 8, 4);

  for LIndex := 0 to PIPES - 1 do
  begin
    FResources.OpenPipePair(LServer[LIndex], LClient[LIndex]);
    FEngine.ReadAsync(LClient[LIndex], LBytes[LIndex], 1, 0, LIndex, RecordCompletion);
  end;

  LDeadline := TThread.GetTickCount64 + 5000;

  while (FEngine.Stats.Requests < PIPES) and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  CheckEqualsU64('All taken by the I/O threads', PIPES, FEngine.Stats.Requests);
  AssertTrue(Format('%d I/O threads took requests', [BusyIOThreads]), BusyIOThreads >= 2);
  AssertEquals('Pending', 0, TAtomic.LoadAcquire(FCallbackCount));

  FreeAndNil(FEngine);    // returns only when all have completed
  AssertEquals('Every request completed', PIPES, FCallbackCount);
  AssertEquals('As cancelled', PIPES, FCancelledCount);
end;

{ Several producer threads }

procedure TIORingEngineTests.WorkRandomReads(AIndex: Integer);
var
  LBuffers: array[0..STRESS_IN_FLIGHT - 1] of TBytes;
  LHandles: array[0..STRESS_IN_FLIGHT - 1] of TIORingRequestHandle;
  LOffsets: array[0..STRESS_IN_FLIGHT - 1] of UInt64;
  LCounts: array[0..STRESS_IN_FLIGHT - 1] of Cardinal;
  LSlot: Integer;
  LRead: Integer;
  LRandom: Cardinal;
begin
  LRandom := Cardinal(AIndex + 1) * 2654435761;
  FillChar(LHandles, SizeOf(LHandles), 0);
  FillChar(LOffsets, SizeOf(LOffsets), 0);
  FillChar(LCounts, SizeOf(LCounts), 0);

  for LSlot := 0 to STRESS_IN_FLIGHT - 1 do
    SetLength(LBuffers[LSlot], MAX_READ_SIZE);

  for LRead := 0 to STRESS_READS - 1 do
  begin
    LSlot := LRead mod STRESS_IN_FLIGHT;

    if (LRead >= STRESS_IN_FLIGHT) and
      not ReadWasRight(FEngine, LHandles[LSlot], LOffsets[LSlot], @LBuffers[LSlot][0], LCounts[LSlot]) then
      TAtomic.Increment(FFailures);

    LCounts[LSlot] := 1 + NextRandom(LRandom) mod MAX_READ_SIZE;
    LOffsets[LSlot] := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - LCounts[LSlot] + 1);
    LHandles[LSlot] := FEngine.ReadAsync(FFile, LBuffers[LSlot][0], LCounts[LSlot], LOffsets[LSlot]);
  end;

  for LSlot := 0 to STRESS_IN_FLIGHT - 1 do
    if not ReadWasRight(FEngine, LHandles[LSlot], LOffsets[LSlot], @LBuffers[LSlot][0], LCounts[LSlot]) then
      TAtomic.Increment(FFailures);
end;

procedure TIORingEngineTests.Stress_ManyProducers_RandomReads;
begin
  RunManyProducers(1);
end;

procedure TIORingEngineTests.Stress_ManyProducers_FourIOThreads;
begin
  RunManyProducers(4);
end;

procedure TIORingEngineTests.RunManyProducers(const AIOThreads: Integer);
begin
  FEngine := TIORingEngine.Create(STRESS_POOL, 16, AIOThreads);
  RunThreads(STRESS_PRODUCERS, WorkRandomReads);
  AssertEquals('Reads with wrong results or data', 0, FFailures);
  CheckEqualsU64('Completed', STRESS_PRODUCERS * STRESS_READS, FEngine.Stats.Completed);
  CheckEqualsU64('Failed', 0, FEngine.Stats.Failed);
end;

procedure TIORingEngineTests.WorkMixed(AIndex: Integer);
var
  LRead: Integer;
  LRandom: Cardinal;
  LCallbackRead: PCallbackRead;
  LBuffer: TBytes;
  LOffset: UInt64;
  LCount: Cardinal;
begin
  LRandom := Cardinal(AIndex + 7) * 2654435761;
  SetLength(LBuffer, MAX_READ_SIZE);

  for LRead := 0 to MIXED_READS - 1 do
  begin
    LCount := 1 + NextRandom(LRandom) mod MAX_READ_SIZE;
    LOffset := NextRandom(LRandom) mod (PATTERN_FILE_SIZE - LCount + 1);

    if Odd(LRead) then
    begin
      New(LCallbackRead);
      LCallbackRead^.Offset := LOffset;
      LCallbackRead^.Count := LCount;
      FEngine.ReadAsync(FFile, LCallbackRead^.Buffer, LCount, LOffset, NativeUInt(LCallbackRead), CheckCallbackRead);
    end
    else if not ReadWasRight(FEngine, FEngine.ReadAsync(FFile, LBuffer[0], LCount, LOffset), LOffset,
      @LBuffer[0], LCount) then
      TAtomic.Increment(FFailures);
  end;
end;

procedure TIORingEngineTests.Stress_CallbacksAndWaitsMixed;
begin
  RunCallbacksAndWaits(1);
end;

procedure TIORingEngineTests.Stress_CallbacksAndWaitsMixed_FourIOThreads;
begin
  RunCallbacksAndWaits(4);
end;

procedure TIORingEngineTests.RunCallbacksAndWaits(const AIOThreads: Integer);
begin
  { Every second request has a callback, which checks the data (and that it runs on an I/O thread); the others are
    waited for by the producer }
  FEngine := TIORingEngine.Create(16, 8, AIOThreads);
  RunThreads(MIXED_PRODUCERS, WorkMixed);
  AssertTrue('All callbacks ran', WaitForCount(FCallbackCount, MIXED_PRODUCERS * MIXED_READS div 2));
  AssertEquals('Reads with wrong results or data', 0, FFailures);
  CheckEqualsU64('Callback errors', 0, FEngine.Stats.CallbackErrors);
end;

initialization
  RegisterTests(TIORingEngineTests);

end.
