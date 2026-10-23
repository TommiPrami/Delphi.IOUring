unit Tests.RequestPool;

{
  Tests for Delphi.IOUring.RequestPool: the lock-free free list and the
  request pool (slots, states, handles, waiting).

  Stale handles: after Release every method must see the old handle as
  stale. Multi-thread stress: no slot or index may ever be held by two
  threads at once, none may get lost, and a simulated engine (producers + one
  "I/O thread") must hand every request over and back without a lost
  wake-up.
}

interface

uses
  DUnitX.TestFramework,
  Delphi.IOUring.RequestPool;

const
  STRESS_CAPACITY = 8;

type
  [TestFixture]
  TFreeListTests = class
  private
    FList: TIORingFreeList;
    FOwned: array[0..STRESS_CAPACITY - 1] of Integer;   // 1 while a thread holds the index
    FFailures: Integer;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure Open_Full_PopsEveryIndexOnce;
    [Test]
    procedure Open_Empty_LastPushedComesFirst;
    [Test]
    procedure CapacityOne_Works;
    [Test]
    procedure BadArguments_Raise;
    [Test]
    procedure Stress_NoIndexLostOrTakenTwice;
  end;

  [TestFixture]
  TRequestPoolTests = class
  private
    FPool: TIORingRequestPool;
    FOwned: array[0..STRESS_CAPACITY - 1] of Integer;   // 1 while a thread holds the slot
    FFailures: Integer;
    FWaitResult: TIORingWaitResult;
    // The simulated engine: one mailbox per producer, the I/O thread takes
    // the handles from them
    FMailboxes: array[0..7] of NativeUInt;
    FProducersDone: Integer;
    procedure RunEngineSimulation(const ASpinMicroseconds: Cardinal);
    procedure CheckAllSlotsFree;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // Slots and handles
    [Test]
    procedure Open_EverySlotAcquirableOnce;
    [Test]
    procedure BadArguments_Raise;
    [Test]
    procedure Handle_HoldsIndexAndGeneration;
    [Test]
    procedure Release_MakesHandleStale;
    [Test]
    procedure EmptyAndOutOfRangeHandles_AreStale;
    [Test]
    procedure StateChanges_FollowTheRules;
    [Test]
    procedure TryChangeState_FreeOrStale_Raises;
    [Test]
    procedure Payload_IsAlignedSeparateAndZeroed;
    [Test]
    procedure GenerationBits_DependOnCapacity;
    [Test]
    procedure Generation_WrapsAroundWithoutZero;

    // Waiting
    [Test]
    procedure WaitFor_Completed_ReturnsAtOnce;
    [Test]
    procedure WaitFor_ZeroTimeout_OnlyChecks;
    [Test]
    procedure WaitFor_Timeout_ReturnsAfterTimeout;
    [Test]
    procedure WaitFor_WokenByCompletion;
    [Test]
    procedure WaitFor_WokenByRelease_ReturnsStale;

    // Several threads
    [Test]
    procedure Stress_NoSlotTakenTwice;
    [Test]
    procedure Stress_EngineSimulation;
    [Test]
    procedure Stress_EngineSimulation_WithoutSpinning;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  Delphi.IOUring,
  Delphi.IOUring.Atomics,
  TestThreadHelpers;

type
  // The payload of the engine simulation
  TTestPayload = record
    Request: Int64;    // written by the producer
    Answer: Int64;     // written by the I/O thread: Request * 3
  end;
  PTestPayload = ^TTestPayload;

{ TFreeListTests }

procedure TFreeListTests.Setup;
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
  Assert.AreEqual(Cardinal(CAPACITY), FList.Capacity);
  for LCount := 1 to CAPACITY do
  begin
    Assert.IsTrue(FList.TryPop(LIndex), 'Pop ' + IntToStr(LCount));
    Assert.IsTrue(LIndex < CAPACITY, 'In range');
    Assert.IsFalse(LSeen[LIndex], 'Popped twice: ' + IntToStr(LIndex));
    LSeen[LIndex] := True;
  end;
  Assert.IsFalse(FList.TryPop(LIndex), 'Empty after all');
end;

procedure TFreeListTests.Open_Empty_LastPushedComesFirst;
var
  LIndex: Cardinal;
begin
  FList.Open(10, False);
  Assert.IsFalse(FList.TryPop(LIndex), 'Opened empty');
  FList.Push(3);
  FList.Push(7);
  FList.Push(1);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(1), LIndex);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(7), LIndex);
  FList.Push(9);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(9), LIndex);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(3), LIndex);
  Assert.IsFalse(FList.TryPop(LIndex), 'Empty again');
