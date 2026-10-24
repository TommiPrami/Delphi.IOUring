unit Delphi.IOUring.Backend.Custom;

// OS-neutral types shared by all backends (Docs/Design.md §5.1).
//
// Everything used per operation is a plain record: no managed fields, no
// set-up or clean-up cost. The meaning of TIORingCompletion.NativeResult is
// the OS's own (HRESULT on Windows, res = bytes or -errno on Linux); the few
// helpers that interpret it are the only OS-dependent code in this unit.

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

const
  // Timeout value meaning "wait forever"
  IORING_INFINITE = Cardinal($FFFFFFFF);

{$IFDEF MSWINDOWS}
  // NativeResult of a read that starts at or after the end of the file:
  // HRESULT_FROM_WIN32(ERROR_HANDLE_EOF). (On Linux such a read returns 0.)
  IORING_RESULT_END_OF_FILE = Integer($80070026);
  // NativeResult of a cancelled operation:
  // HRESULT_FROM_WIN32(ERROR_OPERATION_ABORTED). The engine uses it also for
  // requests it cancels before they reach the ring.
  IORING_RESULT_CANCELLED = Integer($800703E3);
{$ENDIF}
{$IFDEF LINUX}
  // NativeResult of a cancelled operation: -ECANCELED. The engine uses it also
  // for requests it cancels before they reach the ring. (A read at or after
  // the end of the file succeeds on Linux, with 0 bytes: IsEndOfFile.)
  IORING_RESULT_CANCELLED = -125;
{$ENDIF}

type
  // Value that identifies an operation in its completion. Pointer-sized, like
  // the OS type (UINT_PTR on Windows): on Win32 it has 32 bits.
  TIORingUserData = NativeUInt;

  TIORingOp = (ioRead, ioWrite, ioFlush, ioCancel, ioRegisterFiles, ioRegisterBuffers,
    ioReadScatter, ioWriteGather);
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

  TIORingCapabilities = record
    BackendName: string;              // e.g. 'Windows IoRing'; empty if not available
    NativeVersion: Cardinal;          // IORING_VERSION on Windows
    MaxSubmissionQueueSize: Cardinal;
    MaxCompletionQueueSize: Cardinal;
    SupportedOps: TIORingOps;
    Emulated: Boolean;                // works, but without kernel support (slow)
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

  // Entry for PrepareRegisterBuffers. Address = nil and Length = 0 is a "sparse"
  // entry (releases that index). Same layout as Windows IORING_BUFFER_INFO.
  PIORingBufferInfo = ^TIORingBufferInfo;
  TIORingBufferInfo = record
    Address: Pointer;
    Length: Cardinal;
  end;

  // Result of one operation. Field order and sizes match Windows IORING_CQE,
  // so the Windows backend pops straight into this record.
  // The same meaning on every system: NativeResult is 0 (success) or a
  // negative error code (HRESULT on Windows, -errno on Linux), the bytes are
  // in BytesTransferred. End of file differs: check IsEndOfFile first.
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
      raise EIORingError.CreateNative(NativeResult, AOperation)
    else
      raise EIORingError.CreateNative(NativeResult, 'I/O operation');
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

end.
