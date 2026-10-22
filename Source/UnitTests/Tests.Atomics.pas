unit Tests.Atomics;

{
  Tests for TAtomic (Delphi.IOUring.Atomics).

  One thread: the result of every operation for every type. 64-bit values
  have different upper and lower halves, so a Win32 version that handles
  only one half fails.

  Several threads: counters that must come out exact, 64-bit reads that must
  never see half of a write, data handed over with StoreRelease/LoadAcquire,
  a spin loop that must see another thread's write, and sleep/wake without
  lost wake-ups.

  The compiler-related tests (the spin loop, the hand-over) mean most with
  optimization on: run them in the Release configuration too.
}

interface

uses
  System.SysUtils,
  DUnitX.TestFramework;

type
  [TestFixture]
  TAtomicTests = class
  private
    // Shared by the threads of a test. Object fields: aligned to their size.
    FValue32: Integer;
    FValue64: Int64;
    FFlag: Integer;
    FData: Int64;
    FFailures: Integer;
    FWoken: Integer;
  public
    [Setup]
    procedure Setup;

    // One thread
    [Test]
    procedure CompareExchange_AllTypes;
    [Test]
    procedure CompareExchange64_ComparesBothHalves;
    [Test]
    procedure TryCompareExchange_AllTypes;
    [Test]
    procedure Exchange_AllTypes;
    [Test]
    procedure FetchAdd_ReturnsOldValueAndWraps;
    [Test]
    procedure IncrementDecrement_ReturnNewValue;
    [Test]
    procedure LoadStore_AllTypes;
    [Test]
    procedure NativeTypes_UseMatchingSize;
    [Test]
    procedure BarrierAndPause_Run;
    [Test]
    procedure BackOff_DoublesUpToTheLimit;

    // Several threads
    [Test]
    procedure Stress_Increment32_IsExact;
    [Test]
    procedure Stress_FetchAdd64_CarriesIntoUpperHalf;
    [Test]
    procedure Stress_CompareExchange64Loop_IsExact;
    [Test]
    procedure Stress_Load64_NeverSeesHalfAWrite;
    [Test]
    procedure Stress_ReleaseAcquire_HandsOverData;
    [Test]
    procedure Spin_SeesWriteOfOtherThread;

    // Wait and wake
    [Test]
    procedure Wait_ValueDiffers_ReturnsAtOnce;
    [Test]
    procedure Wait_Timeout_ReturnsFalse;
    [Test]
    procedure WakeOne_WakesSleepingThread;
    [Test]
    procedure WakeAll_WakesAllSleepingThreads;
    [Test]
    procedure Stress_PingPong_NoLostWakeUps;
  end;

implementation

uses
  System.Classes,
  System.Diagnostics,
  Delphi.IOUring.Atomics,
  TestThreadHelpers;

const
  THREAD_COUNT = 4;

  // Changes both halves of a 64-bit value; the lower half carries into the
  // upper half about every second addition
  STEP_64 = Int64($0000000180000001);

  // The two values a writer alternates between. Half of one and half of
  // the other gives 0 or -1, never one of these.
  PATTERN_A = Int64($00000000FFFFFFFF);
  PATTERN_B = Int64(-4294967296); // $FFFFFFFF00000000

{ TAtomicTests }

procedure TAtomicTests.Setup;
begin
  FValue32 := 0;
  FValue64 := 0;
  FFlag := 0;
  FData := 0;
  FFailures := 0;
  FWoken := 0;
end;

procedure TAtomicTests.CompareExchange_AllTypes;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
  LPointer: Pointer;
