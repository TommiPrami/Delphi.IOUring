unit PIRUnit.RequestQueue;

  {
    The queue from the producer threads to an I/O thread (Docs/Design.md §10.5): a bounded, lock-free first-in
    first-out queue of pointer-sized values (request handles). Fixed memory, no allocation per item.

    The algorithm is Dmitry Vyukov's bounded MPMC queue: an array of cells, and two position counters that only grow
    (enqueue and dequeue position, each on its own cache line). Each cell has a sequence number that says whose turn
    the cell is:

      Sequence = P          free: the producer that claims position P may write it
      Sequence = P + 1      full: the consumer of position P may read it
      Sequence = P + Size   free again, for position P + Size (the next lap)

    A producer claims a position with one compare-exchange on the enqueue position, writes the value, then publishes
    it by storing the sequence. A consumer does the same on the dequeue side. Producers do not touch the consumer's
    counter and the other way round, so a busy queue has little contention between the two sides.

    Any number of producers and consumers may use the queue at the same time (the engine has one consumer per queue,
    the I/O thread; one compare-exchange per item is the price of not having to trust that). Positions are NativeUInt
    and wrap around on Win32 after 2^32 items; the differences are compared as signed numbers, so that is harmless.

    All methods are thread-safe, except Open and Close: no other thread may use the queue during them.
  }

{$I PIRInclude.Compiler.inc}

// The positions wrap around on purpose
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Atomics;

const
  IORING_QUEUE_MAX_CAPACITY = 1 shl 20;

type
  TIORingRequestQueue = record
  private
    type
      TCell = record
        Sequence: NativeUInt;
        Value: NativeUInt;
      end;

      TCellArray = array[0..MaxInt div SizeOf(TCell) - 1] of TCell;
      PCellArray = ^TCellArray;

  private
    FMemory: Pointer;                 // as allocated
    FEnqueuePosition: ^NativeUInt;    // its own cache line
    FDequeuePosition: ^NativeUInt;    // its own cache line
    FCells: PCellArray;
    FMask: NativeUInt;                // Capacity - 1
    FCapacity: Cardinal;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingRequestQueue);
    class operator Finalize(var ADest: TIORingRequestQueue);
    class operator Copy(constref ASource: TIORingRequestQueue; var ADest: TIORingRequestQueue);
{$ELSE}
    class operator Initialize(out ADest: TIORingRequestQueue);
    class operator Finalize(var ADest: TIORingRequestQueue);
    class operator Assign(var ADest: TIORingRequestQueue; const [ref] ASource: TIORingRequestQueue);
{$ENDIF}

    {
      At least ACapacity cells: rounded up to a power of two (at least 2). Raises EIORingError for 0, above
      IORING_QUEUE_MAX_CAPACITY, or if already open. AFirstPosition is only for tests: starting near the end of the
      NativeUInt range checks the wrap-around of the positions.
    }
    procedure Open(const ACapacity: Cardinal; const AFirstPosition: NativeUInt = 0);
    // Values still in the queue are dropped
    procedure Close;

    // False if the queue is full
    function TryEnqueue(const AValue: NativeUInt): Boolean;
    // False if the queue is empty
    function TryDequeue(out AValue: NativeUInt): Boolean;

    { Values in the queue. Exact only when no other thread uses the queue; otherwise a moment's picture (it may count a
      value that is still being written). }
    function Count: Cardinal;

    property Capacity: Cardinal read FCapacity;
  end;

implementation

uses
  PIRUnit.Types;

{ TIORingRequestQueue - life cycle }

{$IFDEF FPC}
class operator TIORingRequestQueue.Initialize(var ADest: TIORingRequestQueue);
{$ELSE}
class operator TIORingRequestQueue.Initialize(out ADest: TIORingRequestQueue);
{$ENDIF}
begin
  ADest.FMemory := nil;
  ADest.FEnqueuePosition := nil;
  ADest.FDequeuePosition := nil;
  ADest.FCells := nil;
  ADest.FMask := 0;
  ADest.FCapacity := 0;
end;

