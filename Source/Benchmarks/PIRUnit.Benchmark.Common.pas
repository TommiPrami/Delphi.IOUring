unit PIRUnit.Benchmark.Common;

{
  Shared pieces of the benchmarks: the consumer every contender feeds its data
  to, time and CPU measurement, file cache purge, test file creation, and the
  plain file calls the contenders use. Compiles with Delphi and Free Pascal,
  for Windows and (Free Pascal) Linux.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils;
{$ELSE}
  Winapi.Windows,
  System.SysUtils;
{$ENDIF}

const
  MiB = 1024 * 1024;

{$IFDEF MSWINDOWS}
  // The plain synchronous read call of the platform, for contender names
  READ_CALL_NAME = 'ReadFile';
{$ELSE}
  READ_CALL_NAME = 'read';
{$ENDIF}

type
  PBenchConsumer = ^TBenchConsumer;

  {
    Gets the file's data in order, like a real program would.
    - Checksum: XOR of all 64-bit words, so every byte is touched and all
      contenders can be checked against each other.
    - Work: if WorkMicrosecondsPerMiB > 0, burns that much CPU time per MiB,
      to simulate processing the data (the "data for free" scenario).
  }
  TBenchConsumer = record
  private
    FChecksum: UInt64;
    FBytes: Int64;
    FWorkMicrosecondsPerMiB: Cardinal;
    FUnworkedBytes: Int64;
  public
    procedure Init(const AWorkMicrosecondsPerMiB: Cardinal);
    procedure Consume(const AData: PByte; const ALength: NativeInt);
    { Adds the result of a consumer that got another part of the file (multi-threaded contender). XOR
      does not depend on the order. }
    procedure Merge(const AOther: TBenchConsumer);
    property Checksum: UInt64 read FChecksum;
    property Bytes: Int64 read FBytes;
  end;

  // Wall clock and process CPU time (all threads) of one run
  TBenchMeasurement = record
  private
    FStartMicroseconds: UInt64;
    FStartUser: UInt64;
    FStartKernel: UInt64;
  public
    Seconds: Double;
    UserMilliseconds: Double;
    KernelMilliseconds: Double;
    procedure Start;
    procedure Stop;
  end;

  // A monotonic clock
  function BenchMicroseconds: UInt64;

  // Busy-waits for AMicroseconds (simulated work)
  procedure SpinMicroseconds(const AMicroseconds: Cardinal);

  {
    Drops the file's data from the file cache. Windows: opening a file without buffering makes the cache manager
    flush and purge it (checked at start-up by the benchmark, see CheckCachePurge in the program). Linux: fsync,
    then posix_fadvise(POSIX_FADV_DONTNEED). (In WSL2 the Windows host may still have the data in its own cache:
    there "cold" is not the disk.)
  }
  procedure PurgeFileCache(const AFileName: string);

  { Creates a file of ASize bytes (multiple of 4096) with pseudo-random data, written without buffering so the new data
    is not left in the cache. }
  procedure CreateBenchFile(const AFileName: string; const ASize: Int64);

  function FileSizeOf(const AFileName: string): Int64;

  {
    Opens a file for reading. AOverlapped: Windows FILE_FLAG_OVERLAPPED (Linux: no such thing). AUnbuffered: past the file
    cache (FILE_FLAG_NO_BUFFERING / O_DIRECT): buffers, offsets and lengths must then be sector-aligned. ASequentialHint:
    FILE_FLAG_SEQUENTIAL_SCAN / POSIX_FADV_SEQUENTIAL.
  }
  function BenchOpenForReading(const AFileName: string; const AOverlapped, AUnbuffered: Boolean;
    const ASequentialHint: Boolean = False): THandle;
  procedure BenchCloseFile(const AHandle: THandle);
  // Reads at the current position; returns the bytes read (0 at the end)
  function BenchRead(const AFile: THandle; var ABuffer; const ACount: Cardinal): Cardinal;
  // Reads ACount bytes at AOffset (positioned, no seek call); raises on a short read
  procedure BenchReadAt(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64);
  // Puts what the file cache still holds of the file onto the disk, through a handle of its own (FlushFileBuffers / fsync)
  procedure BenchFlushFile(const AFileName: string);

  // The logical processors this process may run on. (Free Pascal 3.2.2's TThread.ProcessorCount is 1 on Linux.)
  function BenchProcessorCount: Integer;
  // 'Win32', 'Win64' or 'Linux64'
  function BenchPlatformName: string;
  // <temp>/Pascal.IOUring.Bench
  function DefaultBenchFolder: string;

implementation

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
{$IFDEF UNIX}
  BaseUnix, Unix, Syscall,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Types;

{$Q-}
{$R-}

{$IFDEF MSWINDOWS}
var
  GFrequency: Int64;
{$ENDIF}

{$IFDEF UNIX}
const
  POSIX_FADV_DONTNEED = 4;

procedure RaiseLastErrno(const AOperation: string); overload; {$IFNDEF FPC} noreturn; {$ENDIF}
var
  LErrno: Integer;
begin
  LErrno := fpgeterrno;
  RaiseErrorFmt(EOSError, '%s: %s (errno %d)', [AOperation, SysErrorMessage(LErrno), LErrno]);
end;

procedure RaiseLastErrno(const AFormat: string; const AArgs: array of const); overload; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseLastErrno(Format(AFormat, AArgs));
end;
{$ENDIF}

{ TBenchConsumer }

procedure TBenchConsumer.Init(const AWorkMicrosecondsPerMiB: Cardinal);
begin
  FChecksum := 0;
  FBytes := 0;
  FWorkMicrosecondsPerMiB := AWorkMicrosecondsPerMiB;
  FUnworkedBytes := 0;
end;

procedure TBenchConsumer.Consume(const AData: PByte; const ALength: NativeInt);
var
  LWord: PUInt64;
  LWordCount: NativeInt;
  LChecksum: UInt64;
  LTail: PByte;
  LIndex: NativeInt;
begin
  LWord := PUInt64(AData);
  LWordCount := ALength div 8;
  LChecksum := FChecksum;

  for LIndex := 1 to LWordCount do
  begin
    LChecksum := LChecksum xor LWord^;
    Inc(LWord);
  end;

  // Chunks end on 8-byte file offsets except at the end of the file
  LTail := PByte(LWord);

  for LIndex := 1 to ALength mod 8 do
  begin
    LChecksum := LChecksum xor LTail^;
    Inc(LTail);
  end;

  FChecksum := LChecksum;
  Inc(FBytes, ALength);

  if FWorkMicrosecondsPerMiB > 0 then
  begin
    Inc(FUnworkedBytes, ALength);

    while FUnworkedBytes >= MiB do
    begin
      SpinMicroseconds(FWorkMicrosecondsPerMiB);
      Dec(FUnworkedBytes, MiB);
    end;
  end;
end;

procedure TBenchConsumer.Merge(const AOther: TBenchConsumer);
begin
  FChecksum := FChecksum xor AOther.FChecksum;
  Inc(FBytes, AOther.FBytes);
end;

{ TBenchMeasurement }

// User and kernel CPU time of the process, in 100 ns units
{$IFDEF MSWINDOWS}
function FileTimeToUInt64(const AValue: TFileTime): UInt64;
begin
  Result := UInt64(AValue.dwHighDateTime) shl 32 or AValue.dwLowDateTime;
end;

procedure ProcessTimes(out AUser, AKernel: UInt64);
var
  LCreation: TFileTime;
  LExit: TFileTime;
  LKernel: TFileTime;
  LUser: TFileTime;
begin
  GetProcessTimes(GetCurrentProcess, LCreation, LExit, LKernel, LUser);
  AUser := FileTimeToUInt64(LUser);
  AKernel := FileTimeToUInt64(LKernel);
end;

function BenchMicroseconds: UInt64;
var
  LCounter: Int64;
begin
  QueryPerformanceCounter(LCounter);

  Result := UInt64(LCounter div GFrequency) * 1000000 + UInt64((LCounter mod GFrequency) * 1000000 div GFrequency);
end;
{$ELSE}
type
  // struct rusage (FPC 3.2.2 has no getrusage for Linux): the two times, then 14 counters we do not use
  TBenchRUsage = record
    UserTime: TTimeVal;
    SystemTime: TTimeVal;
    Counters: array[0..13] of NativeInt;
  end;

const
  RUSAGE_SELF = 0;    // all threads of the process

procedure ProcessTimes(out AUser, AKernel: UInt64);
var
  LUsage: TBenchRUsage;
begin
  FillChar(LUsage, SizeOf(LUsage), 0);
  do_SysCall(syscall_nr_getrusage, RUSAGE_SELF, TSysParam(@LUsage));
  AUser := UInt64(LUsage.UserTime.tv_sec) * 10000000 + UInt64(LUsage.UserTime.tv_usec) * 10;
  AKernel := UInt64(LUsage.SystemTime.tv_sec) * 10000000 + UInt64(LUsage.SystemTime.tv_usec) * 10;
end;

{ The C library's clock_gettime: through the vDSO, without a system call (13 ns in WSL2). FPC 3.2.2's own clock_gettime
  is a system call (94 ns), which would make the busy-wait of the work scenario mostly kernel time. }
function LibcClockGetTime(AClock: Integer; ATime: PTimeSpec): Integer; cdecl; external 'c' name 'clock_gettime';

function BenchMicroseconds: UInt64;
const
  CLOCK_MONOTONIC = 1;
var
  LTime: TTimeSpec;
begin
  LibcClockGetTime(CLOCK_MONOTONIC, @LTime);

  Result := UInt64(LTime.tv_sec) * 1000000 + UInt64(LTime.tv_nsec div 1000);
end;
{$ENDIF}

procedure TBenchMeasurement.Start;
begin
  ProcessTimes(FStartUser, FStartKernel);
  FStartMicroseconds := BenchMicroseconds;
end;

procedure TBenchMeasurement.Stop;
var
  LMicroseconds: UInt64;
  LUser: UInt64;
  LKernel: UInt64;
begin
  LMicroseconds := BenchMicroseconds;
  ProcessTimes(LUser, LKernel);
  Seconds := (LMicroseconds - FStartMicroseconds) / 1000000;
  // 100 ns units
  UserMilliseconds := (LUser - FStartUser) / 10000;
  KernelMilliseconds := (LKernel - FStartKernel) / 10000;
end;

procedure SpinMicroseconds(const AMicroseconds: Cardinal);
var
  LStart: UInt64;
begin
  LStart := BenchMicroseconds;

  repeat
  until BenchMicroseconds - LStart >= AMicroseconds;
end;

{ Files }

{$IFDEF MSWINDOWS}
procedure PurgeFileCache(const AFileName: string);
var
  LHandle: THandle;
begin
  LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, 0);

  if LHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  CloseHandle(LHandle);
