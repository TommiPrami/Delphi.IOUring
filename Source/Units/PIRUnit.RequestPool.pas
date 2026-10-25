unit PIRUnit.RequestPool;

{
  The engine's request slots (Docs/Design.md §10.3): a fixed number of slots,
  made once and used again and again - no memory allocation per request.

  Each slot has a 32-bit state word and room for the engine's own request
  data (the "payload", APayloadSize bytes; the pool does not look at it).
  Slots are padded to whole cache lines, so two requests never share one.

  A request is known by its handle: slot index + generation in one
  NativeUInt, which is also the UserData the ring gives back in the
  completion. Releasing a slot moves its generation on, so an old handle (a
  late WaitFor, a stale completion) is recognised: every method that takes a
  handle checks it. (The generation wraps around after 2^GenerationBits
  releases of the same slot; a handle that old is not recognised as stale.)

  Life of a request:

   TryAcquire       Free      -> Defined     the owner (any thread)
   TryChangeState   Defined   -> Queued      the owner, when it hands the request on
   TryChangeState   Queued    -> Submitted   the I/O thread
   TryChangeState   Submitted -> Completed   the I/O thread; wakes WaitFor
   WaitFor                                   the owner (or anyone with the handle)
   Release          Completed -> Free        the owner (also Defined -> Free)

  TryChangeState allows any change between Defined, Queued, Submitted and
  Completed (for example Queued -> Completed for a request cancelled before
  it was submitted); the caller says which state it expects.

  Free slots are kept in a TIORingFreeList, a lock-free stack.

  All methods are thread-safe, except Open and Close: no other thread may use
  the pool (or the free list) during them.
}

{$I PIRInclude.Compiler.inc}

// The tag of the free list wraps around on purpose
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
  IORING_POOL_MAX_CAPACITY = 1 shl 20;
  IORING_POOL_MAX_PAYLOAD_SIZE = 64 * 1024;
  {
    Before WaitFor goes to sleep, it checks the state for this long, with CPU pauses ("spinning"). A request that
    completes meanwhile costs neither thread a sleep and a wake-up. A time, not a number of pauses: a pause takes 17 ns
    on an E-core of an Intel i7-14700 and 33 ns on a P-core, and much less on older CPUs. Longer spins (up to 64 µs) and
    spins learned from earlier waits were measured too and did not pay off (Docs/Design.md §10.11).
  }
  IORING_POOL_DEFAULT_SPIN_MICROSECONDS = 4;

