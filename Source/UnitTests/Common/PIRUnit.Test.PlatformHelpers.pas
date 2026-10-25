unit PIRUnit.Test.PlatformHelpers;

{
  Platform helpers for the tests, for Windows and Linux: files, pipes and
  page-aligned memory that are released automatically, a thread that writes to
  a pipe later, waiting on an event handle, and what the platform reports for
  some failures. Plus small HRESULT helpers on Windows.

  No test framework dependency (failures raise exceptions): used by the
  Delphi and the Free Pascal tests.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  Classes;
{$ELSE}
  Winapi.Windows,
  System.Classes;
{$ENDIF}

type
  // How OpenFile and CreateNewFile open a file; the same on every platform
  TTestOpenFlag = (
    tofWriteOnly,    // write access only (OpenFile; the default is read only)
    tofUnbuffered,   // past the file cache: FILE_FLAG_NO_BUFFERING / O_DIRECT
    tofSynchronous   // Windows: without FILE_FLAG_OVERLAPPED (Linux: no difference)
  );

  TTestOpenFlags = set of TTestOpenFlag;

  { Collects test resources and releases them all in Destroy (or ReleaseAll). Release order: memory last, so no buffer
    goes away before its handle. }
  TTestResources = class
  private
    FHandles: array of THandle;
    FFiles: array of string;
    FMemory: array of Pointer;
    FMemorySizes: array of NativeUInt;
  public
    destructor Destroy; override;
    procedure ReleaseAll;

    procedure AddHandle(const AHandle: THandle);
    procedure AddFile(const AFileName: string);

    // Opens an existing file; raises on failure
    function OpenFile(const AFileName: string; const AFlags: TTestOpenFlags = []): THandle; overload;
{$IFDEF MSWINDOWS}
    // With Windows flags and access (the Windows API tests)
    function OpenFile(const AFileName: string; const AFlags: DWORD; const AAccess: DWORD = GENERIC_READ): THandle; overload;
{$ENDIF}
    // Creates a new empty file (read/write) in the test folder; deleted on release
    function CreateNewFile(const AFlags: TTestOpenFlags = []): THandle;
    // Page-aligned, zero-filled memory
    function AllocPages(const ASize: NativeUInt): Pointer;
    { A connected duplex pipe: reads from one end stay pending until something is written to the other. Windows: a named
      pipe, both ends overlapped. Linux: a Unix socket pair. }
    procedure OpenPipePair(out AServer, AClient: THandle);
    {
      Makes every later write to the open file AFileName fail: Windows locks the file through another handle
      (byte-range lock); Linux puts a read-only descriptor in place of the writer's (dup2): EBADF. Linux has no
      mandatory byte-range locks.
    }
    procedure MakeWritesFail(const AFileName: string);
  end;

  // Writes one byte to a pipe after a delay. Create, then Start; WaitFor and Free when done.
  TDelayedPipeWriter = class(TThread)
  private
    FPipe: THandle;
    FDelayMilliseconds: Cardinal;
    FValue: Byte;
  protected
    procedure Execute; override;
  public
    constructor Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
  end;

const
  // A file handle that is not open: requests on it fail (on Linux 0 is standard input, a valid descriptor)
{$IFDEF MSWINDOWS}
  BAD_HANDLE = THandle(0);
{$ELSE}
  BAD_HANDLE = THandle(1000000);
{$ENDIF}

  // NativeResult of a read on a file opened for writing only
{$IFDEF MSWINDOWS}
  RESULT_ACCESS_DENIED = Integer($80070005);   // E_ACCESSDENIED
{$ELSE}
  RESULT_ACCESS_DENIED = -9;                   // -EBADF
{$ENDIF}

  // Writes one byte to a pipe and waits until it is written
  procedure WriteByteToPipe(const APipe: THandle; const AValue: Byte);

  // Reads ACount bytes from a pipe (waits for them)
  procedure ReadFromPipe(const APipe: THandle; const ACount: Cardinal);

  // True when the event (Windows event / Linux eventfd) is signalled within ATimeoutMilliseconds
  function WaitForEvent(const AHandle: THandle; const ATimeoutMilliseconds: Cardinal): Boolean;

  function PageSize: NativeUInt;

{$IFDEF UNIX}
  // The number of open file descriptors of this process (/proc/self/fd)
  function OpenFileDescriptorCount: Integer;
{$ENDIF}

{$IFDEF MSWINDOWS}
  function HResultFromWin32(const ACode: DWORD): HRESULT;
  function HrToStr(const AResult: HRESULT): string;
{$ENDIF}

implementation

uses
{$IFDEF FPC}
  {$IFDEF UNIX}
  BaseUnix,
  Unix,       // fpReadLink
  Sockets,    // fpsocketpair
  PIRUnit.IORing,
  {$ENDIF}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.Types, PIRUnit.Test.FileHelpers;

{$IFDEF UNIX}
const
  O_CLOEXEC_FLAG = &02000000;
  { ARM64's own fcntl.h value; FPC 3.2.2's BaseUnix.O_DIRECT is the x86 one (O_DIRECTORY on ARM64). As in
    PIRUnit.Linux.Ring. }
{$IF defined(CPUAARCH64)}
  O_DIRECT_FLAG = &0200000;
{$ELSE}
  O_DIRECT_FLAG = &040000;
{$ENDIF}

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

{ TTestResources }

destructor TTestResources.Destroy;
begin
  ReleaseAll;

  inherited Destroy;
end;

procedure TTestResources.ReleaseAll;
var
  LIndex: Integer;
begin
  for LIndex := High(FHandles) downto 0 do
{$IFDEF MSWINDOWS}
    CloseHandle(FHandles[LIndex]);
{$ELSE}
    FpClose(FHandles[LIndex]);
{$ENDIF}

  FHandles := nil;

  for LIndex := High(FFiles) downto 0 do
    TTestFileHelpers.DeleteTestFile(FFiles[LIndex]);

  FFiles := nil;

  for LIndex := High(FMemory) downto 0 do
{$IFDEF MSWINDOWS}
    VirtualFree(FMemory[LIndex], 0, MEM_RELEASE);
{$ELSE}
    Fpmunmap(FMemory[LIndex], FMemorySizes[LIndex]);
{$ENDIF}

  FMemory := nil;
  FMemorySizes := nil;
end;

procedure TTestResources.AddHandle(const AHandle: THandle);
begin
  SetLength(FHandles, Length(FHandles) + 1);
  FHandles[High(FHandles)] := AHandle;
end;

procedure TTestResources.AddFile(const AFileName: string);
begin
  SetLength(FFiles, Length(FFiles) + 1);
  FFiles[High(FFiles)] := AFileName;
end;

{$IFDEF MSWINDOWS}
function WindowsFlags(const AFlags: TTestOpenFlags): DWORD;
begin
  Result := 0;

  if not (tofSynchronous in AFlags) then
    Result := Result or FILE_FLAG_OVERLAPPED;

  if tofUnbuffered in AFlags then
    Result := Result or FILE_FLAG_NO_BUFFERING;
end;

function TTestResources.OpenFile(const AFileName: string; const AFlags: TTestOpenFlags): THandle;
begin
  if tofWriteOnly in AFlags then
    Result := OpenFile(AFileName, WindowsFlags(AFlags), GENERIC_WRITE)
  else
    Result := OpenFile(AFileName, WindowsFlags(AFlags), GENERIC_READ);
end;

function TTestResources.OpenFile(const AFileName: string; const AFlags, AAccess: DWORD): THandle;
begin
  Result := CreateFile(PChar(AFileName), AAccess, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL or AFlags, 0);

  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  AddHandle(Result);
end;

function TTestResources.CreateNewFile(const AFlags: TTestOpenFlags): THandle;
var
  LFileName: string;
begin
  LFileName := TTestFileHelpers.NewTestFileName('Write');
  Result := CreateFile(PChar(LFileName), GENERIC_READ or GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL or WindowsFlags(AFlags), 0);

  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  // Handle first: handles are closed before files are deleted
  AddHandle(Result);
  AddFile(LFileName);
end;

function TTestResources.AllocPages(const ASize: NativeUInt): Pointer;
begin
  Result := VirtualAlloc(nil, ASize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);

  if Result = nil then
    RaiseLastOSError;

  SetLength(FMemory, Length(FMemory) + 1);
  FMemory[High(FMemory)] := Result;
  SetLength(FMemorySizes, Length(FMemorySizes) + 1);
  FMemorySizes[High(FMemorySizes)] := ASize;
end;

procedure TTestResources.OpenPipePair(out AServer, AClient: THandle);
var
  LGuid: TGUID;
  LName: string;
begin
  CreateGUID(LGuid);
  LName := '\\.\pipe\Pascal.IOUring.Tests.' + GUIDToString(LGuid);

  AServer := CreateNamedPipe(PChar(LName), PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, 1, 4096, 4096, 0, nil);

  if AServer = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  AddHandle(AServer);

  AClient := CreateFile(PChar(LName), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, 0);

  if AClient = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  AddHandle(AClient);
end;

const
  LOCKFILE_FAIL_IMMEDIATELY_FLAG = 1;
  LOCKFILE_EXCLUSIVE_LOCK_FLAG = 2;

// Own import: the declaration differs between FPC versions
function IORingLockFileEx(hFile: THandle; dwFlags, dwReserved, nNumberOfBytesToLockLow,
  nNumberOfBytesToLockHigh: DWORD; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32.dll' name 'LockFileEx';

procedure TTestResources.MakeWritesFail(const AFileName: string);
var
  LHandle: THandle;
  LOverlapped: TOverlapped;
begin
  // The writer lets others read; this handle lets the writer write. The lock covers the whole file (and beyond).
  LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);

  if LHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  AddHandle(LHandle);
  FillChar(LOverlapped, SizeOf(LOverlapped), 0);

  if not IORingLockFileEx(LHandle, LOCKFILE_EXCLUSIVE_LOCK_FLAG or LOCKFILE_FAIL_IMMEDIATELY_FLAG, 0,
    $FFFFFFFF, $7FFFFFFF, @LOverlapped) then
    RaiseLastOSError;
end;

procedure WriteByteToPipe(const APipe: THandle; const AValue: Byte);
var
  LValue: Byte;
  LWritten: DWORD;
  LOverlapped: TOverlapped;
begin
  LValue := AValue;
  FillChar(LOverlapped, SizeOf(LOverlapped), 0);
  LOverlapped.hEvent := CreateEvent(nil, True, False, nil);
  try
    if not WriteFile(APipe, LValue, 1, LWritten, @LOverlapped) then
      if GetLastError <> ERROR_IO_PENDING then
        RaiseLastOSError;

    if not GetOverlappedResult(APipe, LOverlapped, LWritten, True) then
      RaiseLastOSError;
  finally
    CloseHandle(LOverlapped.hEvent);
  end;
end;

procedure ReadFromPipe(const APipe: THandle; const ACount: Cardinal);
var
  LBuffer: TBytes;
  LRead: DWORD;
  LTotal: Cardinal;
  LOverlapped: TOverlapped;
begin
  SetLength(LBuffer, ACount);
  LTotal := 0;

  while LTotal < ACount do
  begin
    FillChar(LOverlapped, SizeOf(LOverlapped), 0);
    LOverlapped.hEvent := CreateEvent(nil, True, False, nil);
    try
      LRead := 0;

      if not ReadFile(APipe, LBuffer[LTotal], ACount - LTotal, LRead, @LOverlapped) then
        if GetLastError <> ERROR_IO_PENDING then
          RaiseLastOSError;

      if not GetOverlappedResult(APipe, LOverlapped, LRead, True) then
        RaiseLastOSError;
    finally
      CloseHandle(LOverlapped.hEvent);
    end;

    Inc(LTotal, LRead);
  end;
end;

function WaitForEvent(const AHandle: THandle; const ATimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := WaitForSingleObject(AHandle, ATimeoutMilliseconds) = WAIT_OBJECT_0;
end;

function PageSize: NativeUInt;
var
  LInfo: TSystemInfo;
begin
  GetSystemInfo(LInfo);

  Result := LInfo.dwPageSize;
end;

function HResultFromWin32(const ACode: DWORD): HRESULT;
begin
  if ACode = 0 then
    Result := S_OK
  else
    Result := HRESULT((ACode and $0000FFFF) or (FACILITY_WIN32 shl 16) or $80000000);
end;

function HrToStr(const AResult: HRESULT): string;
begin
  Result := Format('0x%.8x', [Cardinal(AResult)]);
end;
{$ENDIF}

{$IFDEF UNIX}
function UnixFlags(const AFlags: TTestOpenFlags): Integer;
begin
  Result := O_CLOEXEC_FLAG;

  if tofUnbuffered in AFlags then
    Result := Result or O_DIRECT_FLAG;
end;

function TTestResources.OpenFile(const AFileName: string; const AFlags: TTestOpenFlags): THandle;
var
  LAccess: Integer;
begin
  if tofWriteOnly in AFlags then
    LAccess := O_WRONLY
  else
    LAccess := O_RDONLY;

  Result := FpOpen(AFileName, LAccess or UnixFlags(AFlags));

  if Result < 0 then
    RaiseLastErrno('Open "%s"', [AFileName]);

  AddHandle(Result);
end;

function TTestResources.CreateNewFile(const AFlags: TTestOpenFlags): THandle;
var
  LFileName: string;
begin
  LFileName := TTestFileHelpers.NewTestFileName('Write');
  Result := FpOpen(LFileName, O_RDWR or O_CREAT or O_TRUNC or UnixFlags(AFlags), &644);

  if Result < 0 then
    RaiseLastErrno('Create "%s"', [LFileName]);

  // Handle first: handles are closed before files are deleted
  AddHandle(Result);
  AddFile(LFileName);
end;

function TTestResources.AllocPages(const ASize: NativeUInt): Pointer;
begin
  Result := Fpmmap(nil, ASize, PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0);

  if Result = MAP_FAILED then
    RaiseLastErrno('mmap');

  SetLength(FMemory, Length(FMemory) + 1);
  FMemory[High(FMemory)] := Result;
  SetLength(FMemorySizes, Length(FMemorySizes) + 1);
  FMemorySizes[High(FMemorySizes)] := ASize;
end;

procedure TTestResources.OpenPipePair(out AServer, AClient: THandle);
var
  LPair: array[0..1] of cint;
begin
  // pipe() goes one way only; a socket pair both ways, like the named pipe
  if fpsocketpair(AF_UNIX, SOCK_STREAM, 0, @LPair[0]) <> 0 then
    RaiseLastErrno('socketpair');

  AServer := LPair[0];
  AClient := LPair[1];
  AddHandle(AServer);
  AddHandle(AClient);
end;

procedure TTestResources.MakeWritesFail(const AFileName: string);

  procedure RaiseNotOpen(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EOSError, 'MakeWritesFail: "%s" is not open', [AName]);
  end;

var
  LPath: string;
  LReadOnly: Integer;
  LSearch: TSearchRec;
  LFound: Boolean;
begin
  LPath := ExpandFileName(AFileName);
  LReadOnly := FpOpen(LPath, O_RDONLY or O_CLOEXEC_FLAG);

  if LReadOnly < 0 then
    RaiseLastErrno('Open "%s"', [LPath]);

  AddHandle(LReadOnly);
  { Every descriptor of this process that points to the file gets the read-only one in its place (the same number, so
    the writer goes on using it) }
  LFound := False;

  if FindFirst('/proc/self/fd/*', faAnyFile, LSearch) = 0 then

  try
    repeat
      if (LSearch.Name <> '.') and (LSearch.Name <> '..') and (StrToIntDef(LSearch.Name, -1) <> LReadOnly) and
        (fpReadLink('/proc/self/fd/' + LSearch.Name) = LPath) then
      begin
        if FpDup2(LReadOnly, StrToInt(LSearch.Name)) < 0 then
          RaiseLastErrno('dup2');

        LFound := True;
      end;
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;

  if not LFound then
    RaiseNotOpen(LPath);
end;

procedure WriteByteToPipe(const APipe: THandle; const AValue: Byte);
var
  LValue: Byte;
begin
  LValue := AValue;

  if FpWrite(APipe, LValue, 1) <> 1 then
    RaiseLastErrno('Write to the pipe');
end;

procedure ReadFromPipe(const APipe: THandle; const ACount: Cardinal);
var
  LBuffer: TBytes;
  LTotal: Cardinal;
  LRead: Integer;
begin
  SetLength(LBuffer, ACount);
  LTotal := 0;

  while LTotal < ACount do
  begin
    LRead := FpRead(APipe, LBuffer[LTotal], ACount - LTotal);

    if LRead <= 0 then
      RaiseLastErrno('Read from the pipe');

    Inc(LTotal, LRead);
  end;
end;

function WaitForEvent(const AHandle: THandle; const ATimeoutMilliseconds: Cardinal): Boolean;
var
  LPoll: TPollFd;
begin
  LPoll.fd := AHandle;
  LPoll.events := POLLIN;
  LPoll.revents := 0;

  Result := FpPoll(@LPoll, 1, Integer(ATimeoutMilliseconds)) = 1;
end;

function PageSize: NativeUInt;
begin
  // The library's own answer (AT_PAGESZ from the auxiliary vector)
  Result := TIORingPlatform.PageSize;
end;

function OpenFileDescriptorCount: Integer;
var
  LSearch: TSearchRec;
begin
  Result := 0;

  if FindFirst('/proc/self/fd/*', faAnyFile, LSearch) = 0 then

  try
    repeat
      if (LSearch.Name <> '.') and (LSearch.Name <> '..') then
        Inc(Result);
    until FindNext(LSearch) <> 0;
  finally
    FindClose(LSearch);
  end;
end;
{$ENDIF}

{ TDelayedPipeWriter }

constructor TDelayedPipeWriter.Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
begin
  FPipe := APipe;
  FDelayMilliseconds := ADelayMilliseconds;
  FValue := AValue;

  inherited Create(True);
end;

procedure TDelayedPipeWriter.Execute;
begin
  Sleep(FDelayMilliseconds);
  WriteByteToPipe(FPipe, FValue);
end;

end.
