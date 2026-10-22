unit Delphi.IOUring.Atomics;

// Atomic operations, memory order, CPU pause, and wait/wake on an address:
// the building blocks of the engine's lock-free parts (Docs/Design.md §10.5).
//
// Delphi uses its compiler intrinsics (AtomicCmpExchange, ...), Free Pascal
// its RTL routines (InterlockedCompareExchange, ...). The differences between
// compilers and CPUs stay in this unit; the rest of the library uses TAtomic.
//
// Rules for callers:
// - A target must be aligned to its size: 4 bytes for 32-bit values, 8 bytes
//   for 64-bit values. Heap blocks and record/class fields are; a 64-bit local
//   variable on the Win32 stack may not be.
// - CompareExchange, Exchange, FetchAdd, Increment and Decrement are full
//   barriers: no read or write moves across them, in either direction.
// - LoadAcquire: the reads and writes after it stay after it.
//   StoreRelease: the reads and writes before it stay before it.
//   Together they hand data to another thread: write the data, then
//   StoreRelease a flag; the other thread LoadAcquires the flag, then reads
//   the data.
// - A StoreRelease followed by a LoadAcquire of ANOTHER variable can still
//   change order (on x86 too). "Set my flag, then check yours" needs Exchange
//   or FullBarrier.
// - WaitWhileEqual, WakeOne and WakeAll work on 32-bit values only (the Linux
//   futex has the same limit).
//
// On x86 and x64 the CPU keeps the acquire/release order by itself, so
// LoadAcquire and StoreRelease are plain moves; only where a compiler would
// split a 64-bit value into two 32-bit moves is the move a tiny assembler
// routine. Neither compiler moves or caches reads and writes of shared
// memory across them (the tests check this with optimization on, too).
// Other CPUs (AArch64, Milestone 4) need real barriers here, so they are
// refused until then.

{$I Delphi.IOUring.inc}

// Counters wrap around on purpose
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{$IFDEF FPC}
  {$ASMMODE INTEL}
{$ENDIF}

{$IF defined(CPUX86)}
  // 32-bit x86: 64-bit loads and stores are SSE moves (assembler)
  {$DEFINE IORING_ATOMICS_X86}
  {$DEFINE IORING_ATOMICS_ASM_STORE64}
  {$IFDEF FPC}
    // Free Pascal has no 64-bit compare-exchange on i386: CMPXCHG8B here
    {$DEFINE IORING_ATOMICS_FPC_X86}
  {$ENDIF}
{$ELSEIF defined(CPUX64)}
  {$IFDEF FPC}
    // Free Pascal x64 writes a 64-bit constant that does not fit in 32 bits
    // as two 32-bit stores, so an inlined StoreRelease(X, $FFFFFFFF00000000)
    // could be seen half-written. A small assembler routine gets the value in
    // a register and writes it with one instruction. (Delphi Win64 uses one
    // 64-bit store; checked.)
    {$DEFINE IORING_ATOMICS_ASM_STORE64}
  {$ENDIF}
{$ELSE}
  {$MESSAGE ERROR 'Delphi.IOUring.Atomics supports only x86 and x64 for now (other CPUs need acquire/release barriers: Milestone 4)'}
{$ENDIF}

{$IFNDEF MSWINDOWS}
  {$MESSAGE ERROR 'Delphi.IOUring.Atomics: wait/wake exists only for Windows for now (Linux futex: Milestone 4)'}
{$ENDIF}

interface

const
  // Cache line size of x86/x64 CPUs (and most ARM ones). Values that
  // different threads write often are kept at least this far apart, so they
  // do not share a cache line ("false sharing").
  IORING_CACHE_LINE_SIZE = 64;

  // Timeout for TAtomic.WaitWhileEqual: no time limit
  IORING_WAIT_INFINITE = Cardinal($FFFFFFFF);

