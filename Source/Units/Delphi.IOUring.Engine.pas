unit Delphi.IOUring.Engine;

// The I/O engine (Docs/Design.md §10, API decisions in §10.4): many threads
// start reads, writes and flushes; one or more I/O threads, each with its own
// ring, carry them out, many at a time.
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
//   any thread                                 an I/O thread
//   ReadAsync: take a slot (request pool),
//   fill it, put its handle in the queue  -->  take it from the queue and
//   (wake an I/O thread if all sleep)          prepare it on its ring; one
//                                              submit for all of them
//                                              pop the completions, store
//   Wait: sleep on the slot's state word  <--  the results, mark them
//   read the result, free the slot             Completed (or call the
//                                              callback and free the slot)
//
// An I/O thread sleeps only when nothing happened in a round: no new
// requests, nothing to submit, no completions. It then waits for either its
// "new requests" event or its ring's completion event. Producers wake an I/O
// thread only when all of them sleep, so while the engine is busy, starting
// a request costs no system call.
//
// Several I/O threads (AIOThreads in Create) all take requests from the same
// queue. Windows does the work of a request inside the submit call, in the
// I/O thread - about 7.5 µs for an unbuffered 4 KiB read on a fast PC - so
// one I/O thread can submit only so many requests per second. More I/O
// threads help with many small requests of cached data and with unbuffered
// requests (3.2x as many 4 KiB reads with 4 threads), not with data that
// comes from the disk through the file cache (Docs/Benchmarks.md, "Several
// I/O threads"). With siblings, an I/O thread takes at most
// IORING_ENGINE_SHARE_SIZE requests per round and wakes a sleeping sibling if
// more are waiting.
//
// Open files with FILE_FLAG_OVERLAPPED (TIORingPlatform.OpenFileForRead does):
// a handle opened without it works, but Windows then carries out its I/O one
// request at a time - no parallel reads (measured: Docs/Benchmarks.md,
// "Blocks known in advance").
//
// Every request completes: done, failed or cancelled. Destroy cancels what is
// left and waits for it. Buffers and file handles must stay valid until their
// request has completed. (Known limit: if a ring itself fails - a system
// call error, not an I/O error - its I/O thread stops, and the requests in
// that ring do not complete.)
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
  IORING_ENGINE_MAX_IO_THREADS = 64;
  // With more than one I/O thread: the most requests a thread takes from the
  // queue in one round, before it submits them; if more are waiting, it
  // first wakes a sleeping sibling
  IORING_ENGINE_SHARE_SIZE = 16;

