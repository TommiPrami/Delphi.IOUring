unit PIRUnit.RequestPool.Tests;

{
  Tests for PIRUnit.RequestPool: the lock-free free list and the
  request pool (slots, states, handles, waiting).

  Stale handles: after Release every method must see the old handle as
  stale. Multi-thread stress: no slot or index may ever be held by two
  threads at once, none may get lost, and a simulated engine (producers + one
  "I/O thread") must hand every request over and back without a lost
  wake-up. The thread bodies are methods of the tests (Work*), run by
  RunThreads.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.RequestPool, PIRUnit.Test.Support;

const
  STRESS_CAPACITY = 8;

type
  TFreeListTests = class(TIORingTestCase)
  private
    FList: TIORingFreeList;
    FOwned: array[0..STRESS_CAPACITY - 1] of Integer;   // 1 while a thread holds the index
    FFailures: Integer;
    procedure WorkPopAndPush(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Open_Full_PopsEveryIndexOnce;
    procedure Open_Empty_LastPushedComesFirst;
    procedure CapacityOne_Works;
    procedure BadArguments_Raise;
    procedure Stress_NoIndexLostOrTakenTwice;
  end;

  TRequestPoolTests = class(TIORingTestCase)
  private
    FPool: TIORingRequestPool;
    FOwned: array[0..STRESS_CAPACITY - 1] of Integer;   // 1 while a thread holds the slot
    FFailures: Integer;
    FHandle: TIORingRequestHandle;                      // for WorkWaitFor
    FWaitResult: TIORingWaitResult;
    // The simulated engine: one mailbox per producer, the I/O thread takes the handles from them
    FMailboxes: array[0..7] of NativeUInt;
    FProducersDone: Integer;
    procedure RunEngineSimulation(const ASpinMicroseconds: Cardinal);
    procedure CheckAllSlotsFree;
    procedure StartWaiter(out AThread: TWorkerThread);
    // Thread bodies
    procedure WorkWaitFor(AIndex: Integer);
    procedure WorkAcquireAndRelease(AIndex: Integer);
    procedure WorkEngine(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // Slots and handles
    procedure Open_EverySlotAcquirableOnce;
    procedure BadArguments_Raise;
    procedure Handle_HoldsIndexAndGeneration;
    procedure Release_MakesHandleStale;
    procedure EmptyAndOutOfRangeHandles_AreStale;
    procedure StateChanges_FollowTheRules;
    procedure TryChangeState_FreeOrStale_Raises;
    procedure Payload_IsAlignedSeparateAndZeroed;
    procedure GenerationBits_DependOnCapacity;
    procedure Generation_WrapsAroundWithoutZero;
    // Waiting
    procedure WaitFor_Completed_ReturnsAtOnce;
    procedure WaitFor_ZeroTimeout_OnlyChecks;
    procedure WaitFor_Timeout_ReturnsAfterTimeout;
    procedure WaitFor_WokenByCompletion;
    procedure WaitFor_WokenByRelease_ReturnsStale;
    // Several threads
    procedure Stress_NoSlotTakenTwice;
    procedure Stress_EngineSimulation;
    procedure Stress_EngineSimulation_WithoutSpinning;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Atomics;

const
  STRESS_THREADS = 4;
  STRESS_ROUNDS = 50000;
  STRESS_HOLD = 3;          // 4 threads x 3 > 8: pops and acquires also find nothing free
  ENGINE_PRODUCERS = 4;
  ENGINE_ROUNDS = 20000;

type
  // The payload of the engine simulation
  TTestPayload = record
    Request: Int64;    // written by the producer
    Answer: Int64;     // written by the I/O thread: Request * 3
  end;
  PTestPayload = ^TTestPayload;

{ TFreeListTests }

procedure TFreeListTests.SetUp;
begin
  FillChar(FOwned, SizeOf(FOwned), 0);
  FFailures := 0;
end;

procedure TFreeListTests.TearDown;
begin
  FList.Close;
end;

procedure TFreeListTests.Open_Full_PopsEveryIndexOnce;
const
  CAPACITY = 100;
var
  LSeen: array[0..CAPACITY - 1] of Boolean;
  LCount: Integer;
  LIndex: Cardinal;
begin
  FillChar(LSeen, SizeOf(LSeen), 0);
  FList.Open(CAPACITY);
  AssertEquals('Capacity', CAPACITY, Int64(FList.Capacity));

  for LCount := 1 to CAPACITY do
  begin
    AssertTrue('Pop ' + IntToStr(LCount), FList.TryPop(LIndex));
    AssertTrue('In range', LIndex < CAPACITY);
    AssertFalse('Popped twice: ' + IntToStr(LIndex), LSeen[LIndex]);
    LSeen[LIndex] := True;
  end;

  AssertFalse('Empty after all', FList.TryPop(LIndex));
end;

procedure TFreeListTests.Open_Empty_LastPushedComesFirst;
var
  LIndex: Cardinal;
begin
  FList.Open(10, False);
  AssertFalse('Opened empty', FList.TryPop(LIndex));
  FList.Push(3);
  FList.Push(7);
  FList.Push(1);
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(1, Int64(LIndex));
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(7, Int64(LIndex));
  FList.Push(9);
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(9, Int64(LIndex));
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(3, Int64(LIndex));
  AssertFalse('Empty again', FList.TryPop(LIndex));
end;

procedure TFreeListTests.CapacityOne_Works;
var
  LIndex: Cardinal;
begin
  FList.Open(1);
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(0, Int64(LIndex));
  AssertFalse(FList.TryPop(LIndex));
  FList.Push(0);
  AssertTrue(FList.TryPop(LIndex));
  AssertEquals(0, Int64(LIndex));
end;

procedure TFreeListTests.BadArguments_Raise;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    FList.Open(0);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity 0', LRaised);

  LRaised := False;

  try
    FList.Open(IORING_POOL_MAX_CAPACITY + 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity too big', LRaised);

  FList.Open(4, False);
  LRaised := False;

  try
    FList.Push(4);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Index out of range', LRaised);

  LRaised := False;

  try
    FList.Open(4);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Opened twice', LRaised);
end;

procedure TFreeListTests.WorkPopAndPush(AIndex: Integer);
var
  LRound: Integer;
  LHeld: array[0..STRESS_HOLD - 1] of Cardinal;
  LHeldCount: Integer;
  LSlot: Integer;
begin
  for LRound := 1 to 2 * STRESS_ROUNDS do
  begin
    LHeldCount := 0;

    while (LHeldCount < STRESS_HOLD) and FList.TryPop(LHeld[LHeldCount]) do
    begin
      if TAtomic.Exchange(FOwned[LHeld[LHeldCount]], 1) <> 0 then
        TAtomic.Increment(FFailures);    // another thread holds it too

      Inc(LHeldCount);
    end;

    for LSlot := 0 to LHeldCount - 1 do
    begin
      if TAtomic.Exchange(FOwned[LHeld[LSlot]], 0) <> 1 then
        TAtomic.Increment(FFailures);

      FList.Push(LHeld[LSlot]);
    end;
  end;
end;

procedure TFreeListTests.Stress_NoIndexLostOrTakenTwice;
var
  LSeen: array[0..STRESS_CAPACITY - 1] of Boolean;
  LCount: Integer;
  LIndex: Cardinal;
begin
  FList.Open(STRESS_CAPACITY);
  RunThreads(STRESS_THREADS, WorkPopAndPush);
  AssertEquals('Indices held by two threads at once', 0, FFailures);

  // Every index is back, once
  FillChar(LSeen, SizeOf(LSeen), 0);

  for LCount := 1 to STRESS_CAPACITY do
  begin
    AssertTrue('Lost index', FList.TryPop(LIndex));
    AssertFalse('Index twice in the stack', LSeen[LIndex]);
    LSeen[LIndex] := True;
  end;

  AssertFalse('More indices than the capacity', FList.TryPop(LIndex));
end;

{ TRequestPoolTests }

procedure TRequestPoolTests.SetUp;
begin
  FillChar(FOwned, SizeOf(FOwned), 0);
  FillChar(FMailboxes, SizeOf(FMailboxes), 0);
  FFailures := 0;
  FProducersDone := 0;
end;

procedure TRequestPoolTests.TearDown;
begin
  FPool.Close;
end;

procedure TRequestPoolTests.CheckAllSlotsFree;
var
  LHandles: array of TIORingRequestHandle;
  LIndex: Integer;
  LExtra: TIORingRequestHandle;
begin
  SetLength(LHandles, FPool.Capacity);

  for LIndex := 0 to High(LHandles) do
    AssertTrue('Slot lost', FPool.TryAcquire(LHandles[LIndex]));

  AssertFalse('More slots than the capacity', FPool.TryAcquire(LExtra));

  for LIndex := 0 to High(LHandles) do
    AssertTrue('Release', FPool.Release(LHandles[LIndex]));
end;

procedure TRequestPoolTests.StartWaiter(out AThread: TWorkerThread);
begin
  FWaitResult := wrTimeout;
  AThread := TWorkerThread.Create(0, 1, nil, WorkWaitFor);
  AThread.Start;
end;

procedure TRequestPoolTests.WorkWaitFor(AIndex: Integer);
begin
  FWaitResult := FPool.WaitFor(FHandle, 10000);
end;

procedure TRequestPoolTests.Open_EverySlotAcquirableOnce;
const
  CAPACITY = 50;
var
  LHandles: array[0..CAPACITY - 1] of TIORingRequestHandle;
  LSeen: array[0..CAPACITY - 1] of Boolean;
  LIndex: Integer;
  LSlot: Cardinal;
  LExtra: TIORingRequestHandle;
begin
  FillChar(LSeen, SizeOf(LSeen), 0);
  FPool.Open(CAPACITY);
  AssertEquals('Capacity', CAPACITY, Int64(FPool.Capacity));

  for LIndex := 0 to CAPACITY - 1 do
  begin
    AssertTrue('Acquire ' + IntToStr(LIndex), FPool.TryAcquire(LHandles[LIndex]));
    AssertFalse('Handle is not empty', LHandles[LIndex].IsEmpty);
    AssertTrue('Defined', FPool.State(LHandles[LIndex]) = rsDefined);
    LSlot := FPool.IndexOf(LHandles[LIndex]);
    AssertTrue('Index in range', LSlot < CAPACITY);
    AssertFalse('Slot given twice', LSeen[LSlot]);
    LSeen[LSlot] := True;
  end;

  AssertFalse('All slots in use', FPool.TryAcquire(LExtra));
  AssertTrue('Failed acquire gives an empty handle', LExtra.IsEmpty);

  for LIndex := 0 to CAPACITY - 1 do
    AssertTrue('Release ' + IntToStr(LIndex), FPool.Release(LHandles[LIndex]));

  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.BadArguments_Raise;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    FPool.Open(0);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity 0', LRaised);

  LRaised := False;

  try
    FPool.Open(IORING_POOL_MAX_CAPACITY + 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity too big', LRaised);

  LRaised := False;

  try
    FPool.Open(4, IORING_POOL_MAX_PAYLOAD_SIZE + 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Payload too big', LRaised);

  FPool.Open(4);
  LRaised := False;

  try
    FPool.Open(4);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Opened twice', LRaised);
end;

procedure TRequestPoolTests.Handle_HoldsIndexAndGeneration;
var
  LFirst: TIORingRequestHandle;
  LSecond: TIORingRequestHandle;
begin
  FPool.Open(10);
  AssertTrue(FPool.TryAcquire(LFirst));
  AssertTrue(FPool.Release(LFirst));
  // The free list is last-in first-out: the same slot comes back
  AssertTrue(FPool.TryAcquire(LSecond));
  AssertEquals('Same slot', Int64(FPool.IndexOf(LFirst)), Int64(FPool.IndexOf(LSecond)));
  AssertTrue('Another generation, another handle', LFirst.Value <> LSecond.Value);
  AssertTrue('New handle is current', FPool.State(LSecond) = rsDefined);
  AssertTrue('Old handle is stale', FPool.State(LFirst) = rsStale);
  AssertTrue('FromUserData', TIORingRequestHandle.FromUserData(LSecond.Value).Value = LSecond.Value);
end;

procedure TRequestPoolTests.Release_MakesHandleStale;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsCompleted));
  AssertTrue(FPool.Release(LHandle));

  AssertTrue('State', FPool.State(LHandle) = rsStale);
  AssertFalse('Release again', FPool.Release(LHandle));
  AssertFalse('Change from Defined', FPool.TryChangeState(LHandle, rsDefined, rsQueued));
  AssertFalse('Change from Completed', FPool.TryChangeState(LHandle, rsCompleted, rsQueued));
  AssertTrue('WaitFor returns at once', FPool.WaitFor(LHandle) = wrStale);
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.EmptyAndOutOfRangeHandles_AreStale;
var
  LEmpty: TIORingRequestHandle;
  LOutOfRange: TIORingRequestHandle;
begin
  FPool.Open(10);   // 4 index bits: index 15 is out of range
  LEmpty.Value := 0;
  LOutOfRange.Value := (1 shl 4) or 15;
  AssertTrue('Empty: State', FPool.State(LEmpty) = rsStale);
  AssertFalse('Empty: Release', FPool.Release(LEmpty));
  AssertTrue('Empty: WaitFor', FPool.WaitFor(LEmpty) = wrStale);
  AssertTrue('Out of range: State', FPool.State(LOutOfRange) = rsStale);
  AssertFalse('Out of range: Release', FPool.Release(LOutOfRange));
  AssertFalse('Out of range: change', FPool.TryChangeState(LOutOfRange, rsDefined, rsQueued));
  AssertTrue('Out of range: WaitFor', FPool.WaitFor(LOutOfRange) = wrStale);
end;

procedure TRequestPoolTests.StateChanges_FollowTheRules;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.State(LHandle) = rsDefined);
  AssertFalse('Wrong "from" state', FPool.TryChangeState(LHandle, rsQueued, rsSubmitted));
  AssertTrue('Unchanged', FPool.State(LHandle) = rsDefined);

  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsQueued));
  AssertTrue(FPool.State(LHandle) = rsQueued);
  AssertFalse('No release while Queued', FPool.Release(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsQueued, rsSubmitted));
  AssertFalse('No release while Submitted', FPool.Release(LHandle));
  AssertTrue(FPool.State(LHandle) = rsSubmitted);
  AssertTrue(FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted));
  AssertTrue(FPool.State(LHandle) = rsCompleted);
  AssertTrue('Release when Completed', FPool.Release(LHandle));

  // Released without ever being queued
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue('Release when Defined', FPool.Release(LHandle));

  // Cancelled before it was submitted
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsQueued));
  AssertTrue(FPool.TryChangeState(LHandle, rsQueued, rsCompleted));
  AssertTrue(FPool.Release(LHandle));
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.TryChangeState_FreeOrStale_Raises;
var
  LHandle: TIORingRequestHandle;
  LRaised: Boolean;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));

  LRaised := False;

  try
    FPool.TryChangeState(LHandle, rsDefined, rsFree);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('To Free (use Release)', LRaised);

  LRaised := False;

  try
    FPool.TryChangeState(LHandle, rsFree, rsDefined);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('From Free (use TryAcquire)', LRaised);

  LRaised := False;

  try
    FPool.TryChangeState(LHandle, rsDefined, rsStale);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('To Stale', LRaised);
  AssertTrue('Unchanged', FPool.State(LHandle) = rsDefined);