begin
  LInteger := 10;
  Assert.AreEqual(10, TAtomic.CompareExchange(LInteger, -20, 10), 'Integer: old value');
  Assert.AreEqual(-20, LInteger, 'Integer: exchanged');
  Assert.AreEqual(-20, TAtomic.CompareExchange(LInteger, 30, 10), 'Integer: old value, not equal');
  Assert.AreEqual(-20, LInteger, 'Integer: unchanged');

  LCardinal := $FFFFFFF0;
  Assert.AreEqual(Cardinal($FFFFFFF0), TAtomic.CompareExchange(LCardinal, $80000000, $FFFFFFF0), 'Cardinal: old value');
  Assert.AreEqual(Cardinal($80000000), LCardinal, 'Cardinal: exchanged');
  Assert.AreEqual(Cardinal($80000000), TAtomic.CompareExchange(LCardinal, 1, 2), 'Cardinal: old value, not equal');
  Assert.AreEqual(Cardinal($80000000), LCardinal, 'Cardinal: unchanged');

  LInt64 := $0123456789ABCDEF;
  Assert.AreEqual(Int64($0123456789ABCDEF), TAtomic.CompareExchange(LInt64, -2, $0123456789ABCDEF), 'Int64: old value');
  Assert.AreEqual(Int64(-2), LInt64, 'Int64: exchanged');
  Assert.AreEqual(Int64(-2), TAtomic.CompareExchange(LInt64, 5, -3), 'Int64: old value, not equal');
  Assert.AreEqual(Int64(-2), LInt64, 'Int64: unchanged');

  LUInt64 := $FEDCBA9876543210;
  Assert.AreEqual<UInt64>($FEDCBA9876543210, TAtomic.CompareExchange(LUInt64, 7, $FEDCBA9876543210), 'UInt64: old value');
  Assert.AreEqual<UInt64>(7, LUInt64, 'UInt64: exchanged');
  Assert.AreEqual<UInt64>(7, TAtomic.CompareExchange(LUInt64, 8, 9), 'UInt64: old value, not equal');
  Assert.AreEqual<UInt64>(7, LUInt64, 'UInt64: unchanged');

  LPointer := @LInteger;
  Assert.AreEqual(Pointer(@LInteger), TAtomic.CompareExchange(LPointer, @LCardinal, @LInteger), 'Pointer: old value');
  Assert.AreEqual(Pointer(@LCardinal), LPointer, 'Pointer: exchanged');
  Assert.AreEqual(Pointer(@LCardinal), TAtomic.CompareExchange(LPointer, nil, @LInteger), 'Pointer: old value, not equal');
  Assert.AreEqual(Pointer(@LCardinal), LPointer, 'Pointer: unchanged');
end;

procedure TAtomicTests.CompareExchange64_ComparesBothHalves;
const
  VALUE = Int64($0000000100000002);
begin
  FValue64 := VALUE;
  Assert.AreEqual(VALUE, TAtomic.CompareExchange(FValue64, 0, $0000000200000002), 'Same lower half');
  Assert.AreEqual(VALUE, FValue64, 'Same lower half: unchanged');
  Assert.AreEqual(VALUE, TAtomic.CompareExchange(FValue64, 0, $0000000100000003), 'Same upper half');
  Assert.AreEqual(VALUE, FValue64, 'Same upper half: unchanged');
  Assert.AreEqual(VALUE, TAtomic.CompareExchange(FValue64, PATTERN_B, VALUE), 'Both halves the same');
  Assert.AreEqual(PATTERN_B, FValue64, 'Both halves written');
end;

procedure TAtomicTests.TryCompareExchange_AllTypes;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
  LPointer: Pointer;
begin
  LInteger := 1;
  Assert.IsFalse(TAtomic.TryCompareExchange(LInteger, 2, 0), 'Integer: not equal');
  Assert.IsTrue(TAtomic.TryCompareExchange(LInteger, 2, 1), 'Integer: equal');
  Assert.AreEqual(2, LInteger, 'Integer: value');

  LCardinal := $F0000000;
  Assert.IsFalse(TAtomic.TryCompareExchange(LCardinal, 2, 0), 'Cardinal: not equal');
  Assert.IsTrue(TAtomic.TryCompareExchange(LCardinal, 2, $F0000000), 'Cardinal: equal');
  Assert.AreEqual(Cardinal(2), LCardinal, 'Cardinal: value');

  LInt64 := PATTERN_A;
  Assert.IsFalse(TAtomic.TryCompareExchange(LInt64, 2, PATTERN_B), 'Int64: not equal');
  Assert.IsTrue(TAtomic.TryCompareExchange(LInt64, PATTERN_B, PATTERN_A), 'Int64: equal');
  Assert.AreEqual(PATTERN_B, LInt64, 'Int64: value');

  LUInt64 := High(UInt64);
  Assert.IsFalse(TAtomic.TryCompareExchange(LUInt64, 2, 0), 'UInt64: not equal');
  Assert.IsTrue(TAtomic.TryCompareExchange(LUInt64, 2, High(UInt64)), 'UInt64: equal');
  Assert.AreEqual<UInt64>(2, LUInt64, 'UInt64: value');

  LPointer := nil;
  Assert.IsFalse(TAtomic.TryCompareExchange(LPointer, @LInteger, @LCardinal), 'Pointer: not equal');
  Assert.IsTrue(TAtomic.TryCompareExchange(LPointer, @LInteger, nil), 'Pointer: equal');
  Assert.AreEqual(Pointer(@LInteger), LPointer, 'Pointer: value');