type
  // The handle of a request (from Delphi.IOUring.RequestPool), here too so
  // that users of the engine need only this unit and Delphi.IOUring
  TIORingRequestHandle = Delphi.IOUring.RequestPool.TIORingRequestHandle;

  // Called on the I/O thread that completed the request, for a request
  // started with a callback; ACompletion.UserData is the caller's value. Keep
  // it short (the I/O thread does nothing else meanwhile), and do not wait for
  // other requests in it.
  TIORingCompletionEvent = procedure(const ACompletion: TIORingCompletion) of object;

  // Counted by the I/O threads
  TIORingEngineStats = record
    Requests: UInt64;          // taken from the queue
    Completed: UInt64;         // finished: done, failed or cancelled
    Failed: UInt64;            // finished with an error (not counting end of file and cancelled)
    Cancelled: UInt64;
    Submits: UInt64;           // SubmitIoRing calls
    Sleeps: UInt64;            // times an I/O thread went to sleep
    CallbackErrors: UInt64;    // exceptions raised by callbacks (caught)
  end;

  TIORingEngine = class
  private
    FPool: TIORingRequestPool;
    FQueue: TIORingRequestQueue;
    // The I/O threads (TIORingIOThread, declared in the implementation)
    FIOThreads: array of TThread;
    FStarted: Boolean;
    FMaxRequests: Cardinal;
    // Words that several threads write, each on a cache line of its own
    // (the I/O threads' sleeping flags too)
    FSharedMemory: Pointer;
    FStopping: PInteger;          // 1: Destroy has begun: no new requests
    FStartCalls: PInteger;        // threads inside ReadAsync / WriteAsync / FlushAsync
    FWaitCalls: PInteger;         // threads inside Wait
    FSlotsReleased: PCardinal;    // counts slot releases; threads waiting for a slot sleep on it
    FSlotWaiters: PInteger;       // threads waiting for a free slot
    FSleepingCount: PInteger;     // I/O threads that sleep (or are about to)
    FShutdown: Integer;           // set by Destroy: the I/O threads cancel everything and end

    function StartRequest(const AOperation: TIORingOp; const AFile: THandle; const ABuffer: Pointer;
      const ACount: Cardinal; const AOffset: UInt64; const AFlushMode: TIORingFlushMode;
      const AUserData: NativeUInt; const AOnComplete: TIORingCompletionEvent): TIORingRequestHandle;
    function AcquireSlot: TIORingRequestHandle;
    procedure SlotReleased;
    procedure WakeIOThread;
    function WakeSleepingIOThread(const AExceptIndex: Integer): Boolean;
    function GetIOThreadCount: Integer;
  public
    // AMaxRequests: requests that can be started and not yet waited for (or
    // whose callback has not run); ASubmissionQueueSize: the submission queue
    // of each I/O thread's ring; AIOThreads: 1..IORING_ENGINE_MAX_IO_THREADS.
    // Raises EIORingNotSupported without IoRing.
    constructor Create(const AMaxRequests: Cardinal = IORING_ENGINE_DEFAULT_MAX_REQUESTS;
      const ASubmissionQueueSize: Cardinal = IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE;
      const AIOThreads: Integer = 1);
    // Accepts no new requests, cancels the requests not finished yet and waits
    // until each has completed. Threads blocked in Wait wake up (the result is
    // "cancelled"); calling the engine after Destroy has returned is an error.
    destructor Destroy; override;

    // Start a request and return at once. ABuffer and AFile must stay valid
    // until the request has completed. AUserData comes back in the completion.
    // When all MaxRequests requests are in use, the call sleeps until one is
    // free. Without AOnComplete, finish the request with Wait (or
    // TryGetResult / WaitAll). With AOnComplete, it is called on an I/O
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
    // wake an I/O thread; EndBatch wakes one (if all sleep), so that they go
    // to a ring with few submits. Batches can be nested; one engine at a time
    // per thread.
    procedure BeginBatch;
    procedure EndBatch;

    // All I/O threads added up
    function Stats: TIORingEngineStats;
    // One I/O thread, 0..IOThreadCount - 1
    function IOThreadStats(const AIndex: Integer): TIORingEngineStats;
    // True if AThreadId is one of the engine's I/O threads
    function IsIOThread(const AThreadId: TThreadID): Boolean;

    property MaxRequests: Cardinal read FMaxRequests;
    property IOThreadCount: Integer read GetIOThreadCount;
  end;

implementation

const
  // UserData of the engine's own cancel operations (a request handle is never 0)
  CANCEL_USER_DATA = 0;
  // E_FAIL: for a request the ring refused without an error code
  RESULT_FAILED = Integer($80004005);
  // Cache lines of the engine's shared words, before the sleeping flags
  SHARED_LINES = 5;

