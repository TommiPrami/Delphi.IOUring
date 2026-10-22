unit Delphi.IOUring.Backend.Windows;

// The Windows ring: TWindowsIORing, built on Delphi.IOUring.Backend.Windows.API
// (Docs/Design.md §5.2). User code normally uses it through the TIORing alias
// in Delphi.IOUring.
//
// TWindowsIORing is a custom managed record: it owns the ring and closes it
// automatically at the end of the variable's scope. It cannot be copied; pass
// it as var or const [ref].
//
// Rules for the caller:
// - One thread at a time. A ring has no locks.
// - Buffers, file handles and scatter/gather segment arrays must stay valid
//   until the operation's completion has been popped.
// - Close (and the end of scope) waits until every submitted operation has
//   completed, because CloseIoRing does not cancel them and the kernel would
//   still write into the buffers. Operations that may never complete (pipe
//   reads etc.) must be cancelled first: PrepareCancel, or CancelIoEx on the
//   handle.

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  Windows,
  SysUtils,
{$ELSE}
  Winapi.Windows,
  System.SysUtils,
{$ENDIF}
  Delphi.IOUring.Backend.Custom,
  Delphi.IOUring.Backend.Windows.API;

type
  // One scatter/gather segment: a page-sized, page-aligned buffer. Windows
  // needs a file opened with FILE_FLAG_NO_BUFFERING for scatter/gather.
  TIORingSegment = FILE_SEGMENT_ELEMENT;
  PIORingSegment = PFILE_SEGMENT_ELEMENT;

function IORingSegment(const AAddress: Pointer): TIORingSegment;