end;

procedure TRequestPoolTests.Payload_IsAlignedSeparateAndZeroed;
const
  CAPACITY = 16;
  PAYLOAD_SIZE = 100;
var
  LHandles: array[0..CAPACITY - 1] of TIORingRequestHandle;
  LIndex: Integer;
  LByte: Integer;
  LPayload: PByte;
begin
  FPool.Open(CAPACITY, PAYLOAD_SIZE);
  AssertEquals('PayloadSize', PAYLOAD_SIZE, Int64(FPool.PayloadSize));

  for LIndex := 0 to CAPACITY - 1 do
  begin
    AssertTrue(FPool.TryAcquire(LHandles[LIndex]));
    LPayload := FPool.Payload(LHandles[LIndex]);
    AssertEquals('Payload 8-byte aligned', 0, Int64(NativeUInt(LPayload) mod 8));
    AssertEquals('Slot starts on a cache line', 0, Int64((NativeUInt(LPayload) - 8) mod 64));

    for LByte := 0 to PAYLOAD_SIZE - 1 do
      AssertEquals('Zeroed at Open', 0, LPayload[LByte]);

    FillChar(LPayload^, PAYLOAD_SIZE, Byte(LIndex + 1));
  end;

  // No payload overlaps another
  for LIndex := 0 to CAPACITY - 1 do
  begin
    LPayload := FPool.Payload(LHandles[LIndex]);

    for LByte := 0 to PAYLOAD_SIZE - 1 do
      AssertEquals(Format('Slot %d byte %d', [LIndex, LByte]), LIndex + 1, LPayload[LByte]);
  end;