type
  // The engine's data in a request slot (the pool's payload)
  TEngineRequest = record
    Operation: TIORingOp;          // ioRead, ioWrite or ioFlush
    FlushMode: TIORingFlushMode;
    InFlightIndex: Integer;        // position in its I/O thread's FInFlight (-1: not in a ring)
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

  // One I/O thread with its own ring
  TIORingIOThread = class(TThread)
  private
    FEngine: TIORingEngine;
    FIndex: Integer;
    FRing: TIORing;
    FWakeEvent: THandle;          // auto-reset: "new requests" (or Destroy)
    FSleeping: PInteger;          // 1: sleeps (or is about to); on its own cache line
    // Written by this thread only (FStats is also read by others)
    FStats: TIORingEngineStats;
    FInFlight: array of TIORingRequestHandle;    // requests in the ring
    FInFlightCount: Integer;
    FDeferred: TIORingRequestHandle;            // taken from the queue, did not fit into the ring yet

    procedure CountStat(var ACounter: UInt64);
    procedure Run;
    function TakeNewRequests: Boolean;
    function PrepareRequest(const AHandle: TIORingRequestHandle): Boolean;
    function ReapCompletions: Boolean;
    procedure FinishRequest(const AHandle: TIORingRequestHandle; const ANativeResult: Integer;
      const ABytesTransferred: NativeUInt);
    procedure RemoveInFlight(const AHandle: TIORingRequestHandle);
    procedure SleepUntilWork;
    procedure CancelEverything;
  protected
    procedure Execute; override;
  public
    constructor Create(const AEngine: TIORingEngine; const AIndex: Integer; const ASleeping: PInteger);
    destructor Destroy; override;
    // Opens the ring; before Start
    procedure Prepare(const ASubmissionQueueSize: Cardinal);
    // Any thread: if this I/O thread sleeps, claims the wake-up and wakes it
    function TryWake: Boolean;
    procedure Signal;
    function GetStats: TIORingEngineStats;
  end;

threadvar
  // BeginBatch / EndBatch of the current thread
  GBatchEngine: TIORingEngine;
  GBatchDepth: Integer;

function IOThread(const AThread: TThread): TIORingIOThread; inline;
begin
  Result := TIORingIOThread(AThread);
end;

{ TIORingIOThread - life cycle }

constructor TIORingIOThread.Create(const AEngine: TIORingEngine; const AIndex: Integer; const ASleeping: PInteger);
begin
  FEngine := AEngine;
  FIndex := AIndex;
  FSleeping := ASleeping;
  inherited Create(True);
end;

destructor TIORingIOThread.Destroy;
begin
  inherited;    // the thread has ended
  FRing.Close;
  if FWakeEvent <> 0 then
    CloseHandle(FWakeEvent);
end;

procedure TIORingIOThread.Prepare(const ASubmissionQueueSize: Cardinal);
begin
  SetLength(FInFlight, FEngine.FMaxRequests);
  FRing.Open(ASubmissionQueueSize);
  FWakeEvent := CreateEvent(nil, False, False, nil);   // auto-reset
  if FWakeEvent = 0 then
    RaiseLastOSError;
end;

procedure TIORingIOThread.Execute;
begin
  // Terminated before it ran: the engine's constructor failed
  if not Terminated then
    Run;
end;

function TIORingIOThread.TryWake: Boolean;
begin
  Result := (TAtomic.LoadAcquire(FSleeping^) <> 0) and (TAtomic.Exchange(FSleeping^, 0) <> 0);
  if Result then
    SetEvent(FWakeEvent);
end;

procedure TIORingIOThread.Signal;
begin
  SetEvent(FWakeEvent);
end;

function TIORingIOThread.GetStats: TIORingEngineStats;
begin
  Result.Requests := TAtomic.LoadAcquire(FStats.Requests);
  Result.Completed := TAtomic.LoadAcquire(FStats.Completed);
  Result.Failed := TAtomic.LoadAcquire(FStats.Failed);
  Result.Cancelled := TAtomic.LoadAcquire(FStats.Cancelled);
  Result.Submits := TAtomic.LoadAcquire(FStats.Submits);
  Result.Sleeps := TAtomic.LoadAcquire(FStats.Sleeps);
  Result.CallbackErrors := TAtomic.LoadAcquire(FStats.CallbackErrors);
end;

{ TIORingIOThread - the loop }

procedure TIORingIOThread.CountStat(var ACounter: UInt64);
begin
  // Only this thread writes: a plain add, stored whole for the readers
  TAtomic.StoreRelease(ACounter, ACounter + 1);
end;

procedure TIORingIOThread.Run;
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
    if TAtomic.LoadAcquire(FEngine.FShutdown) <> 0 then
    begin
      CancelEverything;
      Exit;
    end;
    if not LBusy then
      SleepUntilWork;
  until False;