type
  TWindowsIORing = record
  private
    FHandle: HIORING;
    FCompletionEvent: THandle;
    FSubmissionQueueSize: Cardinal;
    FCompletionQueueSize: Cardinal;
    FPreparedCount: Cardinal;   // built, not yet submitted
    FPendingCount: Cardinal;    // submitted, completion not yet popped
    // Copies of registration arrays: the kernel reads them when the
    // registration runs, so they must outlive the Prepare call
    FKeepAlive: array of TBytes;

    function NoRoom: Boolean;
    function BuildFailed(const AResult: HRESULT; const AFunctionName: string): Boolean;
    function KeepAlive(const AData: Pointer; const ASize: NativeInt): Pointer;
    function SubmitAndWait(const AWaitCount, ATimeoutMs: Cardinal): Boolean;
    procedure WaitForAllPending;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TWindowsIORing);
    class operator Finalize(var ADest: TWindowsIORing);
    class operator Copy(constref ASource: TWindowsIORing; var ADest: TWindowsIORing);
{$ELSE}
    class operator Initialize(out ADest: TWindowsIORing);
    class operator Finalize(var ADest: TWindowsIORing);
    class operator Assign(var ADest: TWindowsIORing; const [ref] ASource: TWindowsIORing);
{$ENDIF}

    // Creates the ring. Sizes are rounded up to powers of two by Windows; the
    // completion queue is at least twice the submission queue (0 = minimum).
    procedure Open(const ASubmissionQueueSize: Cardinal = 256; const ACompletionQueueSize: Cardinal = 0);
    // Waits for all submitted operations, then closes. Prepared but not
    // submitted entries are dropped. Does nothing if the ring is not open.
    procedure Close;
    function IsOpen: Boolean;

    // --- Prepare: no system call. False = no room (submission queue full, or the
    // completion queue could not take one more completion): pop completions,
    // Submit and try again.
    function PrepareRead(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
      const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []): Boolean;
    function PrepareWrite(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
      const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []; const AWriteThrough: Boolean = False): Boolean;
    function PrepareFlush(const AFile: TIORingFileRef; const AMode: TIORingFlushMode;
      const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = []): Boolean;
    // ASegments: ASegmentCount page-sized buffers; the array must stay valid
    // until the completion is popped. ACount = bytes to transfer.
    function PrepareReadScatter(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
      const ASegmentCount: Cardinal; const ACount: Cardinal; const AOffset: UInt64;
      const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = []): Boolean;
    function PrepareWriteGather(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
      const ASegmentCount: Cardinal; const ACount: Cardinal; const AOffset: UInt64;
      const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = [];
      const AWriteThrough: Boolean = False): Boolean;
    // Requests cancellation of the operation prepared with ATargetUserData on
    // AFile. Both operations produce a completion.
    function PrepareCancel(const AFile: TIORingFileRef; const ATargetUserData: TIORingUserData;
      const AUserData: TIORingUserData): Boolean;
    // Replaces all registered files / buffers. The arrays are copied.
    function PrepareRegisterFiles(const AHandles: array of THandle;
      const AUserData: TIORingUserData): Boolean;
    function PrepareRegisterBuffers(const ABuffers: array of TIORingBufferInfo;
      const AUserData: TIORingUserData): Boolean;

    // --- Submit: one system call. Submits all prepared entries and, if
    // AWaitCount > 0, waits until that many completions are available (at most
    // the number of outstanding operations) or the timeout ends. A timeout is
    // not an error. Returns the number of entries submitted.
    function Submit(const AWaitCount: Cardinal = 0; const ATimeoutMs: Cardinal = IORING_INFINITE): Cardinal;

    // --- Reap: no system call
    function TryPopCompletion(out ACompletion: TIORingCompletion): Boolean;
    function PopCompletions(var ACompletions: array of TIORingCompletion): Integer;

    // Waits until ACount completions are available (at most the number of
    // outstanding operations). False on timeout. Uses the same system call as
    // Submit, so it also submits prepared entries.
    function WaitForCompletions(const ACount: Cardinal; const ATimeoutMs: Cardinal = IORING_INFINITE): Boolean;

    // Auto-reset event, signalled when the completion queue goes from empty to
    // non-empty. Pop until TryPopCompletion returns False before waiting on it.
    function CompletionEventHandle: THandle;

    class function Available: Boolean; static;
    class function QueryCapabilities: TIORingCapabilities; static;

    // The raw ring, for calls into Delphi.IOUring.Backend.Windows.API
    property Handle: HIORING read FHandle;
    property SubmissionQueueSize: Cardinal read FSubmissionQueueSize;
    property CompletionQueueSize: Cardinal read FCompletionQueueSize;
    property PreparedCount: Cardinal read FPreparedCount;
    property PendingCount: Cardinal read FPendingCount;
  end;

  // File, memory and clock services the higher layers need. Every platform
  // has a record with these names; Delphi.IOUring exports it as TIORingPlatform.
  // Failures raise EIORingError (NativeCode = HRESULT).
  TWindowsIORingPlatform = record
  public
    // Read-only, shared for reading and writing (so a file being written by
    // someone else can be read), overlapped. AUnbuffered = FILE_FLAG_NO_BUFFERING,
    // ASequentialHint = FILE_FLAG_SEQUENTIAL_SCAN.
    class function OpenFileForRead(const AFileName: string; const AUnbuffered,
      ASequentialHint: Boolean): THandle; static;
    class procedure CloseFile(const AHandle: THandle); static;
    class function GetFileSize(const AHandle: THandle): Int64; static;
    // Logical sector size of the file's volume: unbuffered I/O must use
    // offsets, sizes and buffer addresses that are multiples of it. 4096 if
    // the system does not tell.
    class function GetSectorSize(const AHandle: THandle): Cardinal; static;
    class function PageSize: Cardinal; static;
    // Page-aligned memory (VirtualAlloc); FreePages(nil) does nothing
    class function AllocPages(const ASize: NativeUInt): Pointer; static;
    class procedure FreePages(const AMemory: Pointer); static;
    // Monotonic clock for statistics
    class function TimestampMicroseconds: UInt64; static;
  end;

implementation

const
  // SubmitIoRing result when its wait times out: HRESULT_FROM_WIN32(ERROR_TIMEOUT)
  // (found by testing; Learn calls it IORING_E_WAIT_TIMEOUT)
  SUBMIT_WAIT_TIMEOUT = HRESULT($800705B4);

  // How long Close sleeps between checks; the event normally wakes it earlier
  CLOSE_WAIT_SLICE_MS = 100;

{$IF SizeOf(TIORingCompletion) <> SizeOf(IORING_CQE)}
  {$MESSAGE FATAL 'TIORingCompletion must have the layout of IORING_CQE'}
{$IFEND}
{$IF SizeOf(TIORingBufferInfo) <> SizeOf(IORING_BUFFER_INFO)}
  {$MESSAGE FATAL 'TIORingBufferInfo must have the layout of IORING_BUFFER_INFO'}
{$IFEND}

type
  TQueryIoRingCapabilities = function(out capabilities: IORING_CAPABILITIES): HRESULT; stdcall;

var
  // 0 = not checked yet, 1 = available, -1 = not available
  GAvailability: Integer = 0;
  GCapabilities: IORING_CAPABILITIES;