end;

procedure TFreeListTests.CapacityOne_Works;
var
  LIndex: Cardinal;
begin
  FList.Open(1);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(0), LIndex);
  Assert.IsFalse(FList.TryPop(LIndex));
  FList.Push(0);
  Assert.IsTrue(FList.TryPop(LIndex));
  Assert.AreEqual(Cardinal(0), LIndex);
end;

procedure TFreeListTests.BadArguments_Raise;
begin
  Assert.WillRaise(
    procedure
    begin
      FList.Open(0);
    end, EIORingError, 'Capacity 0');
  Assert.WillRaise(
    procedure
    begin
      FList.Open(IORING_POOL_MAX_CAPACITY + 1);
    end, EIORingError, 'Capacity too big');
  FList.Open(4, False);
  Assert.WillRaise(
    procedure
    begin
      FList.Push(4);
    end, EIORingError, 'Index out of range');
  Assert.WillRaise(
    procedure
    begin
      FList.Open(4);
    end, EIORingError, 'Opened twice');
end;

procedure TFreeListTests.Stress_NoIndexLostOrTakenTwice;
const
  ROUNDS = 100000;
  HOLD = 3;   // 4 threads x 3 > 8 indices: pops also find the stack empty
var
  LSeen: array[0..STRESS_CAPACITY - 1] of Boolean;
  LCount: Integer;
  LIndex: Cardinal;
begin
  FList.Open(STRESS_CAPACITY);
  RunThreads(4,
    procedure(AThread: Integer)
    var
      LRound: Integer;
      LHeld: array[0..HOLD - 1] of Cardinal;
      LHeldCount: Integer;
      LSlot: Integer;
    begin
      for LRound := 1 to ROUNDS do
      begin
        LHeldCount := 0;
        while (LHeldCount < HOLD) and FList.TryPop(LHeld[LHeldCount]) do
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
    end);
  Assert.AreEqual(0, FFailures, 'Indices held by two threads at once');

  // Every index is back, once
  FillChar(LSeen, SizeOf(LSeen), 0);
  for LCount := 1 to STRESS_CAPACITY do
  begin
    Assert.IsTrue(FList.TryPop(LIndex), 'Lost index');
    Assert.IsFalse(LSeen[LIndex], 'Index twice in the stack');
    LSeen[LIndex] := True;
  end;
  Assert.IsFalse(FList.TryPop(LIndex), 'More indices than the capacity');
end;

{ TRequestPoolTests }

procedure TRequestPoolTests.Setup;
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
    Assert.IsTrue(FPool.TryAcquire(LHandles[LIndex]), 'Slot lost');
  Assert.IsFalse(FPool.TryAcquire(LExtra), 'More slots than the capacity');
  for LIndex := 0 to High(LHandles) do
    Assert.IsTrue(FPool.Release(LHandles[LIndex]));
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
  Assert.AreEqual(Cardinal(CAPACITY), FPool.Capacity);
  for LIndex := 0 to CAPACITY - 1 do
  begin
    Assert.IsTrue(FPool.TryAcquire(LHandles[LIndex]), 'Acquire ' + IntToStr(LIndex));
    Assert.IsFalse(LHandles[LIndex].IsEmpty, 'Handle is not empty');
    Assert.IsTrue(FPool.State(LHandles[LIndex]) = rsDefined, 'Defined');
    LSlot := FPool.IndexOf(LHandles[LIndex]);
    Assert.IsTrue(LSlot < CAPACITY, 'Index in range');
    Assert.IsFalse(LSeen[LSlot], 'Slot given twice');
    LSeen[LSlot] := True;
  end;
  Assert.IsFalse(FPool.TryAcquire(LExtra), 'All slots in use');
  Assert.IsTrue(LExtra.IsEmpty, 'Failed acquire gives an empty handle');

  for LIndex := 0 to CAPACITY - 1 do
    Assert.IsTrue(FPool.Release(LHandles[LIndex]), 'Release ' + IntToStr(LIndex));
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.BadArguments_Raise;
begin
  Assert.WillRaise(
    procedure
    begin
      FPool.Open(0);
    end, EIORingError, 'Capacity 0');
  Assert.WillRaise(
    procedure
    begin
      FPool.Open(IORING_POOL_MAX_CAPACITY + 1);
    end, EIORingError, 'Capacity too big');
  Assert.WillRaise(
    procedure
    begin
      FPool.Open(4, IORING_POOL_MAX_PAYLOAD_SIZE + 1);
    end, EIORingError, 'Payload too big');
  FPool.Open(4);
  Assert.WillRaise(
    procedure
    begin
      FPool.Open(4);
    end, EIORingError, 'Opened twice');
