unit Delphi.IOUring.Engine;

// The I/O engine (Docs/Design.md §10, API decisions in §10.4): many threads
// start reads, writes and flushes; one I/O thread with its own ring carries
// them out, many at a time.
//
//   LEngine := TIORingEngine.Create;
//   try
//     LHandle := LEngine.ReadAsync(LFile, LBuffer, SizeOf(LBuffer), LOffset);
//     ...                                       // other work, more requests
//     LEngine.Wait(LHandle, LCompletion);
//     LCompletion.RaiseIfFailed('Read');
//   finally
//     LEngine.Free;
//   end;
//
// How a request travels:
//
//   any thread                                 the I/O thread
//   ReadAsync: take a slot (request pool),
//   fill it, put its handle in the queue  -->  take it from the queue and
//   (wake the I/O thread if it sleeps)         prepare it on the ring; one
//                                              submit for all of them
//                                              pop the completions, store
//   Wait: sleep on the slot's state word  <--  the results, mark them
//   read the result, free the slot             Completed (or call the
//                                              callback and free the slot)
//
// The I/O thread sleeps only when nothing happened in a round: no new
// requests, nothing to submit, no completions. It then waits for either the
// "new requests" event or the ring's completion event. Producers set the
// first one only when the I/O thread has said it sleeps, so while the engine
// is busy, starting a request costs no system call.
//
// Open files with FILE_FLAG_OVERLAPPED (TIORingPlatform.OpenFileForRead does):
// a handle opened without it works, but Windows then carries out its I/O one
// request at a time - no parallel reads (measured: Docs/Benchmarks.md,
// "Blocks known in advance").
//
// Every request completes: done, failed or cancelled. Destroy cancels what is
// left and waits for it. Buffers and file handles must stay valid until their
// request has completed. (Known limit: if the ring itself fails - a system
// call error, not an I/O error - the I/O thread stops, and requests in flight
// do not complete.)
//
// A request is a slot of the request pool from ReadAsync until Wait (or until
// its callback has run). When all MaxRequests are taken, starting another
// one waits until one is freed - so threads that keep requests without
// waiting for them can wait for each other forever. Rule: MaxRequests must be
// more than the sum, over all threads, of the requests a thread keeps while
// it starts a new one.

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  Windows,
  SysUtils,
  Classes,
{$ELSE}
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Delphi.IOUring,
  Delphi.IOUring.Atomics,
  Delphi.IOUring.RequestPool,
  Delphi.IOUring.RequestQueue;

const
  IORING_ENGINE_DEFAULT_MAX_REQUESTS = 1024;
  IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE = 256;