end;
{$ELSE}
procedure PurgeFileCache(const AFileName: string);
var
  LFile: THandle;
begin
  LFile := TIORingPlatform.OpenFileForRead(AFileName, False, False);
  try
    // Dirty pages stay in the cache: write them first
    FpFsync(LFile);
    do_SysCall(syscall_nr_fadvise64, TSysParam(LFile), 0, 0, POSIX_FADV_DONTNEED);
  finally
    TIORingPlatform.CloseFile(LFile);
  end;
end;
{$ENDIF}

procedure CreateBenchFile(const AFileName: string; const ASize: Int64);

  procedure RaiseBadSize; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'The benchmark file size must be a multiple of 4096');
  end;

const
  CHUNK = 4 * MiB;
var
  LHandle: THandle;
  LBuffer: PUInt64;
  LWord: PUInt64;
  LState: UInt64;
  LRemaining: Int64;
  LCount: Cardinal;
  LIndex: Integer;
{$IFDEF MSWINDOWS}
  LWritten: DWORD;
{$ENDIF}
begin
  if ASize mod 4096 <> 0 then
    RaiseBadSize;

  LBuffer := TIORingPlatform.AllocPages(CHUNK);

  try
{$IFDEF MSWINDOWS}
    LHandle := CreateFile(PChar(AFileName), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_NO_BUFFERING or FILE_FLAG_WRITE_THROUGH, 0);

    if LHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
{$ELSE}
    LHandle := TIORingPlatform.CreateFileForWrite(AFileName, True);
{$ENDIF}

    try
      LState := UInt64($9E3779B97F4A7C15);
      LRemaining := ASize;

      while LRemaining > 0 do
      begin
        // xorshift64: fast, not compressible, different in every chunk
        LWord := LBuffer;

        for LIndex := 1 to CHUNK div 8 do
        begin
          LState := LState xor (LState shl 13);
          LState := LState xor (LState shr 7);
          LState := LState xor (LState shl 17);
          LWord^ := LState;
          Inc(LWord);
        end;

        if LRemaining < CHUNK then
          LCount := Cardinal(LRemaining)
        else
          LCount := CHUNK;

