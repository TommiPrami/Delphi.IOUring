unit TestPlatformHelpers;

{
  Windows helpers for the tests: files, pipes and page-aligned memory that are
  released automatically, a thread that writes to a pipe later, plus small
  HRESULT helpers. The Linux side comes with TLinuxIORing (Phase 20).

  No test framework dependency (failures raise exceptions): used by the
  Delphi and the Free Pascal tests.
}

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  Windows,
  Classes;
{$ELSE}
  Winapi.Windows,
  System.Classes;
{$ENDIF}

type
  // Collects test resources and releases them all in Destroy (or ReleaseAll).
  // Release order: memory last, so no buffer goes away before its handle.
  TTestResources = class
  private
    FHandles: array of THandle;
    FFiles: array of string;
    FMemory: array of Pointer;
  public
    destructor Destroy; override;
    procedure ReleaseAll;

    procedure AddHandle(const AHandle: THandle);
    procedure AddFile(const AFileName: string);

    // Opens an existing file; raises on failure
    function OpenFile(const AFileName: string; const AFlags: DWORD = FILE_FLAG_OVERLAPPED;
      const AAccess: DWORD = GENERIC_READ): THandle;
    // Creates a new empty file (read/write) in the test folder; deleted on release
    function CreateNewFile(const AFlags: DWORD = FILE_FLAG_OVERLAPPED): THandle;
    // Page-aligned, zero-filled memory (VirtualAlloc)
    function AllocPages(const ASize: NativeUInt): Pointer;
    // Connected named pipe pair, both ends overlapped. Reads from AClient stay
    // pending until something is written to AServer.
    procedure OpenPipePair(out AServer, AClient: THandle);
  end;

  // Writes one byte to a pipe after a delay. Create, then Start; WaitFor and
  // Free when done.
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

// Writes one byte to an overlapped pipe handle and waits until it is written
procedure WriteByteToPipe(const APipe: THandle; const AValue: Byte);

function PageSize: NativeUInt;
function HResultFromWin32(const ACode: DWORD): HRESULT;
function HrToStr(const AResult: HRESULT): string;

implementation

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  TestFileHelpers;

{ TTestResources }

destructor TTestResources.Destroy;
begin
  ReleaseAll;
  inherited;
end;

procedure TTestResources.ReleaseAll;
var
  LIndex: Integer;
begin
  for LIndex := High(FHandles) downto 0 do
    CloseHandle(FHandles[LIndex]);
  FHandles := nil;

  for LIndex := High(FFiles) downto 0 do
    TTestFileHelpers.DeleteTestFile(FFiles[LIndex]);
  FFiles := nil;

  for LIndex := High(FMemory) downto 0 do
    VirtualFree(FMemory[LIndex], 0, MEM_RELEASE);
  FMemory := nil;
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

function TTestResources.OpenFile(const AFileName: string; const AFlags, AAccess: DWORD): THandle;
begin
  Result := CreateFile(PChar(AFileName), AAccess, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL or AFlags, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  AddHandle(Result);
end;

function TTestResources.CreateNewFile(const AFlags: DWORD): THandle;
var
  LFileName: string;
begin
  LFileName := TTestFileHelpers.NewTestFileName('Write');
  Result := CreateFile(PChar(LFileName), GENERIC_READ or GENERIC_WRITE, 0, nil, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL or AFlags, 0);
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
end;

procedure TTestResources.OpenPipePair(out AServer, AClient: THandle);
var
  LGuid: TGUID;
  LName: string;
begin
  CreateGUID(LGuid);
  LName := '\\.\pipe\Delphi.IOUring.Tests.' + GUIDToString(LGuid);

  AServer := CreateNamedPipe(PChar(LName), PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT, 1, 4096, 4096, 0, nil);
  if AServer = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  AddHandle(AServer);

  AClient := CreateFile(PChar(LName), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING,
    FILE_FLAG_OVERLAPPED, 0);
  if AClient = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  AddHandle(AClient);
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

end.