type
  {
    Lock-free stack of the indices 0..Capacity-1 (a Treiber stack).

    The top of the stack and a counter (the "tag") share one 64-bit word, changed with one compare-exchange
    (CMPXCHG8B on Win32). The tag changes on every push and pop, so a thread that read the top before another thread
    changed the stack always fails and tries again (no ABA problem). The links stay in memory until Close, so reading
    the link of an index that another thread has just taken is harmless. Before trying again, a thread backs off
    (TAtomic.BackOff).
  }
  TIORingFreeList = record
  private
    type
      TIndexArray = array[0..MaxInt div SizeOf(Cardinal) - 1] of Cardinal;
      PIndexArray = ^TIndexArray;

  private
    FMemory: Pointer;          // as allocated
    FHead: PUInt64;            // tag (upper 32 bits) | top index (lower 32 bits); its own cache line
    FNext: PIndexArray;        // FNext[Index]: the index below Index
    FCapacity: Cardinal;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingFreeList);
    class operator Finalize(var ADest: TIORingFreeList);
    class operator Copy(constref ASource: TIORingFreeList; var ADest: TIORingFreeList);
{$ELSE}
    class operator Initialize(out ADest: TIORingFreeList);
    class operator Finalize(var ADest: TIORingFreeList);
    class operator Assign(var ADest: TIORingFreeList; const [ref] ASource: TIORingFreeList);
{$ENDIF}

    { AFull: all indices are in the stack (0 on top); otherwise it is empty. Raises EIORingError for a bad
      capacity or if already open. }
    procedure Open(const ACapacity: Cardinal; const AFull: Boolean = True);
    procedure Close;

    // False if the stack is empty
    function TryPop(out AIndex: Cardinal): Boolean;
    // AIndex must not be in the stack already
    procedure Push(const AIndex: Cardinal);

    property Capacity: Cardinal read FCapacity;
  end;

  TIORingRequestState = (
    rsFree,
    rsDefined,
    rsQueued,
    rsSubmitted,
    rsCompleted,
    rsStale    // only as an answer of State: the handle is old (its slot was released)
  );

  TIORingWaitResult = (wrCompleted, wrTimeout, wrStale);

  // One request: slot index + generation. 0 = no request.
  TIORingRequestHandle = record
    Value: TIORingUserData;    // also the ring's UserData for the request
    // Not inline: the engine re-exports this type, and Delphi does not inline through an alias (hint H2443)
    class function FromUserData(const AUserData: TIORingUserData): TIORingRequestHandle; static;
    function IsEmpty: Boolean;
  end;

  TIORingRequestPool = record
  private
    FMemory: Pointer;          // as allocated
    FSlots: PByte;             // the first slot, cache-line aligned
    FPayloads: PByte;          // the payload of the first slot
    FStride: NativeUInt;       // bytes from one slot to the next
    FCapacity: Cardinal;
    FPayloadSize: Cardinal;
    FIndexBits: Cardinal;
    FIndexMask: NativeUInt;
    FGenerationBits: Cardinal;
    FGenerationMask: Cardinal;
    FSpinMicroseconds: Cardinal;
    FFreeList: TIORingFreeList;
    // The state word of the handle's slot; nil if the index is out of range
    function StateWordOf(const AHandle: TIORingRequestHandle): PCardinal; inline;
    function GenerationOf(const AHandle: TIORingRequestHandle): Cardinal; inline;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingRequestPool);
    class operator Finalize(var ADest: TIORingRequestPool);
    class operator Copy(constref ASource: TIORingRequestPool; var ADest: TIORingRequestPool);
{$ELSE}
    class operator Initialize(out ADest: TIORingRequestPool);
    class operator Finalize(var ADest: TIORingRequestPool);
    class operator Assign(var ADest: TIORingRequestPool; const [ref] ASource: TIORingRequestPool);
{$ENDIF}

    { ACapacity slots of APayloadSize bytes each, all free, payloads zeroed. Raises EIORingError for a capacity of 0 or
      above IORING_POOL_MAX_CAPACITY, a payload above IORING_POOL_MAX_PAYLOAD_SIZE, or if already open. }
    procedure Open(const ACapacity: Cardinal; const APayloadSize: Cardinal = 0);
    // No request may be in use any more
    procedure Close;

    // Takes a free slot (state Defined). False if all slots are in use.
    function TryAcquire(out AHandle: TIORingRequestHandle): Boolean;
    { Gives the slot back (from Defined or Completed); the handle becomes stale and threads waiting on it wake up. False
      if the handle is stale or the request is still Queued or Submitted. }
    function Release(const AHandle: TIORingRequestHandle): Boolean;

    { AFrom -> ATo, if the handle is current and the request is in AFrom. AFrom and ATo: Defined, Queued, Submitted or
      Completed (EIORingError otherwise). Changing to Completed wakes the threads in WaitFor. }
    function TryChangeState(const AHandle: TIORingRequestHandle; const AFrom, ATo: TIORingRequestState): Boolean;
    // The current state, or rsStale
    function State(const AHandle: TIORingRequestHandle): TIORingRequestState;

    // Waits until the request is Completed: spins SpinMicroseconds, then sleeps. A timeout of 0 only checks.
    function WaitFor(const AHandle: TIORingRequestHandle;
      const ATimeoutMilliseconds: Cardinal = IORING_INFINITE): TIORingWaitResult;

    // The slot index of the handle (0..Capacity-1 for a valid handle)
    function IndexOf(const AHandle: TIORingRequestHandle): Cardinal; inline;
    { The payload of the handle's slot: 8-byte aligned, PayloadSize bytes. Not checked - the caller
      must own a current handle. }
    function Payload(const AHandle: TIORingRequestHandle): Pointer; inline;

    property Capacity: Cardinal read FCapacity;
    property PayloadSize: Cardinal read FPayloadSize;
    // Bits of the generation in a handle (depends on the capacity on Win32)
    property GenerationBits: Cardinal read FGenerationBits;
    // How long WaitFor spins before it sleeps; 0: no spinning, sleep at once
    property SpinMicroseconds: Cardinal read FSpinMicroseconds write FSpinMicroseconds;
  end;