end;

procedure TRequestPoolTests.Handle_HoldsIndexAndGeneration;
var
  LFirst: TIORingRequestHandle;
  LSecond: TIORingRequestHandle;
begin
  FPool.Open(10);
  Assert.IsTrue(FPool.TryAcquire(LFirst));
  Assert.IsTrue(FPool.Release(LFirst));
  // The free list is last-in first-out: the same slot comes back
  Assert.IsTrue(FPool.TryAcquire(LSecond));
  Assert.AreEqual(FPool.IndexOf(LFirst), FPool.IndexOf(LSecond), 'Same slot');
  Assert.IsTrue(LFirst.Value <> LSecond.Value, 'Another generation, another handle');
  Assert.IsTrue(FPool.State(LSecond) = rsDefined, 'New handle is current');
  Assert.IsTrue(FPool.State(LFirst) = rsStale, 'Old handle is stale');
  Assert.IsTrue(TIORingRequestHandle.FromUserData(LSecond.Value).Value = LSecond.Value, 'FromUserData');
end;

procedure TRequestPoolTests.Release_MakesHandleStale;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsCompleted));
  Assert.IsTrue(FPool.Release(LHandle));

  Assert.IsTrue(FPool.State(LHandle) = rsStale, 'State');
  Assert.IsFalse(FPool.Release(LHandle), 'Release again');
  Assert.IsFalse(FPool.TryChangeState(LHandle, rsDefined, rsQueued), 'Change from Defined');
  Assert.IsFalse(FPool.TryChangeState(LHandle, rsCompleted, rsQueued), 'Change from Completed');
  Assert.IsTrue(FPool.WaitFor(LHandle) = wrStale, 'WaitFor returns at once');
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
  Assert.IsTrue(FPool.State(LEmpty) = rsStale, 'Empty: State');
  Assert.IsFalse(FPool.Release(LEmpty), 'Empty: Release');
  Assert.IsTrue(FPool.WaitFor(LEmpty) = wrStale, 'Empty: WaitFor');
  Assert.IsTrue(FPool.State(LOutOfRange) = rsStale, 'Out of range: State');
  Assert.IsFalse(FPool.Release(LOutOfRange), 'Out of range: Release');
  Assert.IsFalse(FPool.TryChangeState(LOutOfRange, rsDefined, rsQueued), 'Out of range: change');
  Assert.IsTrue(FPool.WaitFor(LOutOfRange) = wrStale, 'Out of range: WaitFor');
end;

procedure TRequestPoolTests.StateChanges_FollowTheRules;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.State(LHandle) = rsDefined);
  Assert.IsFalse(FPool.TryChangeState(LHandle, rsQueued, rsSubmitted), 'Wrong "from" state');
  Assert.IsTrue(FPool.State(LHandle) = rsDefined, 'Unchanged');

  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsQueued));
  Assert.IsTrue(FPool.State(LHandle) = rsQueued);
  Assert.IsFalse(FPool.Release(LHandle), 'No release while Queued');
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsQueued, rsSubmitted));
  Assert.IsFalse(FPool.Release(LHandle), 'No release while Submitted');
  Assert.IsTrue(FPool.State(LHandle) = rsSubmitted);
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted));
  Assert.IsTrue(FPool.State(LHandle) = rsCompleted);
  Assert.IsTrue(FPool.Release(LHandle), 'Release when Completed');

  // Released without ever being queued
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.Release(LHandle), 'Release when Defined');

  // Cancelled before it was submitted
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsQueued));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsQueued, rsCompleted));
  Assert.IsTrue(FPool.Release(LHandle));
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.TryChangeState_FreeOrStale_Raises;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.WillRaise(
    procedure
    begin
      FPool.TryChangeState(LHandle, rsDefined, rsFree);
    end, EIORingError, 'To Free (use Release)');
  Assert.WillRaise(
    procedure
    begin
      FPool.TryChangeState(LHandle, rsFree, rsDefined);
    end, EIORingError, 'From Free (use TryAcquire)');
  Assert.WillRaise(
    procedure
    begin
      FPool.TryChangeState(LHandle, rsDefined, rsStale);
    end, EIORingError, 'To Stale');
  Assert.IsTrue(FPool.State(LHandle) = rsDefined, 'Unchanged');
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
  Assert.AreEqual(Cardinal(PAYLOAD_SIZE), FPool.PayloadSize);
  for LIndex := 0 to CAPACITY - 1 do
  begin
    Assert.IsTrue(FPool.TryAcquire(LHandles[LIndex]));
    LPayload := FPool.Payload(LHandles[LIndex]);
    Assert.AreEqual(0, Integer(NativeUInt(LPayload) mod 8), 'Payload 8-byte aligned');
    Assert.AreEqual(0, Integer((NativeUInt(LPayload) - 8) mod 64), 'Slot starts on a cache line');
    for LByte := 0 to PAYLOAD_SIZE - 1 do
      Assert.AreEqual(Byte(0), LPayload[LByte], 'Zeroed at Open');
    FillChar(LPayload^, PAYLOAD_SIZE, Byte(LIndex + 1));
  end;
  // No payload overlaps another
  for LIndex := 0 to CAPACITY - 1 do
  begin
    LPayload := FPool.Payload(LHandles[LIndex]);
    for LByte := 0 to PAYLOAD_SIZE - 1 do
      Assert.AreEqual(Byte(LIndex + 1), LPayload[LByte], Format('Slot %d byte %d', [LIndex, LByte]));
  end;
