unit PIRUnit.Windows.Platform;

{
  The Windows platform services: TWindowsIORingPlatform – files, memory, the clock and a wake event – for the higher
  layers (Docs/Design.md §5.2). User code normally uses it through the TIORingPlatform alias in PIRUnit.IORing.
}

{$I PIRInclude.Compiler.inc}

interface

type
  { File, memory and clock services the higher layers need. Every platform has a record with these names; PIRUnit.IORing
    exports it as TIORingPlatform. Failures raise EIORingError (NativeCode = HRESULT). }
  TWindowsIORingPlatform = record
  public
    { Read-only, shared for reading and writing (so a file being written by someone else can be read), overlapped.
      AUnbuffered = FILE_FLAG_NO_BUFFERING, ASequentialHint = FILE_FLAG_SEQUENTIAL_SCAN. }
    class function OpenFileForRead(const AFileName: string; const AUnbuffered, ASequentialHint: Boolean): THandle; static;
    { Creates the file, or empties it if it exists; write access, others may read meanwhile, overlapped. AUnbuffered
      = FILE_FLAG_NO_BUFFERING. }
    class function CreateFileForWrite(const AFileName: string; const AUnbuffered: Boolean): THandle; static;
    // Makes the file ASize bytes long (cuts it, or extends it with zeros)
    class procedure SetFileSize(const AHandle: THandle; const ASize: Int64); static;
    class procedure CloseFile(const AHandle: THandle); static;
    class function GetFileSize(const AHandle: THandle): Int64; static;
    { Logical sector size of the file's volume: unbuffered I/O must use offsets, sizes and buffer addresses that are
      multiples of it. 4096 if the system does not tell. }
    class function GetSectorSize(const AHandle: THandle): Cardinal; static;
    class function PageSize: Cardinal; static;
    { Page-aligned memory (VirtualAlloc); FreePages(nil, ...) does nothing. ASize: the size given to AllocPages
      (Linux needs it; Windows not) }
    class function AllocPages(const ASize: NativeUInt): Pointer; static;
    class procedure FreePages(const AMemory: Pointer; const ASize: NativeUInt); static;
    // Monotonic clock for statistics
    class function TimestampMicroseconds: UInt64; static;

    { An auto-reset event for waking a thread (an event): SignalWakeEvent sets it, WaitForEvents resets it
      when it returns because of it }
    class function CreateWakeEvent: THandle; static;
    class procedure SignalWakeEvent(const AEvent: THandle); static;
    class procedure CloseWakeEvent(const AEvent: THandle); static;
    { Waits, without a time limit, until AEvent1 or AEvent2 is signalled (WaitForMultipleObjects). AEvent2 may be a
      ring's CompletionEventHandle. }
    class procedure WaitForEvents(const AEvent1, AEvent2: THandle); static;
  end;

implementation

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  PIRUnit.Types;

type
  // fileapi.h / minwinbase.h; not in the RTL
  FILE_STORAGE_INFO = record
    LogicalBytesPerSector: ULONG;
    PhysicalBytesPerSectorForAtomicity: ULONG;
    PhysicalBytesPerSectorForPerformance: ULONG;
    FileSystemEffectivePhysicalBytesPerSectorForAtomicity: ULONG;
    Flags: ULONG;
    ByteOffsetForSectorAlignment: ULONG;
    ByteOffsetForPartitionAlignment: ULONG;
  end;

  // FILE_END_OF_FILE_INFO
  TFileEndOfFileInfo = record
    EndOfFile: Int64;
  end;

const
  FILE_INFO_CLASS_END_OF_FILE_INFO = 6;  // FILE_INFO_BY_HANDLE_CLASS.FileEndOfFileInfo
  FILE_INFO_CLASS_STORAGE_INFO = 16;  // FILE_INFO_BY_HANDLE_CLASS.FileStorageInfo
  DEFAULT_SECTOR_SIZE = 4096;

  function GetFileInformationByHandleEx(hFile: THandle; FileInformationClass: Integer;
    lpFileInformation: Pointer; dwBufferSize: DWORD): BOOL; stdcall; external kernel32;

  // Own import: works on any handle, also overlapped ones (no file position)
  function IORingSetFileInformationByHandle(hFile: THandle; FileInformationClass: Integer;
    lpFileInformation: Pointer; dwBufferSize: DWORD): BOOL; stdcall; external kernel32
    name 'SetFileInformationByHandle';

  // Own import: FPC's Windows unit does not declare GetFileSizeEx
  function IORingGetFileSizeEx(hFile: THandle; out lpFileSize: Int64): BOOL; stdcall;
    external kernel32 name 'GetFileSizeEx';

function LastErrorAsHResult: HRESULT;
var
  LError: DWORD;
begin
  LError := GetLastError;

  if LError = 0 then
    Result := E_FAIL
  else
    Result := HRESULT((LError and $0000FFFF) or $80070000);
end;

class function TWindowsIORingPlatform.OpenFileForRead(const AFileName: string; const AUnbuffered,
  ASequentialHint: Boolean): THandle;

  procedure RaiseOpenFailed(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(LastErrorAsHResult, 'Open "%s"', [AName]);
  end;

var
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED;

  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;

  if ASequentialHint then
    LFlags := LFlags or FILE_FLAG_SEQUENTIAL_SCAN;

  Result := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, LFlags, 0);

  if Result = INVALID_HANDLE_VALUE then
    RaiseOpenFailed(AFileName);
end;

class function TWindowsIORingPlatform.CreateFileForWrite(const AFileName: string; const AUnbuffered: Boolean): THandle;

  procedure RaiseCreateFailed(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(LastErrorAsHResult, 'Create "%s"', [AName]);
  end;

var
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED;

  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;

  Result := CreateFile(PChar(AFileName), GENERIC_WRITE, FILE_SHARE_READ, nil, CREATE_ALWAYS, LFlags, 0);

  if Result = INVALID_HANDLE_VALUE then
    RaiseCreateFailed(AFileName);
end;

class procedure TWindowsIORingPlatform.SetFileSize(const AHandle: THandle; const ASize: Int64);

  procedure RaiseSetFileSizeFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(LastErrorAsHResult, 'Set the file size');
  end;

var
  LInfo: TFileEndOfFileInfo;
begin
  LInfo.EndOfFile := ASize;

  if not IORingSetFileInformationByHandle(AHandle, FILE_INFO_CLASS_END_OF_FILE_INFO, @LInfo, SizeOf(LInfo)) then
    RaiseSetFileSizeFailed;
end;

class procedure TWindowsIORingPlatform.CloseFile(const AHandle: THandle);
begin
  CloseHandle(AHandle);
end;

class function TWindowsIORingPlatform.GetFileSize(const AHandle: THandle): Int64;

  procedure RaiseGetFileSizeFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(LastErrorAsHResult, 'GetFileSizeEx');
  end;

begin
  if not IORingGetFileSizeEx(AHandle, Result) then
    RaiseGetFileSizeFailed;
end;

class function TWindowsIORingPlatform.GetSectorSize(const AHandle: THandle): Cardinal;
var
  LInfo: FILE_STORAGE_INFO;
begin
  FillChar(LInfo, SizeOf(LInfo), 0);

  if GetFileInformationByHandleEx(AHandle, FILE_INFO_CLASS_STORAGE_INFO, @LInfo, SizeOf(LInfo))
    and (LInfo.LogicalBytesPerSector > 0) then
    Result := LInfo.LogicalBytesPerSector
  else
    Result := DEFAULT_SECTOR_SIZE;
end;

class function TWindowsIORingPlatform.PageSize: Cardinal;
var
  LInfo: TSystemInfo;
begin
  GetSystemInfo(LInfo);

  Result := LInfo.dwPageSize;
end;

class function TWindowsIORingPlatform.AllocPages(const ASize: NativeUInt): Pointer;

  procedure RaiseAllocFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(LastErrorAsHResult, 'VirtualAlloc');
  end;

begin
  Result := VirtualAlloc(nil, ASize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);

  if Result = nil then
    RaiseAllocFailed;
end;

class procedure TWindowsIORingPlatform.FreePages(const AMemory: Pointer; const ASize: NativeUInt);
begin
  if AMemory <> nil then
    VirtualFree(AMemory, 0, MEM_RELEASE);
end;

class function TWindowsIORingPlatform.TimestampMicroseconds: UInt64;
var
  LCounter: Int64;
  LFrequency: Int64;
begin
  QueryPerformanceCounter(LCounter);
  QueryPerformanceFrequency(LFrequency);

  Result := UInt64(LCounter div LFrequency) * 1000000 + UInt64((LCounter mod LFrequency) * 1000000 div LFrequency);
end;

class function TWindowsIORingPlatform.CreateWakeEvent: THandle;

  procedure RaiseCreateEventFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(LastErrorAsHResult, 'CreateEvent');
  end;

begin
  Result := CreateEvent(nil, False, False, nil);   // auto-reset

  if Result = 0 then
    RaiseCreateEventFailed;
end;

class procedure TWindowsIORingPlatform.SignalWakeEvent(const AEvent: THandle);
begin
  SetEvent(AEvent);
end;

class procedure TWindowsIORingPlatform.CloseWakeEvent(const AEvent: THandle);
begin
  CloseHandle(AEvent);
end;

class procedure TWindowsIORingPlatform.WaitForEvents(const AEvent1, AEvent2: THandle);
var
  LEvents: array[0..1] of THandle;
begin
  LEvents[0] := AEvent1;
  LEvents[1] := AEvent2;

  WaitForMultipleObjects(2, @LEvents[0], False, INFINITE);
end;

end.