{$IFDEF MSWINDOWS}
        if not WriteFile(LHandle, LBuffer^, LCount, LWritten, nil) or (LWritten <> LCount) then
          RaiseLastOSError;
{$ELSE}
        if FpWrite(LHandle, LBuffer^, LCount) <> LCount then
          RaiseLastErrno('Write "%s"', [AFileName]);
{$ENDIF}

        Dec(LRemaining, LCount);
      end;
    finally
      BenchCloseFile(LHandle);
    end;
  finally
    TIORingPlatform.FreePages(LBuffer, CHUNK);
  end;
end;

{$IFDEF MSWINDOWS}
function FileSizeOf(const AFileName: string): Int64;
var
  LData: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(AFileName), GetFileExInfoStandard, @LData) then
    Exit(-1);

  Result := Int64(LData.nFileSizeHigh) shl 32 or LData.nFileSizeLow;
end;

function BenchOpenForReading(const AFileName: string; const AOverlapped, AUnbuffered: Boolean;
  const ASequentialHint: Boolean): THandle;
var
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL;

  if AOverlapped then
    LFlags := LFlags or FILE_FLAG_OVERLAPPED;

  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;

  if ASequentialHint then
    LFlags := LFlags or FILE_FLAG_SEQUENTIAL_SCAN;

  Result := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    LFlags, 0);

  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

