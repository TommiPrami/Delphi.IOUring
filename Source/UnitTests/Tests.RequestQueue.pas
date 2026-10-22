unit Tests.RequestQueue;

{
  Tests for TIORingRequestQueue (Delphi.IOUring.RequestQueue): order, full
  and empty, the capacity, many laps around the array, and the wrap-around of
  the position counters (started just before the end of the NativeUInt
  range).

  Multi-thread stress: producers and consumers at the same time. Every value
  must come out exactly once; with one consumer (the engine's case) also in
  the order each producer put them in.
}

interface

uses
  DUnitX.TestFramework,
  Delphi.IOUring.RequestQueue;

type
  [TestFixture]
  TRequestQueueTests = class
  private
    FQueue: TIORingRequestQueue;
    FFailures: Integer;
    FConsumed: Integer;
    FSeen: array of Integer;            // [Producer * Items + Sequence]: 1 when consumed
    FNextExpected: array of Integer;    // per producer, with one consumer
    FDeadline: UInt64;                  // TThread.GetTickCount64: give up (a lost value would hang the test)
    FTimedOut: Integer;
    // Runs AProducers producers that each put AItems values into a queue of
    // ACapacity cells, and AConsumers consumers that take them all out; then
    // checks that every value came out once (and in order, with one consumer).
    // AProducerPauses: CPU pauses a producer waits between two values (slow
    // producers: the consumers wait at the empty queue).
    procedure RunProducersAndConsumers(const AProducers, AConsumers, AItems: Integer;
      const ACapacity: Cardinal; const AFirstPosition: NativeUInt = 0; const AProducerPauses: Integer = 0);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // One thread
    [Test]
    procedure Open_RoundsCapacityUp;
    [Test]
    procedure BadArguments_Raise;
    [Test]
    procedure FirstInFirstOut_FullAndEmpty;
    [Test]
    procedure AnyValue_PassesThrough;
    [Test]
    procedure ManyLaps_KeepOrder;
    [Test]
    procedure PositionWrapAround_KeepsOrder;
    [Test]
    procedure ClosedQueue_RefusesValues;

    // Several threads
    [Test]
    procedure Stress_ManyProducersOneConsumer;
    [Test]
    procedure Stress_ManyProducersManyConsumers;
    [Test]
    procedure Stress_SmallQueue_OftenFullAndEmpty;
    [Test]
    procedure Stress_PositionWrapAroundUnderLoad;
    [Test]
    procedure Stress_ConsumerWaitsForEveryValue;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Delphi.IOUring,
  Delphi.IOUring.Atomics,
  TestThreadHelpers;

// A value that says who put it in and when: producer in the bits 24..30,
// its sequence number below (fits NativeUInt on Win32 too)
function EncodeValue(const AProducer, ASequence: Integer): NativeUInt;
begin
  Result := (NativeUInt(AProducer) shl 24) or NativeUInt(ASequence);
end;

{ TRequestQueueTests }

procedure TRequestQueueTests.Setup;
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
  Assert.AreEqual(Cardinal(8), FQueue.Capacity, '5 -> 8');
  FQueue.Close;
  FQueue.Open(1);
  Assert.AreEqual(Cardinal(2), FQueue.Capacity, '1 -> 2 (the smallest)');
  FQueue.Close;
  FQueue.Open(1024);
  Assert.AreEqual(Cardinal(1024), FQueue.Capacity, 'A power of two stays');
  Assert.AreEqual(Cardinal(0), FQueue.Count, 'Empty');
end;

procedure TRequestQueueTests.BadArguments_Raise;
begin
  Assert.WillRaise(
    procedure
    begin
      FQueue.Open(0);
    end, EIORingError, 'Capacity 0');
  Assert.WillRaise(
    procedure
    begin
      FQueue.Open(IORING_QUEUE_MAX_CAPACITY + 1);
    end, EIORingError, 'Capacity too big');
  FQueue.Open(4);
  Assert.WillRaise(
    procedure
    begin
      FQueue.Open(4);
    end, EIORingError, 'Opened twice');
end;

procedure TRequestQueueTests.FirstInFirstOut_FullAndEmpty;
var
  LValue: NativeUInt;
  LIndex: Integer;
begin
  FQueue.Open(8);
  for LIndex := 1 to 8 do
    Assert.IsTrue(FQueue.TryEnqueue(LIndex * 10), 'Enqueue ' + IntToStr(LIndex));
  Assert.IsFalse(FQueue.TryEnqueue(90), 'Full');
  Assert.AreEqual(Cardinal(8), FQueue.Count, 'Count when full');

  for LIndex := 1 to 8 do
  begin
    Assert.IsTrue(FQueue.TryDequeue(LValue), 'Dequeue ' + IntToStr(LIndex));
    Assert.AreEqual<NativeUInt>(NativeUInt(LIndex * 10), LValue, 'Order');
  end;
  Assert.IsFalse(FQueue.TryDequeue(LValue), 'Empty');
  Assert.AreEqual<NativeUInt>(0, LValue, 'Empty gives 0');
  Assert.AreEqual(Cardinal(0), FQueue.Count, 'Count when empty');

  // Usable again after full and empty
  Assert.IsTrue(FQueue.TryEnqueue(5));
  Assert.AreEqual(Cardinal(1), FQueue.Count);
  Assert.IsTrue(FQueue.TryDequeue(LValue));
  Assert.AreEqual<NativeUInt>(5, LValue);
end;

procedure TRequestQueueTests.AnyValue_PassesThrough;
const
  VALUES: array[0..3] of NativeUInt = (0, High(NativeUInt), NativeUInt(High(NativeUInt)) div 3, 1);
var
  LIndex: Integer;
  LValue: NativeUInt;
begin
  FQueue.Open(4);
  for LIndex := 0 to High(VALUES) do
    Assert.IsTrue(FQueue.TryEnqueue(VALUES[LIndex]));
  for LIndex := 0 to High(VALUES) do
  begin
    Assert.IsTrue(FQueue.TryDequeue(LValue));
    Assert.AreEqual<NativeUInt>(VALUES[LIndex], LValue);
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
      Assert.IsTrue(FQueue.TryEnqueue(LNext));
      Inc(LNext);
    end;
    for LItem := 1 to 3 do
    begin
      Assert.IsTrue(FQueue.TryDequeue(LValue));
      if LValue <> LExpected then
        Assert.Fail(Format('Lap %d: expected %d, got %d', [LLap, LExpected, LValue]));
      Inc(LExpected);
    end;
  end;
  Assert.AreEqual(Cardinal(0), FQueue.Count);
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
      Assert.IsTrue(FQueue.TryEnqueue(LIndex), Format('Round %d: enqueue %d', [LRound, LIndex]));
    Assert.IsFalse(FQueue.TryEnqueue(99), Format('Round %d: full', [LRound]));
    Assert.AreEqual(Cardinal(4), FQueue.Count, Format('Round %d: count', [LRound]));
    for LIndex := 1 to 4 do
    begin
      Assert.IsTrue(FQueue.TryDequeue(LValue), Format('Round %d: dequeue %d', [LRound, LIndex]));
      Assert.AreEqual<NativeUInt>(NativeUInt(LIndex), LValue, Format('Round %d: order', [LRound]));
    end;
    Assert.IsFalse(FQueue.TryDequeue(LValue), Format('Round %d: empty', [LRound]));
    // One more pair, so that the next round starts at another offset
    Assert.IsTrue(FQueue.TryEnqueue(7));
    Assert.IsTrue(FQueue.TryDequeue(LValue));
  end;
end;

procedure TRequestQueueTests.ClosedQueue_RefusesValues;
var
  LValue: NativeUInt;
begin
  Assert.IsFalse(FQueue.TryEnqueue(1), 'Enqueue');
  Assert.IsFalse(FQueue.TryDequeue(LValue), 'Dequeue');
  Assert.AreEqual(Cardinal(0), FQueue.Count, 'Count');
  Assert.AreEqual(Cardinal(0), FQueue.Capacity, 'Capacity');
end;

procedure TRequestQueueTests.RunProducersAndConsumers(const AProducers, AConsumers, AItems: Integer;
  const ACapacity: Cardinal; const AFirstPosition: NativeUInt; const AProducerPauses: Integer);
var
  LTotal: Integer;
  LIndex: Integer;
  LValue: NativeUInt;
begin
  FQueue.Open(ACapacity, AFirstPosition);
  LTotal := AProducers * AItems;
  SetLength(FSeen, (AProducers + 1) * AItems);
  FillChar(FSeen[0], Length(FSeen) * SizeOf(Integer), 0);
  SetLength(FNextExpected, AProducers + 1);
  FillChar(FNextExpected[0], Length(FNextExpected) * SizeOf(Integer), 0);
  FDeadline := TThread.GetTickCount64 + 20000;

  // Threads 0..AConsumers-1 consume, the rest produce (producer 1..AProducers)
  RunThreads(AConsumers + AProducers,
    procedure(AThread: Integer)
    var
      LProducer: Integer;
      LSequence: Integer;
      LItem: NativeUInt;
      LPause: Integer;
    begin
      if AThread < AConsumers then
      begin
        while TAtomic.LoadAcquire(FConsumed) < LTotal do
          if FQueue.TryDequeue(LItem) then
          begin
            LProducer := Integer(LItem shr 24);
            LSequence := Integer(LItem and $FFFFFF);
            if (LProducer < 1) or (LProducer > AProducers) or (LSequence >= AItems) then
              TAtomic.Increment(FFailures)    // a value nobody put in
            else
            begin
              if TAtomic.Exchange(FSeen[LProducer * AItems + LSequence], 1) <> 0 then
                TAtomic.Increment(FFailures);    // came out twice
              if AConsumers = 1 then
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
        LProducer := AThread - AConsumers + 1;
        for LSequence := 0 to AItems - 1 do
        begin
          for LPause := 1 to AProducerPauses do
            TAtomic.CpuPause;
          while not FQueue.TryEnqueue(EncodeValue(LProducer, LSequence)) do
            if TAtomic.LoadAcquire(FTimedOut) <> 0 then
              Exit    // the consumers gave up
            else
              TAtomic.CpuPause;    // full: wait for the consumers
        end;
      end;
    end);

  Assert.AreEqual(0, FTimedOut, 'Gave up after 20 s: values were lost');
  Assert.AreEqual(0, FFailures, 'Values twice, out of order, or unknown');
  Assert.AreEqual(LTotal, FConsumed, 'Values consumed');
  for LIndex := AItems to High(FSeen) do
    if FSeen[LIndex] <> 1 then
      Assert.Fail(Format('Value of producer %d, sequence %d never came out', [LIndex div AItems, LIndex mod AItems]));
  Assert.AreEqual(Cardinal(0), FQueue.Count, 'Empty at the end');
  Assert.IsFalse(FQueue.TryDequeue(LValue), 'Nothing left');
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
  // Slow producers: the consumer waits at the empty queue and takes every
  // value right after it is published - the "empty" path, which the busy
  // queues above rarely take
  RunProducersAndConsumers(2, 1, 50000, 64, 0, 20);
end;

initialization
  TDUnitX.RegisterTestFixture(TRequestQueueTests);

end.
