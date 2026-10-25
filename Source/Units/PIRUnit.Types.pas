unit PIRUnit.Types;

{
  OS-neutral types shared by all backends (Docs/Design.md §5.1).

  Everything used per operation is a plain record: no managed fields, no set-up or clean-up cost. The meaning of
  TIORingCompletion.NativeResult is the OS's own (HRESULT on Windows, res = bytes or -errno on Linux); the few helpers
  that interpret it are the only OS-dependent code in this unit.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  // The version of the library. It stays below 1.0 for a long time: the API may still change (Docs/Design.md §12.6).
  IORING_LIBRARY_VERSION = '0.1.0';

  // Timeout value meaning "wait forever"
  IORING_INFINITE = Cardinal($FFFFFFFF);

{$IFDEF MSWINDOWS}
  { NativeResult of a read that starts at or after the end of the file: HRESULT_FROM_WIN32(ERROR_HANDLE_EOF). (On
    Linux such a read returns 0.) }
  IORING_RESULT_END_OF_FILE = Integer($80070026);
  { NativeResult of a cancelled operation: HRESULT_FROM_WIN32(ERROR_OPERATION_ABORTED). The engine uses it also for
    requests it cancels before they reach the ring. }
  IORING_RESULT_CANCELLED = Integer($800703E3);
{$ENDIF}
{$IFDEF LINUX}
  { NativeResult of a cancelled operation: -ECANCELED. The engine uses it also for requests it cancels before they reach
    the ring. (A read at or after the end of the file succeeds on Linux, with 0 bytes: IsEndOfFile.) }
  IORING_RESULT_CANCELLED = -125;
{$ENDIF}

type
  { Value that identifies an operation in its completion. Pointer-sized, like the OS type (UINT_PTR on
    Windows): on Win32 it has 32 bits. }
  TIORingUserData = NativeUInt;

  TIORingOp = (ioRead, ioWrite, ioFlush, ioCancel, ioRegisterFiles, ioRegisterBuffers, ioReadScatter, ioWriteGather);

  TIORingOps = set of TIORingOp;

  TIORingSubmitFlag = (
    sfDrainPreceding   // start only after all earlier operations have completed (full barrier)
  );

  TIORingSubmitFlags = set of TIORingSubmitFlag;

  TIORingFlushMode = (
    rfmDefault,        // data, metadata and a sync command to the device (FlushFileBuffers)
    rfmData,           // data only
    rfmMinMetadata,    // data + sync, minimal metadata
    rfmNoSync          // data + metadata, no sync command
  );

  // What a system offers beyond the common subset (Docs/Design.md §5.8)
  TIORingExtra = (
    ieSockets,         // socket operations through the ring (Linux: send, receive, accept, connect)
    ieLinkedOps,       // an operation can wait for the one before it (Linux: TLinuxIORing.LinkToNext)
    ieSqPoll,          // a kernel thread takes the submissions, no system calls (Linux: IORING_SETUP_SQPOLL)
    ieRawEntries       // any operation of the system can be prepared (Linux: TLinuxIORing.PrepareSqe)
  );

  TIORingExtras = set of TIORingExtra;

  // Opcodes of the system's ring API: Windows IORING_OP_*, Linux IORING_OP_*
  TIORingNativeOps = set of Byte;

  { What this system offers. Windows and Linux differ, and so do Linux systems among themselves (kernel, distribution,
    what is switched off): ToString describes it all for logs and bug reports. }
  TIORingCapabilities = record
    BackendName: string;              // e.g. 'Windows IoRing'; empty if not available
    { Windows: the IoRing version (IORING_VERSION_*: 1, 2, 300, 400);
      Linux: the kernel version, major * 100 + minor (618 = 6.18) }
    NativeVersion: Cardinal;
    MaxSubmissionQueueSize: Cardinal;
    MaxCompletionQueueSize: Cardinal;
    SupportedOps: TIORingOps;
    Emulated: Boolean;                // works, but without kernel support (slow)
    // The system, e.g. 'Windows 11 (10.0, build 26300)' or 'Ubuntu 24.04.3 LTS, Linux 6.18.54.1-microsoft-standard-WSL2'
    SystemDescription: string;
    // Why the ring cannot be used here; empty if it can
    NotAvailableReason: string;
    { Feature bits of the system's ring API: Windows IORING_FEATURE_FLAGS, Linux
      io_uring_params.features (IORING_FEAT_*) }
    NativeFeatures: UInt64;
    // The opcodes the kernel supports (Windows: IsIoRingOpSupported, Linux: the probe)
    NativeOps: TIORingNativeOps;
    Extras: TIORingExtras;
    // All of the above in a few lines
    function ToString: string;
  end;

  // A file: raw OS handle, or index into the files registered with the ring
  TIORingFileRef = record
    Registered: Boolean;
    Handle: THandle;
    Index: Cardinal;
    class function FromHandle(const AHandle: THandle): TIORingFileRef; static;
    class function FromIndex(const AIndex: Cardinal): TIORingFileRef; static;
  end;

  // A buffer: raw pointer, or (index, offset) into the buffers registered with the ring
  TIORingBufferRef = record
    Registered: Boolean;
    Address: Pointer;
    Index: Cardinal;
    Offset: Cardinal;
    class function FromPointer(const AAddress: Pointer): TIORingBufferRef; static;
    class function FromRegistered(const AIndex, AOffset: Cardinal): TIORingBufferRef; static;
  end;

  { Entry for PrepareRegisterBuffers. Address = nil and Length = 0 is a "sparse" entry (releases that index). Same
    layout as Windows IORING_BUFFER_INFO. }
  PIORingBufferInfo = ^TIORingBufferInfo;

  TIORingBufferInfo = record
    Address: Pointer;
    Length: Cardinal;
  end;

  {
    Result of one operation. Field order and sizes match Windows IORING_CQE, so the Windows backend pops straight into
    this record. The same meaning on every system: NativeResult is 0 (success) or a negative error code (HRESULT on
    Windows, -errno on Linux), the bytes are in BytesTransferred. End of file differs: check IsEndOfFile first.
  }
  PIORingCompletion = ^TIORingCompletion;

  TIORingCompletion = record
    UserData: TIORingUserData;
    NativeResult: Integer;          // 0, or HRESULT (Windows) / -errno (Linux)
    BytesTransferred: NativeUInt;
    function Succeeded: Boolean;
    // Read started at or after the end of the file (not an error)
    function IsEndOfFile: Boolean;
    // The operation was cancelled
    function IsCancelled: Boolean;
    function ErrorMessage: string;
    procedure RaiseIfFailed(const AOperation: string = '');
  end;

  EIORingError = class(Exception)
  private
    FNativeCode: Integer;
  public
    constructor CreateNative(const ANativeCode: Integer; const AOperation: string);
    property NativeCode: Integer read FNativeCode;
  end;

  EIORingNotSupported = class(EIORingError);

  // Readable text for an OS result code (HRESULT on Windows, -errno on Linux)
  function IORingErrorMessage(const ANativeCode: Integer): string;

  {
    Raise helpers (Docs/CodingStyle.md, "Raising"), called from the small raise procedures: the text stays out of the
    routines that do the work. They raise at the caller's address. Pass a constant text, or a format and its
    arguments - not Format(...) or a string built with +.
  }
  procedure RaiseIORingError(const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  procedure RaiseIORingErrorFmt(const AFormat: string; const AArgs: array of const); {$IFNDEF FPC} noreturn; {$ENDIF}
  procedure RaiseIORingErrorNative(const ANativeCode: Integer; const AOperation: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  procedure RaiseIORingErrorNativeFmt(const ANativeCode: Integer; const AFormat: string; const AArgs: array of const);
    {$IFNDEF FPC} noreturn; {$ENDIF}
  procedure RaiseError(const AClass: ExceptClass; const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  procedure RaiseErrorFmt(const AClass: ExceptClass; const AFormat: string; const AArgs: array of const);
    {$IFNDEF FPC} noreturn; {$ENDIF}

  { The buffer arguments of the sequential reader and writer: ABufferSize a multiple of ASizeUnit (not 0), ABufferCount
    1..AMaxCount, and all buffers together not too big for memory. Returns their total size; raises EIORingError. }
  function IORingCheckBufferArguments(const ABufferSize, ABufferCount, ASizeUnit, AMaxCount: Cardinal): UInt64;
  // Unbuffered I/O: ABufferSize must be a multiple of the sector size; raises EIORingError
  procedure IORingCheckSectorMultiple(const ABufferSize, ASectorSize: Cardinal);

implementation

{$IFDEF MSWINDOWS}
const
  FACILITY_WIN32_MASK = Integer($FFFF0000);
  FACILITY_WIN32_VALUE = Integer($80070000);
{$ENDIF}

{ TIORingFileRef }

class function TIORingFileRef.FromHandle(const AHandle: THandle): TIORingFileRef;
begin
  Result.Registered := False;
  Result.Handle := AHandle;
  Result.Index := 0;
end;

class function TIORingFileRef.FromIndex(const AIndex: Cardinal): TIORingFileRef;
begin
  Result.Registered := True;
  Result.Handle := 0;
  Result.Index := AIndex;
end;

{ TIORingBufferRef }

class function TIORingBufferRef.FromPointer(const AAddress: Pointer): TIORingBufferRef;
begin
  Result.Registered := False;
  Result.Address := AAddress;
  Result.Index := 0;
  Result.Offset := 0;
end;

class function TIORingBufferRef.FromRegistered(const AIndex, AOffset: Cardinal): TIORingBufferRef;
begin
  Result.Registered := True;
  Result.Address := nil;
  Result.Index := AIndex;
  Result.Offset := AOffset;
end;

{ TIORingCapabilities }

function TIORingCapabilities.ToString: string;
const
  OP_NAMES: array[TIORingOp] of string = ('read', 'write', 'flush', 'cancel', 'register files',
    'register buffers', 'read scatter', 'write gather');
  EXTRA_NAMES: array[TIORingExtra] of string = ('sockets', 'linked operations', 'SQPOLL', 'raw entries');
var
  LOp: TIORingOp;
  LExtra: TIORingExtra;
  LOpcode: Integer;
  LCount: Integer;
  LHighest: Integer;
  LList: string;
begin
  // The reason first: also when the system has the API, but too old a version of it
  Result := '';

  if NotAvailableReason <> '' then
    Result := 'Not available: ' + NotAvailableReason + sLineBreak;

  if BackendName <> '' then
  begin
{$IFDEF MSWINDOWS}
    // ioringapi.h numbers the versions 1, 2, 300, 400
    if NativeVersion >= 100 then
      Result := Result + Format('%s, version %d', [BackendName, NativeVersion div 100])
    else
      Result := Result + Format('%s, version %d', [BackendName, NativeVersion]);
{$ELSE}
    Result := Result + Format('%s, kernel %d.%d', [BackendName, NativeVersion div 100, NativeVersion mod 100]);
{$ENDIF}

    if Emulated then
      Result := Result + ' (emulated)';

    Result := Result + sLineBreak;
  end;

  Result := Result + 'System: ' + SystemDescription;

  if BackendName <> '' then
  begin
    Result := Result + sLineBreak + Format('Queues: submission up to %d, completion up to %d',
      [MaxSubmissionQueueSize, MaxCompletionQueueSize]);
    LList := '';

    for LOp := Low(TIORingOp) to High(TIORingOp) do
      if LOp in SupportedOps then
      begin
        if LList <> '' then
          LList := LList + ', ';

        LList := LList + OP_NAMES[LOp];
      end;

    Result := Result + sLineBreak + 'Operations: ' + LList;

    LCount := 0;
    LHighest := -1;

    for LOpcode := 0 to 255 do
      if Byte(LOpcode) in NativeOps then
      begin
        Inc(LCount);
        LHighest := LOpcode;
      end;

    Result := Result + sLineBreak + Format('Native: %d opcodes (highest %d), features $%x', [LCount, LHighest,
      NativeFeatures]);

    LList := '';

    for LExtra := Low(TIORingExtra) to High(TIORingExtra) do
      if LExtra in Extras then
      begin
        if LList <> '' then
          LList := LList + ', ';

        LList := LList + EXTRA_NAMES[LExtra];
      end;

    if LList = '' then
      LList := 'none';

    Result := Result + sLineBreak + 'Extras: ' + LList;
  end;

  // Last, also when the ring is not available: which version ran
  Result := Result + sLineBreak + 'Library: Pascal.IOUring ' + IORING_LIBRARY_VERSION;
end;

{ TIORingCompletion }

function TIORingCompletion.Succeeded: Boolean;
begin
  Result := NativeResult >= 0;
end;

function TIORingCompletion.IsEndOfFile: Boolean;
begin
{$IFDEF MSWINDOWS}
  Result := NativeResult = IORING_RESULT_END_OF_FILE;
{$ELSE}
  // Linux: the read succeeded with 0 bytes
  Result := (NativeResult = 0) and (BytesTransferred = 0);
{$ENDIF}
end;

function TIORingCompletion.IsCancelled: Boolean;
begin
  Result := NativeResult = IORING_RESULT_CANCELLED;
end;

function TIORingCompletion.ErrorMessage: string;
begin
  Result := IORingErrorMessage(NativeResult);
end;

procedure TIORingCompletion.RaiseIfFailed(const AOperation: string);
begin
  if not Succeeded then
  begin
    if AOperation <> '' then
      RaiseIORingErrorNative(NativeResult, AOperation)
    else
      RaiseIORingErrorNative(NativeResult, 'I/O operation');
  end;
end;

{ EIORingError }

constructor EIORingError.CreateNative(const ANativeCode: Integer; const AOperation: string);
begin
  inherited Create(AOperation + ' failed: ' + IORingErrorMessage(ANativeCode));

  FNativeCode := ANativeCode;
end;

function IORingErrorMessage(const ANativeCode: Integer): string;
begin
{$IFDEF MSWINDOWS}
  // IoRing's own codes (facility 0x46): the system may not have texts for them
  case Cardinal(ANativeCode) of
    $80460001: Result := 'One or more of the required flags is not supported by the IoRing implementation';
    $80460002: Result := 'The IoRing submission queue is full';
    $80460003: Result := 'The IoRing version is not known or not supported';
    $80460004: Result := 'The IoRing submission queue size is too big';
    $80460005: Result := 'The IoRing completion queue size is too big';
    $80460006: Result := 'Another thread is submitting to this IoRing at the same time';
    $80460007: Result := 'The shared ring buffers of the IoRing are corrupt';
    $80460008: Result := 'The IoRing completion queue does not have room for the completions of all entries being submitted';
    else
      if (ANativeCode and FACILITY_WIN32_MASK) = FACILITY_WIN32_VALUE then
        Result := SysErrorMessage(Cardinal(ANativeCode) and $FFFF)
      else
        Result := SysErrorMessage(Cardinal(ANativeCode));
  end;

  if Result = '' then
    Result := 'Unknown error';

  Result := Result + Format(' (0x%.8x)', [Cardinal(ANativeCode)]);
{$ELSE}
  Result := SysErrorMessage(-ANativeCode) + Format(' (errno %d)', [-ANativeCode]);
{$ENDIF}
end;

{ Raise helpers. Free Pascal: get_caller_addr and get_caller_frame give what Delphi's ReturnAddress gives. }

procedure RaiseIORingError(const AMessage: string);
begin
{$IFDEF FPC}
  raise EIORingError.Create(AMessage) at get_caller_addr(get_frame), get_caller_frame(get_frame);
{$ELSE}
  raise EIORingError.Create(AMessage) at ReturnAddress;
{$ENDIF}
end;

procedure RaiseIORingErrorFmt(const AFormat: string; const AArgs: array of const);
begin
{$IFDEF FPC}
  raise EIORingError.CreateFmt(AFormat, AArgs) at get_caller_addr(get_frame), get_caller_frame(get_frame);
{$ELSE}
  raise EIORingError.CreateFmt(AFormat, AArgs) at ReturnAddress;
{$ENDIF}
end;

procedure RaiseIORingErrorNative(const ANativeCode: Integer; const AOperation: string);
begin
{$IFDEF FPC}
  raise EIORingError.CreateNative(ANativeCode, AOperation) at get_caller_addr(get_frame), get_caller_frame(get_frame);
{$ELSE}
  raise EIORingError.CreateNative(ANativeCode, AOperation) at ReturnAddress;
{$ENDIF}
end;

procedure RaiseIORingErrorNativeFmt(const ANativeCode: Integer; const AFormat: string; const AArgs: array of const);
begin
{$IFDEF FPC}
  raise EIORingError.CreateNative(ANativeCode, Format(AFormat, AArgs)) at get_caller_addr(get_frame),
    get_caller_frame(get_frame);
{$ELSE}
  raise EIORingError.CreateNative(ANativeCode, Format(AFormat, AArgs)) at ReturnAddress;
{$ENDIF}
end;

procedure RaiseError(const AClass: ExceptClass; const AMessage: string);
begin
{$IFDEF FPC}
  raise AClass.Create(AMessage) at get_caller_addr(get_frame), get_caller_frame(get_frame);
{$ELSE}
  raise AClass.Create(AMessage) at ReturnAddress;
{$ENDIF}
end;

procedure RaiseErrorFmt(const AClass: ExceptClass; const AFormat: string; const AArgs: array of const);
begin
{$IFDEF FPC}
  raise AClass.CreateFmt(AFormat, AArgs) at get_caller_addr(get_frame), get_caller_frame(get_frame);
{$ELSE}
  raise AClass.CreateFmt(AFormat, AArgs) at ReturnAddress;
{$ENDIF}
end;

function IORingCheckBufferArguments(const ABufferSize, ABufferCount, ASizeUnit, AMaxCount: Cardinal): UInt64;

  procedure RaiseBufferSizeNotMultiple(const ASize, AUnit: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Buffer size %d is not a multiple of %d', [ASize, AUnit]);
  end;

  procedure RaiseBufferCountOutOfRange(const ACount, AMax: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Buffer count %d is not between 1 and %d', [ACount, AMax]);
  end;

  procedure RaiseBuffersTooBig(const ACount, ASize: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('%d buffers of %d bytes do not fit in memory', [ACount, ASize]);
  end;

begin
  if (ABufferSize = 0) or (ABufferSize mod ASizeUnit <> 0) then
    RaiseBufferSizeNotMultiple(ABufferSize, ASizeUnit);

  if (ABufferCount = 0) or (ABufferCount > AMaxCount) then
    RaiseBufferCountOutOfRange(ABufferCount, AMaxCount);

  Result := UInt64(ABufferSize) * ABufferCount;

  if Result > UInt64(High(NativeInt) div 2) then
    RaiseBuffersTooBig(ABufferCount, ABufferSize);
end;

procedure IORingCheckSectorMultiple(const ABufferSize, ASectorSize: Cardinal);

  procedure RaiseNotSectorMultiple(const ASector: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Unbuffered I/O needs a buffer size that is a multiple of the sector size %d', [ASector]);
  end;

begin
  if ABufferSize mod ASectorSize <> 0 then
    RaiseNotSectorMultiple(ASectorSize);
end;

end.
