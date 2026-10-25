unit Pascal.IOUring;

{
  The unit user code normally uses.

  TIORing is the ring of the current platform (a compile-time alias, so calls are direct, Docs/Design.md §4).
  The other types are re-exported here, so "uses Pascal.IOUring" is enough.

  var
    LRing: TIORing;
  begin
    LRing.Open; // closed automatically at the end of scope
    LRing.PrepareRead(TIORingFileRef.FromHandle(LFile), TIORingBufferRef.FromPointer(@LBuffer),
      SizeOf(LBuffer), 0, 1);
   LRing.Submit(1); // submit and wait for one completion

   if LRing.TryPopCompletion(LCompletion) then
     LCompletion.RaiseIfFailed('Read');
 end;
}

{$I Pascal.IOUring.inc}

interface

uses
  Pascal.IOUring.Types
{$IFDEF MSWINDOWS}
  , Pascal.IOUring.Backend.Windows, Pascal.IOUring.Backend.Windows.Platform
{$ENDIF}
{$IFDEF LINUX}
  , Pascal.IOUring.Backend.Linux, Pascal.IOUring.Backend.Linux.Platform
{$ENDIF}
  ;

const
  IORING_LIBRARY_VERSION = Pascal.IOUring.Types.IORING_LIBRARY_VERSION;
  IORING_INFINITE = Pascal.IOUring.Types.IORING_INFINITE;
{$IFDEF MSWINDOWS}
  IORING_RESULT_END_OF_FILE = Pascal.IOUring.Types.IORING_RESULT_END_OF_FILE;
  IORING_RESULT_CANCELLED = Pascal.IOUring.Types.IORING_RESULT_CANCELLED;
{$ENDIF}
{$IFDEF LINUX}
  IORING_RESULT_CANCELLED = Pascal.IOUring.Types.IORING_RESULT_CANCELLED;
{$ENDIF}

type
  TIORingUserData = Pascal.IOUring.Types.TIORingUserData;
  TIORingOp = Pascal.IOUring.Types.TIORingOp;
  TIORingOps = Pascal.IOUring.Types.TIORingOps;
  TIORingSubmitFlag = Pascal.IOUring.Types.TIORingSubmitFlag;
  TIORingSubmitFlags = Pascal.IOUring.Types.TIORingSubmitFlags;
  TIORingFlushMode = Pascal.IOUring.Types.TIORingFlushMode;
  TIORingExtra = Pascal.IOUring.Types.TIORingExtra;
  TIORingExtras = Pascal.IOUring.Types.TIORingExtras;
  TIORingNativeOps = Pascal.IOUring.Types.TIORingNativeOps;
  TIORingCapabilities = Pascal.IOUring.Types.TIORingCapabilities;
  TIORingFileRef = Pascal.IOUring.Types.TIORingFileRef;
  TIORingBufferRef = Pascal.IOUring.Types.TIORingBufferRef;
  TIORingBufferInfo = Pascal.IOUring.Types.TIORingBufferInfo;
  PIORingBufferInfo = Pascal.IOUring.Types.PIORingBufferInfo;
  TIORingCompletion = Pascal.IOUring.Types.TIORingCompletion;
  PIORingCompletion = Pascal.IOUring.Types.PIORingCompletion;
  EIORingError = Pascal.IOUring.Types.EIORingError;
  EIORingNotSupported = Pascal.IOUring.Types.EIORingNotSupported;

{$IFDEF MSWINDOWS}
  TIORing = Pascal.IOUring.Backend.Windows.TWindowsIORing;
  TIORingPlatform = Pascal.IOUring.Backend.Windows.Platform.TWindowsIORingPlatform;
  TIORingSegment = Pascal.IOUring.Backend.Windows.TIORingSegment;
  PIORingSegment = Pascal.IOUring.Backend.Windows.PIORingSegment;
{$ENDIF}
{$IFDEF LINUX}
  TIORing = Pascal.IOUring.Backend.Linux.TLinuxIORing;
  TIORingPlatform = Pascal.IOUring.Backend.Linux.Platform.TLinuxIORingPlatform;
  TIORingSegment = Pascal.IOUring.Backend.Linux.TIORingSegment;
  PIORingSegment = Pascal.IOUring.Backend.Linux.PIORingSegment;
{$ENDIF}