// Queries the capabilities without the delayed import, so this works (and
// returns False) on Windows versions without IoRing
function LoadCapabilities(out ACapabilities: IORING_CAPABILITIES): Boolean;
var
  LQuery: TQueryIoRingCapabilities;
begin
  FillChar(ACapabilities, SizeOf(ACapabilities), 0);
  @LQuery := GetProcAddress(GetModuleHandle(IORING_DLL), 'QueryIoRingCapabilities');
  Result := Assigned(LQuery) and (LQuery(ACapabilities) = S_OK);
end;

procedure CheckAvailability;
var
  LCapabilities: IORING_CAPABILITIES;
  LAvailable: Boolean;
begin
  LAvailable := LoadCapabilities(LCapabilities)
    and (LCapabilities.MaxVersion >= IORING_VERSION_4)
    and ((LCapabilities.FeatureFlags and IORING_FEATURE_UM_EMULATION) = 0);

  GCapabilities := LCapabilities;
  if LAvailable then
    GAvailability := 1
  else
    GAvailability := -1;
end;

function NotAvailableMessage: string;
begin
  if GCapabilities.MaxVersion = 0 then
    Result := 'IoRing is not available on this system. Windows 11 24H2 or newer (IoRing version 4) is required.'
  else if GCapabilities.MaxVersion < IORING_VERSION_4 then
    Result := Format('This system has IoRing version %d; version %d (Windows 11 24H2 or newer) is required.',
      [GCapabilities.MaxVersion, IORING_VERSION_4])
  else
    Result := 'IoRing is only emulated in user mode on this system (no kernel support).';
end;

function ToHandleRef(const AFile: TIORingFileRef): IORING_HANDLE_REF; inline;
begin
  if AFile.Registered then
    Result := IoRingHandleRefFromIndex(AFile.Index)
  else
    Result := IoRingHandleRefFromHandle(AFile.Handle);
end;

function ToBufferRef(const ABuffer: TIORingBufferRef): IORING_BUFFER_REF; inline;
begin
  if ABuffer.Registered then
    Result := IoRingBufferRefFromIndexAndOffset(ABuffer.Index, ABuffer.Offset)
  else
    Result := IoRingBufferRefFromPointer(ABuffer.Address);
end;

function ToSqeFlags(const AFlags: TIORingSubmitFlags): IORING_SQE_FLAGS; inline;
begin
  if sfDrainPreceding in AFlags then
    Result := IOSQE_FLAGS_DRAIN_PRECEDING_OPS
  else
    Result := IOSQE_FLAGS_NONE;
end;

function ToWriteFlags(const AWriteThrough: Boolean): FILE_WRITE_FLAGS; inline;
begin
  if AWriteThrough then
    Result := FILE_WRITE_FLAGS_WRITE_THROUGH
  else
    Result := FILE_WRITE_FLAGS_NONE;
end;

function IORingSegment(const AAddress: Pointer): TIORingSegment;
begin
  Result.Alignment := 0;
  Result.Buffer := UInt64(NativeUInt(AAddress));
end;

{ TWindowsIORing - life cycle }

{$IFDEF FPC}
class operator TWindowsIORing.Initialize(var ADest: TWindowsIORing);
{$ELSE}
class operator TWindowsIORing.Initialize(out ADest: TWindowsIORing);
{$ENDIF}
begin
  ADest.FHandle := 0;
  ADest.FCompletionEvent := 0;
  ADest.FSubmissionQueueSize := 0;
  ADest.FCompletionQueueSize := 0;
  ADest.FPreparedCount := 0;
  ADest.FPendingCount := 0;
end;

class operator TWindowsIORing.Finalize(var ADest: TWindowsIORing);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TWindowsIORing.Copy(constref ASource: TWindowsIORing; var ADest: TWindowsIORing);
{$ELSE}
class operator TWindowsIORing.Assign(var ADest: TWindowsIORing; const [ref] ASource: TWindowsIORing);
{$ENDIF}
begin
  raise EInvalidOpException.Create('A ring cannot be copied. Pass it as var or const [ref].');
end;

procedure TWindowsIORing.Open(const ASubmissionQueueSize, ACompletionQueueSize: Cardinal);
var
  LFlags: IORING_CREATE_FLAGS;
  LInfo: IORING_INFO;
  LResult: HRESULT;
