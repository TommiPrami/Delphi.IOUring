unit Delphi.IOUring;

// The unit user code normally uses.
//
// TIORing is the ring of the current platform (a compile-time alias, so calls
// are direct, Docs/Design.md §4). The other types are re-exported here, so
// "uses Delphi.IOUring" is enough.
//
//   var
//     LRing: TIORing;
//   begin
//     LRing.Open;                       // closed automatically at the end of scope
//     LRing.PrepareRead(TIORingFileRef.FromHandle(LFile),
//       TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1);
//     LRing.Submit(1);                  // submit and wait for one completion
//     if LRing.TryPopCompletion(LCompletion) then
//       LCompletion.RaiseIfFailed('Read');
//   end;

{$I Delphi.IOUring.inc}

interface

uses
  Delphi.IOUring.Backend.Custom
{$IFDEF MSWINDOWS}
  , Delphi.IOUring.Backend.Windows
{$ENDIF}
{$IFDEF LINUX}
  , Delphi.IOUring.Backend.Posix
{$ENDIF}
  ;

const
  IORING_LIBRARY_VERSION = Delphi.IOUring.Backend.Custom.IORING_LIBRARY_VERSION;
  IORING_INFINITE = Delphi.IOUring.Backend.Custom.IORING_INFINITE;
{$IFDEF MSWINDOWS}
  IORING_RESULT_END_OF_FILE = Delphi.IOUring.Backend.Custom.IORING_RESULT_END_OF_FILE;
  IORING_RESULT_CANCELLED = Delphi.IOUring.Backend.Custom.IORING_RESULT_CANCELLED;
{$ENDIF}
{$IFDEF LINUX}
  IORING_RESULT_CANCELLED = Delphi.IOUring.Backend.Custom.IORING_RESULT_CANCELLED;
{$ENDIF}

type
  TIORingUserData = Delphi.IOUring.Backend.Custom.TIORingUserData;
  TIORingOp = Delphi.IOUring.Backend.Custom.TIORingOp;
  TIORingOps = Delphi.IOUring.Backend.Custom.TIORingOps;
  TIORingSubmitFlag = Delphi.IOUring.Backend.Custom.TIORingSubmitFlag;
  TIORingSubmitFlags = Delphi.IOUring.Backend.Custom.TIORingSubmitFlags;
  TIORingFlushMode = Delphi.IOUring.Backend.Custom.TIORingFlushMode;
  TIORingExtra = Delphi.IOUring.Backend.Custom.TIORingExtra;
  TIORingExtras = Delphi.IOUring.Backend.Custom.TIORingExtras;
  TIORingNativeOps = Delphi.IOUring.Backend.Custom.TIORingNativeOps;
  TIORingCapabilities = Delphi.IOUring.Backend.Custom.TIORingCapabilities;
  TIORingFileRef = Delphi.IOUring.Backend.Custom.TIORingFileRef;
  TIORingBufferRef = Delphi.IOUring.Backend.Custom.TIORingBufferRef;
  TIORingBufferInfo = Delphi.IOUring.Backend.Custom.TIORingBufferInfo;
  PIORingBufferInfo = Delphi.IOUring.Backend.Custom.PIORingBufferInfo;
  TIORingCompletion = Delphi.IOUring.Backend.Custom.TIORingCompletion;
  PIORingCompletion = Delphi.IOUring.Backend.Custom.PIORingCompletion;
  EIORingError = Delphi.IOUring.Backend.Custom.EIORingError;
  EIORingNotSupported = Delphi.IOUring.Backend.Custom.EIORingNotSupported;

{$IFDEF MSWINDOWS}
  TIORing = Delphi.IOUring.Backend.Windows.TWindowsIORing;
  TIORingPlatform = Delphi.IOUring.Backend.Windows.TWindowsIORingPlatform;
  TIORingSegment = Delphi.IOUring.Backend.Windows.TIORingSegment;
  PIORingSegment = Delphi.IOUring.Backend.Windows.PIORingSegment;
{$ENDIF}
{$IFDEF LINUX}
  TIORing = Delphi.IOUring.Backend.Posix.TLinuxIORing;
  TIORingPlatform = Delphi.IOUring.Backend.Posix.TLinuxIORingPlatform;
  TIORingSegment = Delphi.IOUring.Backend.Posix.TIORingSegment;
  PIORingSegment = Delphi.IOUring.Backend.Posix.PIORingSegment;
{$ENDIF}

