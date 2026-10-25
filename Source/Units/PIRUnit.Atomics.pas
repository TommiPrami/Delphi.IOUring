unit PIRUnit.Atomics;

{
  Atomic operations, memory order, CPU pause, and wait/wake on an address: the building blocks of the engine's lock-free
  parts (Docs/Design.md §10.5).

  Delphi uses its compiler intrinsics (AtomicCmpExchange, ...), Free Pascal its RTL routines
  (InterlockedCompareExchange, ...). The differences between compilers and CPUs stay in this unit; the rest of
  the library uses TAtomic.

  Rules for callers:
  - A target must be aligned to its size: 4 bytes for 32-bit values, 8 bytes
    for 64-bit values. Heap blocks and record/class fields are; a 64-bit local
    variable on the Win32 stack may not be.
  - CompareExchange, Exchange, FetchAdd, Increment and Decrement are full
    barriers: no read or write moves across them, in either direction.
  - LoadAcquire: the reads and writes after it stay after it.
    StoreRelease: the reads and writes before it stay before it.
    Together they hand data to another thread: write the data, then
    StoreRelease a flag; the other thread LoadAcquires the flag, then reads
    the data.
  - A StoreRelease followed by a LoadAcquire of ANOTHER variable can still
    change order (on x86 too). "Set my flag, then check yours" needs Exchange
    or FullBarrier.
  - WaitWhileEqual, WakeOne and WakeAll work on 32-bit values only (the Linux
    futex has the same limit).

  On x86 and x64 the CPU keeps the acquire/release order by itself, so LoadAcquire and StoreRelease are plain moves;
  only where a compiler would split a 64-bit value into two 32-bit moves is the move a tiny assembler routine. Neither
  compiler moves or caches reads and writes of shared memory across them (the tests check this with optimization on,
  too). AArch64 (Linux, Free Pascal) does not keep that order by itself: there the operations are small assembler
  routines - LDXR/STLXR loops with a full barrier (DMB) after them, LDAR and STLR for LoadAcquire and StoreRelease
  (Docs/Design.md §12.9). Tested on ARM64 in CI, with the stress tests, debug and -O3 (Docs/Design.md §5.7, §12.5).

  Sleeping and waking: WaitOnAddress on Windows, the futex on Linux.
}

{$I PIRInclude.Compiler.inc}

// Counters wrap around on purpose
{$OVERFLOWCHECKS OFF}
{$RANGECHECKS OFF}

{$IF defined(FPC) and (defined(CPUX86) or defined(CPUX64))}
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
    {
      Free Pascal x64 writes a 64-bit constant that does not fit in 32 bits as two 32-bit stores, so an inlined
      StoreRelease(X, $FFFFFFFF00000000) could be seen half-written. A small assembler routine gets the value in a
      register and writes it with one instruction. (Delphi Win64 uses one 64-bit store; checked.)
    }
    {$DEFINE IORING_ATOMICS_ASM_STORE64}
  {$ENDIF}
{$ELSEIF defined(CPUAARCH64) and defined(FPC)}
  // The CPU may reorder reads and writes: barriers around the operations
  {$DEFINE IORING_ATOMICS_AARCH64}
  {
    Small assembler routines (Docs/Design.md §12.9). IORING_ATOMICS_AARCH64_RTL keeps the way before Phase 27 – FPC's
    Interlocked routines with a full barrier on each side – for comparing them in the benchmark.
    IORING_ATOMICS_AARCH64_YIELD: CpuPause is a YIELD instead of an ISB (measured slower under contention).
  }
  {$IFNDEF IORING_ATOMICS_AARCH64_RTL}
    {$DEFINE IORING_ATOMICS_AARCH64_ASM}
  {$ENDIF}
{$ELSE}
  {$MESSAGE ERROR 'PIRUnit.Atomics supports x86, x64 and (Free Pascal) AArch64'}
{$ENDIF}