begin
  if FHandle <> 0 then
    raise EIORingError.Create('The ring is already open');
  if not Available then
    raise EIORingNotSupported.Create(NotAvailableMessage);

  LFlags.Required := IORING_CREATE_REQUIRED_FLAGS_NONE;
  LFlags.Advisory := IORING_CREATE_ADVISORY_FLAGS_NONE;

  LResult := CreateIoRing(IORING_VERSION_4, LFlags, ASubmissionQueueSize, ACompletionQueueSize, FHandle);
  if LResult <> S_OK then
  begin
    FHandle := 0;
    raise EIORingError.CreateNative(LResult, 'CreateIoRing');
  end;

  try
    LResult := GetIoRingInfo(FHandle, LInfo);
    if LResult <> S_OK then
      raise EIORingError.CreateNative(LResult, 'GetIoRingInfo');
    FSubmissionQueueSize := LInfo.SubmissionQueueSize;
    FCompletionQueueSize := LInfo.CompletionQueueSize;

    // Auto-reset. Close needs it to wait without submitting anything.
    FCompletionEvent := CreateEvent(nil, False, False, nil);
    if FCompletionEvent = 0 then
      RaiseLastOSError;
    LResult := SetIoRingCompletionEvent(FHandle, FCompletionEvent);
    if LResult <> S_OK then
      raise EIORingError.CreateNative(LResult, 'SetIoRingCompletionEvent');
  except
    CloseIoRing(FHandle);
    FHandle := 0;
    if FCompletionEvent <> 0 then
      CloseHandle(FCompletionEvent);
    FCompletionEvent := 0;
    raise;
  end;
end;

procedure TWindowsIORing.WaitForAllPending;
var
  LCqe: IORING_CQE;
begin
  while FPendingCount > 0 do
  begin
    while (FPendingCount > 0) and (PopIoRingCompletion(FHandle, LCqe) = S_OK) do
      Dec(FPendingCount);

    // The queue is empty now, so the next completion signals the event
    if FPendingCount > 0 then
      WaitForSingleObject(FCompletionEvent, CLOSE_WAIT_SLICE_MS);
  end;
end;

procedure TWindowsIORing.Close;
begin
  if FHandle = 0 then
    Exit;

  try
    // CloseIoRing does not cancel submitted operations; wait for them so the
    // kernel is done with the caller's buffers before Close returns
    WaitForAllPending;
  finally
    CloseIoRing(FHandle);
    FHandle := 0;
    if FCompletionEvent <> 0 then
      CloseHandle(FCompletionEvent);
    FCompletionEvent := 0;
    FSubmissionQueueSize := 0;
    FCompletionQueueSize := 0;
    FPreparedCount := 0;
    FPendingCount := 0;
    FKeepAlive := nil;
  end;
end;

function TWindowsIORing.IsOpen: Boolean;
begin
  Result := FHandle <> 0;
end;

{ TWindowsIORing - helpers }

function TWindowsIORing.NoRoom: Boolean;
begin
  if FHandle = 0 then
    raise EIORingError.Create('The ring is not open');
  Result := False;
end;

function TWindowsIORing.BuildFailed(const AResult: HRESULT; const AFunctionName: string): Boolean;
begin
  if AResult = IORING_E_SUBMISSION_QUEUE_FULL then
    Exit(False);
  raise EIORingError.CreateNative(AResult, AFunctionName);
end;

function TWindowsIORing.KeepAlive(const AData: Pointer; const ASize: NativeInt): Pointer;
var
  LCopy: TBytes;
begin
  if ASize = 0 then
    Exit(nil);

  SetLength(LCopy, ASize);
  Move(AData^, LCopy[0], ASize);
  SetLength(FKeepAlive, Length(FKeepAlive) + 1);
  FKeepAlive[High(FKeepAlive)] := LCopy;
  Result := @LCopy[0];
end;

{ TWindowsIORing - prepare }

// Room check: an entry needs a free submission queue slot (Build reports that)
// and room for its completion. Keeping PreparedCount + PendingCount below the
// completion queue size means SubmitIoRing never fails with
// IORING_E_COMPLETION_QUEUE_TOO_FULL.

function TWindowsIORing.PrepareRead(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
  const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags): Boolean;
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingReadFile(FHandle, ToHandleRef(AFile), ToBufferRef(ABuffer), ACount, AOffset,
    AUserData, ToSqeFlags(AFlags));
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingReadFile');
end;

