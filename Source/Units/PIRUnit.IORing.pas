unit PIRUnit.IORing;

{
  The unit user code normally uses.

  TIORing is the ring of the current platform (a compile-time alias, so calls are direct, Docs/Design.md §4).
  The other types are re-exported here, so "uses PIRUnit.IORing" is enough.

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

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Types
{$IFDEF MSWINDOWS}
  , PIRUnit.Windows.Ring, PIRUnit.Windows.Platform
{$ENDIF}
{$IFDEF LINUX}
  , PIRUnit.Linux.Ring, PIRUnit.Linux.Platform
{$ENDIF}
  ;

const
  IORING_LIBRARY_VERSION = PIRUnit.Types.IORING_LIBRARY_VERSION;
  IORING_INFINITE = PIRUnit.Types.IORING_INFINITE;
{$IFDEF MSWINDOWS}
  IORING_RESULT_END_OF_FILE = PIRUnit.Types.IORING_RESULT_END_OF_FILE;
  IORING_RESULT_CANCELLED = PIRUnit.Types.IORING_RESULT_CANCELLED;
{$ENDIF}
{$IFDEF LINUX}
  IORING_RESULT_CANCELLED = PIRUnit.Types.IORING_RESULT_CANCELLED;
{$ENDIF}

type
  TIORingUserData = PIRUnit.Types.TIORingUserData;
  TIORingOp = PIRUnit.Types.TIORingOp;
  TIORingOps = PIRUnit.Types.TIORingOps;
  TIORingSubmitFlag = PIRUnit.Types.TIORingSubmitFlag;
  TIORingSubmitFlags = PIRUnit.Types.TIORingSubmitFlags;
  TIORingFlushMode = PIRUnit.Types.TIORingFlushMode;
  TIORingExtra = PIRUnit.Types.TIORingExtra;
  TIORingExtras = PIRUnit.Types.TIORingExtras;
  TIORingNativeOps = PIRUnit.Types.TIORingNativeOps;
  TIORingCapabilities = PIRUnit.Types.TIORingCapabilities;
  TIORingFileRef = PIRUnit.Types.TIORingFileRef;
  TIORingBufferRef = PIRUnit.Types.TIORingBufferRef;
  TIORingBufferInfo = PIRUnit.Types.TIORingBufferInfo;
  PIORingBufferInfo = PIRUnit.Types.PIORingBufferInfo;
  TIORingCompletion = PIRUnit.Types.TIORingCompletion;
  PIORingCompletion = PIRUnit.Types.PIORingCompletion;
  EIORingError = PIRUnit.Types.EIORingError;
  EIORingNotSupported = PIRUnit.Types.EIORingNotSupported;

{$IFDEF MSWINDOWS}
  TIORing = PIRUnit.Windows.Ring.TWindowsIORing;
  TIORingPlatform = PIRUnit.Windows.Platform.TWindowsIORingPlatform;
  TIORingSegment = PIRUnit.Windows.Ring.TIORingSegment;
  PIORingSegment = PIRUnit.Windows.Ring.PIORingSegment;
{$ENDIF}
{$IFDEF LINUX}
  TIORing = PIRUnit.Linux.Ring.TLinuxIORing;
  TIORingPlatform = PIRUnit.Linux.Platform.TLinuxIORingPlatform;
  TIORingSegment = PIRUnit.Linux.Ring.TIORingSegment;
  PIORingSegment = PIRUnit.Linux.Ring.PIORingSegment;
{$ENDIF}

// Enumeration values are not visible through a type alias; re-export them too
const
  ioRead = PIRUnit.Types.ioRead;
  ioWrite = PIRUnit.Types.ioWrite;
  ioFlush = PIRUnit.Types.ioFlush;
  ioCancel = PIRUnit.Types.ioCancel;
  ioRegisterFiles = PIRUnit.Types.ioRegisterFiles;
  ioRegisterBuffers = PIRUnit.Types.ioRegisterBuffers;
  ioReadScatter = PIRUnit.Types.ioReadScatter;
  ioWriteGather = PIRUnit.Types.ioWriteGather;

  sfDrainPreceding = PIRUnit.Types.sfDrainPreceding;

  rfmDefault = PIRUnit.Types.rfmDefault;
  rfmData = PIRUnit.Types.rfmData;
  rfmMinMetadata = PIRUnit.Types.rfmMinMetadata;
  rfmNoSync = PIRUnit.Types.rfmNoSync;
  ieSockets = PIRUnit.Types.ieSockets;
  ieLinkedOps = PIRUnit.Types.ieLinkedOps;
  ieSqPoll = PIRUnit.Types.ieSqPoll;
  ieRawEntries = PIRUnit.Types.ieRawEntries;

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
  Result := PIRUnit.Types.IORingErrorMessage(ANativeCode);
end;

function IORingSegment(const AAddress: Pointer): TIORingSegment;
begin
{$IFDEF MSWINDOWS}
  Result := PIRUnit.Windows.Ring.IORingSegment(AAddress);
{$ENDIF}

{$IFDEF LINUX}
  Result := PIRUnit.Linux.Ring.IORingSegment(AAddress);
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