end;

function TIORingIOThread.TakeNewRequests: Boolean;
var
  LHandle: TIORingRequestHandle;
  LValue: NativeUInt;
  LTaken: Integer;
begin
  Result := False;
  LTaken := 0;
  repeat
    if not FDeferred.IsEmpty then
    begin
      LHandle := FDeferred;
      FDeferred.Value := 0;
    end
    else
    begin
      // With siblings: a share per round, the rest is theirs
      if (LTaken >= IORING_ENGINE_SHARE_SIZE) and (Length(FEngine.FIOThreads) > 1) then
      begin
        if FEngine.FQueue.Count > 0 then
          FEngine.WakeSleepingIOThread(FIndex);
        Exit;
      end;
      if not FEngine.FQueue.TryDequeue(LValue) then
        Exit;
      Inc(LTaken);
      LHandle.Value := LValue;
      CountStat(FStats.Requests);
      FEngine.FPool.TryChangeState(LHandle, rsQueued, rsSubmitted);
    end;

    if not PrepareRequest(LHandle) then
    begin
      FDeferred := LHandle;    // the ring is full: next round
      Exit;
    end;
    Result := True;
  until False;
end;

function TIORingIOThread.PrepareRequest(const AHandle: TIORingRequestHandle): Boolean;
var
  LRequest: PEngineRequest;
  LFile: TIORingFileRef;
  LError: Integer;
begin
  // One place in the ring stays free: Destroy needs it for a cancel when the
  // ring is full of requests that only a cancel ends (reads from a pipe that
  // gets no data). Without it, Destroy waited for them forever.
  if (FRing.CompletionQueueSize > 1) and
    (FRing.PreparedCount + FRing.PendingCount + 1 >= FRing.CompletionQueueSize) then
    Exit(False);

  LRequest := FEngine.FPool.Payload(AHandle);
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

function TIORingIOThread.ReapCompletions: Boolean;
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

procedure TIORingIOThread.RemoveInFlight(const AHandle: TIORingRequestHandle);
var
  LRequest: PEngineRequest;
  LIndex: Integer;
begin
  LRequest := FEngine.FPool.Payload(AHandle);
  LIndex := LRequest^.InFlightIndex;
  if LIndex < 0 then
    Exit;
  // The last one takes its place
  Dec(FInFlightCount);
  if LIndex < FInFlightCount then
  begin
    FInFlight[LIndex] := FInFlight[FInFlightCount];
    PEngineRequest(FEngine.FPool.Payload(FInFlight[LIndex]))^.InFlightIndex := LIndex;
  end;
  LRequest^.InFlightIndex := -1;
end;

procedure TIORingIOThread.FinishRequest(const AHandle: TIORingRequestHandle; const ANativeResult: Integer;
  const ABytesTransferred: NativeUInt);
var
  LRequest: PEngineRequest;
  LCallback: TIORingCompletionEvent;
  LCompletion: TIORingCompletion;
begin
  LRequest := FEngine.FPool.Payload(AHandle);
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
    FEngine.FPool.TryChangeState(AHandle, rsSubmitted, rsCompleted);
    FEngine.FPool.Release(AHandle);
    FEngine.SlotReleased;
  end
  else
    FEngine.FPool.TryChangeState(AHandle, rsSubmitted, rsCompleted);    // wakes the thread in Wait
end;

procedure TIORingIOThread.SleepUntilWork;
var
  LEvents: array[0..1] of THandle;
  LStayAwake: Boolean;