function TWindowsIORing.PrepareWrite(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
  const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags; const AWriteThrough: Boolean): Boolean;
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingWriteFile(FHandle, ToHandleRef(AFile), ToBufferRef(ABuffer), ACount, AOffset,
    ToWriteFlags(AWriteThrough), AUserData, ToSqeFlags(AFlags));
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingWriteFile');
end;

function TWindowsIORing.PrepareFlush(const AFile: TIORingFileRef; const AMode: TIORingFlushMode;
  const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags): Boolean;
const
  FLUSH_MODES: array[TIORingFlushMode] of FILE_FLUSH_MODE =
    (FILE_FLUSH_DEFAULT, FILE_FLUSH_DATA, FILE_FLUSH_MIN_METADATA, FILE_FLUSH_NO_SYNC);
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingFlushFile(FHandle, ToHandleRef(AFile), FLUSH_MODES[AMode], AUserData,
    ToSqeFlags(AFlags));
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingFlushFile');
end;

function TWindowsIORing.PrepareReadScatter(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
  const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags): Boolean;
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingReadFileScatter(FHandle, ToHandleRef(AFile), ASegmentCount, ASegments, ACount,
    AOffset, AUserData, ToSqeFlags(AFlags));
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingReadFileScatter');
end;

function TWindowsIORing.PrepareWriteGather(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
  const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags; const AWriteThrough: Boolean): Boolean;
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingWriteFileGather(FHandle, ToHandleRef(AFile), ASegmentCount, ASegments, ACount,
    AOffset, ToWriteFlags(AWriteThrough), AUserData, ToSqeFlags(AFlags));
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingWriteFileGather');
end;

function TWindowsIORing.PrepareCancel(const AFile: TIORingFileRef; const ATargetUserData,
  AUserData: TIORingUserData): Boolean;
var
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  LResult := BuildIoRingCancelRequest(FHandle, ToHandleRef(AFile), ATargetUserData, AUserData);
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingCancelRequest');
end;

function TWindowsIORing.PrepareRegisterFiles(const AHandles: array of THandle;
  const AUserData: TIORingUserData): Boolean;
var
  LHandles: PHandle;
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  if Length(AHandles) > 0 then
    LHandles := KeepAlive(@AHandles[0], Length(AHandles) * SizeOf(THandle))
  else
    LHandles := nil;

  LResult := BuildIoRingRegisterFileHandles(FHandle, Length(AHandles), LHandles, AUserData);
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingRegisterFileHandles');
end;

function TWindowsIORing.PrepareRegisterBuffers(const ABuffers: array of TIORingBufferInfo;
  const AUserData: TIORingUserData): Boolean;
var
  LBuffers: PIORING_BUFFER_INFO;
  LResult: HRESULT;
begin
  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(NoRoom);

  // TIORingBufferInfo has the layout of IORING_BUFFER_INFO (checked above)
  if Length(ABuffers) > 0 then
    LBuffers := KeepAlive(@ABuffers[0], Length(ABuffers) * SizeOf(TIORingBufferInfo))
  else
    LBuffers := nil;

  LResult := BuildIoRingRegisterBuffers(FHandle, Length(ABuffers), LBuffers, AUserData);
  if LResult = S_OK then
  begin
    Inc(FPreparedCount);
    Result := True;
  end
  else
    Result := BuildFailed(LResult, 'BuildIoRingRegisterBuffers');
end;

{ TWindowsIORing - submit and reap }

function TWindowsIORing.SubmitAndWait(const AWaitCount, ATimeoutMs: Cardinal): Boolean;
var
  LWaitCount: Cardinal;
  LResult: HRESULT;
begin
  if FHandle = 0 then
    raise EIORingError.Create('The ring is not open');

  // Never wait for more completions than there can be
  LWaitCount := AWaitCount;
  if LWaitCount > FPreparedCount + FPendingCount then
    LWaitCount := FPreparedCount + FPendingCount;

  if (FPreparedCount = 0) and (LWaitCount = 0) then
    Exit(True);

  LResult := SubmitIoRing(FHandle, LWaitCount, ATimeoutMs, nil);
  if (LResult <> S_OK) and (LResult <> SUBMIT_WAIT_TIMEOUT) then
    raise EIORingError.CreateNative(LResult, 'SubmitIoRing');  // all entries stay prepared

  // Also on a wait timeout every prepared entry was submitted
  Inc(FPendingCount, FPreparedCount);
  FPreparedCount := 0;
  Result := LResult = S_OK;
end;

function TWindowsIORing.Submit(const AWaitCount, ATimeoutMs: Cardinal): Cardinal;
begin
  Result := FPreparedCount;
  SubmitAndWait(AWaitCount, ATimeoutMs);