{$IF not (defined(MSWINDOWS) or defined(LINUX))}
  {$MESSAGE ERROR 'PIRUnit.Atomics: wait/wake exists for Windows and Linux only'}
{$ENDIF}

interface

uses
  // IORING_INFINITE: the timeout of WaitWhileEqual that means no time limit
  PIRUnit.Types;

const
  { Cache line size of x86/x64 CPUs (and most ARM ones). Values that different threads write often are kept at least
    this far apart, so they do not share a cache line ("false sharing"). }
  IORING_CACHE_LINE_SIZE = 64;

  { The longest wait of TAtomic.BackOff, in CPU pauses: ~35 µs on a recent Intel performance core
    (Docs/Benchmarks.md, "Engine structures") }
  IORING_BACKOFF_MAX_PAUSES = 1024;

type
  {
    Atomic operations; only class methods, nothing to create.

    CompareExchange, Exchange and FetchAdd return the OLD value, Increment and Decrement the NEW value. NativeInt and
    NativeUInt variables use the 32-bit or 64-bit versions automatically.
  }
  TAtomic = record
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  private
    { AArch64 assembler (Docs/Design.md §12.9): the inline methods below call these, so each operation is one call.
      Read-modify-write: an LDXR/STLXR loop and a full barrier (DMB ISH) after it, so they stay full barriers. }
    class function A64CompareExchange32(var ATarget: Integer; ANewValue, AComparand: Integer): Integer; static;
    class function A64CompareExchange64(var ATarget: Int64; ANewValue, AComparand: Int64): Int64; static;
    class function A64Exchange32(var ATarget: Integer; AValue: Integer): Integer; static;
    class function A64Exchange64(var ATarget: Int64; AValue: Int64): Int64; static;
    class function A64FetchAdd32(var ATarget: Integer; ADelta: Integer): Integer; static;
    class function A64FetchAdd64(var ATarget: Int64; ADelta: Int64): Int64; static;
    // LDAR and STLR: one instruction each
    class function A64LoadAcquire32(var ATarget: Integer): Integer; static;
    class function A64LoadAcquire64(var ATarget: Int64): Int64; static;
    class procedure A64StoreRelease32(var ATarget: Integer; AValue: Integer); static;
    class procedure A64StoreRelease64(var ATarget: Int64; AValue: Int64); static;
{$ENDIF}
  public
    {
      If ATarget = AComparand, sets ATarget := ANewValue. Returns the old
      value (AComparand when the exchange happened).
    }
    class function CompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Integer; overload; static; inline;
    class function CompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Cardinal; overload; static; inline;
    class function CompareExchange(var ATarget: Int64; ANewValue, AComparand: Int64): Int64; overload; static;
      {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
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
    class function Exchange(var ATarget: Int64; AValue: Int64): Int64; overload; static;
      {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
    class function Exchange(var ATarget: UInt64; AValue: UInt64): UInt64; overload; static; inline;
    class function Exchange(var ATarget: Pointer; AValue: Pointer): Pointer; overload; static; inline;

    // Adds ADelta to ATarget; returns the old value
    class function FetchAdd(var ATarget: Integer; ADelta: Integer): Integer; overload; static; inline;
    class function FetchAdd(var ATarget: Cardinal; ADelta: Cardinal): Cardinal; overload; static; inline;
    class function FetchAdd(var ATarget: Int64; ADelta: Int64): Int64; overload; static;
      {$IFNDEF IORING_ATOMICS_FPC_X86}inline;{$ENDIF}
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

    // Reads ATarget whole (a 64-bit value on Win32 too); later reads and writes stay after it
    class function LoadAcquire(var ATarget: Integer): Integer; overload; static; inline;
    class function LoadAcquire(var ATarget: Cardinal): Cardinal; overload; static; inline;
    class function LoadAcquire(var ATarget: Int64): Int64; overload; static;
      {$IFNDEF IORING_ATOMICS_X86}inline;{$ENDIF}
    class function LoadAcquire(var ATarget: UInt64): UInt64; overload; static; inline;
    class function LoadAcquire(var ATarget: Pointer): Pointer; overload; static; inline;

    // Writes ATarget whole (a 64-bit value on Win32 too); earlier reads and writes stay before it
    class procedure StoreRelease(var ATarget: Integer; AValue: Integer); overload; static; inline;
    class procedure StoreRelease(var ATarget: Cardinal; AValue: Cardinal); overload; static; inline;
    class procedure StoreRelease(var ATarget: Int64; AValue: Int64); overload; static;
      {$IFNDEF IORING_ATOMICS_ASM_STORE64}inline;{$ENDIF}
    class procedure StoreRelease(var ATarget: UInt64; AValue: UInt64); overload; static; inline;
    class procedure StoreRelease(var ATarget: Pointer; AValue: Pointer); overload; static; inline;

    // No read or write moves across this, in either direction
    class procedure FullBarrier; static; {$IFNDEF FPC}inline;{$ENDIF}

    { Tells the CPU that this thread is spinning (x86 PAUSE): saves power and gives the other hyper-thread of the core
      more time. Use in every spin loop. }
    class procedure CpuPause; static; {$IFNDEF FPC}inline;{$ENDIF}

    {
      After a failed compare-exchange (or another lost race): waits APauses CPU pauses, then doubles APauses, up to
      AMaxPauses. Start every operation with APauses = 1. Without it, threads that fail together try again together and
      fail again - a lock-free structure then loses badly to a lock (Docs/Benchmarks.md, "Engine structures").
    }
    class procedure BackOff(var APauses: Integer; const AMaxPauses: Integer = IORING_BACKOFF_MAX_PAUSES); static;

    {
      Sleeps while ATarget = AExpected, until a WakeOne/WakeAll on ATarget or the timeout. Returns at once if ATarget <>
      AExpected already. True: woken, or the value differed - possibly also without a reason (a spurious wake-up), so
      always check the value again. False: timed out.
    }
    class function WaitWhileEqual(var ATarget: Integer; AExpected: Integer;
      ATimeoutMilliseconds: Cardinal = IORING_INFINITE): Boolean; overload; static;
    class function WaitWhileEqual(var ATarget: Cardinal; AExpected: Cardinal;
      ATimeoutMilliseconds: Cardinal = IORING_INFINITE): Boolean; overload; static;

    { Wakes one / all threads sleeping in WaitWhileEqual on ATarget. Change the value first, with an atomic operation
      (Exchange, CompareExchange, FetchAdd ...), then wake. }
    class procedure WakeOne(var ATarget); static;
    class procedure WakeAll(var ATarget); static;
  end;

  { ASize bytes, zeroed, starting at a cache-line boundary - for data that threads share (lock-free structures). Free
    with FreeMem(AMemory): AMemory is the block as allocated. }
  function IORingAllocCacheAligned(const ASize: NativeUInt; var AMemory: Pointer): Pointer;

implementation

{$IFDEF LINUX}
uses
  BaseUnix,   // fpgeterrno, TTimeSpec
  Linux;      // Futex
{$ENDIF}

{$IFDEF MSWINDOWS}
const
  SYNCHRONIZATION_DLL = 'api-ms-win-core-synch-l1-2-0.dll';

  // Windows 8 and newer. Delphi's Winapi.Windows declares them too, Free Pascal 3.2.2's Windows unit does not.
  function IORingWaitOnAddress(AAddress, ACompareAddress: Pointer; AAddressSize: NativeUInt;
    AMilliseconds: Cardinal): LongBool; stdcall; external SYNCHRONIZATION_DLL name 'WaitOnAddress';
  procedure IORingWakeByAddressSingle(AAddress: Pointer); stdcall; external SYNCHRONIZATION_DLL name 'WakeByAddressSingle';
  procedure IORingWakeByAddressAll(AAddress: Pointer); stdcall; external SYNCHRONIZATION_DLL name 'WakeByAddressAll';
{$ENDIF}

{ TAtomic }

{ Only the Integer and Int64 versions have their own code; Cardinal, UInt64 and Pointer use them through a
  typecast of the same size. }

{$IFDEF IORING_ATOMICS_AARCH64_ASM}
{
  AArch64 (Docs/Design.md §12.9). Arguments in x0 (ATarget's address), x1/w1 and x2/w2; the result in x0/w0.
  The read-modify-write routines are the fully ordered pattern of the Linux kernel: LDXR, then STLXR (a release store),
  then DMB ISH (written "dmb #11", as in FPC's RTL). The compare-exchange always stores (the old value back when it does
  not match, as FPC's own InterlockedCompareExchange does), so it orders like the others also when it fails.
}

class function TAtomic.A64CompareExchange32(var ATarget: Integer; ANewValue, AComparand: Integer): Integer;
  assembler; nostackframe;
asm
.LCompareExchange32Loop:
  ldxr   w3, [x0]
  cmp    w3, w2
  csel   w4, w1, w3, eq
  stlxr  w5, w4, [x0]
  cbnz   w5, .LCompareExchange32Loop
  dmb    #11
  mov    w0, w3
end;

class function TAtomic.A64CompareExchange64(var ATarget: Int64; ANewValue, AComparand: Int64): Int64;
  assembler; nostackframe;
asm
.LCompareExchange64Loop:
  ldxr   x3, [x0]
  cmp    x3, x2
  csel   x4, x1, x3, eq
  stlxr  w5, x4, [x0]
  cbnz   w5, .LCompareExchange64Loop
  dmb    #11
  mov    x0, x3
end;

class function TAtomic.A64Exchange32(var ATarget: Integer; AValue: Integer): Integer; assembler; nostackframe;
asm
.LExchange32Loop:
  ldxr   w2, [x0]
  stlxr  w3, w1, [x0]
  cbnz   w3, .LExchange32Loop
  dmb    #11
  mov    w0, w2
end;

class function TAtomic.A64Exchange64(var ATarget: Int64; AValue: Int64): Int64; assembler; nostackframe;
asm
.LExchange64Loop:
  ldxr   x2, [x0]
  stlxr  w3, x1, [x0]
  cbnz   w3, .LExchange64Loop
  dmb    #11
  mov    x0, x2
end;

class function TAtomic.A64FetchAdd32(var ATarget: Integer; ADelta: Integer): Integer; assembler; nostackframe;
asm
.LFetchAdd32Loop:
  ldxr   w2, [x0]
  add    w3, w2, w1
  stlxr  w4, w3, [x0]
  cbnz   w4, .LFetchAdd32Loop
  dmb    #11
  mov    w0, w2
end;

class function TAtomic.A64FetchAdd64(var ATarget: Int64; ADelta: Int64): Int64; assembler; nostackframe;
asm
.LFetchAdd64Loop:
  ldxr   x2, [x0]
  add    x3, x2, x1
  stlxr  w4, x3, [x0]
  cbnz   w4, .LFetchAdd64Loop
  dmb    #11
  mov    x0, x2
end;

class function TAtomic.A64LoadAcquire32(var ATarget: Integer): Integer; assembler; nostackframe;
asm
  ldar   w0, [x0]
end;

class function TAtomic.A64LoadAcquire64(var ATarget: Int64): Int64; assembler; nostackframe;
asm
  ldar   x0, [x0]
end;

class procedure TAtomic.A64StoreRelease32(var ATarget: Integer; AValue: Integer); assembler; nostackframe;
asm
  stlr   w1, [x0]
end;

class procedure TAtomic.A64StoreRelease64(var ATarget: Int64; AValue: Int64); assembler; nostackframe;
asm
  stlr   x1, [x0]
end;
{$ENDIF}

class function TAtomic.CompareExchange(var ATarget: Integer; ANewValue, AComparand: Integer): Integer;
begin
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64CompareExchange32(ATarget, ANewValue, AComparand);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedCompareExchange(ATarget, ANewValue, AComparand);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
{$ELSE}
  Result := AtomicCmpExchange(ATarget, ANewValue, AComparand);
{$ENDIF}
end;

class function TAtomic.CompareExchange(var ATarget: Cardinal; ANewValue, AComparand: Cardinal): Cardinal;
begin
  Result := Cardinal(CompareExchange(Integer(ATarget), Integer(ANewValue), Integer(AComparand)));
end;

{$IFDEF IORING_ATOMICS_FPC_X86}
{ LOCK CMPXCHG8B: compares EDX:EAX with the target; if equal, writes ECX:EBX. Either way EDX:EAX ends up holding the old
  value, which is the result. }
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
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64CompareExchange64(ATarget, ANewValue, AComparand);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedCompareExchange64(ATarget, ANewValue, AComparand);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
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
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64Exchange32(ATarget, AValue);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedExchange(ATarget, AValue);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
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
  { No 64-bit exchange instruction on x86: repeat the compare-exchange until no other thread changed the value in
    between. A torn first read only costs one more round. }
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
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64Exchange64(ATarget, AValue);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedExchange64(ATarget, AValue);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
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
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64FetchAdd32(ATarget, ADelta);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedExchangeAdd(ATarget, ADelta);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
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
{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
  Result := A64FetchAdd64(ATarget, ADelta);
{$ELSEIF defined(FPC)}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
  Result := InterlockedExchangeAdd64(ATarget, ADelta);
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
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

// AArch64: a barrier after the read keeps the later reads and writes after it (on x86/x64 the CPU does that by itself)
class function TAtomic.LoadAcquire(var ATarget: Integer): Integer;
begin
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  Result := A64LoadAcquire32(ATarget);
{$ELSE}
  Result := ATarget;
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
{$ENDIF}
end;

class function TAtomic.LoadAcquire(var ATarget: Cardinal): Cardinal;
begin
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  Result := Cardinal(A64LoadAcquire32(Integer(ATarget)));
{$ELSE}
  Result := ATarget;
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
{$ENDIF}
end;

{$IFDEF IORING_ATOMICS_X86}
{ Two 32-bit moves could see half of another thread's write. An aligned 64-bit SSE move is one access
  (Intel SDM vol. 3, 9.1.1). }
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
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  Result := A64LoadAcquire64(ATarget);
{$ELSE}
  Result := ATarget;
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}
{$ENDIF}
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

// AArch64: a barrier before the write keeps the earlier reads and writes before it
class procedure TAtomic.StoreRelease(var ATarget: Integer; AValue: Integer);
begin
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  A64StoreRelease32(ATarget, AValue);
{$ELSE}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}

  ATarget := AValue;
{$ENDIF}
end;

class procedure TAtomic.StoreRelease(var ATarget: Cardinal; AValue: Cardinal);
begin
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  A64StoreRelease32(Integer(ATarget), Integer(AValue));
{$ELSE}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}

  ATarget := AValue;
{$ENDIF}
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
{$IFDEF IORING_ATOMICS_AARCH64_ASM}
  A64StoreRelease64(ATarget, AValue);
{$ELSE}
  {$IFDEF IORING_ATOMICS_AARCH64}ReadWriteBarrier;{$ENDIF}

  ATarget := AValue;
{$ENDIF}
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

{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
class procedure TAtomic.FullBarrier; assembler; nostackframe;
asm
  dmb    #11                             // DMB ISH
end;
{$ELSEIF defined(IORING_ATOMICS_AARCH64)}
class procedure TAtomic.FullBarrier;
begin
  ReadWriteBarrier;   // DMB ISH
end;
{$ELSEIF defined(FPC)}
{ Any LOCK-prefixed instruction is a full barrier on x86/x64 (and often cheaper than MFENCE). FPC's ReadWriteBarrier
  does the same job, but on x64 it gives a "not inlined" note wherever it is used. }
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

{$IF defined(IORING_ATOMICS_AARCH64_ASM)}
{ ISB: a short real wait. YIELD is the architecture's hint for a spinning thread, but on GitHub's ARM64 runner it did
  almost nothing: with 2-3 producers the queue was 3-4 times faster with ISB (Docs/Design.md §12.9). }
class procedure TAtomic.CpuPause; assembler; nostackframe;
asm
{$IFDEF IORING_ATOMICS_AARCH64_YIELD}
  yield
{$ELSE}
  isb
{$ENDIF}
end;
{$ELSEIF defined(IORING_ATOMICS_AARCH64)}
// The way before Phase 27: no hint at all
class procedure TAtomic.CpuPause;
begin
end;
{$ELSEIF defined(FPC)}
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

class procedure TAtomic.BackOff(var APauses: Integer; const AMaxPauses: Integer);
var
  LPause: Integer;
begin
  for LPause := 1 to APauses do
    CpuPause;

  if APauses < AMaxPauses then
  begin
    APauses := APauses * 2;

    if APauses > AMaxPauses then
      APauses := AMaxPauses;
  end;
end;

{$IFDEF MSWINDOWS}
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
{$ENDIF}

{$IFDEF LINUX}
const
  // linux/futex.h: the futex is used by this process only
  FUTEX_PRIVATE_FLAG = 128;
  FUTEX_WAIT_PRIVATE = FUTEX_WAIT or FUTEX_PRIVATE_FLAG;
  FUTEX_WAKE_PRIVATE = FUTEX_WAKE or FUTEX_PRIVATE_FLAG;

{ FPC's Futex returns -1 and sets errno: ETIMEDOUT = timed out; EAGAIN = the value differed already; EINTR = a
  signal (a spurious wake-up) }
function FutexWait(const AAddress: Pointer; const AExpected: Integer; const ATimeoutMilliseconds: Cardinal): Boolean;
var
  LTimeout: TTimeSpec;
  LTimeoutPointer: PTimeSpec;
begin
  if ATimeoutMilliseconds = IORING_INFINITE then
    LTimeoutPointer := nil
  else
  begin
    LTimeout.tv_sec := ATimeoutMilliseconds div 1000;
    LTimeout.tv_nsec := (ATimeoutMilliseconds mod 1000) * 1000000;
    LTimeoutPointer := @LTimeout;
  end;

  Result := (Futex(AAddress, FUTEX_WAIT_PRIVATE, AExpected, LTimeoutPointer) = 0) or (fpgeterrno <> ESysETIMEDOUT);
end;

class function TAtomic.WaitWhileEqual(var ATarget: Integer; AExpected: Integer; ATimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := FutexWait(@ATarget, AExpected, ATimeoutMilliseconds);
end;

class function TAtomic.WaitWhileEqual(var ATarget: Cardinal; AExpected: Cardinal; ATimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := FutexWait(@ATarget, Integer(AExpected), ATimeoutMilliseconds);
end;

class procedure TAtomic.WakeOne(var ATarget);
begin
  Futex(@ATarget, FUTEX_WAKE_PRIVATE, 1, nil);
end;

class procedure TAtomic.WakeAll(var ATarget);
begin
  Futex(@ATarget, FUTEX_WAKE_PRIVATE, MaxInt, nil);
end;
{$ENDIF}

function IORingAllocCacheAligned(const ASize: NativeUInt; var AMemory: Pointer): Pointer;
var
  LAddress: NativeUInt;
begin
  GetMem(AMemory, ASize + (IORING_CACHE_LINE_SIZE - 1));
  LAddress := NativeUInt(AMemory) + NativeUInt(IORING_CACHE_LINE_SIZE - 1);
  LAddress := LAddress and not NativeUInt(IORING_CACHE_LINE_SIZE - 1);

  Result := Pointer(LAddress);

  FillChar(Result^, ASize, 0);
end;

end.