class operator TIORingRequestQueue.Finalize(var ADest: TIORingRequestQueue);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TIORingRequestQueue.Copy(constref ASource: TIORingRequestQueue; var ADest: TIORingRequestQueue);
{$ELSE}
class operator TIORingRequestQueue.Assign(var ADest: TIORingRequestQueue; const [ref] ASource: TIORingRequestQueue);
{$ENDIF}

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A request queue cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure TIORingRequestQueue.Open(const ACapacity: Cardinal; const AFirstPosition: NativeUInt);

  procedure RaiseCapacityOutOfRange(const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Request queue capacity must be 1..%d, not %d', [IORING_QUEUE_MAX_CAPACITY, ACount]);
  end;

  procedure RaiseAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The request queue is already open');
  end;

var
  LCapacity: Cardinal;
  LBlock: PByte;
  LIndex: Cardinal;
  LPosition: NativeUInt;
begin
  if (ACapacity = 0) or (ACapacity > IORING_QUEUE_MAX_CAPACITY) then
    RaiseCapacityOutOfRange(ACapacity);

  if FMemory <> nil then
    RaiseAlreadyOpen;

  LCapacity := 2;

  while LCapacity < ACapacity do
    LCapacity := LCapacity * 2;

  // Line 0: enqueue position, line 1: dequeue position, then the cells
  LBlock := IORingAllocCacheAligned(2 * IORING_CACHE_LINE_SIZE + NativeUInt(LCapacity) * SizeOf(TCell),
    FMemory);
  FEnqueuePosition := Pointer(LBlock);
  FDequeuePosition := Pointer(LBlock + IORING_CACHE_LINE_SIZE);
  FCells := Pointer(LBlock + 2 * IORING_CACHE_LINE_SIZE);
  FMask := LCapacity - 1;
  FCapacity := LCapacity;

  // Every cell is free for the first lap: the position that lands on it
  FEnqueuePosition^ := AFirstPosition;
  FDequeuePosition^ := AFirstPosition;

  for LIndex := 0 to LCapacity - 1 do
  begin
    LPosition := AFirstPosition + LIndex;
    FCells^[LPosition and FMask].Sequence := LPosition;
  end;
end;

procedure TIORingRequestQueue.Close;
begin
  if FMemory <> nil then
    FreeMem(FMemory);

  FMemory := nil;
  FEnqueuePosition := nil;
  FDequeuePosition := nil;
  FCells := nil;
  FMask := 0;
  FCapacity := 0;
end;

{ TIORingRequestQueue - items }

function TIORingRequestQueue.TryEnqueue(const AValue: NativeUInt): Boolean;
var
  LPosition: NativeUInt;
  LCell: ^TCell;
  LDifference: NativeInt;
  LBackoff: Integer;
begin
  if FCells = nil then
    Exit(False);

  LBackoff := 1;
  LPosition := TAtomic.LoadAcquire(FEnqueuePosition^);

  repeat
    LCell := @FCells^[LPosition and FMask];
    LDifference := NativeInt(TAtomic.LoadAcquire(LCell^.Sequence) - LPosition);

    if LDifference = 0 then
    begin
      // The cell is free for this position: claim the position
      if TAtomic.TryCompareExchange(FEnqueuePosition^, LPosition + 1, LPosition) then
        Break;

      TAtomic.BackOff(LBackoff);
    end
    else if LDifference < 0 then
      Exit(False)    // the cell still holds a value from the last lap: full
    else
      TAtomic.BackOff(LBackoff);    // another producer took this position

    LPosition := TAtomic.LoadAcquire(FEnqueuePosition^);
  until False;

  LCell^.Value := AValue;
  // Publish: now the consumer of this position may read it
  TAtomic.StoreRelease(LCell^.Sequence, LPosition + 1);

  Result := True;
end;

function TIORingRequestQueue.TryDequeue(out AValue: NativeUInt): Boolean;
var
  LPosition: NativeUInt;
  LCell: ^TCell;
  LDifference: NativeInt;
  LBackoff: Integer;
begin
  AValue := 0;

  if FCells = nil then
    Exit(False);

  LBackoff := 1;
  LPosition := TAtomic.LoadAcquire(FDequeuePosition^);

  repeat
    LCell := @FCells^[LPosition and FMask];
    LDifference := NativeInt(TAtomic.LoadAcquire(LCell^.Sequence) - (LPosition + 1));

    if LDifference = 0 then
    begin
      // The cell holds the value of this position: claim the position
      if TAtomic.TryCompareExchange(FDequeuePosition^, LPosition + 1, LPosition) then
        Break;

      TAtomic.BackOff(LBackoff);
    end
    else if LDifference < 0 then
      Exit(False)    // not written yet: empty
    else
      TAtomic.BackOff(LBackoff);    // another consumer took this position

    LPosition := TAtomic.LoadAcquire(FDequeuePosition^);
  until False;

  AValue := LCell^.Value;
  // Free the cell for the position one lap later
  TAtomic.StoreRelease(LCell^.Sequence, LPosition + FMask + 1);

  Result := True;
end;

function TIORingRequestQueue.Count: Cardinal;
var
  LDequeue: NativeUInt;
  LCount: NativeInt;
begin
  if FCells = nil then
    Exit(0);

  // Dequeue position first: then the difference can be too big, never negative
  LDequeue := TAtomic.LoadAcquire(FDequeuePosition^);
  LCount := NativeInt(TAtomic.LoadAcquire(FEnqueuePosition^) - LDequeue);

  if LCount < 0 then
    Result := 0
  else if LCount > NativeInt(FCapacity) then
    Result := FCapacity
  else
    Result := Cardinal(LCount);
end;

end.