// Enumeration values are not visible through a type alias; re-export them too
const
  ioRead = Pascal.IOUring.Types.ioRead;
  ioWrite = Pascal.IOUring.Types.ioWrite;
  ioFlush = Pascal.IOUring.Types.ioFlush;
  ioCancel = Pascal.IOUring.Types.ioCancel;
  ioRegisterFiles = Pascal.IOUring.Types.ioRegisterFiles;
  ioRegisterBuffers = Pascal.IOUring.Types.ioRegisterBuffers;
  ioReadScatter = Pascal.IOUring.Types.ioReadScatter;
  ioWriteGather = Pascal.IOUring.Types.ioWriteGather;

  sfDrainPreceding = Pascal.IOUring.Types.sfDrainPreceding;

  rfmDefault = Pascal.IOUring.Types.rfmDefault;
  rfmData = Pascal.IOUring.Types.rfmData;
  rfmMinMetadata = Pascal.IOUring.Types.rfmMinMetadata;
  rfmNoSync = Pascal.IOUring.Types.rfmNoSync;
  ieSockets = Pascal.IOUring.Types.ieSockets;
  ieLinkedOps = Pascal.IOUring.Types.ieLinkedOps;
  ieSqPoll = Pascal.IOUring.Types.ieSqPoll;
  ieRawEntries = Pascal.IOUring.Types.ieRawEntries;

  // True if the ring can be used on this system
  function IORingAvailable: Boolean;
  // What the ring offers on this system, and the system itself (for logs: IORingCapabilities.ToString)
  function IORingCapabilities: TIORingCapabilities;

  // Readable text for an OS result code (TIORingCompletion.NativeResult)
  function IORingErrorMessage(const ANativeCode: Integer): string;

  // One scatter/gather segment (a page-sized, page-aligned buffer)
  function IORingSegment(const AAddress: Pointer): TIORingSegment;

  { Blocking helpers: prepare, submit, wait, pop. They need an idle ring (nothing prepared or in flight) and raise
    EIORingError on failure. IORingReadAt returns the bytes read; 0 at or after the end of the file. }
  function IORingReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer; const ACount: Cardinal;
    const AOffset: UInt64): Cardinal;
  function IORingWriteAt(var ARing: TIORing; const AFile: TIORingFileRef; const ABuffer; const ACount: Cardinal;
    const AOffset: UInt64): Cardinal;

implementation

function IORingAvailable: Boolean;
begin
  Result := TIORing.Available;
end;

function IORingCapabilities: TIORingCapabilities;
begin
  Result := TIORing.QueryCapabilities;
end;

function IORingErrorMessage(const ANativeCode: Integer): string;
begin
  Result := Pascal.IOUring.Types.IORingErrorMessage(ANativeCode);
end;

function IORingSegment(const AAddress: Pointer): TIORingSegment;
begin
{$IFDEF MSWINDOWS}
  Result := Pascal.IOUring.Backend.Windows.IORingSegment(AAddress);
{$ENDIF}

{$IFDEF LINUX}
  Result := Pascal.IOUring.Backend.Linux.IORingSegment(AAddress);
{$ENDIF}
end;

procedure CheckIdle(var ARing: TIORing; const AOperation: string);

  procedure RaiseNotIdle(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('%s needs an idle ring (nothing prepared or in flight)', [AName]);
  end;

begin
  if (ARing.PreparedCount <> 0) or (ARing.PendingCount <> 0) then
    RaiseNotIdle(AOperation);
end;

function WaitForSingleCompletion(var ARing: TIORing; const AOperation: string): TIORingCompletion;

  procedure RaiseNoCompletion(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('%s: no completion after the wait', [AName]);
  end;

begin
  ARing.Submit(1);

  if not ARing.TryPopCompletion(Result) then
    RaiseNoCompletion(AOperation);
end;

function IORingReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer; const ACount: Cardinal;
  const AOffset: UInt64): Cardinal;

  procedure RaiseNoRoom; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('IORingReadAt: no room in the ring');
  end;

var
  LCompletion: TIORingCompletion;
begin
  CheckIdle(ARing, 'IORingReadAt');

  if not ARing.PrepareRead(AFile, TIORingBufferRef.FromPointer(@ABuffer), ACount, AOffset, 0) then
    RaiseNoRoom;

  LCompletion := WaitForSingleCompletion(ARing, 'IORingReadAt');

  if LCompletion.IsEndOfFile then
    Exit(0);

  LCompletion.RaiseIfFailed('IORingReadAt');

  Result := LCompletion.BytesTransferred;
end;

function IORingWriteAt(var ARing: TIORing; const AFile: TIORingFileRef; const ABuffer; const ACount: Cardinal;
  const AOffset: UInt64): Cardinal;

  procedure RaiseNoRoom; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('IORingWriteAt: no room in the ring');
  end;

var
  LCompletion: TIORingCompletion;
begin
  CheckIdle(ARing, 'IORingWriteAt');

  if not ARing.PrepareWrite(AFile, TIORingBufferRef.FromPointer(@ABuffer), ACount, AOffset, 0) then
    RaiseNoRoom;

  LCompletion := WaitForSingleCompletion(ARing, 'IORingWriteAt');
  LCompletion.RaiseIfFailed('IORingWriteAt');

  Result := LCompletion.BytesTransferred;
end;

end.