begin
  // Say "sleeping" first, then look once more: a producer that queued a
  // request before it saw all I/O threads sleeping woke none. (Both sides
  // use full barriers, so at least one of the two sees the other.)
  TAtomic.Exchange(FSleeping^, 1);
  TAtomic.Increment(FEngine.FSleepingCount^);
  LStayAwake := TAtomic.LoadAcquire(FEngine.FShutdown) <> 0;
  if not LStayAwake and (FEngine.FQueue.Count > 0) then
  begin
    if FDeferred.IsEmpty then
      LStayAwake := True
    else
      // This ring is full, only a completion helps it: a sibling may take
      // the waiting requests meanwhile
      FEngine.WakeSleepingIOThread(FIndex);
  end;
  if not LStayAwake then
  begin
    CountStat(FStats.Sleeps);
    LEvents[0] := FWakeEvent;
    LEvents[1] := FRing.CompletionEventHandle;
    WaitForMultipleObjects(2, @LEvents[0], False, INFINITE);
  end;
  // (If a producer claimed the wake-up meanwhile, its event comes later:
  // one extra round, harmless)
  TAtomic.Exchange(FSleeping^, 0);
  TAtomic.Decrement(FEngine.FSleepingCount^);
end;

procedure TIORingIOThread.CancelEverything;
var
  LValue: NativeUInt;
  LHandle: TIORingRequestHandle;
  LTargets: array of TIORingRequestHandle;
  LIndex: Integer;
  LPrepared: Boolean;
begin
  // 1. Requests not in a ring yet: cancelled without starting them (the
  //    other I/O threads empty the queue too)
  if not FDeferred.IsEmpty then
  begin
    FinishRequest(FDeferred, IORING_RESULT_CANCELLED, 0);
    FDeferred.Value := 0;
  end;
  while FEngine.FQueue.TryDequeue(LValue) do
  begin
    LHandle.Value := LValue;
    CountStat(FStats.Requests);
    FEngine.FPool.TryChangeState(LHandle, rsQueued, rsSubmitted);
    FinishRequest(LHandle, IORING_RESULT_CANCELLED, 0);
  end;

  // 2. Requests in this ring: ask the ring to cancel each one. (One that
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
          TIORingFileRef.FromHandle(PEngineRequest(FEngine.FPool.Payload(LTargets[LIndex]))^.FileHandle),
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

  // 3. Wait until every request in this ring has completed
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

{ TIORingEngine - life cycle }

constructor TIORingEngine.Create(const AMaxRequests: Cardinal; const ASubmissionQueueSize: Cardinal;
  const AIOThreads: Integer);
var
  LShared: PByte;
  LIndex: Integer;
  LThread: TIORingIOThread;
begin
  inherited Create;
  if (AIOThreads < 1) or (AIOThreads > IORING_ENGINE_MAX_IO_THREADS) then
    raise EIORingError.CreateFmt('The engine needs 1..%d I/O threads, not %d', [IORING_ENGINE_MAX_IO_THREADS,
      AIOThreads]);
  FMaxRequests := AMaxRequests;
  LShared := IORingAllocCacheAligned((SHARED_LINES + AIOThreads) * IORING_CACHE_LINE_SIZE, FSharedMemory);
  FStopping := Pointer(LShared);
  FStartCalls := Pointer(LShared + IORING_CACHE_LINE_SIZE);
  FWaitCalls := Pointer(LShared + 2 * IORING_CACHE_LINE_SIZE);
  // Used together, and only when the pool is full
  FSlotsReleased := Pointer(LShared + 3 * IORING_CACHE_LINE_SIZE);
  FSlotWaiters := Pointer(LShared + 3 * IORING_CACHE_LINE_SIZE + SizeOf(Cardinal));
  FSleepingCount := Pointer(LShared + 4 * IORING_CACHE_LINE_SIZE);

  FPool.Open(AMaxRequests, SizeOf(TEngineRequest));
  // As big as the pool: a request is in the queue at most once, so the queue
  // is never full
  FQueue.Open(AMaxRequests);
  SetLength(FIOThreads, AIOThreads);
  for LIndex := 0 to AIOThreads - 1 do
  begin
    LThread := TIORingIOThread.Create(Self, LIndex,
      Pointer(LShared + (SHARED_LINES + LIndex) * IORING_CACHE_LINE_SIZE));
    FIOThreads[LIndex] := LThread;
    LThread.Prepare(ASubmissionQueueSize);
  end;
  for LIndex := 0 to AIOThreads - 1 do
    FIOThreads[LIndex].Start;
  FStarted := True;