end;

procedure TAtomicTests.Exchange_AllTypes;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
  LPointer: Pointer;
begin
  LInteger := -1;
  Assert.AreEqual(-1, TAtomic.Exchange(LInteger, 5), 'Integer: old value');
  Assert.AreEqual(5, LInteger, 'Integer: new value');

  LCardinal := High(Cardinal);
  Assert.AreEqual(High(Cardinal), TAtomic.Exchange(LCardinal, 5), 'Cardinal: old value');
  Assert.AreEqual(Cardinal(5), LCardinal, 'Cardinal: new value');

  LInt64 := PATTERN_A;
  Assert.AreEqual(PATTERN_A, TAtomic.Exchange(LInt64, PATTERN_B), 'Int64: old value');
  Assert.AreEqual(PATTERN_B, LInt64, 'Int64: new value');

  LUInt64 := $FEDCBA9876543210;
  Assert.AreEqual<UInt64>($FEDCBA9876543210, TAtomic.Exchange(LUInt64, $0123456789ABCDEF), 'UInt64: old value');
  Assert.AreEqual<UInt64>($0123456789ABCDEF, LUInt64, 'UInt64: new value');

  LPointer := @LInteger;
  Assert.AreEqual(Pointer(@LInteger), TAtomic.Exchange(LPointer, nil), 'Pointer: old value');
  Assert.IsNull(LPointer, 'Pointer: new value');
end;

procedure TAtomicTests.FetchAdd_ReturnsOldValueAndWraps;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
begin
  LInteger := 5;
  Assert.AreEqual(5, TAtomic.FetchAdd(LInteger, -7), 'Integer: old value');
  Assert.AreEqual(-2, LInteger, 'Integer: new value');
  LInteger := MaxInt;
  TAtomic.FetchAdd(LInteger, 1);
  Assert.AreEqual(Low(Integer), LInteger, 'Integer: wraps');

  LCardinal := High(Cardinal);
  Assert.AreEqual(High(Cardinal), TAtomic.FetchAdd(LCardinal, 2), 'Cardinal: old value');
  Assert.AreEqual(Cardinal(1), LCardinal, 'Cardinal: wraps');

  LInt64 := PATTERN_A;
  Assert.AreEqual(PATTERN_A, TAtomic.FetchAdd(LInt64, 1), 'Int64: old value');
  Assert.AreEqual(Int64($0000000100000000), LInt64, 'Int64: carries into the upper half');
  Assert.AreEqual(Int64($0000000100000000), TAtomic.FetchAdd(LInt64, -1), 'Int64: old value, subtract');
  Assert.AreEqual(PATTERN_A, LInt64, 'Int64: borrows from the upper half');
  LInt64 := High(Int64);
  TAtomic.FetchAdd(LInt64, 1);
  Assert.AreEqual(Low(Int64), LInt64, 'Int64: wraps');

  LUInt64 := High(UInt64);
  Assert.AreEqual<UInt64>(High(UInt64), TAtomic.FetchAdd(LUInt64, 3), 'UInt64: old value');
  Assert.AreEqual<UInt64>(2, LUInt64, 'UInt64: wraps');
end;

procedure TAtomicTests.IncrementDecrement_ReturnNewValue;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
begin
  LInteger := -1;
  Assert.AreEqual(0, TAtomic.Increment(LInteger), 'Integer: increment');
  Assert.AreEqual(-1, TAtomic.Decrement(LInteger), 'Integer: decrement');
  Assert.AreEqual(-1, LInteger, 'Integer: value');

  LCardinal := 0;
  Assert.AreEqual(High(Cardinal), TAtomic.Decrement(LCardinal), 'Cardinal: decrement wraps');
  Assert.AreEqual(Cardinal(0), TAtomic.Increment(LCardinal), 'Cardinal: increment wraps');

  LInt64 := PATTERN_A;
  Assert.AreEqual(Int64($0000000100000000), TAtomic.Increment(LInt64), 'Int64: increment carries');
  Assert.AreEqual(PATTERN_A, TAtomic.Decrement(LInt64), 'Int64: decrement borrows');

  LUInt64 := 0;
  Assert.AreEqual<UInt64>(High(UInt64), TAtomic.Decrement(LUInt64), 'UInt64: decrement wraps');
  Assert.AreEqual<UInt64>(0, TAtomic.Increment(LUInt64), 'UInt64: increment wraps');