end;

procedure TRequestPoolTests.GenerationBits_DependOnCapacity;
begin
  FPool.Open(10);
  AssertEquals('Small pool: the most the state word holds', 28, Int64(FPool.GenerationBits));
  FPool.Close;
  FPool.Open(IORING_POOL_MAX_CAPACITY);
{$IF SizeOf(NativeUInt) = 4}
  AssertEquals('Win32, 2^20 slots: 32 - 20 bits', 12, Int64(FPool.GenerationBits));
{$ELSE}
  AssertEquals('64-bit: always 28', 28, Int64(FPool.GenerationBits));
{$ENDIF}
end;

procedure TRequestPoolTests.Generation_WrapsAroundWithoutZero;
{$IF SizeOf(NativeUInt) = 8}
begin
  // Checked on Win32 only: 28 generation bits are too many to wrap in a test
  AssertTrue(True);
end;
{$ELSE}
var
  LFirst: TIORingRequestHandle;
  LHandle: TIORingRequestHandle;
  LRound: Integer;
begin
  FPool.Open(IORING_POOL_MAX_CAPACITY);   // Win32: 20 index bits, 12 generation bits
  AssertTrue(FPool.TryAcquire(LFirst));
  AssertTrue(FPool.Release(LFirst));

  // Generations 2 .. 4095, then 1 again (0 is skipped)
  for LRound := 2 to (1 shl FPool.GenerationBits) - 1 do
  begin
    AssertTrue(FPool.TryAcquire(LHandle));
    AssertEquals('Same slot', Int64(FPool.IndexOf(LFirst)), Int64(FPool.IndexOf(LHandle)));
    CheckEqualsU64('Generation', LRound, LHandle.Value shr 20);
    AssertTrue(FPool.Release(LHandle));
  end;

  AssertTrue(FPool.TryAcquire(LHandle));
  CheckEqualsU64('Wrapped around to generation 1', LFirst.Value, LHandle.Value);