end;

function TWindowsIORing.WaitForCompletions(const ACount, ATimeoutMs: Cardinal): Boolean;
begin
  Result := SubmitAndWait(ACount, ATimeoutMs);
end;

function TWindowsIORing.TryPopCompletion(out ACompletion: TIORingCompletion): Boolean;
begin
  if FPendingCount = 0 then
    Exit(False);

  // TIORingCompletion has the layout of IORING_CQE (checked above)
  Result := PopIoRingCompletion(FHandle, PIORING_CQE(@ACompletion)^) = S_OK;
  if Result then
  begin
    Dec(FPendingCount);
    // Nothing in flight and nothing prepared: no registration array is needed any more
    if (FPendingCount = 0) and (FPreparedCount = 0) and (FKeepAlive <> nil) then
      FKeepAlive := nil;
  end;
end;

function TWindowsIORing.PopCompletions(var ACompletions: array of TIORingCompletion): Integer;
begin
  Result := 0;
  while (Result <= High(ACompletions)) and TryPopCompletion(ACompletions[Result]) do
    Inc(Result);
end;

function TWindowsIORing.CompletionEventHandle: THandle;
begin
  Result := FCompletionEvent;
end;

{ TWindowsIORing - capabilities }

class function TWindowsIORing.Available: Boolean;
begin
  if GAvailability = 0 then
    CheckAvailability;
  Result := GAvailability > 0;
end;

class function TWindowsIORing.QueryCapabilities: TIORingCapabilities;
var
  LCapabilities: IORING_CAPABILITIES;
begin
  Result.BackendName := '';
  Result.NativeVersion := 0;
  Result.MaxSubmissionQueueSize := 0;
  Result.MaxCompletionQueueSize := 0;
  Result.SupportedOps := [];
  Result.Emulated := False;

  if not LoadCapabilities(LCapabilities) then
    Exit;

  Result.BackendName := 'Windows IoRing';
  Result.NativeVersion := LCapabilities.MaxVersion;
  Result.MaxSubmissionQueueSize := LCapabilities.MaxSubmissionQueueSize;
  Result.MaxCompletionQueueSize := LCapabilities.MaxCompletionQueueSize;
  Result.Emulated := (LCapabilities.FeatureFlags and IORING_FEATURE_UM_EMULATION) <> 0;

  if LCapabilities.MaxVersion >= IORING_VERSION_1 then
    Result.SupportedOps := [ioRead, ioCancel, ioRegisterFiles, ioRegisterBuffers];
  if LCapabilities.MaxVersion >= IORING_VERSION_3 then
    Result.SupportedOps := Result.SupportedOps + [ioWrite, ioFlush];
  if LCapabilities.MaxVersion >= IORING_VERSION_4 then
    Result.SupportedOps := Result.SupportedOps + [ioReadScatter, ioWriteGather];
end;

{ TWindowsIORingPlatform }

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

const
  FILE_INFO_CLASS_STORAGE_INFO = 16;  // FILE_INFO_BY_HANDLE_CLASS.FileStorageInfo
  DEFAULT_SECTOR_SIZE = 4096;

function GetFileInformationByHandleEx(hFile: THandle; FileInformationClass: Integer;
  lpFileInformation: Pointer; dwBufferSize: DWORD): BOOL; stdcall; external kernel32;

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
var
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED;
  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;
  if ASequentialHint then
    LFlags := LFlags or FILE_FLAG_SEQUENTIAL_SCAN;

  Result := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil,
    OPEN_EXISTING, LFlags, 0);
  if Result = INVALID_HANDLE_VALUE then
    raise EIORingError.CreateNative(LastErrorAsHResult, 'Open "' + AFileName + '"');
end;

class procedure TWindowsIORingPlatform.CloseFile(const AHandle: THandle);
begin
  CloseHandle(AHandle);
end;

class function TWindowsIORingPlatform.GetFileSize(const AHandle: THandle): Int64;
begin
  if not IORingGetFileSizeEx(AHandle, Result) then
    raise EIORingError.CreateNative(LastErrorAsHResult, 'GetFileSizeEx');
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
begin
  Result := VirtualAlloc(nil, ASize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  if Result = nil then
    raise EIORingError.CreateNative(LastErrorAsHResult, 'VirtualAlloc');
end;

class procedure TWindowsIORingPlatform.FreePages(const AMemory: Pointer);
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

end.