type
  // Atomic operations; only class methods, nothing to create.
  //
  // CompareExchange, Exchange and FetchAdd return the OLD value, Increment
  // and Decrement the NEW value. NativeInt and NativeUInt variables use the
  // 32-bit or 64-bit versions automatically.
  TAtomic = record
  public
    // If ATarget = AComparand, sets ATarget := ANewValue. Returns the old
    // value (AComparand when the exchange happened).
    class function CompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Integer; overload; static; inline;
    class function CompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Cardinal; overload; static; inline;
    class function CompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Int64; overload; static; {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
    class function CompareExchange(var ATarget: UInt64; ANewValue, AComparand: UInt64): UInt64; overload; static; inline;
    class function CompareExchange(var ATarget: Pointer; ANewValue, AComparand: Pointer): Pointer; overload; static; inline;

    // Same as CompareExchange; True if the exchange happened
    class function TryCompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Boolean; overload; static; inline;
    class function TryCompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Boolean; overload; static; inline;
    class function TryCompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Boolean; overload; static; inline;
    class function TryCompareExchange(var ATarget: UInt64; ANewValue, AComparand: UInt64): Boolean; overload; static; inline;
    class function TryCompareExchange(var ATarget: Pointer; ANewValue, AComparand: Pointer): Boolean; overload; static; inline;

    // Sets ATarget := AValue; returns the old value
    class function Exchange(var ATarget: Integer; AValue: Integer): Integer; overload; static; inline;
    class function Exchange(var ATarget: Cardinal; AValue: Cardinal): Cardinal; overload; static; inline;
    class function Exchange(var ATarget: Int64; AValue: Int64): Int64; overload; static; {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
    class function Exchange(var ATarget: UInt64; AValue: UInt64): UInt64; overload; static; inline;
    class function Exchange(var ATarget: Pointer; AValue: Pointer): Pointer; overload; static; inline;

    // Adds ADelta to ATarget; returns the old value
    class function FetchAdd(var ATarget: Integer; ADelta: Integer): Integer; overload; static; inline;
    class function FetchAdd(var ATarget: Cardinal; ADelta: Cardinal): Cardinal; overload; static; inline;
    class function FetchAdd(var ATarget: Int64; ADelta: Int64): Int64; overload; static; {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
    class function FetchAdd(var ATarget: UInt64; ADelta: UInt64): UInt64; overload; static; inline;

    // Adds or subtracts one; returns the new value
    class function Increment(var ATarget: Integer): Integer; overload; static; inline;
    class function Increment(var ATarget: Cardinal): Cardinal; overload; static; inline;
    class function Increment(var ATarget: Int64): Int64; overload; static; inline;
    class function Increment(var ATarget: UInt64): UInt64; overload; static; inline;
    class function Decrement(var ATarget: Integer): Integer; overload; static; inline;
    class function Decrement(var ATarget: Cardinal): Cardinal; overload; static; inline;
    class function Decrement(var ATarget: Int64): Int64; overload; static; inline;
    class function Decrement(var ATarget: UInt64): UInt64; overload; static; inline;

    // Reads ATarget whole (a 64-bit value on Win32 too); later reads and
    // writes stay after it
    class function LoadAcquire(var ATarget: Integer): Integer; overload; static; inline;
    class function LoadAcquire(var ATarget: Cardinal): Cardinal; overload; static; inline;
    class function LoadAcquire(var ATarget: Int64): Int64; overload; static; {$IFNDEF IORING_ATOMICS_X86}inline;{$ENDIF}
    class function LoadAcquire(var ATarget: UInt64): UInt64; overload; static; inline;
    class function LoadAcquire(var ATarget: Pointer): Pointer; overload; static; inline;

    // Writes ATarget whole (a 64-bit value on Win32 too); earlier reads and
    // writes stay before it
    class procedure StoreRelease(var ATarget: Integer; AValue: Integer); overload; static; inline;
    class procedure StoreRelease(var ATarget: Cardinal; AValue: Cardinal); overload; static; inline;
    class procedure StoreRelease(var ATarget: Int64; AValue: Int64); overload; static; {$IFNDEF IORING_ATOMICS_ASM_STORE64}inline;{$ENDIF}
    class procedure StoreRelease(var ATarget: UInt64; AValue: UInt64); overload; static; inline;
    class procedure StoreRelease(var ATarget: Pointer; AValue: Pointer); overload; static; inline;

    // No read or write moves across this, in either direction
    class procedure FullBarrier; static; {$IFNDEF FPC}inline;{$ENDIF}

    // Tells the CPU that this thread is spinning (x86 PAUSE): saves power and
    // gives the other hyper-thread of the core more time. Use in every spin
    // loop.
    class procedure CpuPause; static; {$IFNDEF FPC}inline;{$ENDIF}

    // Sleeps while ATarget = AExpected, until a WakeOne/WakeAll on ATarget or
    // the timeout. Returns at once if ATarget <> AExpected already. True:
    // woken, or the value differed - possibly also without a reason (a
    // spurious wake-up), so always check the value again. False: timed out.
    class function WaitWhileEqual(var ATarget: Integer; AExpected: Integer;
      ATimeoutMilliseconds: Cardinal = IORING_WAIT_INFINITE): Boolean; overload; static;
    class function WaitWhileEqual(var ATarget: Cardinal; AExpected: Cardinal;
      ATimeoutMilliseconds: Cardinal = IORING_WAIT_INFINITE): Boolean; overload; static;

    // Wakes one / all threads sleeping in WaitWhileEqual on ATarget. Change
    // the value first, with an atomic operation (Exchange, CompareExchange,
    // FetchAdd ...), then wake.
    class procedure WakeOne(var ATarget); static;
    class procedure WakeAll(var ATarget); static;
  end;

implementation

{$IFDEF MSWINDOWS}
const
  SYNCHRONIZATION_DLL = 'api-ms-win-core-synch-l1-2-0.dll';

// Windows 8 and newer. Delphi's Winapi.Windows declares them too, Free
// Pascal 3.2.2's Windows unit does not.
function IORingWaitOnAddress(AAddress, ACompareAddress: Pointer; AAddressSize: NativeUInt;
  AMilliseconds: Cardinal): LongBool; stdcall; external SYNCHRONIZATION_DLL name 'WaitOnAddress';
procedure IORingWakeByAddressSingle(AAddress: Pointer); stdcall; external SYNCHRONIZATION_DLL name 'WakeByAddressSingle';
procedure IORingWakeByAddressAll(AAddress: Pointer); stdcall; external SYNCHRONIZATION_DLL name 'WakeByAddressAll';
{$ENDIF}

{ TAtomic }

// Only the Integer and Int64 versions have their own code; Cardinal, UInt64
// and Pointer use them through a typecast of the same size.

class function TAtomic.CompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterlockedCompareExchange(ATarget, ANewValue, AComparand);
{$ELSE}
  Result := AtomicCmpExchange(ATarget, ANewValue, AComparand);
{$ENDIF}
end;

class function TAtomic.CompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Cardinal;
begin
  Result := Cardinal(CompareExchange(Integer(ATarget), Integer(ANewValue), Integer(AComparand)));
end;

{$IFDEF IORING_ATOMICS_FPC_X86}
// LOCK CMPXCHG8B: compares EDX:EAX with the target; if equal, writes ECX:EBX.
// Either way EDX:EAX ends up holding the old value, which is the result.
class function TAtomic.CompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Int64;
asm
  push  ebx
  push  edi
  mov   edi, eax                         // ATarget (register convention: EAX)
  mov   eax, dword ptr [AComparand]
  mov   edx, dword ptr [AComparand + 4]
  mov   ebx, dword ptr [ANewValue]
  mov   ecx, dword ptr [ANewValue + 4]
  lock cmpxchg8b qword ptr [edi]
  pop   edi
  pop   ebx
end;
{$ELSE}
class function TAtomic.CompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Int64;
begin
{$IFDEF FPC}
  Result := InterlockedCompareExchange64(ATarget, ANewValue, AComparand);
{$ELSE}
  Result := AtomicCmpExchange(ATarget, ANewValue, AComparand);
{$ENDIF}
end;
{$ENDIF}

class function TAtomic.CompareExchange(var ATarget: UInt64; ANewValue, AComparand: UInt64): UInt64;
begin
  Result := UInt64(CompareExchange(Int64(ATarget), Int64(ANewValue), Int64(AComparand)));
end;

class function TAtomic.CompareExchange(var ATarget: Pointer; ANewValue, AComparand: Pointer): Pointer;
begin
  Result := Pointer(CompareExchange(NativeInt(ATarget), NativeInt(ANewValue), NativeInt(AComparand)));
end;

class function TAtomic.TryCompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Boolean;
begin
  Result := CompareExchange(ATarget, ANewValue, AComparand) = AComparand;
end;

class function TAtomic.TryCompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Boolean;
begin
  Result := CompareExchange(ATarget, ANewValue, AComparand) = AComparand;
end;

class function TAtomic.TryCompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Boolean;
begin
  Result := CompareExchange(ATarget, ANewValue, AComparand) = AComparand;
end;

class function TAtomic.TryCompareExchange(var ATarget: UInt64; ANewValue, AComparand: UInt64): Boolean;
begin
  Result := CompareExchange(ATarget, ANewValue, AComparand) = AComparand;
end;

class function TAtomic.TryCompareExchange(var ATarget: Pointer; ANewValue, AComparand: Pointer): Boolean;
begin
  Result := CompareExchange(ATarget, ANewValue, AComparand) = AComparand;
end;

class function TAtomic.Exchange(var ATarget: Integer; AValue: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterlockedExchange(ATarget, AValue);
{$ELSE}
  Result := AtomicExchange(ATarget, AValue);
{$ENDIF}
end;

class function TAtomic.Exchange(var ATarget: Cardinal; AValue: Cardinal): Cardinal;
begin
  Result := Cardinal(Exchange(Integer(ATarget), Integer(AValue)));
end;

class function TAtomic.Exchange(var ATarget: Int64; AValue: Int64): Int64;
{$IFDEF IORING_ATOMICS_FPC_X86}
var
  LSeen: Int64;
begin
  // No 64-bit exchange instruction on x86: repeat the compare-exchange until
  // no other thread changed the value in between. A torn first read only
  // costs one more round.
  Result := ATarget;
  repeat
    LSeen := CompareExchange(ATarget, AValue, Result);
    if LSeen = Result then
      Exit;
    Result := LSeen;
  until False;
end;
{$ELSE}
begin
{$IFDEF FPC}
  Result := InterlockedExchange64(ATarget, AValue);
{$ELSE}
  Result := AtomicExchange(ATarget, AValue);
{$ENDIF}
end;
{$ENDIF}

class function TAtomic.Exchange(var ATarget: UInt64; AValue: UInt64): UInt64;
begin
  Result := UInt64(Exchange(Int64(ATarget), Int64(AValue)));
end;

class function TAtomic.Exchange(var ATarget: Pointer; AValue: Pointer): Pointer;
begin
  Result := Pointer(Exchange(NativeInt(ATarget), NativeInt(AValue)));
end;

class function TAtomic.FetchAdd(var ATarget: Integer; ADelta: Integer): Integer;
begin
{$IFDEF FPC}
  Result := InterlockedExchangeAdd(ATarget, ADelta);
{$ELSE}
  Result := AtomicIncrement(ATarget, ADelta) - ADelta;
{$ENDIF}
end;

class function TAtomic.FetchAdd(var ATarget: Cardinal; ADelta: Cardinal): Cardinal;
begin
  Result := Cardinal(FetchAdd(Integer(ATarget), Integer(ADelta)));
end;

class function TAtomic.FetchAdd(var ATarget: Int64; ADelta: Int64): Int64;
{$IFDEF IORING_ATOMICS_FPC_X86}
var
  LSeen: Int64;
begin
  // Compare-exchange loop, as in Exchange
  Result := ATarget;
  repeat
    LSeen := CompareExchange(ATarget, Result + ADelta, Result);
    if LSeen = Result then
      Exit;
    Result := LSeen;
  until False;
end;
{$ELSE}
begin
{$IFDEF FPC}
  Result := InterlockedExchangeAdd64(ATarget, ADelta);
{$ELSE}
  Result := AtomicIncrement(ATarget, ADelta) - ADelta;
{$ENDIF}
end;
{$ENDIF}

class function TAtomic.FetchAdd(var ATarget: UInt64; ADelta: UInt64): UInt64;
begin
  Result := UInt64(FetchAdd(Int64(ATarget), Int64(ADelta)));
end;

class function TAtomic.Increment(var ATarget: Integer): Integer;
begin
  Result := FetchAdd(ATarget, 1) + 1;
end;

class function TAtomic.Increment(var ATarget: Cardinal): Cardinal;
begin
  Result := Cardinal(Increment(Integer(ATarget)));
end;

class function TAtomic.Increment(var ATarget: Int64): Int64;
begin
  Result := FetchAdd(ATarget, 1) + 1;
end;

class function TAtomic.Increment(var ATarget: UInt64): UInt64;
begin
  Result := UInt64(Increment(Int64(ATarget)));
end;

class function TAtomic.Decrement(var ATarget: Integer): Integer;
begin
  Result := FetchAdd(ATarget, -1) - 1;
end;

class function TAtomic.Decrement(var ATarget: Cardinal): Cardinal;
begin
  Result := Cardinal(Decrement(Integer(ATarget)));
end;

class function TAtomic.Decrement(var ATarget: Int64): Int64;
begin
  Result := FetchAdd(ATarget, -1) - 1;
end;

class function TAtomic.Decrement(var ATarget: UInt64): UInt64;
begin
  Result := UInt64(Decrement(Int64(ATarget)));
end;

class function TAtomic.LoadAcquire(var ATarget: Integer): Integer;
begin
  Result := ATarget;
end;

class function TAtomic.LoadAcquire(var ATarget: Cardinal): Cardinal;
begin
  Result := ATarget;
end;

{$IFDEF IORING_ATOMICS_X86}
// Two 32-bit moves could see half of another thread's write. An aligned
// 64-bit SSE move is one access (Intel SDM vol. 3, 9.1.1).
class function TAtomic.LoadAcquire(var ATarget: Int64): Int64;
asm
  movlps  xmm0, qword ptr [eax]          // ATarget (register convention: EAX)
  movd    eax, xmm0                      // result in EDX:EAX
  psrlq   xmm0, 32
  movd    edx, xmm0
end;
{$ELSE}
class function TAtomic.LoadAcquire(var ATarget: Int64): Int64;
begin
  Result := ATarget;
end;
{$ENDIF}

class function TAtomic.LoadAcquire(var ATarget: UInt64): UInt64;
begin
  Result := UInt64(LoadAcquire(Int64(ATarget)));
end;

class function TAtomic.LoadAcquire(var ATarget: Pointer): Pointer;
begin
  Result := Pointer(LoadAcquire(NativeInt(ATarget)));
end;

class procedure TAtomic.StoreRelease(var ATarget: Integer; AValue: Integer);
begin
  ATarget := AValue;
end;

class procedure TAtomic.StoreRelease(var ATarget: Cardinal; AValue: Cardinal);
begin
  ATarget := AValue;
end;

{$IF defined(IORING_ATOMICS_X86)}
// One 64-bit SSE move, as in LoadAcquire
class procedure TAtomic.StoreRelease(var ATarget: Int64; AValue: Int64);
asm
  movlps  xmm0, qword ptr [AValue]
  movlps  qword ptr [eax], xmm0          // ATarget (register convention: EAX)
end;
{$ELSEIF defined(IORING_ATOMICS_ASM_STORE64)}
// Free Pascal x64: one 64-bit move from a register (see the top of the unit)
class procedure TAtomic.StoreRelease(var ATarget: Int64; AValue: Int64);
asm
  mov     qword ptr [ATarget], AValue
end;
{$ELSE}
class procedure TAtomic.StoreRelease(var ATarget: Int64; AValue: Int64);
begin
  ATarget := AValue;
end;
{$ENDIF}

class procedure TAtomic.StoreRelease(var ATarget: UInt64; AValue: UInt64);
begin
  StoreRelease(Int64(ATarget), Int64(AValue));
end;

class procedure TAtomic.StoreRelease(var ATarget: Pointer; AValue: Pointer);
begin
  StoreRelease(NativeInt(ATarget), NativeInt(AValue));
end;

{$IFDEF FPC}
// Any LOCK-prefixed instruction is a full barrier on x86/x64 (and often
// cheaper than MFENCE). FPC's ReadWriteBarrier does the same job, but on x64
// it gives a "not inlined" note wherever it is used.
class procedure TAtomic.FullBarrier;
asm
{$IFDEF IORING_ATOMICS_X86}
  lock or dword ptr [esp], 0
{$ELSE}
  lock or dword ptr [rsp], 0
{$ENDIF}
end;
{$ELSE}
class procedure TAtomic.FullBarrier;
begin
  MemoryBarrier;
end;
{$ENDIF}

{$IFDEF FPC}
class procedure TAtomic.CpuPause;
asm
  pause
end;
{$ELSE}
class procedure TAtomic.CpuPause;
begin
  YieldProcessor;
end;
{$ENDIF}

class function TAtomic.WaitWhileEqual(var ATarget: Integer; AExpected: Integer;
  ATimeoutMilliseconds: Cardinal): Boolean;
begin
  // FALSE means timeout (ERROR_TIMEOUT); the value is checked by the caller
  Result := IORingWaitOnAddress(@ATarget, @AExpected, SizeOf(ATarget), ATimeoutMilliseconds);
end;

class function TAtomic.WaitWhileEqual(var ATarget: Cardinal; AExpected: Cardinal;
  ATimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := IORingWaitOnAddress(@ATarget, @AExpected, SizeOf(ATarget), ATimeoutMilliseconds);
end;

class procedure TAtomic.WakeOne(var ATarget);
begin
  IORingWakeByAddressSingle(@ATarget);
end;

class procedure TAtomic.WakeAll(var ATarget);
begin
  IORingWakeByAddressAll(@ATarget);
end;

end.