end;
{$ENDIF}

procedure TRequestPoolTests.WaitFor_Completed_ReturnsAtOnce;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsCompleted));
  AssertTrue(FPool.WaitFor(LHandle) = wrCompleted);
  AssertTrue('Timeout 0', FPool.WaitFor(LHandle, 0) = wrCompleted);
end;

procedure TRequestPoolTests.WaitFor_ZeroTimeout_OnlyChecks;
var
  LHandle: TIORingRequestHandle;
  LStart: UInt64;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsSubmitted));
  LStart := TThread.GetTickCount64;
  AssertTrue(FPool.WaitFor(LHandle, 0) = wrTimeout);
  AssertTrue(Format('Took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 100);
end;

procedure TRequestPoolTests.WaitFor_Timeout_ReturnsAfterTimeout;
var
  LHandle: TIORingRequestHandle;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(LHandle));
  AssertTrue(FPool.TryChangeState(LHandle, rsDefined, rsSubmitted));
  LStart := TThread.GetTickCount64;
  AssertTrue(FPool.WaitFor(LHandle, 50) = wrTimeout);
  LElapsed := TThread.GetTickCount64 - LStart;
  // GetTickCount64 moves in steps of about 16 ms: 50 ms show as 46 or more
  AssertTrue(Format('Waited only %d ms', [LElapsed]), LElapsed >= 45);
  // Still usable: completes and releases normally
  AssertTrue(FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted));
  AssertTrue(FPool.Release(LHandle));
