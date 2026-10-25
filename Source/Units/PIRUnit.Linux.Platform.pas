unit PIRUnit.Linux.Platform;

{
  The Linux platform services: TLinuxIORingPlatform – files, memory, the clock and a wake event – for the higher
  layers, with the same names as on Windows (Docs/Design.md §5.7). User code normally uses it through the
  TIORingPlatform alias in PIRUnit.IORing. Free Pascal, Linux, x86-64 and AArch64.
}

{$I PIRInclude.Compiler.inc}

{$IFNDEF LINUX}
  {$MESSAGE FATAL 'PIRUnit.Linux.Platform is for Linux.'}
{$ENDIF}
{$IF not (defined(CPUX86_64) or defined(CPUAARCH64))}
  {$MESSAGE FATAL 'PIRUnit.Linux.Platform is for x86-64 and AArch64.'}
{$ENDIF}

interface

type
  { File, memory and clock services the higher layers need; the same names as TWindowsIORingPlatform. PIRUnit.IORing
    exports it as TIORingPlatform. Failures raise EIORingError (NativeCode = -errno). }
  TLinuxIORingPlatform = record
  public
    // Read-only. AUnbuffered = O_DIRECT, ASequentialHint = posix_fadvise(POSIX_FADV_SEQUENTIAL).
    class function OpenFileForRead(const AFileName: string; const AUnbuffered, ASequentialHint: Boolean): THandle; static;
    // Creates the file, or empties it if it exists; write access. AUnbuffered = O_DIRECT.
    class function CreateFileForWrite(const AFileName: string; const AUnbuffered: Boolean): THandle; static;
    // Makes the file ASize bytes long (cuts it, or extends it with zeros)
    class procedure SetFileSize(const AHandle: THandle; const ASize: Int64); static;
    class procedure CloseFile(const AHandle: THandle); static;
    class function GetFileSize(const AHandle: THandle): Int64; static;
    { The alignment unbuffered I/O needs for offsets and sizes (statx, STATX_DIOALIGN, Linux 6.1 and newer). 4096 if
      the kernel does not tell. }
    class function GetSectorSize(const AHandle: THandle): Cardinal; static;
    class function PageSize: Cardinal; static;
    // Page-aligned, zero-filled memory (mmap); FreePages(nil, ...) does nothing. ASize: the size given to AllocPages.
    class function AllocPages(const ASize: NativeUInt): Pointer; static;
    class procedure FreePages(const AMemory: Pointer; const ASize: NativeUInt); static;
    // Monotonic clock for statistics
    class function TimestampMicroseconds: UInt64; static;

    { An auto-reset event for waking a thread (an eventfd): SignalWakeEvent sets it, WaitForEvents resets it
      when it returns because of it }
    class function CreateWakeEvent: THandle; static;
    class procedure SignalWakeEvent(const AEvent: THandle); static;
    class procedure CloseWakeEvent(const AEvent: THandle); static;
    { Waits, without a time limit, until AEvent1 or AEvent2 is signalled (poll), and resets the signalled ones (reads
      them). AEvent2 may be a ring's CompletionEventHandle. }
    class procedure WaitForEvents(const AEvent1, AEvent2: THandle); static;
  end;

implementation

uses
  BaseUnix, Linux, Syscall, PIRUnit.Types;

// Pointers go to the kernel as system call arguments. The unit is for 64-bit CPUs only.
{$WARN 4055 OFF}

const
  // System calls that FPC 3.2.2 has no number for (they differ per CPU)
{$IF defined(CPUX86_64)}
  SYSCALL_EVENTFD2 = 290;
  SYSCALL_STATX = 332;
{$ELSE}
  SYSCALL_EVENTFD2 = 19;
  SYSCALL_STATX = 291;
{$ENDIF}

  // fcntl.h, eventfd.h, fadvise.h, stat.h, auxvec.h
  O_CLOEXEC_FLAG = &02000000;
  {
    ARM64 has fcntl.h values of its own: there 040000 (O_DIRECT elsewhere) is O_DIRECTORY. FPC 3.2.2's
    BaseUnix.O_DIRECT is 040000 on every CPU, so on AArch64 an unbuffered open failed with ENOTDIR (found by the first
    run on an ARM machine, Phase 23).
  }
{$IF defined(CPUAARCH64)}
  O_DIRECT_FLAG = &0200000;
{$ELSE}
  O_DIRECT_FLAG = &040000;
{$ENDIF}
  EFD_CLOEXEC = O_CLOEXEC_FLAG;
  EFD_NONBLOCK = &04000;
  POSIX_FADV_SEQUENTIAL = 2;
  AT_EMPTY_PATH = $1000;
  STATX_DIOALIGN = $2000;
  AT_PAGESZ = 6;

  DEFAULT_SECTOR_SIZE = 4096;
  DEFAULT_PAGE_SIZE = 4096;

type
  // struct statx: the fields up to the direct I/O alignment (256 bytes in all)
  TStatx = record
    stx_mask: Cardinal;
    stx_blksize: Cardinal;
    stx_rest: array[0..$97 - 8] of Byte;   // up to offset $98
    stx_dio_mem_align: Cardinal;          // offset $98
    stx_dio_offset_align: Cardinal;       // offset $9C
    stx_spare: array[0..95] of Byte;
  end;

var
  GPageSize: Cardinal = 0;

{$IFDEF IORING_CLOCK_LIBC}
{ For measuring only: the C library's clock_gettime reads the clock through the vDSO, without a system call (13 ns in
  WSL2, FPC's Linux.clock_gettime 94 ns), but the engine got no faster with it (Docs/Design.md §12.10). }
function LibcClockGetTime(AClock: Integer; ATime: PTimeSpec): Integer; cdecl; external 'c' name 'clock_gettime';
{$ENDIF}

function OpenFlags(const AUnbuffered: Boolean): Integer;
begin
  Result := O_CLOEXEC_FLAG;

  if AUnbuffered then
    Result := Result or O_DIRECT_FLAG;
end;

class function TLinuxIORingPlatform.OpenFileForRead(const AFileName: string; const AUnbuffered,
  ASequentialHint: Boolean): THandle;

  procedure RaiseOpenFailed(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(-fpgeterrno, 'Open "%s"', [AName]);
  end;

begin
  Result := FpOpen(AFileName, O_RDONLY or OpenFlags(AUnbuffered));

  if Result < 0 then
    RaiseOpenFailed(AFileName);

  // A hint only: a failure does not matter
  if ASequentialHint then
    do_SysCall(syscall_nr_fadvise64, TSysParam(Result), 0, 0, POSIX_FADV_SEQUENTIAL);
end;

class function TLinuxIORingPlatform.CreateFileForWrite(const AFileName: string; const AUnbuffered: Boolean): THandle;

  procedure RaiseCreateFailed(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(-fpgeterrno, 'Create "%s"', [AName]);
  end;

begin
  Result := FpOpen(AFileName, O_WRONLY or O_CREAT or O_TRUNC or OpenFlags(AUnbuffered), &666);

  if Result < 0 then
    RaiseCreateFailed(AFileName);
end;

class procedure TLinuxIORingPlatform.SetFileSize(const AHandle: THandle; const ASize: Int64);

  procedure RaiseSetFileSizeFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'Set the file size');
  end;

begin
  if FpFtruncate(AHandle, ASize) < 0 then
    RaiseSetFileSizeFailed;
end;

class procedure TLinuxIORingPlatform.CloseFile(const AHandle: THandle);
begin
  FpClose(AHandle);
end;

class function TLinuxIORingPlatform.GetFileSize(const AHandle: THandle): Int64;

  procedure RaiseFstatFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'fstat');
  end;

var
  LStat: Stat;
begin
  if FpFstat(AHandle, LStat) < 0 then
    RaiseFstatFailed;

  Result := LStat.st_size;
end;

class function TLinuxIORingPlatform.GetSectorSize(const AHandle: THandle): Cardinal;
var
  LStatx: TStatx;
begin
  FillChar(LStatx, SizeOf(LStatx), 0);

  if (do_SysCall(SYSCALL_STATX, TSysParam(AHandle), TSysParam(PChar('')), AT_EMPTY_PATH, STATX_DIOALIGN,
    TSysParam(@LStatx)) = 0) and (LStatx.stx_mask and STATX_DIOALIGN <> 0) and (LStatx.stx_dio_offset_align > 0) then
    Result := LStatx.stx_dio_offset_align
  else
    Result := DEFAULT_SECTOR_SIZE;
end;

{ AT_PAGESZ from the auxiliary vector (pairs of type and value, ended by 0): AArch64 systems can
  have 4, 16 or 64 KiB pages }
function ReadPageSize: Cardinal;
var
  LFile: Integer;
  LPair: array[0..1] of NativeUInt;
begin
  Result := DEFAULT_PAGE_SIZE;

  LFile := FpOpen('/proc/self/auxv', O_RDONLY or O_CLOEXEC_FLAG);

  if LFile < 0 then
    Exit;

  try
    while (FpRead(LFile, LPair, SizeOf(LPair)) = SizeOf(LPair)) and (LPair[0] <> 0) do
      if LPair[0] = AT_PAGESZ then
      begin
        if LPair[1] > 0 then
          Result := Cardinal(LPair[1]);

        Break;
      end;
  finally
    FpClose(LFile);
  end;
end;

class function TLinuxIORingPlatform.PageSize: Cardinal;
begin
  if GPageSize = 0 then
    GPageSize := ReadPageSize;

  Result := GPageSize;
end;

class function TLinuxIORingPlatform.AllocPages(const ASize: NativeUInt): Pointer;

  procedure RaiseMmapFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'mmap');
  end;

begin
  Result := fpmmap(nil, ASize, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);

  if Result = MAP_FAILED then
    RaiseMmapFailed;
end;

class procedure TLinuxIORingPlatform.FreePages(const AMemory: Pointer; const ASize: NativeUInt);
begin
  if AMemory <> nil then
    fpmunmap(AMemory, ASize);
end;

class function TLinuxIORingPlatform.TimestampMicroseconds: UInt64;
var
  LTime: TTimeSpec;
begin
{$IFDEF IORING_CLOCK_LIBC}
  LibcClockGetTime(CLOCK_MONOTONIC, @LTime);
{$ELSE}
  clock_gettime(CLOCK_MONOTONIC, @LTime);
{$ENDIF}

  Result := UInt64(LTime.tv_sec) * 1000000 + UInt64(LTime.tv_nsec div 1000);
end;

class function TLinuxIORingPlatform.CreateWakeEvent: THandle;

  procedure RaiseEventFdFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'eventfd');
  end;