end;

procedure TRequestPoolTests.GenerationBits_DependOnCapacity;
begin
  FPool.Open(10);
  Assert.AreEqual(Cardinal(28), FPool.GenerationBits, 'Small pool: the most the state word holds');
  FPool.Close;
  FPool.Open(IORING_POOL_MAX_CAPACITY);
{$IF SizeOf(NativeUInt) = 4}
  Assert.AreEqual(Cardinal(12), FPool.GenerationBits, 'Win32, 2^20 slots: 32 - 20 bits');
{$ELSE}
  Assert.AreEqual(Cardinal(28), FPool.GenerationBits, '64-bit: always 28');
{$ENDIF}
end;

procedure TRequestPoolTests.Generation_WrapsAroundWithoutZero;
{$IF SizeOf(NativeUInt) = 8}
begin
  Assert.Pass('Checked on Win32 only: 28 generation bits are too many to wrap in a test');
end;
{$ELSE}
var
  LFirst: TIORingRequestHandle;
  LHandle: TIORingRequestHandle;
  LRound: Integer;
begin
  FPool.Open(IORING_POOL_MAX_CAPACITY);   // Win32: 20 index bits, 12 generation bits
  Assert.IsTrue(FPool.TryAcquire(LFirst));
  Assert.IsTrue(FPool.Release(LFirst));
  // Generations 2 .. 4095, then 1 again (0 is skipped)
  for LRound := 2 to (1 shl FPool.GenerationBits) - 1 do
  begin
    Assert.IsTrue(FPool.TryAcquire(LHandle));
    Assert.AreEqual(FPool.IndexOf(LFirst), FPool.IndexOf(LHandle), 'Same slot');
    Assert.AreEqual<NativeUInt>(NativeUInt(LRound), LHandle.Value shr 20, 'Generation');
    Assert.IsTrue(FPool.Release(LHandle));
  end;
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.AreEqual<NativeUInt>(LFirst.Value, LHandle.Value, 'Wrapped around to generation 1');
end;
{$ENDIF}

procedure TRequestPoolTests.WaitFor_Completed_ReturnsAtOnce;
var
  LHandle: TIORingRequestHandle;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsCompleted));
  Assert.IsTrue(FPool.WaitFor(LHandle) = wrCompleted);
  Assert.IsTrue(FPool.WaitFor(LHandle, 0) = wrCompleted, 'Timeout 0');
end;

procedure TRequestPoolTests.WaitFor_ZeroTimeout_OnlyChecks;
var
  LHandle: TIORingRequestHandle;
  LWatch: TStopwatch;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsSubmitted));
  LWatch := TStopwatch.StartNew;
  Assert.IsTrue(FPool.WaitFor(LHandle, 0) = wrTimeout);
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 100, Format('Took %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TRequestPoolTests.WaitFor_Timeout_ReturnsAfterTimeout;
var
  LHandle: TIORingRequestHandle;
  LWatch: TStopwatch;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsSubmitted));
  LWatch := TStopwatch.StartNew;
  Assert.IsTrue(FPool.WaitFor(LHandle, 50) = wrTimeout);
  Assert.IsTrue(LWatch.ElapsedMilliseconds >= 45, Format('Waited only %d ms', [LWatch.ElapsedMilliseconds]));
  // Still usable: completes and releases normally
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted));
  Assert.IsTrue(FPool.Release(LHandle));