// Enumeration values are not visible through a type alias; re-export them too
const
  ioRead = Delphi.IOUring.Backend.Custom.ioRead;
  ioWrite = Delphi.IOUring.Backend.Custom.ioWrite;
  ioFlush = Delphi.IOUring.Backend.Custom.ioFlush;
  ioCancel = Delphi.IOUring.Backend.Custom.ioCancel;
  ioRegisterFiles = Delphi.IOUring.Backend.Custom.ioRegisterFiles;
  ioRegisterBuffers = Delphi.IOUring.Backend.Custom.ioRegisterBuffers;
  ioReadScatter = Delphi.IOUring.Backend.Custom.ioReadScatter;
  ioWriteGather = Delphi.IOUring.Backend.Custom.ioWriteGather;

  sfDrainPreceding = Delphi.IOUring.Backend.Custom.sfDrainPreceding;

  rfmDefault = Delphi.IOUring.Backend.Custom.rfmDefault;
  rfmData = Delphi.IOUring.Backend.Custom.rfmData;
  rfmMinMetadata = Delphi.IOUring.Backend.Custom.rfmMinMetadata;
  rfmNoSync = Delphi.IOUring.Backend.Custom.rfmNoSync;
  ieSockets = Delphi.IOUring.Backend.Custom.ieSockets;
  ieLinkedOps = Delphi.IOUring.Backend.Custom.ieLinkedOps;
  ieSqPoll = Delphi.IOUring.Backend.Custom.ieSqPoll;
  ieRawEntries = Delphi.IOUring.Backend.Custom.ieRawEntries;

// True if the ring can be used on this system
function IORingAvailable: Boolean;
// What the ring offers on this system, and the system itself (for logs:
// IORingCapabilities.ToString)
function IORingCapabilities: TIORingCapabilities;

// Readable text for an OS result code (TIORingCompletion.NativeResult)
function IORingErrorMessage(const ANativeCode: Integer): string;

// One scatter/gather segment (a page-sized, page-aligned buffer)
function IORingSegment(const AAddress: Pointer): TIORingSegment;

// Blocking helpers: prepare, submit, wait, pop. They need an idle ring
// (nothing prepared or in flight) and raise EIORingError on failure.
// ReadAt returns the bytes read; 0 at or after the end of the file.
function ReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;
function WriteAt(var ARing: TIORing; const AFile: TIORingFileRef; const ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;

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
  Result := Delphi.IOUring.Backend.Custom.IORingErrorMessage(ANativeCode);
end;

function IORingSegment(const AAddress: Pointer): TIORingSegment;
begin
{$IFDEF MSWINDOWS}
  Result := Delphi.IOUring.Backend.Windows.IORingSegment(AAddress);
{$ENDIF}
{$IFDEF LINUX}
  Result := Delphi.IOUring.Backend.Posix.IORingSegment(AAddress);
{$ENDIF}
end;

procedure CheckIdle(var ARing: TIORing; const AOperation: string);
begin
  if (ARing.PreparedCount <> 0) or (ARing.PendingCount <> 0) then
    raise EIORingError.Create(AOperation + ' needs an idle ring (nothing prepared or in flight)');
end;

function WaitForSingleCompletion(var ARing: TIORing; const AOperation: string): TIORingCompletion;
begin
  ARing.Submit(1);
  if not ARing.TryPopCompletion(Result) then
    raise EIORingError.Create(AOperation + ': no completion after the wait');
end;

function ReadAt(var ARing: TIORing; const AFile: TIORingFileRef; var ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;
var
  LCompletion: TIORingCompletion;
begin
  CheckIdle(ARing, 'ReadAt');
  if not ARing.PrepareRead(AFile, TIORingBufferRef.FromPointer(@ABuffer), ACount, AOffset, 0) then
    raise EIORingError.Create('ReadAt: no room in the ring');

  LCompletion := WaitForSingleCompletion(ARing, 'ReadAt');
  if LCompletion.IsEndOfFile then
    Exit(0);
  LCompletion.RaiseIfFailed('ReadAt');
  Result := LCompletion.BytesTransferred;
end;

function WriteAt(var ARing: TIORing; const AFile: TIORingFileRef; const ABuffer;
  const ACount: Cardinal; const AOffset: UInt64): Cardinal;
var
  LCompletion: TIORingCompletion;
begin
  CheckIdle(ARing, 'WriteAt');
  if not ARing.PrepareWrite(AFile, TIORingBufferRef.FromPointer(@ABuffer), ACount, AOffset, 0) then
    raise EIORingError.Create('WriteAt: no room in the ring');

  LCompletion := WaitForSingleCompletion(ARing, 'WriteAt');
  LCompletion.RaiseIfFailed('WriteAt');
  Result := LCompletion.BytesTransferred;
end;

end.