end;

procedure TAtomicTests.LoadStore_AllTypes;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
  LPointer: Pointer;
begin
  TAtomic.StoreRelease(LInteger, -123);
  Assert.AreEqual(-123, LInteger, 'Integer: stored');
  Assert.AreEqual(-123, TAtomic.LoadAcquire(LInteger), 'Integer: loaded');

  TAtomic.StoreRelease(LCardinal, $DEADBEEF);
  Assert.AreEqual(Cardinal($DEADBEEF), LCardinal, 'Cardinal: stored');
  Assert.AreEqual(Cardinal($DEADBEEF), TAtomic.LoadAcquire(LCardinal), 'Cardinal: loaded');

  TAtomic.StoreRelease(LInt64, $0123456789ABCDEF);
  Assert.AreEqual(Int64($0123456789ABCDEF), LInt64, 'Int64: stored');
  Assert.AreEqual(Int64($0123456789ABCDEF), TAtomic.LoadAcquire(LInt64), 'Int64: loaded');
  TAtomic.StoreRelease(LInt64, PATTERN_B);
  Assert.AreEqual(PATTERN_B, TAtomic.LoadAcquire(LInt64), 'Int64: negative');

  TAtomic.StoreRelease(LUInt64, $FEDCBA9876543210);
  Assert.AreEqual<UInt64>($FEDCBA9876543210, LUInt64, 'UInt64: stored');
  Assert.AreEqual<UInt64>($FEDCBA9876543210, TAtomic.LoadAcquire(LUInt64), 'UInt64: loaded');

  TAtomic.StoreRelease(LPointer, @LInteger);
  Assert.AreEqual(Pointer(@LInteger), LPointer, 'Pointer: stored');
  Assert.AreEqual(Pointer(@LInteger), TAtomic.LoadAcquire(LPointer), 'Pointer: loaded');
end;

procedure TAtomicTests.NativeTypes_UseMatchingSize;
var
  LNativeInt: NativeInt;
  LNativeUInt: NativeUInt;
begin
  // Picks the 32-bit or 64-bit overload; a wrong size would not compile
  LNativeInt := -5;
  Assert.AreEqual(NativeInt(-5), TAtomic.Exchange(LNativeInt, High(NativeInt)), 'NativeInt: exchange');
  Assert.AreEqual(High(NativeInt), TAtomic.LoadAcquire(LNativeInt), 'NativeInt: load');
  Assert.AreEqual(Low(NativeInt), TAtomic.Increment(LNativeInt), 'NativeInt: increment wraps');

  LNativeUInt := High(NativeUInt);
  Assert.AreEqual<NativeUInt>(High(NativeUInt), TAtomic.CompareExchange(LNativeUInt, 1, High(NativeUInt)),
    'NativeUInt: compare-exchange');
  Assert.AreEqual<NativeUInt>(1, TAtomic.FetchAdd(LNativeUInt, 1), 'NativeUInt: fetch-add');
  Assert.AreEqual<NativeUInt>(2, LNativeUInt, 'NativeUInt: value');
end;

procedure TAtomicTests.BarrierAndPause_Run;
begin
  TAtomic.FullBarrier;
  TAtomic.CpuPause;
  Assert.Pass;
end;

procedure TAtomicTests.BackOff_DoublesUpToTheLimit;
var
  LPauses: Integer;
begin
  LPauses := 1;
  TAtomic.BackOff(LPauses);
  Assert.AreEqual(2, LPauses, 'First');
  TAtomic.BackOff(LPauses);
  Assert.AreEqual(4, LPauses, 'Second');
  LPauses := IORING_BACKOFF_MAX_PAUSES div 2;
  TAtomic.BackOff(LPauses);
  Assert.AreEqual(IORING_BACKOFF_MAX_PAUSES, LPauses, 'Reaches the limit');
  TAtomic.BackOff(LPauses);
  Assert.AreEqual(IORING_BACKOFF_MAX_PAUSES, LPauses, 'Stays at the limit');
  LPauses := 3;
  TAtomic.BackOff(LPauses, 5);
  Assert.AreEqual(5, LPauses, 'Own limit: never more than it');