implementation

uses
  PIRUnit.Types;

const
  NO_INDEX = Cardinal($FFFFFFFF);

  {
    State word: generation (bits 4..31) | WAITING_FLAG | state (bits 0..2).
    WAITING_FLAG is set by a thread that is about to sleep in WaitFor; only
    then does a change to Completed (or a release) call the wake function.
  }
  STATE_MASK = Cardinal($7);
  WAITING_FLAG = Cardinal($8);
  GENERATION_SHIFT = 4;
  STATE_WORD_GENERATION_BITS = 32 - GENERATION_SHIFT;

  // The state word, then padding: the payload starts 8-byte aligned
  SLOT_HEADER_SIZE = 8;

  // While spinning, WaitFor reads the clock every SPIN_CLOCK_CHECK_MASK + 1 pauses
  SPIN_CLOCK_CHECK_MASK = 7;

{ TIORingFreeList }

{$IFDEF FPC}
class operator TIORingFreeList.Initialize(var ADest: TIORingFreeList);
{$ELSE}
class operator TIORingFreeList.Initialize(out ADest: TIORingFreeList);
{$ENDIF}
begin
  ADest.FMemory := nil;
  ADest.FHead := nil;
  ADest.FNext := nil;
  ADest.FCapacity := 0;
end;

class operator TIORingFreeList.Finalize(var ADest: TIORingFreeList);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TIORingFreeList.Copy(constref ASource: TIORingFreeList; var ADest: TIORingFreeList);
{$ELSE}
class operator TIORingFreeList.Assign(var ADest: TIORingFreeList; const [ref] ASource: TIORingFreeList);
{$ENDIF}

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A free list cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure TIORingFreeList.Open(const ACapacity: Cardinal; const AFull: Boolean);

  procedure RaiseCapacityOutOfRange(const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Free list capacity must be 1..%d, not %d', [IORING_POOL_MAX_CAPACITY, ACount]);
  end;

  procedure RaiseAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The free list is already open');
  end;

var
  LIndex: Cardinal;
begin
  if (ACapacity = 0) or (ACapacity > IORING_POOL_MAX_CAPACITY) then
    RaiseCapacityOutOfRange(ACapacity);

  if FMemory <> nil then
    RaiseAlreadyOpen;

  // The head alone on the first cache line, the links after it
  FHead := IORingAllocCacheAligned(IORING_CACHE_LINE_SIZE + NativeUInt(ACapacity) * SizeOf(Cardinal), FMemory);
  FNext := PIndexArray(PByte(FHead) + IORING_CACHE_LINE_SIZE);
  FCapacity := ACapacity;

  if AFull then
  begin
    for LIndex := 1 to ACapacity - 1 do
      FNext^[LIndex - 1] := LIndex;

    FNext^[ACapacity - 1] := NO_INDEX;
    FHead^ := 0;              // tag 0, top 0
  end
  else
  begin
    for LIndex := 0 to ACapacity - 1 do
      FNext^[LIndex] := NO_INDEX;

    FHead^ := NO_INDEX;       // tag 0, empty
  end;
end;

procedure TIORingFreeList.Close;
begin
  if FMemory <> nil then
    FreeMem(FMemory);

  FMemory := nil;
  FHead := nil;
  FNext := nil;
  FCapacity := 0;
end;

function TIORingFreeList.TryPop(out AIndex: Cardinal): Boolean;
var
  LOld: UInt64;
  LNew: UInt64;
  LTop: Cardinal;
  LBackoff: Integer;
begin
  AIndex := NO_INDEX;

  if FHead = nil then
    Exit(False);

  LBackoff := 1;

  repeat
    LOld := TAtomic.LoadAcquire(FHead^);
    LTop := Cardinal(LOld and $FFFFFFFF);

    if LTop = NO_INDEX then
      Exit(False);

    {
      If another thread took LTop meanwhile, this link may be wrong - but
      then the tag has changed too, and the compare-exchange fails
    }
    LNew := (((LOld shr 32) + 1) shl 32) or TAtomic.LoadAcquire(FNext^[LTop]);

    if TAtomic.CompareExchange(FHead^, LNew, LOld) = LOld then
      Break;

    TAtomic.BackOff(LBackoff);
  until False;

  AIndex := LTop;

  Result := True;
end;

procedure TIORingFreeList.Push(const AIndex: Cardinal);

  procedure RaiseIndexOutOfRange(const AValue: Cardinal; const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Free list index %d out of range (capacity %d)', [AValue, ACount]);
  end;

var
  LOld: UInt64;
  LNew: UInt64;
  LBackoff: Integer;
begin
  if AIndex >= FCapacity then
    RaiseIndexOutOfRange(AIndex, FCapacity);

  LBackoff := 1;

  repeat
    LOld := TAtomic.LoadAcquire(FHead^);
    TAtomic.StoreRelease(FNext^[AIndex], Cardinal(LOld and $FFFFFFFF));
    LNew := (((LOld shr 32) + 1) shl 32) or AIndex;

    if TAtomic.CompareExchange(FHead^, LNew, LOld) = LOld then
      Exit;

    TAtomic.BackOff(LBackoff);
  until False;
end;

{ TIORingRequestHandle }

class function TIORingRequestHandle.FromUserData(const AUserData: TIORingUserData): TIORingRequestHandle;
begin
  Result.Value := AUserData;
end;

function TIORingRequestHandle.IsEmpty: Boolean;
begin
  Result := Value = 0;
end;

{ TIORingRequestPool - life cycle }

{$IFDEF FPC}
class operator TIORingRequestPool.Initialize(var ADest: TIORingRequestPool);
{$ELSE}
class operator TIORingRequestPool.Initialize(out ADest: TIORingRequestPool);
{$ENDIF}
begin
  ADest.FMemory := nil;
  ADest.FSlots := nil;
  ADest.FPayloads := nil;
  ADest.FStride := 0;
  ADest.FCapacity := 0;
  ADest.FPayloadSize := 0;
  ADest.FIndexBits := 0;
  ADest.FIndexMask := 0;
  ADest.FGenerationBits := 0;
  ADest.FGenerationMask := 0;
  ADest.FSpinMicroseconds := IORING_POOL_DEFAULT_SPIN_MICROSECONDS;
end;

class operator TIORingRequestPool.Finalize(var ADest: TIORingRequestPool);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TIORingRequestPool.Copy(constref ASource: TIORingRequestPool; var ADest: TIORingRequestPool);
{$ELSE}
class operator TIORingRequestPool.Assign(var ADest: TIORingRequestPool; const [ref] ASource: TIORingRequestPool);
{$ENDIF}

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A request pool cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure TIORingRequestPool.Open(const ACapacity: Cardinal; const APayloadSize: Cardinal);

  procedure RaiseCapacityOutOfRange(const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Request pool capacity must be 1..%d, not %d', [IORING_POOL_MAX_CAPACITY, ACount]);
  end;

  procedure RaisePayloadTooBig(const ASize: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Request payload size must be at most %d, not %d', [IORING_POOL_MAX_PAYLOAD_SIZE, ASize]);
  end;

  procedure RaiseAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The request pool is already open');
  end;

  procedure RaisePoolTooBig(const ACount: Cardinal; const AStride: NativeUInt); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Request pool of %d slots of %d bytes is too big', [ACount, AStride]);
  end;

var
  LIndex: Cardinal;
  LSize: UInt64;
begin
  if (ACapacity = 0) or (ACapacity > IORING_POOL_MAX_CAPACITY) then
    RaiseCapacityOutOfRange(ACapacity);

  if APayloadSize > IORING_POOL_MAX_PAYLOAD_SIZE then
    RaisePayloadTooBig(APayloadSize);

  if FMemory <> nil then
    RaiseAlreadyOpen;

  {
    Index bits: enough for ACapacity - 1, at least 4, so that the generation
    never needs more bits than the state word has. The generation gets the
    rest of the handle, at most what the state word holds.
  }
  FIndexBits := 4;

  while (UInt64(1) shl FIndexBits) < ACapacity do
    Inc(FIndexBits);

  FIndexMask := (NativeUInt(1) shl FIndexBits) - 1;
  FGenerationBits := SizeOf(NativeUInt) * 8 - FIndexBits;

  if FGenerationBits > STATE_WORD_GENERATION_BITS then
    FGenerationBits := STATE_WORD_GENERATION_BITS;

  FGenerationMask := Cardinal((UInt64(1) shl FGenerationBits) - 1);

  FStride := (SLOT_HEADER_SIZE + APayloadSize + IORING_CACHE_LINE_SIZE - 1) and
    not NativeUInt(IORING_CACHE_LINE_SIZE - 1);
  LSize := UInt64(ACapacity) * FStride;

  if LSize > UInt64(High(NativeInt) div 2) then
    RaisePoolTooBig(ACapacity, FStride);

  try
    FSlots := IORingAllocCacheAligned(NativeUInt(LSize), FMemory);
    FFreeList.Open(ACapacity);
  except
    Close;

    raise;
  end;

  FPayloads := FSlots + SLOT_HEADER_SIZE;
  FCapacity := ACapacity;
  FPayloadSize := APayloadSize;

  // Generation 1, state Free (generation 0 is never used: a handle is never 0)
  for LIndex := 0 to ACapacity - 1 do
    PCardinal(FSlots + NativeUInt(LIndex) * FStride)^ := (1 shl GENERATION_SHIFT) or Cardinal(Ord(rsFree));
end;

procedure TIORingRequestPool.Close;
begin
  FFreeList.Close;

  if FMemory <> nil then
    FreeMem(FMemory);

  FMemory := nil;
  FSlots := nil;
  FPayloads := nil;
  FStride := 0;
  FCapacity := 0;
  FPayloadSize := 0;
  FIndexBits := 0;
  FIndexMask := 0;
  FGenerationBits := 0;
  FGenerationMask := 0;
end;

{ TIORingRequestPool - handles }

function TIORingRequestPool.IndexOf(const AHandle: TIORingRequestHandle): Cardinal;
begin
  Result := Cardinal(AHandle.Value and FIndexMask);
end;

function TIORingRequestPool.GenerationOf(const AHandle: TIORingRequestHandle): Cardinal;
begin
  Result := Cardinal(AHandle.Value shr FIndexBits);
end;

function TIORingRequestPool.StateWordOf(const AHandle: TIORingRequestHandle): PCardinal;
var
  LIndex: Cardinal;
begin
  LIndex := IndexOf(AHandle);

  if LIndex < FCapacity then
    Result := PCardinal(FSlots + NativeUInt(LIndex) * FStride)
  else
    Result := nil;
end;

function TIORingRequestPool.Payload(const AHandle: TIORingRequestHandle): Pointer;
begin
  // Only fields here (no constants of the implementation part): FPC inlines it into other units then
  Result := FPayloads + NativeUInt(IndexOf(AHandle)) * FStride;
end;

{ TIORingRequestPool - requests }

function TIORingRequestPool.TryAcquire(out AHandle: TIORingRequestHandle): Boolean;
var
  LIndex: Cardinal;
  LWordPtr: PCardinal;
  LWord: Cardinal;
begin
  AHandle.Value := 0;

  if not FFreeList.TryPop(LIndex) then
    Exit(False);

  { A free slot belongs to nobody: a plain store is enough (old handles have another generation, so they cannot change
    the word) }
  LWordPtr := PCardinal(FSlots + NativeUInt(LIndex) * FStride);
  LWord := TAtomic.LoadAcquire(LWordPtr^);
  TAtomic.StoreRelease(LWordPtr^, (LWord and not STATE_MASK) or Cardinal(Ord(rsDefined)));
  AHandle.Value := (TIORingUserData(LWord shr GENERATION_SHIFT) shl FIndexBits) or LIndex;

  Result := True;
end;

function TIORingRequestPool.Release(const AHandle: TIORingRequestHandle): Boolean;
var
  LWordPtr: PCardinal;
  LGeneration: Cardinal;
  LNextGeneration: Cardinal;
  LWord: Cardinal;
  LSeen: Cardinal;
  LState: Cardinal;
begin
  Result := False;
  LWordPtr := StateWordOf(AHandle);

  if LWordPtr = nil then
    Exit;

  LGeneration := GenerationOf(AHandle);
  LNextGeneration := (LGeneration + 1) and FGenerationMask;

  if LNextGeneration = 0 then
    LNextGeneration := 1;

  LWord := TAtomic.LoadAcquire(LWordPtr^);

  repeat
    LState := LWord and STATE_MASK;

    if (LWord shr GENERATION_SHIFT <> LGeneration)
      or ((LState <> Cardinal(Ord(rsDefined))) and (LState <> Cardinal(Ord(rsCompleted)))) then

      Exit;

    LSeen := TAtomic.CompareExchange(LWordPtr^, (LNextGeneration shl GENERATION_SHIFT) or Cardinal(Ord(rsFree)), LWord);

    if LSeen = LWord then
      Break;

    LWord := LSeen;
  until False;

  // Threads still waiting on the old handle wake up and see it stale
  if LWord and WAITING_FLAG <> 0 then
    TAtomic.WakeAll(LWordPtr^);

  FFreeList.Push(IndexOf(AHandle));

  Result := True;
end;

function TIORingRequestPool.TryChangeState(const AHandle: TIORingRequestHandle;
  const AFrom, ATo: TIORingRequestState): Boolean;

  procedure RaiseBadState; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('TryChangeState: states must be Defined, Queued, Submitted or Completed');
  end;

var
  LWordPtr: PCardinal;
  LGeneration: Cardinal;
  LWord: Cardinal;
  LNew: Cardinal;
  LSeen: Cardinal;
begin
  if not (AFrom in [rsDefined..rsCompleted]) or not (ATo in [rsDefined..rsCompleted]) then
    RaiseBadState;

  Result := False;
  LWordPtr := StateWordOf(AHandle);

  if LWordPtr = nil then
    Exit;

  LGeneration := GenerationOf(AHandle);

  LWord := TAtomic.LoadAcquire(LWordPtr^);

  repeat
    if (LWord shr GENERATION_SHIFT <> LGeneration) or (LWord and STATE_MASK <> Cardinal(Ord(AFrom))) then
      Exit;

    // The waiting flag stays until Completed: the waiters sleep until then
    LNew := (LWord and not STATE_MASK) or Cardinal(Ord(ATo));

    if ATo = rsCompleted then
      LNew := LNew and not WAITING_FLAG;

    LSeen := TAtomic.CompareExchange(LWordPtr^, LNew, LWord);

    if LSeen = LWord then
      Break;

    LWord := LSeen;
  until False;

  if (ATo = rsCompleted) and (LWord and WAITING_FLAG <> 0) then
    TAtomic.WakeAll(LWordPtr^);

  Result := True;
end;

function TIORingRequestPool.State(const AHandle: TIORingRequestHandle): TIORingRequestState;
var
  LWordPtr: PCardinal;
  LWord: Cardinal;
begin
  LWordPtr := StateWordOf(AHandle);

  if LWordPtr = nil then
    Exit(rsStale);

  LWord := TAtomic.LoadAcquire(LWordPtr^);

  if LWord shr GENERATION_SHIFT <> GenerationOf(AHandle) then
    Result := rsStale
  else
    Result := TIORingRequestState(LWord and STATE_MASK);
end;

function TIORingRequestPool.WaitFor(const AHandle: TIORingRequestHandle; const ATimeoutMilliseconds: Cardinal)
  : TIORingWaitResult;
var
  LWordPtr: PCardinal;
  LGeneration: Cardinal;
  LWord: Cardinal;
  LSpinMicroseconds: Cardinal;
  LSpins: Cardinal;
  LStart: UInt64;
  LElapsed: UInt64;
  LRemaining: Cardinal;
begin
  LWordPtr := StateWordOf(AHandle);

  if LWordPtr = nil then
    Exit(wrStale);

  LGeneration := GenerationOf(AHandle);
  LWord := TAtomic.LoadAcquire(LWordPtr^);

  if LWord shr GENERATION_SHIFT <> LGeneration then
    Exit(wrStale);

  if LWord and STATE_MASK = Cardinal(Ord(rsCompleted)) then
    Exit(wrCompleted);

  if ATimeoutMilliseconds = 0 then
    Exit(wrTimeout);

  // A real wait: its time counts for the spinning and the timeout
  LStart := TIORingPlatform.TimestampMicroseconds;
  LSpinMicroseconds := FSpinMicroseconds;
  LSpins := 0;

  repeat
    LWord := TAtomic.LoadAcquire(LWordPtr^);

    if LWord shr GENERATION_SHIFT <> LGeneration then
      Exit(wrStale);

    if LWord and STATE_MASK = Cardinal(Ord(rsCompleted)) then
      Exit(wrCompleted);

    if LSpinMicroseconds > 0 then
    begin
      TAtomic.CpuPause;
      Inc(LSpins);

      if (LSpins and SPIN_CLOCK_CHECK_MASK = 0)
        and (TIORingPlatform.TimestampMicroseconds - LStart >= LSpinMicroseconds) then
        LSpinMicroseconds := 0;    // spun long enough: sleep

      Continue;
    end;

    // Announce the sleep first; if the word changed meanwhile, look again
    if LWord and WAITING_FLAG = 0 then
    begin
      if not TAtomic.TryCompareExchange(LWordPtr^, LWord or WAITING_FLAG, LWord) then
        Continue;

      LWord := LWord or WAITING_FLAG;
    end;

    if ATimeoutMilliseconds = IORING_INFINITE then
      LRemaining := IORING_INFINITE
    else
    begin
      LElapsed := (TIORingPlatform.TimestampMicroseconds - LStart) div 1000;

      if LElapsed >= ATimeoutMilliseconds then
        Exit(wrTimeout);

      LRemaining := ATimeoutMilliseconds - Cardinal(LElapsed);
    end;

    // Returns on a wake-up, a timeout, or at once if the word has changed; the loop checks again in every case
    TAtomic.WaitWhileEqual(LWordPtr^, LWord, LRemaining);
  until False;
end;

end.