var
  LFd: Integer;
begin
  // Non-blocking: resetting it never waits
  LFd := Integer(do_SysCall(SYSCALL_EVENTFD2, 0, EFD_CLOEXEC or EFD_NONBLOCK));

  if LFd < 0 then
    RaiseEventFdFailed;

  Result := THandle(LFd);
end;

class procedure TLinuxIORingPlatform.SignalWakeEvent(const AEvent: THandle);
var
  LOne: UInt64;
begin
  LOne := 1;
  FpWrite(AEvent, LOne, SizeOf(LOne));
end;

class procedure TLinuxIORingPlatform.CloseWakeEvent(const AEvent: THandle);
begin
  FpClose(AEvent);
end;

class procedure TLinuxIORingPlatform.WaitForEvents(const AEvent1, AEvent2: THandle);
var
  LPoll: array[0..1] of TPollFd;
  LIndex: Integer;
  LValue: UInt64;
begin
  LPoll[0].fd := AEvent1;
  LPoll[1].fd := AEvent2;

  repeat
    for LIndex := 0 to 1 do
    begin
      LPoll[LIndex].events := POLLIN;
      LPoll[LIndex].revents := 0;
    end;
  until (FpPoll(@LPoll[0], 2, -1) > 0) or (fpgeterrno <> ESysEINTR);

  { Reset what woke us: an eventfd read takes its count back to 0 (the ring's completion eventfd blocks on reading, so
    only when it is signalled) }
  for LIndex := 0 to 1 do
    if LPoll[LIndex].revents and POLLIN <> 0 then
      FpRead(LPoll[LIndex].fd, LValue, SizeOf(LValue));
end;

end.