end;

procedure TAtomicTests.Stress_Increment32_IsExact;
const
  INCREMENTS = 250000;
begin
  RunThreads(THREAD_COUNT,
    procedure(AIndex: Integer)
    var
      LCount: Integer;
    begin
      for LCount := 1 to INCREMENTS do
        TAtomic.Increment(FValue32);
    end);
  Assert.AreEqual(THREAD_COUNT * INCREMENTS, FValue32);
end;

procedure TAtomicTests.Stress_FetchAdd64_CarriesIntoUpperHalf;
const
  ADDS = 250000;
begin
  RunThreads(THREAD_COUNT,
    procedure(AIndex: Integer)
    var
      LCount: Integer;
    begin
      for LCount := 1 to ADDS do
        TAtomic.FetchAdd(FValue64, STEP_64);
    end);
  Assert.AreEqual(Int64(THREAD_COUNT * ADDS) * STEP_64, FValue64);
end;

procedure TAtomicTests.Stress_CompareExchange64Loop_IsExact;
const
  ADDS = 250000;
begin
  // The usual lock-free pattern: read, compute, try; repeat if another
  // thread got there first
  RunThreads(THREAD_COUNT,
    procedure(AIndex: Integer)
    var
      LCount: Integer;
      LOld: Int64;
    begin
      for LCount := 1 to ADDS do
        repeat
          LOld := TAtomic.LoadAcquire(FValue64);
        until TAtomic.TryCompareExchange(FValue64, LOld + STEP_64, LOld);
    end);
  Assert.AreEqual(Int64(THREAD_COUNT * ADDS) * STEP_64, FValue64);
end;

procedure TAtomicTests.Stress_Load64_NeverSeesHalfAWrite;
const
  READERS = 2;
  READS = 2000000;
begin
  Assert.AreEqual(0, Integer(NativeUInt(@FValue64) mod 8), 'Test set-up: FValue64 must be 8-byte aligned');
  FValue64 := PATTERN_A;
  // Thread 0 writes until the readers are done (FFlag counts finished readers)
  RunThreads(1 + READERS,
    procedure(AIndex: Integer)
    var
      LCount: Integer;
      LValue: Int64;
    begin
      if AIndex = 0 then
      begin
        while TAtomic.LoadAcquire(FFlag) < READERS do
        begin
          TAtomic.StoreRelease(FValue64, PATTERN_B);
          TAtomic.Exchange(FValue64, PATTERN_A);
        end;
      end
      else
      begin
        for LCount := 1 to READS do
        begin
          LValue := TAtomic.LoadAcquire(FValue64);
          if (LValue <> PATTERN_A) and (LValue <> PATTERN_B) then
            TAtomic.Increment(FFailures);
        end;
        TAtomic.Increment(FFlag);
      end;
    end);
  Assert.AreEqual(0, FFailures, 'Reads that saw half of a write');
end;

procedure TAtomicTests.Stress_ReleaseAcquire_HandsOverData;
const
  HAND_OVERS = 100000;
begin
  // Thread 0 writes FData (a plain write), then publishes the round number
  // in FFlag with StoreRelease. Thread 1 waits for it with LoadAcquire, checks
  // FData (a plain read), and hands the turn back by storing 0.
  RunThreads(2,
    procedure(AIndex: Integer)
    var
      LRound: Integer;
    begin
      for LRound := 1 to HAND_OVERS do
        if AIndex = 0 then
        begin
          while TAtomic.LoadAcquire(FFlag) <> 0 do
            TAtomic.CpuPause;
          FData := LRound * STEP_64;
          TAtomic.StoreRelease(FFlag, LRound);
        end
        else
        begin
          while TAtomic.LoadAcquire(FFlag) = 0 do
            TAtomic.CpuPause;
          if (FFlag <> LRound) or (FData <> LRound * STEP_64) then
            TAtomic.Increment(FFailures);
          TAtomic.StoreRelease(FFlag, 0);
        end;
    end);
  Assert.AreEqual(0, FFailures, 'Rounds with wrong data');
end;

procedure TAtomicTests.Spin_SeesWriteOfOtherThread;
const
  SPIN_LIMIT = 2000000000; // ~1 s; the write comes after ~20 ms
var
  LThread: TThread;
  LSpins: Integer;
