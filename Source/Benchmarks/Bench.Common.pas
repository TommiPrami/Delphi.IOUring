unit Bench.Common;

{
  Shared pieces of the benchmark: the consumer every contender feeds its data
  to, time and CPU measurement, file cache purge and test file creation.
  Compiles with Delphi and Free Pascal.
}

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  Windows,
  SysUtils;
{$ELSE}
  Winapi.Windows,
  System.SysUtils;
{$ENDIF}

const
  MiB = 1024 * 1024;

type
  PBenchConsumer = ^TBenchConsumer;

  // Gets the file's data in order, like a real program would.
  // - Checksum: XOR of all 64-bit words, so every byte is touched and all
  //   contenders can be checked against each other.
  // - Work: if WorkMicrosecondsPerMiB > 0, burns that much CPU time per MiB,
  //   to simulate processing the data (the "data for free" scenario).
  TBenchConsumer = record
  private
    FChecksum: UInt64;
    FBytes: Int64;
    FWorkMicrosecondsPerMiB: Cardinal;
    FUnworkedBytes: Int64;
  public
    procedure Init(const AWorkMicrosecondsPerMiB: Cardinal);
    procedure Consume(const AData: PByte; const ALength: NativeInt);
    // Adds the result of a consumer that got another part of the file
    // (multi-threaded contender). XOR does not depend on the order.
    procedure Merge(const AOther: TBenchConsumer);
    property Checksum: UInt64 read FChecksum;
    property Bytes: Int64 read FBytes;
  end;

  // Wall clock and process CPU time (all threads) of one run
  TBenchMeasurement = record
  private
    FStartCounter: Int64;
    FStartUser: UInt64;
    FStartKernel: UInt64;
  public
    Seconds: Double;
    UserMilliseconds: Double;
    KernelMilliseconds: Double;
    procedure Start;
    procedure Stop;
  end;

// Busy-waits for AMicroseconds (simulated work)
procedure SpinMicroseconds(const AMicroseconds: Cardinal);

// Drops the file's data from the Windows file cache: opening a file without
// buffering makes the cache manager flush and purge it (checked at start-up
// by the benchmark, see CheckCachePurge in the program).
procedure PurgeFileCache(const AFileName: string);

// Creates a file of ASize bytes (multiple of 4096) with pseudo-random data,
// written without buffering so the new data is not left in the cache.
procedure CreateBenchFile(const AFileName: string; const ASize: Int64);

function FileSizeOf(const AFileName: string): Int64;

implementation

{$Q-}
{$R-}

var
  GFrequency: Int64;

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

procedure TBenchMeasurement.Start;
begin
  ProcessTimes(FStartUser, FStartKernel);
  QueryPerformanceCounter(FStartCounter);
end;

procedure TBenchMeasurement.Stop;
var
  LCounter: Int64;
  LUser: UInt64;
  LKernel: UInt64;
begin
  QueryPerformanceCounter(LCounter);
  ProcessTimes(LUser, LKernel);
  Seconds := (LCounter - FStartCounter) / GFrequency;
  // FILETIME units are 100 ns
  UserMilliseconds := (LUser - FStartUser) / 10000;
  KernelMilliseconds := (LKernel - FStartKernel) / 10000;
end;

procedure SpinMicroseconds(const AMicroseconds: Cardinal);
var
  LStart: Int64;
  LNow: Int64;
  LTicks: Int64;
begin
  LNow := 0;   // set by QueryPerformanceCounter; FPC cannot see that
  QueryPerformanceCounter(LStart);
  LTicks := Int64(AMicroseconds) * GFrequency div 1000000;
  repeat
    QueryPerformanceCounter(LNow);
  until LNow - LStart >= LTicks;
end;

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

procedure CreateBenchFile(const AFileName: string; const ASize: Int64);
const
  CHUNK = 4 * MiB;
var
  LHandle: THandle;
  LBuffer: PUInt64;
  LWord: PUInt64;
  LState: UInt64;
  LWritten: DWORD;
  LRemaining: Int64;
  LCount: DWORD;
  LIndex: Integer;
begin
  if ASize mod 4096 <> 0 then
    raise Exception.Create('The benchmark file size must be a multiple of 4096');

  LBuffer := VirtualAlloc(nil, CHUNK, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if LBuffer = nil then
    RaiseLastOSError;
  try
    LHandle := CreateFile(PChar(AFileName), GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL or FILE_FLAG_NO_BUFFERING or FILE_FLAG_WRITE_THROUGH, 0);
    if LHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
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
          LCount := DWORD(LRemaining)
        else
          LCount := CHUNK;
        if not WriteFile(LHandle, LBuffer^, LCount, LWritten, nil) or (LWritten <> LCount) then
          RaiseLastOSError;
        Dec(LRemaining, LCount);
      end;
    finally
      CloseHandle(LHandle);
    end;
  finally
    VirtualFree(LBuffer, 0, MEM_RELEASE);
  end;
end;

function FileSizeOf(const AFileName: string): Int64;
var
  LData: TWin32FileAttributeData;
begin
  if not GetFileAttributesEx(PChar(AFileName), GetFileExInfoStandard, @LData) then
    Exit(-1);
  Result := Int64(LData.nFileSizeHigh) shl 32 or LData.nFileSizeLow;
end;

initialization
  QueryPerformanceFrequency(GFrequency);

end.
