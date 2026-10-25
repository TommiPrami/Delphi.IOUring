unit PIRUnit.RequestQueue.Tests;

{
  Tests for TIORingRequestQueue (PIRUnit.RequestQueue): order, full
  and empty, the capacity, many laps around the array, and the wrap-around of
  the position counters (started just before the end of the NativeUInt
  range).

  Multi-thread stress: producers and consumers at the same time. Every value
  must come out exactly once; with one consumer (the engine's case) also in
  the order each producer put them in. The thread body is a method of the
  test (WorkQueue), run by RunThreads.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.RequestQueue, PIRUnit.Test.Support;

type
  TRequestQueueTests = class(TIORingTestCase)
  private
    FQueue: TIORingRequestQueue;
    FFailures: Integer;
    FConsumed: Integer;
    FSeen: array of Integer;            // [Producer * Items + Sequence]: 1 when consumed
    FNextExpected: array of Integer;    // per producer, with one consumer
    FDeadline: UInt64;                  // TThread.GetTickCount64: give up (a lost value would hang the test)
    FTimedOut: Integer;
    // The parameters of WorkQueue
    FProducers: Integer;
    FConsumers: Integer;
    FItems: Integer;
    FProducerPauses: Integer;
    {
      Runs AProducers producers that each put AItems values into a queue of ACapacity cells, and AConsumers
      consumers that take them all out; then checks that every value came out once (and in order, with one
      consumer). AProducerPauses: CPU pauses a producer waits between two values (slow producers: the consumers
      wait at the empty queue).
    }
    procedure RunProducersAndConsumers(const AProducers, AConsumers, AItems: Integer;
      const ACapacity: Cardinal; const AFirstPosition: NativeUInt = 0; const AProducerPauses: Integer = 0);
    procedure WorkQueue(AIndex: Integer);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // One thread
    procedure Open_RoundsCapacityUp;
    procedure BadArguments_Raise;
    procedure FirstInFirstOut_FullAndEmpty;
    procedure AnyValue_PassesThrough;
    procedure ManyLaps_KeepOrder;
    procedure PositionWrapAround_KeepsOrder;
    procedure ClosedQueue_RefusesValues;
    // Several threads
    procedure Stress_ManyProducersOneConsumer;
    procedure Stress_ManyProducersManyConsumers;
    procedure Stress_SmallQueue_OftenFullAndEmpty;
    procedure Stress_PositionWrapAroundUnderLoad;
    procedure Stress_ConsumerWaitsForEveryValue;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Atomics;

{ A value that says who put it in and when: producer in the bits 24..30, its sequence number below
  (fits NativeUInt on Win32 too) }
function EncodeValue(const AProducer, ASequence: Integer): NativeUInt;
begin
  Result := (NativeUInt(AProducer) shl 24) or NativeUInt(ASequence);
end;

{ TRequestQueueTests }

procedure TRequestQueueTests.SetUp;
begin
  FFailures := 0;
  FConsumed := 0;
  FTimedOut := 0;
end;

procedure TRequestQueueTests.TearDown;
begin
  FQueue.Close;
end;

procedure TRequestQueueTests.Open_RoundsCapacityUp;
begin
  FQueue.Open(5);
  AssertEquals('5 -> 8', 8, Int64(FQueue.Capacity));
  FQueue.Close;
  FQueue.Open(1);
  AssertEquals('1 -> 2 (the smallest)', 2, Int64(FQueue.Capacity));
  FQueue.Close;
  FQueue.Open(1024);
  AssertEquals('A power of two stays', 1024, Int64(FQueue.Capacity));
  AssertEquals('Empty', 0, Int64(FQueue.Count));
end;

procedure TRequestQueueTests.BadArguments_Raise;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    FQueue.Open(0);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity 0', LRaised);

  LRaised := False;

  try
    FQueue.Open(IORING_QUEUE_MAX_CAPACITY + 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Capacity too big', LRaised);

  FQueue.Open(4);
  LRaised := False;

  try
    FQueue.Open(4);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Opened twice', LRaised);
end;

procedure TRequestQueueTests.FirstInFirstOut_FullAndEmpty;
var
  LValue: NativeUInt;
  LIndex: Integer;
begin
  FQueue.Open(8);

  for LIndex := 1 to 8 do
    AssertTrue('Enqueue ' + IntToStr(LIndex), FQueue.TryEnqueue(LIndex * 10));

  AssertFalse('Full', FQueue.TryEnqueue(90));
  AssertEquals('Count when full', 8, Int64(FQueue.Count));

  for LIndex := 1 to 8 do
  begin
    AssertTrue('Dequeue ' + IntToStr(LIndex), FQueue.TryDequeue(LValue));
    CheckEqualsU64('Order', LIndex * 10, LValue);
  end;

  AssertFalse('Empty', FQueue.TryDequeue(LValue));
  CheckEqualsU64('Empty gives 0', 0, LValue);
  AssertEquals('Count when empty', 0, Int64(FQueue.Count));

  // Usable again after full and empty
  AssertTrue(FQueue.TryEnqueue(5));
  AssertEquals(1, Int64(FQueue.Count));
  AssertTrue(FQueue.TryDequeue(LValue));
  CheckEqualsU64('Again', 5, LValue);
end;

procedure TRequestQueueTests.AnyValue_PassesThrough;
const
  VALUES: array[0..3] of NativeUInt = (0, High(NativeUInt), High(NativeUInt) div 3, 1);
var
  LIndex: Integer;
  LValue: NativeUInt;
begin
  FQueue.Open(4);

  for LIndex := 0 to High(VALUES) do
    AssertTrue(FQueue.TryEnqueue(VALUES[LIndex]));

  for LIndex := 0 to High(VALUES) do
  begin
    AssertTrue(FQueue.TryDequeue(LValue));
    CheckEqualsU64('Value', VALUES[LIndex], LValue);
  end;
end;

procedure TRequestQueueTests.ManyLaps_KeepOrder;
var
  LLap: Integer;
  LItem: Integer;
  LNext: NativeUInt;
  LExpected: NativeUInt;
  LValue: NativeUInt;
begin
  // 3 values per lap through 4 cells: every cell is used at every offset
  FQueue.Open(4);
  LNext := 0;
  LExpected := 0;

  for LLap := 1 to 10000 do
  begin
    for LItem := 1 to 3 do
    begin
      AssertTrue(FQueue.TryEnqueue(LNext));
      Inc(LNext);
    end;

    for LItem := 1 to 3 do
    begin
      AssertTrue(FQueue.TryDequeue(LValue));

      if LValue <> LExpected then
        Fail(Format('Lap %d: expected %d, got %d', [LLap, LExpected, LValue]));

      Inc(LExpected);
    end;
  end;

  AssertEquals(0, Int64(FQueue.Count));
end;

procedure TRequestQueueTests.PositionWrapAround_KeepsOrder;
var
  LIndex: Integer;
  LValue: NativeUInt;
  LRound: Integer;
begin
  // The positions start 5 before the end of the NativeUInt range
  FQueue.Open(4, High(NativeUInt) - 5);

  for LRound := 1 to 5 do
  begin
    // Fill completely, across the wrap-around, then empty
    for LIndex := 1 to 4 do
      AssertTrue(Format('Round %d: enqueue %d', [LRound, LIndex]), FQueue.TryEnqueue(LIndex));

    AssertFalse(Format('Round %d: full', [LRound]), FQueue.TryEnqueue(99));
    AssertEquals(Format('Round %d: count', [LRound]), 4, Int64(FQueue.Count));

    for LIndex := 1 to 4 do
    begin
      AssertTrue(Format('Round %d: dequeue %d', [LRound, LIndex]), FQueue.TryDequeue(LValue));
      CheckEqualsU64(Format('Round %d: order', [LRound]), LIndex, LValue);
    end;

    AssertFalse(Format('Round %d: empty', [LRound]), FQueue.TryDequeue(LValue));
    // One more pair, so that the next round starts at another offset
    AssertTrue(FQueue.TryEnqueue(7));
    AssertTrue(FQueue.TryDequeue(LValue));
  end;
end;

procedure TRequestQueueTests.ClosedQueue_RefusesValues;
var
  LValue: NativeUInt;
begin
  AssertFalse('Enqueue', FQueue.TryEnqueue(1));
  AssertFalse('Dequeue', FQueue.TryDequeue(LValue));
  AssertEquals('Count', 0, Int64(FQueue.Count));
  AssertEquals('Capacity', 0, Int64(FQueue.Capacity));
end;

procedure TRequestQueueTests.WorkQueue(AIndex: Integer);
var
  LProducer: Integer;
  LSequence: Integer;
  LItem: NativeUInt;
  LPause: Integer;
begin
  // Threads 0..FConsumers-1 consume, the rest produce (producer 1..FProducers)
  if AIndex < FConsumers then
  begin
    while TAtomic.LoadAcquire(FConsumed) < FProducers * FItems do
      if FQueue.TryDequeue(LItem) then
      begin
        LProducer := Integer(LItem shr 24);
        LSequence := Integer(LItem and $FFFFFF);

        if (LProducer < 1) or (LProducer > FProducers) or (LSequence >= FItems) then
          TAtomic.Increment(FFailures)    // a value nobody put in
        else
        begin
          if TAtomic.Exchange(FSeen[LProducer * FItems + LSequence], 1) <> 0 then
            TAtomic.Increment(FFailures);    // came out twice

          if FConsumers = 1 then
          begin
            if LSequence <> FNextExpected[LProducer] then
              TAtomic.Increment(FFailures);    // out of order

            FNextExpected[LProducer] := LSequence + 1;
          end;
        end;

        TAtomic.Increment(FConsumed);
      end
      else if TThread.GetTickCount64 > FDeadline then
      begin
        TAtomic.Exchange(FTimedOut, 1);    // values were lost

        Exit;
      end
      else
        TAtomic.CpuPause;
  end
  else
  begin
    LProducer := AIndex - FConsumers + 1;

    for LSequence := 0 to FItems - 1 do
    begin
      for LPause := 1 to FProducerPauses do
        TAtomic.CpuPause;

      while not FQueue.TryEnqueue(EncodeValue(LProducer, LSequence)) do
        if TAtomic.LoadAcquire(FTimedOut) <> 0 then
          Exit    // the consumers gave up
        else
          TAtomic.CpuPause;    // full: wait for the consumers
    end;
  end;
end;

procedure TRequestQueueTests.RunProducersAndConsumers(const AProducers, AConsumers, AItems: Integer;
  const ACapacity: Cardinal; const AFirstPosition: NativeUInt; const AProducerPauses: Integer);
var
  LIndex: Integer;
  LValue: NativeUInt;
begin
  FQueue.Open(ACapacity, AFirstPosition);
  FProducers := AProducers;
  FConsumers := AConsumers;
  FItems := AItems;
  FProducerPauses := AProducerPauses;
  SetLength(FSeen, (AProducers + 1) * AItems);
  FillChar(FSeen[0], Length(FSeen) * SizeOf(Integer), 0);
  SetLength(FNextExpected, AProducers + 1);
  FillChar(FNextExpected[0], Length(FNextExpected) * SizeOf(Integer), 0);
  FDeadline := TThread.GetTickCount64 + 20000;

  RunThreads(AConsumers + AProducers, WorkQueue);

  AssertEquals('Gave up after 20 s: values were lost', 0, FTimedOut);
  AssertEquals('Values twice, out of order, or unknown', 0, FFailures);
  AssertEquals('Values consumed', AProducers * AItems, FConsumed);

  for LIndex := AItems to High(FSeen) do
    if FSeen[LIndex] <> 1 then
      Fail(Format('Value of producer %d, sequence %d never came out', [LIndex div AItems, LIndex mod AItems]));

  AssertEquals('Empty at the end', 0, Int64(FQueue.Count));
  AssertFalse('Nothing left', FQueue.TryDequeue(LValue));
end;

procedure TRequestQueueTests.Stress_ManyProducersOneConsumer;
begin
  // The engine's case: many threads hand requests to one I/O thread
  RunProducersAndConsumers(4, 1, 100000, 64);
end;

procedure TRequestQueueTests.Stress_ManyProducersManyConsumers;
begin
  RunProducersAndConsumers(4, 4, 100000, 64);
end;

procedure TRequestQueueTests.Stress_SmallQueue_OftenFullAndEmpty;
begin
  RunProducersAndConsumers(4, 2, 50000, 2);
end;

procedure TRequestQueueTests.Stress_PositionWrapAroundUnderLoad;
begin
  // The positions wrap around after about 100 000 of the 400 000 values
  RunProducersAndConsumers(4, 1, 100000, 16, High(NativeUInt) - 100000);
end;

procedure TRequestQueueTests.Stress_ConsumerWaitsForEveryValue;
begin
  { Slow producers: the consumer waits at the empty queue and takes every value right after it is published - the
    "empty" path, which the busy queues above rarely take }
  RunProducersAndConsumers(2, 1, 50000, 64, 0, 20);
end;

initialization
  RegisterTests(TRequestQueueTests);

end.