end;

procedure TRequestPoolTests.WaitFor_WokenByCompletion;
var
  LThread: TWorkerThread;
  LStart: UInt64;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(FHandle));
  AssertTrue(FPool.TryChangeState(FHandle, rsDefined, rsSubmitted));
  StartWaiter(LThread);

  try
    Sleep(50); // let it fall asleep
    LStart := TThread.GetTickCount64;
    AssertTrue(FPool.TryChangeState(FHandle, rsSubmitted, rsCompleted));
    LThread.WaitFor;
  finally
    LThread.Free;
  end;

  AssertTrue('Result', FWaitResult = wrCompleted);
  AssertTrue(Format('Wake-up took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 5000);
end;

procedure TRequestPoolTests.WaitFor_WokenByRelease_ReturnsStale;
var
  LThread: TWorkerThread;
  LStart: UInt64;
begin
  FPool.Open(4);
  AssertTrue(FPool.TryAcquire(FHandle));   // Defined: may be released
  StartWaiter(LThread);

  try
    Sleep(50); // let it fall asleep
    LStart := TThread.GetTickCount64;
    AssertTrue(FPool.Release(FHandle));
    LThread.WaitFor;
  finally
    LThread.Free;
  end;

  AssertTrue('Result', FWaitResult = wrStale);
  AssertTrue(Format('Wake-up took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 5000);
end;

procedure TRequestPoolTests.WorkAcquireAndRelease(AIndex: Integer);
var
  LRound: Integer;
  LHeld: array[0..STRESS_HOLD - 1] of TIORingRequestHandle;
  LHeldCount: Integer;
  LSlot: Integer;
begin
  for LRound := 1 to STRESS_ROUNDS do
  begin
    LHeldCount := 0;

    while (LHeldCount < STRESS_HOLD) and FPool.TryAcquire(LHeld[LHeldCount]) do
    begin
      if TAtomic.Exchange(FOwned[FPool.IndexOf(LHeld[LHeldCount])], 1) <> 0 then
        TAtomic.Increment(FFailures);    // another thread holds it too

      Inc(LHeldCount);
    end;

    for LSlot := 0 to LHeldCount - 1 do
    begin
      if not FPool.TryChangeState(LHeld[LSlot], rsDefined, rsCompleted) then
        TAtomic.Increment(FFailures);

      if TAtomic.Exchange(FOwned[FPool.IndexOf(LHeld[LSlot])], 0) <> 1 then
        TAtomic.Increment(FFailures);

      if not FPool.Release(LHeld[LSlot]) then
        TAtomic.Increment(FFailures);
    end;
  end;
end;

procedure TRequestPoolTests.Stress_NoSlotTakenTwice;
begin
  FPool.Open(STRESS_CAPACITY);
  RunThreads(STRESS_THREADS, WorkAcquireAndRelease);
  AssertEquals('Slots held by two threads, or wrong state changes', 0, FFailures);
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.WorkEngine(AIndex: Integer);
var
  LRound: Integer;
  LHandle: TIORingRequestHandle;
  LPayload: PTestPayload;
  LRequest: Int64;
  LProducer: Integer;
  LValue: NativeUInt;
  LFound: Boolean;
  LServed: Integer;
begin
  if AIndex = 0 then
  begin
    // The I/O thread
    LServed := 0;

    while TAtomic.LoadAcquire(FProducersDone) < ENGINE_PRODUCERS do
    begin
      LFound := False;

      for LProducer := 1 to ENGINE_PRODUCERS do
      begin
        LValue := TAtomic.Exchange(FMailboxes[LProducer], 0);

        if LValue = 0 then
          Continue;

        LFound := True;
        LHandle := TIORingRequestHandle.FromUserData(LValue);

        if not FPool.TryChangeState(LHandle, rsQueued, rsSubmitted) then
          TAtomic.Increment(FFailures);

        // Now and then slow: the producer falls asleep
        Inc(LServed);

        if LServed mod 64 = 0 then
          SpinMicroseconds(100);

        LPayload := FPool.Payload(LHandle);
        LPayload^.Answer := LPayload^.Request * 3;

        if not FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted) then
          TAtomic.Increment(FFailures);
      end;

      if not LFound then
        TAtomic.CpuPause;
    end;
  end
  else

  try
    // A producer
    for LRound := 1 to ENGINE_ROUNDS do
    begin
      while not FPool.TryAcquire(LHandle) do
        TThread.Yield;    // all slots in use

      LPayload := FPool.Payload(LHandle);
      LRequest := (Int64(AIndex) shl 32) or LRound;
      LPayload^.Request := LRequest;
      LPayload^.Answer := 0;

      if not FPool.TryChangeState(LHandle, rsDefined, rsQueued) then
        TAtomic.Increment(FFailures);

      TAtomic.StoreRelease(FMailboxes[AIndex], LHandle.Value);

      if FPool.WaitFor(LHandle, 10000) <> wrCompleted then
      begin
        TAtomic.Increment(FFailures);   // lost wake-up

        Exit;
      end;

      if LPayload^.Answer <> LRequest * 3 then
        TAtomic.Increment(FFailures);

      if not FPool.Release(LHandle) then
        TAtomic.Increment(FFailures);
    end;
  finally
    TAtomic.Increment(FProducersDone);
  end;
end;

procedure TRequestPoolTests.RunEngineSimulation(const ASpinMicroseconds: Cardinal);
begin
  // Fewer slots than producers: TryAcquire also fails now and then
  FPool.Open(ENGINE_PRODUCERS - 1, SizeOf(TTestPayload));
  FPool.SpinMicroseconds := ASpinMicroseconds;
  // Thread 0 is the I/O thread, 1..ENGINE_PRODUCERS the producers
  RunThreads(1 + ENGINE_PRODUCERS, WorkEngine);
  AssertEquals('Wrong states, wrong answers or lost wake-ups', 0, FFailures);
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.Stress_EngineSimulation;
begin
  RunEngineSimulation(IORING_POOL_DEFAULT_SPIN_MICROSECONDS);
end;

procedure TRequestPoolTests.Stress_EngineSimulation_WithoutSpinning;
begin
  // Every WaitFor that finds the request not completed goes to sleep
  RunEngineSimulation(0);
end;

initialization
  RegisterTests(TFreeListTests);
  RegisterTests(TRequestPoolTests);

end.