end;

procedure TRequestPoolTests.WaitFor_WokenByCompletion;
var
  LHandle: TIORingRequestHandle;
  LThread: TThread;
  LWatch: TStopwatch;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));
  Assert.IsTrue(FPool.TryChangeState(LHandle, rsDefined, rsSubmitted));
  FWaitResult := wrTimeout;
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      FWaitResult := FPool.WaitFor(LHandle, 10000);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(50); // let it fall asleep
    LWatch := TStopwatch.StartNew;
    Assert.IsTrue(FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted));
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.IsTrue(FWaitResult = wrCompleted, 'Result');
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 5000, Format('Wake-up took %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TRequestPoolTests.WaitFor_WokenByRelease_ReturnsStale;
var
  LHandle: TIORingRequestHandle;
  LThread: TThread;
  LWatch: TStopwatch;
begin
  FPool.Open(4);
  Assert.IsTrue(FPool.TryAcquire(LHandle));   // Defined: may be released
  FWaitResult := wrTimeout;
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      FWaitResult := FPool.WaitFor(LHandle, 10000);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(50); // let it fall asleep
    LWatch := TStopwatch.StartNew;
    Assert.IsTrue(FPool.Release(LHandle));
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.IsTrue(FWaitResult = wrStale, 'Result');
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 5000, Format('Wake-up took %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TRequestPoolTests.Stress_NoSlotTakenTwice;
const
  ROUNDS = 50000;
  HOLD = 3;   // 4 threads x 3 > 8 slots: acquires also find the pool empty
begin
  FPool.Open(STRESS_CAPACITY);
  RunThreads(4,
    procedure(AThread: Integer)
    var
      LRound: Integer;
      LHeld: array[0..HOLD - 1] of TIORingRequestHandle;
      LHeldCount: Integer;
      LSlot: Integer;
    begin
      for LRound := 1 to ROUNDS do
      begin
        LHeldCount := 0;
        while (LHeldCount < HOLD) and FPool.TryAcquire(LHeld[LHeldCount]) do
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
    end);
  Assert.AreEqual(0, FFailures, 'Slots held by two threads, or wrong state changes');
  CheckAllSlotsFree;
end;

procedure TRequestPoolTests.RunEngineSimulation(const ASpinMicroseconds: Cardinal);
const
  PRODUCERS = 4;
  ROUNDS = 20000;
begin
  // Fewer slots than producers: TryAcquire also fails now and then
  FPool.Open(PRODUCERS - 1, SizeOf(TTestPayload));
  FPool.SpinMicroseconds := ASpinMicroseconds;

  // Thread 0 is the I/O thread, 1..PRODUCERS the producers
  RunThreads(1 + PRODUCERS,
    procedure(AThread: Integer)
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
      if AThread = 0 then
      begin
        LServed := 0;
        while TAtomic.LoadAcquire(FProducersDone) < PRODUCERS do
        begin
          LFound := False;
          for LProducer := 1 to PRODUCERS do
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
            LPayload.Answer := LPayload.Request * 3;
            if not FPool.TryChangeState(LHandle, rsSubmitted, rsCompleted) then
              TAtomic.Increment(FFailures);
          end;
          if not LFound then
            TAtomic.CpuPause;
        end;
      end
      else
      try
        for LRound := 1 to ROUNDS do
        begin
          while not FPool.TryAcquire(LHandle) do
            TThread.Yield;    // all slots in use
          LPayload := FPool.Payload(LHandle);
          LRequest := (Int64(AThread) shl 32) or LRound;
          LPayload.Request := LRequest;
          LPayload.Answer := 0;
          if not FPool.TryChangeState(LHandle, rsDefined, rsQueued) then
            TAtomic.Increment(FFailures);
          TAtomic.StoreRelease(FMailboxes[AThread], LHandle.Value);
          if FPool.WaitFor(LHandle, 10000) <> wrCompleted then
          begin
            TAtomic.Increment(FFailures);   // lost wake-up
            Exit;
          end;
          if LPayload.Answer <> LRequest * 3 then
            TAtomic.Increment(FFailures);
          if not FPool.Release(LHandle) then
            TAtomic.Increment(FFailures);
        end;
      finally
        TAtomic.Increment(FProducersDone);
      end;
    end);
  Assert.AreEqual(0, FFailures, 'Wrong states, wrong answers or lost wake-ups');
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
  TDUnitX.RegisterTestFixture(TFreeListTests);
  TDUnitX.RegisterTestFixture(TRequestPoolTests);

end.