procedure BenchCloseFile(const AHandle: THandle);
begin
  CloseHandle(AHandle);
end;

function BenchRead(const AFile: THandle; var ABuffer; const ACount: Cardinal): Cardinal;
var
  LRead: DWORD;
begin
  if not ReadFile(AFile, ABuffer, ACount, LRead, nil) then
    RaiseLastOSError;

  Result := LRead;
end;

procedure BenchReadAt(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64);

  procedure RaiseShortRead(const AValue: UInt64); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Short read at %d', [AValue]);
  end;

var
  LOverlapped: TOverlapped;
  LRead: DWORD;
begin
  FillChar(LOverlapped, SizeOf(LOverlapped), 0);
  LOverlapped.Offset := DWORD(AOffset and $FFFFFFFF);
  LOverlapped.OffsetHigh := DWORD(AOffset shr 32);
  LRead := 0;

  if not ReadFile(AFile, ABuffer, ACount, LRead, @LOverlapped) then
    RaiseLastOSError;

  if LRead <> ACount then
    RaiseShortRead(AOffset);
end;

procedure BenchFlushFile(const AFileName: string);
var
  LHandle: THandle;
begin
  LHandle := CreateFile(PChar(AFileName), GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);

  if LHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  try
    if not FlushFileBuffers(LHandle) then
      RaiseLastOSError;
  finally
    CloseHandle(LHandle);
  end;
end;
{$ELSE}
function FileSizeOf(const AFileName: string): Int64;
var
  LStat: Stat;
begin
  if FpStat(AFileName, LStat) <> 0 then
    Exit(-1);

  Result := LStat.st_size;
end;

function BenchOpenForReading(const AFileName: string; const AOverlapped, AUnbuffered: Boolean;
  const ASequentialHint: Boolean): THandle;
begin
  Result := TIORingPlatform.OpenFileForRead(AFileName, AUnbuffered, ASequentialHint);
end;

procedure BenchCloseFile(const AHandle: THandle);
begin
  TIORingPlatform.CloseFile(AHandle);
end;

function BenchRead(const AFile: THandle; var ABuffer; const ACount: Cardinal): Cardinal;
var
  LRead: Integer;
begin
  LRead := FpRead(AFile, ABuffer, ACount);

  if LRead < 0 then
    RaiseLastErrno('read');

  Result := Cardinal(LRead);
end;

procedure BenchReadAt(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64);

  procedure RaiseShortRead(const AValue: UInt64); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Short read at %d', [AValue]);
  end;

var
  LRead: Integer;
begin
  LRead := FpPRead(AFile, @ABuffer, ACount, Int64(AOffset));

  if LRead < 0 then
    RaiseLastErrno('pread');

  if Cardinal(LRead) <> ACount then
    RaiseShortRead(AOffset);
end;

procedure BenchFlushFile(const AFileName: string);
var
  LFile: THandle;
begin
  // fsync needs no write access
  LFile := TIORingPlatform.OpenFileForRead(AFileName, False, False);
  try
    if FpFsync(LFile) <> 0 then
      RaiseLastErrno('fsync');
  finally
    TIORingPlatform.CloseFile(LFile);
  end;
end;
{$ENDIF}

{$IFDEF MSWINDOWS}
function BenchProcessorCount: Integer;
begin
  Result := TThread.ProcessorCount;
end;
{$ELSE}
function BenchProcessorCount: Integer;
var
  LMask: array[0..15] of UInt64;    // up to 1024 processors
  LBytes: TSysResult;
  LIndex: Integer;
begin
  FillChar(LMask, SizeOf(LMask), 0);
  // Returns the bytes it filled in
  LBytes := do_SysCall(syscall_nr_sched_getaffinity, 0, SizeOf(LMask), TSysParam(@LMask));
  Result := 0;

  if LBytes > 0 then
    for LIndex := 0 to SizeOf(LMask) * 8 - 1 do
      if LMask[LIndex div 64] and (UInt64(1) shl (LIndex mod 64)) <> 0 then
        Inc(Result);

  if Result = 0 then
    Result := 1;
end;
{$ENDIF}

function BenchPlatformName: string;
begin
{$IF defined(MSWINDOWS) and defined(CPUX64)}
  Result := 'Win64';
{$ELSEIF defined(MSWINDOWS)}
  Result := 'Win32';
{$ELSEIF defined(CPUAARCH64)}
  Result := 'LinuxArm64';
{$ELSE}
  Result := 'Linux64';
{$ENDIF}
end;

function DefaultBenchFolder: string;
begin
{$IFDEF MSWINDOWS}
  Result := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'Pascal.IOUring.Bench';
{$ELSE}
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'Pascal.IOUring.Bench';
{$ENDIF}
end;

{$IFDEF MSWINDOWS}
initialization
  QueryPerformanceFrequency(GFrequency);
{$ENDIF}

end.