type
  // The handle of a request (from Delphi.IOUring.RequestPool), here too so
  // that users of the engine need only this unit and Delphi.IOUring
  TIORingRequestHandle = Delphi.IOUring.RequestPool.TIORingRequestHandle;

  // Called on the I/O thread when a request with a callback has completed;
  // ACompletion.UserData is the caller's value. Keep it short (the I/O thread
  // does nothing else meanwhile), and do not wait for other requests in it.
  TIORingCompletionEvent = procedure(const ACompletion: TIORingCompletion) of object;

  // Counted by the I/O thread
  TIORingEngineStats = record
    Requests: UInt64;          // taken from the queue
    Completed: UInt64;         // finished: done, failed or cancelled
    Failed: UInt64;            // finished with an error (not counting end of file and cancelled)
    Cancelled: UInt64;
    Submits: UInt64;           // SubmitIoRing calls
    Sleeps: UInt64;            // times the I/O thread went to sleep
    CallbackErrors: UInt64;    // exceptions raised by callbacks (caught)
  end;

  TIORingEngine = class
  private
    FPool: TIORingRequestPool;
    FQueue: TIORingRequestQueue;
    FRing: TIORing;
    FThread: TThread;
    FWakeEvent: THandle;
    FMaxRequests: Cardinal;
    // Words that several threads write, each on a cache line of its own
    FSharedMemory: Pointer;
    FSleeping: PInteger;          // 1: the I/O thread sleeps (or is about to)
    FStopping: PInteger;          // 1: Destroy has begun: no new requests
    FStartCalls: PInteger;        // threads inside ReadAsync / WriteAsync / FlushAsync
    FWaitCalls: PInteger;         // threads inside Wait
    FSlotsReleased: PCardinal;    // counts slot releases; threads waiting for a slot sleep on it
    FSlotWaiters: PInteger;       // threads waiting for a free slot
    // The I/O thread's own (FShutdown and FStats are also read by others)
    FShutdown: Integer;           // set by Destroy: cancel everything and end
    FStats: TIORingEngineStats;
    FInFlight: array of TIORingRequestHandle;    // requests in the ring
    FInFlightCount: Integer;
    FDeferred: TIORingRequestHandle;            // taken from the queue, did not fit into the ring yet

    function StartRequest(const AOperation: TIORingOp; const AFile: THandle; const ABuffer: Pointer;
      const ACount: Cardinal; const AOffset: UInt64; const AFlushMode: TIORingFlushMode;
      const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
    function AcquireSlot: TIORingRequestHandle;
    procedure SlotReleased;
    procedure WakeIOThread;
    function GetIOThreadId: TThreadID;
    // The I/O thread
    procedure RunIOThread;
    function TakeNewRequests: Boolean;
    function PrepareRequest(const AHandle: TIORingRequestHandle): Boolean;
    function ReapCompletions: Boolean;
    procedure FinishRequest(const AHandle: TIORingRequestHandle; const ANativeResult: Integer;
      const ABytesTransferred: NativeUInt);
    procedure RemoveInFlight(const AHandle: TIORingRequestHandle);
    procedure SleepUntilWork;
    procedure CancelEverything;
    procedure CountStat(var ACounter: UInt64);
  public
    // AMaxRequests: requests that can be started and not yet waited for (or
    // whose callback has not run); ASubmissionQueueSize: the ring's
    // submission queue. Raises EIORingNotSupported without IoRing.
    constructor Create(const AMaxRequests: Cardinal = IORING_ENGINE_DEFAULT_MAX_REQUESTS;
      const ASubmissionQueueSize: Cardinal = IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE);
    // Accepts no new requests, cancels the requests not finished yet and waits
    // until each has completed. Threads blocked in Wait wake up (the result is
    // "cancelled"); calling the engine after Destroy has returned is an error.
    destructor Destroy; override;

    // Start a request and return at once. ABuffer and AFile must stay valid
    // until the request has completed. AUserData comes back in the completion.
    // When all MaxRequests requests are in use, the call sleeps until one is
    // free. Without AOnComplete, finish the request with Wait (or
    // TryGetResult / WaitAll). With AOnComplete, it is called on the I/O
    // thread, the request then ends by itself, and the result is an empty
    // handle. Raises EIORingError when the engine is being destroyed.
    function ReadAsync(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64;
      const AUserData: NativeUInt = 0; const AOnComplete: TIORingCompletionEvent = nil): TIORingRequestHandle;
    function WriteAsync(const AFile: THandle; const ABuffer; const ACount: Cardinal; const AOffset: UInt64;
      const AUserData: NativeUInt = 0; const AOnComplete: TIORingCompletionEvent = nil): TIORingRequestHandle;
    function FlushAsync(const AFile: THandle; const AMode: TIORingFlushMode = rfmDefault;
      const AUserData: NativeUInt = 0; const AOnComplete: TIORingCompletionEvent = nil): TIORingRequestHandle;

    // Waits until the request has completed and returns its completion
    // (UserData = the caller's value); the request is then finished and the
    // handle no longer valid. False: timeout - the handle stays valid. One
    // Wait per request; a handle that is not valid raises EIORingError.
    function Wait(const AHandle: TIORingRequestHandle; out ACompletion: TIORingCompletion;
      const ATimeoutMilliseconds: Cardinal = IORING_INFINITE): Boolean;
    // Wait with timeout 0
    function TryGetResult(const AHandle: TIORingRequestHandle; out ACompletion: TIORingCompletion): Boolean;
    // Waits for all; ACompletions[I] belongs to AHandles[I]
    procedure WaitAll(const AHandles: array of TIORingRequestHandle; var ACompletions: array of TIORingCompletion);

    // Requests started by this thread between BeginBatch and EndBatch do not
    // wake the I/O thread; EndBatch wakes it once, so that they go to the
    // ring with one submit. Batches can be nested; one engine at a time per
    // thread.
    procedure BeginBatch;
    procedure EndBatch;

    function Stats: TIORingEngineStats;
    property MaxRequests: Cardinal read FMaxRequests;
    property IOThreadId: TThreadID read GetIOThreadId;
  end;

implementation

const
  // UserData of the engine's own cancel operations (a request handle is never 0)
  CANCEL_USER_DATA = 0;
  // E_FAIL: for a request the ring refused without an error code
  RESULT_FAILED = Integer($80004005);

type
  // The engine's data in a request slot (the pool's payload)
  TEngineRequest = record
    Operation: TIORingOp;          // ioRead, ioWrite or ioFlush
    FlushMode: TIORingFlushMode;
    InFlightIndex: Integer;        // position in FInFlight (-1: not in the ring)
    FileHandle: THandle;
    Buffer: Pointer;
    Count: Cardinal;
    Offset: UInt64;
    UserData: NativeUInt;          // the caller's, back in the completion
    OnComplete: TIORingCompletionEvent;
    NativeResult: Integer;
    BytesTransferred: NativeUInt;
  end;
  PEngineRequest = ^TEngineRequest;

  TIORingEngineThread = class(TThread)
  private
    FEngine: TIORingEngine;
  protected
    procedure Execute; override;
  public
    constructor Create(const AEngine: TIORingEngine);
  end;

threadvar
  // BeginBatch / EndBatch of the current thread
  GBatchEngine: TIORingEngine;
  GBatchDepth: Integer;

{ TIORingEngineThread }

constructor TIORingEngineThread.Create(const AEngine: TIORingEngine);
begin
  FEngine := AEngine;
  inherited Create(True);
end;

procedure TIORingEngineThread.Execute;
begin
  FEngine.RunIOThread;
end;

{ TIORingEngine - life cycle }

constructor TIORingEngine.Create(const AMaxRequests: Cardinal; const ASubmissionQueueSize: Cardinal);
var
  LShared: PByte;
begin
  inherited Create;
  FMaxRequests := AMaxRequests;
  LShared := IORingAllocCacheAligned(5 * IORING_CACHE_LINE_SIZE, FSharedMemory);
  FSleeping := Pointer(LShared);
  FStopping := Pointer(LShared + IORING_CACHE_LINE_SIZE);
  FStartCalls := Pointer(LShared + 2 * IORING_CACHE_LINE_SIZE);
  FWaitCalls := Pointer(LShared + 3 * IORING_CACHE_LINE_SIZE);
  // Used together, and only when the pool is full
  FSlotsReleased := Pointer(LShared + 4 * IORING_CACHE_LINE_SIZE);
  FSlotWaiters := Pointer(LShared + 4 * IORING_CACHE_LINE_SIZE + SizeOf(Cardinal));

  FPool.Open(AMaxRequests, SizeOf(TEngineRequest));
  // As big as the pool: a request is in the queue at most once, so the queue
  // is never full
  FQueue.Open(AMaxRequests);
  SetLength(FInFlight, AMaxRequests);
  FRing.Open(ASubmissionQueueSize);
  FWakeEvent := CreateEvent(nil, False, False, nil);   // auto-reset
  if FWakeEvent = 0 then
    RaiseLastOSError;
  FThread := TIORingEngineThread.Create(Self);
  FThread.Start;
end;

destructor TIORingEngine.Destroy;
begin
  if FThread <> nil then
  begin
    // 1. No new requests; threads waiting for a free slot give up
    TAtomic.Exchange(FStopping^, 1);
    TAtomic.Increment(FSlotsReleased^);
    TAtomic.WakeAll(FSlotsReleased^);
    // 2. Requests being started right now get into the queue first
    while TAtomic.LoadAcquire(FStartCalls^) > 0 do
      TThread.Yield;
    // 3. The I/O thread cancels what is left, waits for it, and ends
    TAtomic.Exchange(FShutdown, 1);
    SetEvent(FWakeEvent);
    FThread.WaitFor;
    FreeAndNil(FThread);
    // 4. Threads in Wait have been woken (every request has completed): let
    //    them leave before the pool goes away
    while TAtomic.LoadAcquire(FWaitCalls^) > 0 do
      TThread.Yield;
  end;
  FRing.Close;
  FQueue.Close;
  FPool.Close;
  if FWakeEvent <> 0 then
    CloseHandle(FWakeEvent);
  if FSharedMemory <> nil then
    FreeMem(FSharedMemory);
  inherited;
end;

function TIORingEngine.GetIOThreadId: TThreadID;
begin
  if FThread <> nil then
    Result := FThread.ThreadID
  else
    Result := 0;
end;

{ TIORingEngine - starting requests (any thread) }

function TIORingEngine.ReadAsync(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64;
  const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
begin
  Result := StartRequest(ioRead, AFile, @ABuffer, ACount, AOffset, rfmDefault, AUserData, AOnComplete);
end;

function TIORingEngine.WriteAsync(const AFile: THandle; const ABuffer; const ACount: Cardinal; const AOffset: UInt64;
  const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
begin
  Result := StartRequest(ioWrite, AFile, @ABuffer, ACount, AOffset, rfmDefault, AUserData, AOnComplete);
end;

function TIORingEngine.FlushAsync(const AFile: THandle; const AMode: TIORingFlushMode;
  const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
begin
  Result := StartRequest(ioFlush, AFile, nil, 0, 0, AMode, AUserData, AOnComplete);
end;

function TIORingEngine.StartRequest(const AOperation: TIORingOp; const AFile: THandle; const ABuffer: Pointer;
  const ACount: Cardinal; const AOffset: UInt64; const AFlushMode: TIORingFlushMode;
  const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
var
  LHandle: TIORingRequestHandle;
  LRequest: PEngineRequest;
begin
  // Counted, so that Destroy can wait until no thread is half-way here
  TAtomic.Increment(FStartCalls^);
  try
    if TAtomic.LoadAcquire(FStopping^) <> 0 then
      raise EIORingError.Create('The engine is shutting down: no new requests');
    LHandle := AcquireSlot;
    LRequest := FPool.Payload(LHandle);
    LRequest^.Operation := AOperation;
    LRequest^.FlushMode := AFlushMode;
    LRequest^.InFlightIndex := -1;
    LRequest^.FileHandle := AFile;
    LRequest^.Buffer := ABuffer;
    LRequest^.Count := ACount;
    LRequest^.Offset := AOffset;
    LRequest^.UserData := AUserData;
    LRequest^.OnComplete := AOnComplete;
    LRequest^.NativeResult := 0;
    LRequest^.BytesTransferred := 0;
    // Queued before it is in the queue: the I/O thread may take it at once
    FPool.TryChangeState(LHandle, rsDefined, rsQueued);
    if not FQueue.TryEnqueue(LHandle.Value) then
      raise EIORingError.Create('Internal error: the request queue is full');
    if (GBatchDepth = 0) or (GBatchEngine <> Self) then
      WakeIOThread;
    // With a callback the request ends by itself, maybe already now
    if Assigned(AOnComplete) then
      Result.Value := 0
    else
      Result := LHandle;
  finally
    TAtomic.Decrement(FStartCalls^);
  end;
end;

function TIORingEngine.AcquireSlot: TIORingRequestHandle;
var
  LSeen: Cardinal;
begin
  if FPool.TryAcquire(Result) then
    Exit;
  // All requests in use: sleep until one is released. Announce the wait
  // first and then look again, so that a release in between is not missed.
  TAtomic.Increment(FSlotWaiters^);
  try
    repeat
      LSeen := TAtomic.LoadAcquire(FSlotsReleased^);
      if FPool.TryAcquire(Result) then
        Exit;
      if TAtomic.LoadAcquire(FStopping^) <> 0 then
        raise EIORingError.Create('The engine is shutting down: no new requests');
      TAtomic.WaitWhileEqual(FSlotsReleased^, LSeen);
    until False;
  finally
    TAtomic.Decrement(FSlotWaiters^);
  end;
end;

procedure TIORingEngine.SlotReleased;
begin
  TAtomic.Increment(FSlotsReleased^);
  if TAtomic.LoadAcquire(FSlotWaiters^) > 0 then
    TAtomic.WakeAll(FSlotsReleased^);
end;

procedure TIORingEngine.WakeIOThread;
begin
  // The enqueue before this was a full barrier: either this sees the
  // sleeping flag, or the I/O thread (which sets the flag and then looks at
  // the queue) sees the new request
  if (TAtomic.LoadAcquire(FSleeping^) <> 0) and (TAtomic.Exchange(FSleeping^, 0) <> 0) then
    SetEvent(FWakeEvent);
end;

procedure TIORingEngine.BeginBatch;
begin
  if (GBatchDepth > 0) and (GBatchEngine <> Self) then
    raise EIORingError.Create('BeginBatch: this thread is in a batch of another engine');
  GBatchEngine := Self;
  Inc(GBatchDepth);
end;

procedure TIORingEngine.EndBatch;
begin
  if (GBatchDepth = 0) or (GBatchEngine <> Self) then
    raise EIORingError.Create('EndBatch without BeginBatch');
  Dec(GBatchDepth);
  if GBatchDepth = 0 then
  begin
    GBatchEngine := nil;
    WakeIOThread;
  end;
end;

{ TIORingEngine - finishing requests (any thread) }

function TIORingEngine.Wait(const AHandle: TIORingRequestHandle; out ACompletion: TIORingCompletion;
  const ATimeoutMilliseconds: Cardinal): Boolean;
var
  LRequest: PEngineRequest;
begin
  ACompletion.UserData := 0;
  ACompletion.NativeResult := 0;
  ACompletion.BytesTransferred := 0;
  // Counted, so that Destroy can wait until no thread is in here
  TAtomic.Increment(FWaitCalls^);
  try
    case FPool.WaitFor(AHandle, ATimeoutMilliseconds) of
      wrCompleted:
        begin
          LRequest := FPool.Payload(AHandle);
          ACompletion.UserData := LRequest^.UserData;
          ACompletion.NativeResult := LRequest^.NativeResult;
          ACompletion.BytesTransferred := LRequest^.BytesTransferred;
          if not FPool.Release(AHandle) then
            raise EIORingError.Create('Wait: another thread waited for the same request');
          SlotReleased;
          Result := True;
        end;
      wrTimeout:
        Result := False;
    else
      raise EIORingError.Create('Wait: not a request of this engine, or already waited for');
    end;
  finally
    TAtomic.Decrement(FWaitCalls^);
  end;
end;

function TIORingEngine.TryGetResult(const AHandle: TIORingRequestHandle; out ACompletion: TIORingCompletion): Boolean;
begin
  Result := Wait(AHandle, ACompletion, 0);
end;

procedure TIORingEngine.WaitAll(const AHandles: array of TIORingRequestHandle;
  var ACompletions: array of TIORingCompletion);
var
  LIndex: Integer;
begin
  if Length(ACompletions) < Length(AHandles) then
    raise EIORingError.Create('WaitAll: ACompletions is shorter than AHandles');
  for LIndex := 0 to High(AHandles) do
    Wait(AHandles[LIndex], ACompletions[LIndex]);
end;

function TIORingEngine.Stats: TIORingEngineStats;
begin
  Result.Requests := TAtomic.LoadAcquire(FStats.Requests);
  Result.Completed := TAtomic.LoadAcquire(FStats.Completed);
  Result.Failed := TAtomic.LoadAcquire(FStats.Failed);
  Result.Cancelled := TAtomic.LoadAcquire(FStats.Cancelled);
  Result.Submits := TAtomic.LoadAcquire(FStats.Submits);
  Result.Sleeps := TAtomic.LoadAcquire(FStats.Sleeps);
  Result.CallbackErrors := TAtomic.LoadAcquire(FStats.CallbackErrors);
end;

{ TIORingEngine - the I/O thread }

procedure TIORingEngine.CountStat(var ACounter: UInt64);
begin
  // Only the I/O thread writes: a plain add, stored whole for the readers
  TAtomic.StoreRelease(ACounter, ACounter + 1);
end;

procedure TIORingEngine.RunIOThread;
var
  LBusy: Boolean;
begin
  repeat
    LBusy := TakeNewRequests;
    if FRing.PreparedCount > 0 then
    begin
      FRing.Submit(0);
      CountStat(FStats.Submits);
      LBusy := True;
    end;
    if ReapCompletions then
      LBusy := True;
    if TAtomic.LoadAcquire(FShutdown) <> 0 then
    begin
      CancelEverything;
      Exit;
    end;
    if not LBusy then
      SleepUntilWork;
  until False;
end;

function TIORingEngine.TakeNewRequests: Boolean;
var
  LHandle: TIORingRequestHandle;
  LValue: NativeUInt;
begin
  Result := False;
  repeat
    if not FDeferred.IsEmpty then
    begin
      LHandle := FDeferred;
      FDeferred.Value := 0;
    end
    else if FQueue.TryDequeue(LValue) then
    begin
      LHandle.Value := LValue;
      CountStat(FStats.Requests);
      FPool.TryChangeState(LHandle, rsQueued, rsSubmitted);
    end
    else
      Exit;

    if not PrepareRequest(LHandle) then
    begin
      FDeferred := LHandle;    // the ring is full: next round
      Exit;
    end;
    Result := True;
  until False;
end;

function TIORingEngine.PrepareRequest(const AHandle: TIORingRequestHandle): Boolean;
var
  LRequest: PEngineRequest;
  LFile: TIORingFileRef;
  LError: Integer;
begin
  LRequest := FPool.Payload(AHandle);
  LFile := TIORingFileRef.FromHandle(LRequest^.FileHandle);
  try
    case LRequest^.Operation of
      ioRead:
        Result := FRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(LRequest^.Buffer), LRequest^.Count,
          LRequest^.Offset, AHandle.Value);
      ioWrite:
        Result := FRing.PrepareWrite(LFile, TIORingBufferRef.FromPointer(LRequest^.Buffer), LRequest^.Count,
          LRequest^.Offset, AHandle.Value);
    else
      Result := FRing.PrepareFlush(LFile, LRequest^.FlushMode, AHandle.Value);
    end;
  except
    on E: EIORingError do
    begin
      // The ring refused the request (for example a bad handle): it
      // completes at once, with the ring's error
      LError := E.NativeCode;
      if LError = 0 then
        LError := RESULT_FAILED;
      FinishRequest(AHandle, LError, 0);
      Exit(True);
    end;
  end;

  if Result then
  begin
    LRequest^.InFlightIndex := FInFlightCount;
    FInFlight[FInFlightCount] := AHandle;
    Inc(FInFlightCount);
  end;
end;

function TIORingEngine.ReapCompletions: Boolean;
var
  LCompletion: TIORingCompletion;
  LHandle: TIORingRequestHandle;
begin
  Result := False;
  while FRing.TryPopCompletion(LCompletion) do
  begin
    Result := True;
    if LCompletion.UserData = CANCEL_USER_DATA then
      Continue;    // one of our cancel operations
    LHandle.Value := LCompletion.UserData;
    RemoveInFlight(LHandle);
    FinishRequest(LHandle, LCompletion.NativeResult, LCompletion.BytesTransferred);
  end;
end;

procedure TIORingEngine.RemoveInFlight(const AHandle: TIORingRequestHandle);
var
  LRequest: PEngineRequest;
  LIndex: Integer;
begin
  LRequest := FPool.Payload(AHandle);
  LIndex := LRequest^.InFlightIndex;
  if LIndex < 0 then
    Exit;
  // The last one takes its place
  Dec(FInFlightCount);
  if LIndex < FInFlightCount then
  begin
    FInFlight[LIndex] := FInFlight[FInFlightCount];
    PEngineRequest(FPool.Payload(FInFlight[LIndex]))^.InFlightIndex := LIndex;
  end;
  LRequest^.InFlightIndex := -1;
end;

procedure TIORingEngine.FinishRequest(const AHandle: TIORingRequestHandle; const ANativeResult: Integer;
  const ABytesTransferred: NativeUInt);
var
  LRequest: PEngineRequest;
  LCallback: TIORingCompletionEvent;
  LCompletion: TIORingCompletion;
begin
  LRequest := FPool.Payload(AHandle);
  LRequest^.NativeResult := ANativeResult;
  LRequest^.BytesTransferred := ABytesTransferred;
  CountStat(FStats.Completed);
  if ANativeResult = IORING_RESULT_CANCELLED then
    CountStat(FStats.Cancelled)
  else if (ANativeResult < 0) and (ANativeResult <> IORING_RESULT_END_OF_FILE) then
    CountStat(FStats.Failed);

  LCallback := LRequest^.OnComplete;
  if Assigned(LCallback) then
  begin
    LCompletion.UserData := LRequest^.UserData;
    LCompletion.NativeResult := ANativeResult;
    LCompletion.BytesTransferred := ABytesTransferred;
    try
      LCallback(LCompletion);
    except
      CountStat(FStats.CallbackErrors);
    end;
    // Nobody waits for it: the request ends here
    FPool.TryChangeState(AHandle, rsSubmitted, rsCompleted);
    FPool.Release(AHandle);
    SlotReleased;
  end
  else
    FPool.TryChangeState(AHandle, rsSubmitted, rsCompleted);    // wakes the thread in Wait
end;

procedure TIORingEngine.SleepUntilWork;
var
  LEvents: array[0..1] of THandle;
begin
  TAtomic.Exchange(FSleeping^, 1);
  // A producer that queued a request before it saw the flag did not signal:
  // look once more. (Both sides use full barriers, so at least one of the
  // two sees the other.) With a deferred request the ring is full, and only
  // a completion helps.
  if (FDeferred.IsEmpty and (FQueue.Count > 0)) or (TAtomic.LoadAcquire(FShutdown) <> 0) then
  begin
    TAtomic.Exchange(FSleeping^, 0);
    Exit;
  end;
  CountStat(FStats.Sleeps);
  LEvents[0] := FWakeEvent;
  LEvents[1] := FRing.CompletionEventHandle;
  WaitForMultipleObjects(2, @LEvents[0], False, INFINITE);
  TAtomic.Exchange(FSleeping^, 0);
end;

procedure TIORingEngine.CancelEverything;
var
  LValue: NativeUInt;
  LHandle: TIORingRequestHandle;
  LTargets: array of TIORingRequestHandle;
  LIndex: Integer;
  LPrepared: Boolean;
begin
  // 1. Requests not in the ring yet: cancelled without starting them
  if not FDeferred.IsEmpty then
  begin
    FinishRequest(FDeferred, IORING_RESULT_CANCELLED, 0);
    FDeferred.Value := 0;
  end;
  while FQueue.TryDequeue(LValue) do
  begin
    LHandle.Value := LValue;
    CountStat(FStats.Requests);
    FPool.TryChangeState(LHandle, rsQueued, rsSubmitted);
    FinishRequest(LHandle, IORING_RESULT_CANCELLED, 0);
  end;

  // 2. Requests in the ring: ask the ring to cancel each one. (One that
  //    completes meanwhile makes its cancel fail - harmless; no new request
  //    can take its slot any more.)
  SetLength(LTargets, FInFlightCount);
  for LIndex := 0 to FInFlightCount - 1 do
    LTargets[LIndex] := FInFlight[LIndex];
  for LIndex := 0 to High(LTargets) do
    repeat
      LPrepared := True;    // if the ring refuses: it completes by itself
      try
        LPrepared := FRing.PrepareCancel(
          TIORingFileRef.FromHandle(PEngineRequest(FPool.Payload(LTargets[LIndex]))^.FileHandle),
          LTargets[LIndex].Value, CANCEL_USER_DATA);
      except
        on EIORingError do
          ;
      end;
      if not LPrepared then
      begin
        // The ring is full: submit, take what has completed, try again
        FRing.Submit(0);
        CountStat(FStats.Submits);
        if not ReapCompletions then
          FRing.WaitForCompletions(1, 100);
      end;
    until LPrepared;

  // 3. Wait until every request in the ring has completed
  while (FInFlightCount > 0) or (FRing.PreparedCount > 0) do
  begin
    if FRing.PreparedCount > 0 then
    begin
      FRing.Submit(0);
      CountStat(FStats.Submits);
    end;
    if not ReapCompletions then
      FRing.WaitForCompletions(1, 100);
  end;
end;

end.