begin
  // No call inside the loop: if the compiler kept the value in a register,
  // the loop would never see the change and would stop at the limit
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(20);
      TAtomic.StoreRelease(FFlag, 1);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    LSpins := 0;
    repeat
      Inc(LSpins);
    until (TAtomic.LoadAcquire(FFlag) <> 0) or (LSpins = SPIN_LIMIT);
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.IsTrue(LSpins < SPIN_LIMIT, 'The spin loop did not see the write');
end;

procedure TAtomicTests.Wait_ValueDiffers_ReturnsAtOnce;
var
  LWatch: TStopwatch;
begin
  FValue32 := 1;
  LWatch := TStopwatch.StartNew;
  Assert.IsTrue(TAtomic.WaitWhileEqual(FValue32, 0, 5000), 'Result');
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 1000, Format('Waited %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TAtomicTests.Wait_Timeout_ReturnsFalse;
var
  LWatch: TStopwatch;
begin
  LWatch := TStopwatch.StartNew;
  Assert.IsFalse(TAtomic.WaitWhileEqual(FValue32, 0, 50), 'Result');
  Assert.IsTrue(LWatch.ElapsedMilliseconds >= 30, Format('Waited only %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TAtomicTests.WakeOne_WakesSleepingThread;
var
  LThread: TThread;
  LWatch: TStopwatch;
begin
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      if TAtomic.WaitWhileEqual(FValue32, 0, 10000) and (TAtomic.LoadAcquire(FValue32) = 1) then
        TAtomic.Increment(FWoken);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(50); // let it fall asleep
    LWatch := TStopwatch.StartNew;
    TAtomic.Exchange(FValue32, 1);
    TAtomic.WakeOne(FValue32);
    LThread.WaitFor;
  finally
    LThread.Free;
  end;
  Assert.AreEqual(1, FWoken, 'Woken and saw the new value');
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 5000, Format('Wake-up took %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TAtomicTests.WakeAll_WakesAllSleepingThreads;
var
  LThreads: array[0..THREAD_COUNT - 1] of TThread;
  LIndex: Integer;
  LWatch: TStopwatch;
begin
  for LIndex := 0 to High(LThreads) do
  begin
    LThreads[LIndex] := TThread.CreateAnonymousThread(
      procedure
      begin
        if TAtomic.WaitWhileEqual(FValue32, 0, 10000) and (TAtomic.LoadAcquire(FValue32) = 1) then
          TAtomic.Increment(FWoken);
      end);
    LThreads[LIndex].FreeOnTerminate := False;
  end;
  try
    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].Start;
    Sleep(100); // let them fall asleep
    LWatch := TStopwatch.StartNew;
    TAtomic.Exchange(FValue32, 1);
    TAtomic.WakeAll(FValue32);
    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].WaitFor;
  finally
    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].Free;
  end;
  Assert.AreEqual(THREAD_COUNT, FWoken, 'Woken and saw the new value');
  Assert.IsTrue(LWatch.ElapsedMilliseconds < 5000, Format('Wake-up took %d ms', [LWatch.ElapsedMilliseconds]));
end;

procedure TAtomicTests.Stress_PingPong_NoLostWakeUps;
const
  ROUNDS = 5000;
begin
  // FValue32 says whose turn it is (0 or 1). Each thread waits for its turn,
  // gives the turn to the other one and wakes it. A lost wake-up shows as a
  // 5-second timeout.
  //
  // WaitOnAddress spins a little before it sleeps, so most turns change
  // without sleeping (about 0.2 µs each). Every 16th turn is held for 200 µs,
  // so that the other thread really sleeps and must be woken.
  RunThreads(2,
    procedure(AIndex: Integer)
    var
      LRound: Integer;
      LOther: Integer;
    begin
      LOther := 1 - AIndex;
      for LRound := 1 to ROUNDS do
      begin
        while TAtomic.LoadAcquire(FValue32) <> AIndex do
          if not TAtomic.WaitWhileEqual(FValue32, LOther, 5000) then
          begin
            TAtomic.Increment(FFailures); // the other thread times out too
            Exit;
          end;
        if LRound mod 16 = 0 then
          SpinMicroseconds(200);
        if TAtomic.Exchange(FValue32, LOther) <> AIndex then
          TAtomic.Increment(FFailures);
        TAtomic.WakeOne(FValue32);
      end;
    end);
  Assert.AreEqual(0, FFailures, 'Lost wake-ups or wrong turns');
end;

initialization
  TDUnitX.RegisterTestFixture(TAtomicTests);

end.