end;

destructor TIORingEngine.Destroy;
var
  LIndex: Integer;
begin
  if FStarted then
  begin
    // 1. No new requests; threads waiting for a free slot give up
    TAtomic.Exchange(FStopping^, 1);
    TAtomic.Increment(FSlotsReleased^);
    TAtomic.WakeAll(FSlotsReleased^);
    // 2. Requests being started right now get into the queue first
    while TAtomic.LoadAcquire(FStartCalls^) > 0 do
      TThread.Yield;
    // 3. The I/O threads cancel what is left, wait for it, and end
    TAtomic.Exchange(FShutdown, 1);
    for LIndex := 0 to High(FIOThreads) do
      IOThread(FIOThreads[LIndex]).Signal;
    for LIndex := 0 to High(FIOThreads) do
      FIOThreads[LIndex].WaitFor;
    // 4. Threads in Wait have been woken (every request has completed): let
    //    them leave before the pool goes away
    while TAtomic.LoadAcquire(FWaitCalls^) > 0 do
      TThread.Yield;
  end
  else
    // The constructor failed: the threads made so far never ran
    for LIndex := 0 to High(FIOThreads) do
      if FIOThreads[LIndex] <> nil then
      begin
        FIOThreads[LIndex].Terminate;
        FIOThreads[LIndex].Start;
        FIOThreads[LIndex].WaitFor;
      end;
  for LIndex := 0 to High(FIOThreads) do
    FIOThreads[LIndex].Free;
  FIOThreads := nil;
  FQueue.Close;
  FPool.Close;
  if FSharedMemory <> nil then
    FreeMem(FSharedMemory);
  inherited;
end;

function TIORingEngine.GetIOThreadCount: Integer;
begin
  Result := Length(FIOThreads);
end;

function TIORingEngine.IsIOThread(const AThreadId: TThreadID): Boolean;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(FIOThreads) do
    if FIOThreads[LIndex].ThreadID = AThreadId then
      Exit(True);
  Result := False;
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
    // Queued before it is in the queue: an I/O thread may take it at once
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
  // The enqueue before this was a full barrier: either this sees all I/O
  // threads sleeping, or one of them (it counts itself and then looks at the
  // queue) sees the new request. An I/O thread that is awake takes it.
  if TAtomic.LoadAcquire(FSleepingCount^) >= Length(FIOThreads) then
    WakeSleepingIOThread(-1);
end;

function TIORingEngine.WakeSleepingIOThread(const AExceptIndex: Integer): Boolean;
var
  LIndex: Integer;
begin
  // The first one that sleeps, so that a light load stays on few threads
  for LIndex := 0 to High(FIOThreads) do
    if (LIndex <> AExceptIndex) and IOThread(FIOThreads[LIndex]).TryWake then
      Exit(True);
  Result := False;
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
var
  LIndex: Integer;
  LOne: TIORingEngineStats;
begin
  FillChar(Result, SizeOf(Result), 0);
  for LIndex := 0 to High(FIOThreads) do
  begin
    LOne := IOThread(FIOThreads[LIndex]).GetStats;
    Inc(Result.Requests, LOne.Requests);
    Inc(Result.Completed, LOne.Completed);
    Inc(Result.Failed, LOne.Failed);
    Inc(Result.Cancelled, LOne.Cancelled);
    Inc(Result.Submits, LOne.Submits);
    Inc(Result.Sleeps, LOne.Sleeps);
    Inc(Result.CallbackErrors, LOne.CallbackErrors);
  end;
end;

function TIORingEngine.IOThreadStats(const AIndex: Integer): TIORingEngineStats;
begin
  if (AIndex < 0) or (AIndex >= Length(FIOThreads)) then
    raise EIORingError.CreateFmt('IOThreadStats: no I/O thread %d (0..%d)', [AIndex, High(FIOThreads)]);
  Result := IOThread(FIOThreads[AIndex]).GetStats;
end;

end.
