unit PIRUnit.Atomics.Tests;

{
  Tests for TAtomic (PIRUnit.Atomics).

  One thread: the result of every operation for every type. 64-bit values
  have different upper and lower halves, so a Win32 version that handles
  only one half fails.

  Several threads: counters that must come out exact, 64-bit reads that must
  never see half of a write, data handed over with StoreRelease/LoadAcquire,
  a spin loop that must see another thread's write, and sleep/wake without
  lost wake-ups.

  The compiler-related tests (the spin loop, the hand-over) mean most with
  optimization on: run them in the Release configuration too (Free Pascal:
  Build-FPC.ps1 -Optimize).

  The thread bodies are methods of the test (Work*), run by RunThreads.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.Test.Support;

type
  TAtomicTests = class(TIORingTestCase)
  private
    // Shared by the threads of a test. Object fields: aligned to their size.
    FValue32: Integer;
    FValue64: Int64;
    FFlag: Integer;
    FData: Int64;
    FFailures: Integer;
    FWoken: Integer;
    // Thread bodies
    procedure WorkIncrement32(AIndex: Integer);
    procedure WorkFetchAdd64(AIndex: Integer);
    procedure WorkCompareExchange64Loop(AIndex: Integer);
    procedure WorkWriteOrReadPatterns(AIndex: Integer);
    procedure WorkHandOver(AIndex: Integer);
    procedure WorkSetFlagLater(AIndex: Integer);
    procedure WorkWaitForWake(AIndex: Integer);
    procedure WorkPingPong(AIndex: Integer);
  protected
    procedure SetUp; override;
  published
    // One thread
    procedure CompareExchange_AllTypes;
    procedure CompareExchange64_ComparesBothHalves;
    procedure TryCompareExchange_AllTypes;
    procedure Exchange_AllTypes;
    procedure FetchAdd_ReturnsOldValueAndWraps;
    procedure IncrementDecrement_ReturnNewValue;
    procedure LoadStore_AllTypes;
    procedure NativeTypes_UseMatchingSize;
    procedure BarrierAndPause_Run;
    procedure BackOff_DoublesUpToTheLimit;
    // Several threads
    procedure Stress_Increment32_IsExact;
    procedure Stress_FetchAdd64_CarriesIntoUpperHalf;
    procedure Stress_CompareExchange64Loop_IsExact;
    procedure Stress_Load64_NeverSeesHalfAWrite;
    procedure Stress_ReleaseAcquire_HandsOverData;
    procedure Spin_SeesWriteOfOtherThread;
    // Wait and wake
    procedure Wait_ValueDiffers_ReturnsAtOnce;
    procedure Wait_Timeout_ReturnsFalse;
    procedure WakeOne_WakesSleepingThread;
    procedure WakeAll_WakesAllSleepingThreads;
    procedure Stress_PingPong_NoLostWakeUps;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.Atomics;

const
  THREAD_COUNT = 4;

  INCREMENTS = 250000;
  ADDS_64 = 250000;
  READERS = 2;
  READS = 2000000;
  HAND_OVERS = 100000;
  PING_PONG_ROUNDS = 5000;

  // Changes both halves of a 64-bit value; the lower half carries into the upper half about every second addition
  STEP_64 = Int64($0000000180000001);

  // The two values a writer alternates between. Half of one and half of the other gives 0 or -1, never one of these.
  PATTERN_A = Int64($00000000FFFFFFFF);
  PATTERN_B = Int64(-4294967296); // $FFFFFFFF00000000

{ TAtomicTests }

procedure TAtomicTests.SetUp;
begin
  FValue32 := 0;
  FValue64 := 0;
  FFlag := 0;
  FData := 0;
  FFailures := 0;
  FWoken := 0;
end;

procedure TAtomicTests.WorkIncrement32(AIndex: Integer);
var
  LCount: Integer;
begin
  for LCount := 1 to INCREMENTS do
    TAtomic.Increment(FValue32);
end;

procedure TAtomicTests.WorkFetchAdd64(AIndex: Integer);
var
  LCount: Integer;
begin
  for LCount := 1 to ADDS_64 do
    TAtomic.FetchAdd(FValue64, STEP_64);
end;

procedure TAtomicTests.WorkCompareExchange64Loop(AIndex: Integer);
var
  LCount: Integer;
  LOld: Int64;
begin
  for LCount := 1 to ADDS_64 do
    repeat
      LOld := TAtomic.LoadAcquire(FValue64);
    until TAtomic.TryCompareExchange(FValue64, LOld + STEP_64, LOld);
end;

procedure TAtomicTests.WorkWriteOrReadPatterns(AIndex: Integer);
var
  LCount: Integer;
  LValue: Int64;
begin
  if AIndex = 0 then
  begin
    // The writer: until the readers are done (FFlag counts finished readers)
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
end;

procedure TAtomicTests.WorkHandOver(AIndex: Integer);
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
end;

procedure TAtomicTests.WorkSetFlagLater(AIndex: Integer);
begin
  Sleep(20);
  TAtomic.StoreRelease(FFlag, 1);
end;

procedure TAtomicTests.WorkWaitForWake(AIndex: Integer);
begin
  if TAtomic.WaitWhileEqual(FValue32, 0, 10000) and (TAtomic.LoadAcquire(FValue32) = 1) then
    TAtomic.Increment(FWoken);
end;

procedure TAtomicTests.WorkPingPong(AIndex: Integer);
var
  LRound: Integer;
  LOther: Integer;
begin
  LOther := 1 - AIndex;

  for LRound := 1 to PING_PONG_ROUNDS do
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
  AssertEquals('Integer: old value', 10, TAtomic.CompareExchange(LInteger, -20, 10));
  AssertEquals('Integer: exchanged', -20, LInteger);
  AssertEquals('Integer: old value, not equal', -20, TAtomic.CompareExchange(LInteger, 30, 10));
  AssertEquals('Integer: unchanged', -20, LInteger);

  LCardinal := $FFFFFFF0;
  AssertEquals('Cardinal: old value', Int64($FFFFFFF0), Int64(TAtomic.CompareExchange(LCardinal, $80000000, $FFFFFFF0)));
  AssertEquals('Cardinal: exchanged', Int64($80000000), Int64(LCardinal));
  AssertEquals('Cardinal: old value, not equal', Int64($80000000), Int64(TAtomic.CompareExchange(LCardinal, 1, 2)));
  AssertEquals('Cardinal: unchanged', Int64($80000000), Int64(LCardinal));

  LInt64 := $0123456789ABCDEF;
  AssertEquals('Int64: old value', Int64($0123456789ABCDEF), TAtomic.CompareExchange(LInt64, -2, $0123456789ABCDEF));
  AssertEquals('Int64: exchanged', Int64(-2), LInt64);
  AssertEquals('Int64: old value, not equal', Int64(-2), TAtomic.CompareExchange(LInt64, 5, -3));
  AssertEquals('Int64: unchanged', Int64(-2), LInt64);

  LUInt64 := UInt64($FEDCBA9876543210);
  CheckEqualsU64('UInt64: old value', UInt64($FEDCBA9876543210),
    TAtomic.CompareExchange(LUInt64, 7, UInt64($FEDCBA9876543210)));
  CheckEqualsU64('UInt64: exchanged', 7, LUInt64);
  CheckEqualsU64('UInt64: old value, not equal', 7, TAtomic.CompareExchange(LUInt64, 8, 9));
  CheckEqualsU64('UInt64: unchanged', 7, LUInt64);

  LPointer := @LInteger;
  AssertTrue('Pointer: old value', TAtomic.CompareExchange(LPointer, @LCardinal, @LInteger) = @LInteger);
  AssertTrue('Pointer: exchanged', LPointer = @LCardinal);
  AssertTrue('Pointer: old value, not equal', TAtomic.CompareExchange(LPointer, nil, @LInteger) = @LCardinal);
  AssertTrue('Pointer: unchanged', LPointer = @LCardinal);
end;

procedure TAtomicTests.CompareExchange64_ComparesBothHalves;
const
  VALUE = Int64($0000000100000002);
begin
  FValue64 := VALUE;
  AssertEquals('Same lower half', VALUE, TAtomic.CompareExchange(FValue64, 0, $0000000200000002));
  AssertEquals('Same lower half: unchanged', VALUE, FValue64);
  AssertEquals('Same upper half', VALUE, TAtomic.CompareExchange(FValue64, 0, $0000000100000003));
  AssertEquals('Same upper half: unchanged', VALUE, FValue64);
  AssertEquals('Both halves the same', VALUE, TAtomic.CompareExchange(FValue64, PATTERN_B, VALUE));
  AssertEquals('Both halves written', PATTERN_B, FValue64);
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
  AssertFalse('Integer: not equal', TAtomic.TryCompareExchange(LInteger, 2, 0));
  AssertTrue('Integer: equal', TAtomic.TryCompareExchange(LInteger, 2, 1));
  AssertEquals('Integer: value', 2, LInteger);

  LCardinal := $F0000000;
  AssertFalse('Cardinal: not equal', TAtomic.TryCompareExchange(LCardinal, 2, 0));
  AssertTrue('Cardinal: equal', TAtomic.TryCompareExchange(LCardinal, 2, $F0000000));
  AssertEquals('Cardinal: value', 2, Int64(LCardinal));

  LInt64 := PATTERN_A;
  AssertFalse('Int64: not equal', TAtomic.TryCompareExchange(LInt64, 2, PATTERN_B));
  AssertTrue('Int64: equal', TAtomic.TryCompareExchange(LInt64, PATTERN_B, PATTERN_A));
  AssertEquals('Int64: value', PATTERN_B, LInt64);

  LUInt64 := High(UInt64);
  AssertFalse('UInt64: not equal', TAtomic.TryCompareExchange(LUInt64, 2, 0));
  AssertTrue('UInt64: equal', TAtomic.TryCompareExchange(LUInt64, 2, High(UInt64)));
  CheckEqualsU64('UInt64: value', 2, LUInt64);

  LPointer := nil;
  AssertFalse('Pointer: not equal', TAtomic.TryCompareExchange(LPointer, @LInteger, @LCardinal));
  AssertTrue('Pointer: equal', TAtomic.TryCompareExchange(LPointer, @LInteger, nil));
  AssertTrue('Pointer: value', LPointer = @LInteger);
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
  AssertEquals('Integer: old value', -1, TAtomic.Exchange(LInteger, 5));
  AssertEquals('Integer: new value', 5, LInteger);

  LCardinal := High(Cardinal);
  AssertEquals('Cardinal: old value', Int64(High(Cardinal)), Int64(TAtomic.Exchange(LCardinal, 5)));
  AssertEquals('Cardinal: new value', 5, Int64(LCardinal));

  LInt64 := PATTERN_A;
  AssertEquals('Int64: old value', PATTERN_A, TAtomic.Exchange(LInt64, PATTERN_B));
  AssertEquals('Int64: new value', PATTERN_B, LInt64);

  LUInt64 := UInt64($FEDCBA9876543210);
  CheckEqualsU64('UInt64: old value', UInt64($FEDCBA9876543210), TAtomic.Exchange(LUInt64, $0123456789ABCDEF));
  CheckEqualsU64('UInt64: new value', $0123456789ABCDEF, LUInt64);

  LPointer := @LInteger;
  AssertTrue('Pointer: old value', TAtomic.Exchange(LPointer, nil) = @LInteger);
  AssertTrue('Pointer: new value', LPointer = nil);
end;

procedure TAtomicTests.FetchAdd_ReturnsOldValueAndWraps;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
begin
  LInteger := 5;
  AssertEquals('Integer: old value', 5, TAtomic.FetchAdd(LInteger, -7));
  AssertEquals('Integer: new value', -2, LInteger);
  LInteger := MaxInt;
  TAtomic.FetchAdd(LInteger, 1);
  AssertEquals('Integer: wraps', Low(Integer), LInteger);

  LCardinal := High(Cardinal);
  AssertEquals('Cardinal: old value', Int64(High(Cardinal)), Int64(TAtomic.FetchAdd(LCardinal, 2)));
  AssertEquals('Cardinal: wraps', 1, Int64(LCardinal));

  LInt64 := PATTERN_A;
  AssertEquals('Int64: old value', PATTERN_A, TAtomic.FetchAdd(LInt64, 1));
  AssertEquals('Int64: carries into the upper half', Int64($0000000100000000), LInt64);
  AssertEquals('Int64: old value, subtract', Int64($0000000100000000), TAtomic.FetchAdd(LInt64, -1));
  AssertEquals('Int64: borrows from the upper half', PATTERN_A, LInt64);
  LInt64 := High(Int64);
  TAtomic.FetchAdd(LInt64, 1);
  AssertEquals('Int64: wraps', Low(Int64), LInt64);

  LUInt64 := High(UInt64);
  CheckEqualsU64('UInt64: old value', High(UInt64), TAtomic.FetchAdd(LUInt64, 3));
  CheckEqualsU64('UInt64: wraps', 2, LUInt64);
end;

procedure TAtomicTests.IncrementDecrement_ReturnNewValue;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
begin
  LInteger := -1;
  AssertEquals('Integer: increment', 0, TAtomic.Increment(LInteger));
  AssertEquals('Integer: decrement', -1, TAtomic.Decrement(LInteger));
  AssertEquals('Integer: value', -1, LInteger);

  LCardinal := 0;
  AssertEquals('Cardinal: decrement wraps', Int64(High(Cardinal)), Int64(TAtomic.Decrement(LCardinal)));
  AssertEquals('Cardinal: increment wraps', 0, Int64(TAtomic.Increment(LCardinal)));

  LInt64 := PATTERN_A;
  AssertEquals('Int64: increment carries', Int64($0000000100000000), TAtomic.Increment(LInt64));
  AssertEquals('Int64: decrement borrows', PATTERN_A, TAtomic.Decrement(LInt64));

  LUInt64 := 0;
  CheckEqualsU64('UInt64: decrement wraps', High(UInt64), TAtomic.Decrement(LUInt64));
  CheckEqualsU64('UInt64: increment wraps', 0, TAtomic.Increment(LUInt64));
end;

procedure TAtomicTests.LoadStore_AllTypes;
var
  LInteger: Integer;
  LCardinal: Cardinal;
  LInt64: Int64;
  LUInt64: UInt64;
  LPointer: Pointer;
begin
  // Set first, so that FPC sees the variables initialized
  LInteger := 0;
  LCardinal := 0;
  LInt64 := 0;
  LUInt64 := 0;
  LPointer := nil;

  TAtomic.StoreRelease(LInteger, -123);
  AssertEquals('Integer: stored', -123, LInteger);
  AssertEquals('Integer: loaded', -123, TAtomic.LoadAcquire(LInteger));

  TAtomic.StoreRelease(LCardinal, $DEADBEEF);
  AssertEquals('Cardinal: stored', Int64($DEADBEEF), Int64(LCardinal));
  AssertEquals('Cardinal: loaded', Int64($DEADBEEF), Int64(TAtomic.LoadAcquire(LCardinal)));

  TAtomic.StoreRelease(LInt64, $0123456789ABCDEF);
  AssertEquals('Int64: stored', Int64($0123456789ABCDEF), LInt64);
  AssertEquals('Int64: loaded', Int64($0123456789ABCDEF), TAtomic.LoadAcquire(LInt64));
  TAtomic.StoreRelease(LInt64, PATTERN_B);
  AssertEquals('Int64: negative', PATTERN_B, TAtomic.LoadAcquire(LInt64));

  TAtomic.StoreRelease(LUInt64, UInt64($FEDCBA9876543210));
  CheckEqualsU64('UInt64: stored', UInt64($FEDCBA9876543210), LUInt64);
  CheckEqualsU64('UInt64: loaded', UInt64($FEDCBA9876543210), TAtomic.LoadAcquire(LUInt64));

  TAtomic.StoreRelease(LPointer, @LInteger);
  AssertTrue('Pointer: stored', LPointer = @LInteger);
  AssertTrue('Pointer: loaded', TAtomic.LoadAcquire(LPointer) = @LInteger);
end;

procedure TAtomicTests.NativeTypes_UseMatchingSize;
var
  LNativeInt: NativeInt;
  LNativeUInt: NativeUInt;
begin
  // Picks the 32-bit or 64-bit overload; a wrong size would not compile
  LNativeInt := -5;
  AssertEquals('NativeInt: exchange', -5, TAtomic.Exchange(LNativeInt, High(NativeInt)));
  AssertEquals('NativeInt: load', High(NativeInt), TAtomic.LoadAcquire(LNativeInt));
  AssertEquals('NativeInt: increment wraps', Low(NativeInt), TAtomic.Increment(LNativeInt));

  LNativeUInt := High(NativeUInt);
  CheckEqualsU64('NativeUInt: compare-exchange', High(NativeUInt),
    TAtomic.CompareExchange(LNativeUInt, 1, High(NativeUInt)));
  CheckEqualsU64('NativeUInt: fetch-add', 1, TAtomic.FetchAdd(LNativeUInt, 1));
  CheckEqualsU64('NativeUInt: value', 2, LNativeUInt);
end;

procedure TAtomicTests.BarrierAndPause_Run;
begin
  TAtomic.FullBarrier;
  TAtomic.CpuPause;
  AssertTrue(True);
end;

procedure TAtomicTests.BackOff_DoublesUpToTheLimit;
var
  LPauses: Integer;
begin
  LPauses := 1;
  TAtomic.BackOff(LPauses);
  AssertEquals('First', 2, LPauses);
  TAtomic.BackOff(LPauses);
  AssertEquals('Second', 4, LPauses);
  LPauses := IORING_BACKOFF_MAX_PAUSES div 2;
  TAtomic.BackOff(LPauses);
  AssertEquals('Reaches the limit', IORING_BACKOFF_MAX_PAUSES, LPauses);
  TAtomic.BackOff(LPauses);
  AssertEquals('Stays at the limit', IORING_BACKOFF_MAX_PAUSES, LPauses);
  LPauses := 3;
  TAtomic.BackOff(LPauses, 5);
  AssertEquals('Own limit: never more than it', 5, LPauses);
end;

procedure TAtomicTests.Stress_Increment32_IsExact;
begin
  RunThreads(THREAD_COUNT, WorkIncrement32);
  AssertEquals(THREAD_COUNT * INCREMENTS, FValue32);
end;

procedure TAtomicTests.Stress_FetchAdd64_CarriesIntoUpperHalf;
begin
  RunThreads(THREAD_COUNT, WorkFetchAdd64);
  AssertEquals(Int64(THREAD_COUNT * ADDS_64) * STEP_64, FValue64);
end;

procedure TAtomicTests.Stress_CompareExchange64Loop_IsExact;
begin
  // The usual lock-free pattern: read, compute, try; repeat if another thread got there first
  RunThreads(THREAD_COUNT, WorkCompareExchange64Loop);
  AssertEquals(Int64(THREAD_COUNT * ADDS_64) * STEP_64, FValue64);
end;

procedure TAtomicTests.Stress_Load64_NeverSeesHalfAWrite;
begin
  AssertEquals('Test set-up: FValue64 must be 8-byte aligned', 0, Int64(NativeUInt(@FValue64) mod 8));
  FValue64 := PATTERN_A;
  RunThreads(1 + READERS, WorkWriteOrReadPatterns);
  AssertEquals('Reads that saw half of a write', 0, FFailures);
end;

procedure TAtomicTests.Stress_ReleaseAcquire_HandsOverData;
begin
  { Thread 0 writes FData (a plain write), then publishes the round number in FFlag with StoreRelease. Thread 1 waits
    for it with LoadAcquire, checks FData (a plain read), and hands the turn back by storing 0. }
  RunThreads(2, WorkHandOver);
  AssertEquals('Rounds with wrong data', 0, FFailures);
end;

procedure TAtomicTests.Spin_SeesWriteOfOtherThread;
const
  SPIN_LIMIT = 2000000000; // ~1 s; the write comes after ~20 ms
var
  LThread: TWorkerThread;
  LSpins: Integer;
begin
  { No call inside the loop: if the compiler kept the value in a register, the loop would never see the change
    and would stop at the limit }
  LThread := TWorkerThread.Create(0, 1, nil, WorkSetFlagLater);
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

  AssertTrue('The spin loop did not see the write', LSpins < SPIN_LIMIT);
end;

procedure TAtomicTests.Wait_ValueDiffers_ReturnsAtOnce;
var
  LStart: UInt64;
begin
  FValue32 := 1;
  LStart := TThread.GetTickCount64;
  AssertTrue('Result', TAtomic.WaitWhileEqual(FValue32, 0, 5000));
  AssertTrue(Format('Waited %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 1000);
end;

procedure TAtomicTests.Wait_Timeout_ReturnsFalse;
var
  LStart: UInt64;
  LElapsed: UInt64;
begin
  LStart := TThread.GetTickCount64;
  AssertFalse('Result', TAtomic.WaitWhileEqual(FValue32, 0, 50));
  LElapsed := TThread.GetTickCount64 - LStart;
  // GetTickCount64 moves in steps of about 16 ms
  AssertTrue(Format('Waited only %d ms', [LElapsed]), LElapsed >= 30);
end;

procedure TAtomicTests.WakeOne_WakesSleepingThread;
var
  LThread: TWorkerThread;
  LStart: UInt64;
begin
  LThread := TWorkerThread.Create(0, 1, nil, WorkWaitForWake);
  try
    LThread.Start;
    Sleep(50); // let it fall asleep
    LStart := TThread.GetTickCount64;
    TAtomic.Exchange(FValue32, 1);
    TAtomic.WakeOne(FValue32);
    LThread.WaitFor;
  finally
    LThread.Free;
  end;

  AssertEquals('Woken and saw the new value', 1, FWoken);
  AssertTrue(Format('Wake-up took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 5000);
end;

procedure TAtomicTests.WakeAll_WakesAllSleepingThreads;
var
  LThreads: array[0..THREAD_COUNT - 1] of TWorkerThread;
  LIndex: Integer;
  LStart: UInt64;
begin
  for LIndex := 0 to High(LThreads) do
    LThreads[LIndex] := TWorkerThread.Create(LIndex, THREAD_COUNT, nil, WorkWaitForWake);

  try
    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].Start;

    Sleep(100); // let them fall asleep
    LStart := TThread.GetTickCount64;
    TAtomic.Exchange(FValue32, 1);
    TAtomic.WakeAll(FValue32);

    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].WaitFor;
  finally
    for LIndex := 0 to High(LThreads) do
      LThreads[LIndex].Free;
  end;

  AssertEquals('Woken and saw the new value', THREAD_COUNT, FWoken);
  AssertTrue(Format('Wake-up took %d ms', [TThread.GetTickCount64 - LStart]), TThread.GetTickCount64 - LStart < 5000);
end;

procedure TAtomicTests.Stress_PingPong_NoLostWakeUps;
begin
  {
    FValue32 says whose turn it is (0 or 1). Each thread waits for its turn, gives the turn to the other one and wakes
    it. A lost wake-up shows as a 5-second timeout.

    WaitOnAddress spins a little before it sleeps, so most turns change without sleeping (about 0.2 µs each). Every 16th
    turn is held for 200 µs, so that the other thread really sleeps and must be woken.
  }
  RunThreads(2, WorkPingPong);
  AssertEquals('Lost wake-ups or wrong turns', 0, FFailures);
end;

initialization
  RegisterTests(TAtomicTests);

end.
