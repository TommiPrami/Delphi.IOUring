unit PIRUnit.Windows.API;

{
  Complete translation of the Windows IoRing API:
    ioringapi.h, ntioring_x.h (Windows SDK 10.0.26100), the IoRing related
    parts of winbase.h (FILE_WRITE_FLAGS, FILE_FLUSH_MODE) and winnt.h
    (FILE_SEGMENT_ELEMENT), and the IORING_E_* codes of winerror.h.

  This unit is standalone: it depends only on the Windows API unit of the RTL, has no initialization section, no global
  state and raises no exceptions. Other projects can use it without the rest of Pascal.IOUring.

  Names are the original C names. With Delphi all functions are "delayed" imports, so a program using this unit still
  loads on Windows versions without IoRing (or with an older IoRing version); calling a function the OS does not have
  raises a delay-load error at the call. Check QueryIoRingCapabilities first. Free Pascal 3.2.2 has no "delayed"; there
  each function looks itself up with GetProcAddress on its first call, and a function Windows does not have returns
  E_NOTIMPL (see the end of the unit).

  Behaviour found by testing (Windows 11 build 26300) that differs from, or is
  missing in, the documentation:
  - PopIoRingCompletion returning S_FALSE zeroes cqe (Learn: "unmodified").
  - SubmitIoRing whose wait times out returns HRESULT_FROM_WIN32(ERROR_TIMEOUT)
    (0x800705B4). The entries are submitted, but submittedEntries is not written.
  - While one thread waits inside SubmitIoRing, a SubmitIoRing on another
    thread fails with IORING_E_SUBMIT_IN_PROGRESS.
  - Scatter/gather needs a handle opened with FILE_FLAG_NO_BUFFERING; on a
    buffered handle the completion is E_INVALIDARG.
  - Reads crossing EOF complete with S_OK and a short count; reads starting at
    or after EOF complete with HRESULT_FROM_WIN32(ERROR_HANDLE_EOF), 0 bytes.
  - Handles opened without FILE_FLAG_OVERLAPPED work too.

  Versions (IORING_VERSION) and what they add:
    1   (Windows 11 21H2, build 22000) read, register files/buffers, cancel
    2   fix: completion event could miss the empty -> non-empty signal
    300 (Windows 11 22H2) write, flush, IOSQE_FLAGS_DRAIN_PRECEDING_OPS
    400 (Windows 11 24H2) read scatter, write gather

  Documentation: https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/ (Learn has no pages for the version 3
  and 4 functions; the SDK header is the reference for those.)
}

// Standalone on purpose: no PIRInclude.Compiler.inc, the needed switches are here.
{$IFDEF FPC}
  {$MODE DELPHI}
  {$PACKRECORDS C}
{$ELSE}
  {$ALIGN 8}
  {$WARN SYMBOL_PLATFORM OFF} // "delayed" is Windows-only, as is this unit
{$ENDIF}
{$MINENUMSIZE 4}

interface

uses
{$IFDEF FPC}
  Windows;
{$ELSE}
  Winapi.Windows;
{$ENDIF}

const
  IORING_DLL = 'kernel32.dll';

{ ---------------------------------------------------------------------------- }
{ Handle                                                                       }
{ ---------------------------------------------------------------------------- }

type
  // DECLARE_HANDLE(HIORING). Close with CloseIoRing, not CloseHandle.
  HIORING = type NativeUInt;
  PHIORING = ^HIORING;

{ ---------------------------------------------------------------------------- }
{ Enumerations. C enums are 4 bytes; declared as Cardinal + constants.         }
{ ---------------------------------------------------------------------------- }

type
  IORING_VERSION = Cardinal;
  PIORING_VERSION = ^IORING_VERSION;

const
  IORING_VERSION_INVALID = 0;
  IORING_VERSION_1 = 1;
  { Minor update: fixes a race where the completion event could stay unsignalled. On version 1, wait on the
    event only with a timeout. }
  IORING_VERSION_2 = 2;
  // Major update: adds write, flush and drain support
  IORING_VERSION_3 = 300;
  // Major update: adds scatter/gather support
  IORING_VERSION_4 = 400;

type
  IORING_FEATURE_FLAGS = Cardinal;
  PIORING_FEATURE_FLAGS = ^IORING_FEATURE_FLAGS;

const
  IORING_FEATURE_FLAGS_NONE = 0;
  // IoRing is emulated in user mode (no kernel support): works, but slow
  IORING_FEATURE_UM_EMULATION = $00000001;
  // SetIoRingCompletionEvent is available and supported
  IORING_FEATURE_SET_COMPLETION_EVENT = $00000002;

type
  IORING_OP_CODE = Cardinal;
  PIORING_OP_CODE = ^IORING_OP_CODE;

const
  IORING_OP_NOP = 0;              // no I/O; no Build* function exists for it
  IORING_OP_READ = 1;
  IORING_OP_REGISTER_FILES = 2;
  IORING_OP_REGISTER_BUFFERS = 3;
  IORING_OP_CANCEL = 4;
  IORING_OP_WRITE = 5;            // version 3
  IORING_OP_FLUSH = 6;            // version 3
  IORING_OP_READ_SCATTER = 7;     // version 4
  IORING_OP_WRITE_GATHER = 8;     // version 4

type
  IORING_SQE_FLAGS = Cardinal;
  PIORING_SQE_FLAGS = ^IORING_SQE_FLAGS;

const
  IOSQE_FLAGS_NONE = 0;
  // The entry starts only after all earlier entries have completed (version 3)
  IOSQE_FLAGS_DRAIN_PRECEDING_OPS = $00000001;

type
  IORING_CREATE_REQUIRED_FLAGS = Cardinal;
  PIORING_CREATE_REQUIRED_FLAGS = ^IORING_CREATE_REQUIRED_FLAGS;

const
  IORING_CREATE_REQUIRED_FLAGS_NONE = 0;

type
  IORING_CREATE_ADVISORY_FLAGS = Cardinal;
  PIORING_CREATE_ADVISORY_FLAGS = ^IORING_CREATE_ADVISORY_FLAGS;

const
  IORING_CREATE_ADVISORY_FLAGS_NONE = 0;
  // Skip argument validation in the Build* functions
  IORING_CREATE_SKIP_BUILDER_PARAM_CHECKS = $00000001;

type
  IORING_REF_KIND = Cardinal;
  PIORING_REF_KIND = ^IORING_REF_KIND;

const
  IORING_REF_RAW = 0;
  IORING_REF_REGISTERED = 1;

type
  // winbase.h, used by BuildIoRingWriteFile / BuildIoRingWriteFileGather
  FILE_WRITE_FLAGS = Cardinal;
  PFILE_WRITE_FLAGS = ^FILE_WRITE_FLAGS;

const
  FILE_WRITE_FLAGS_NONE = 0;
  FILE_WRITE_FLAGS_WRITE_THROUGH = $00000001;

type
  // winbase.h, used by BuildIoRingFlushFile
  FILE_FLUSH_MODE = Cardinal;
  PFILE_FLUSH_MODE = ^FILE_FLUSH_MODE;

const
  FILE_FLUSH_DEFAULT = 0;       // same as FlushFileBuffers: data, metadata and a SYNC to the hardware
  FILE_FLUSH_DATA = 1;          // data only
  FILE_FLUSH_MIN_METADATA = 2;  // data + SYNC (minimal metadata)
  FILE_FLUSH_NO_SYNC = 3;       // data + metadata, no SYNC

const
  // SubmitIoRing waitOperations value: wait for all submitted operations
  IORING_SUBMIT_WAIT_ALL = $FFFFFFFF;

{ ---------------------------------------------------------------------------- }
{ Error codes (winerror.h, FACILITY_IORING = 0x46)                             }
{ ---------------------------------------------------------------------------- }

const
  // One or more of the required flags provided is unknown by the implementation
  IORING_E_REQUIRED_FLAG_NOT_SUPPORTED = HRESULT($80460001);
  // The submission queue is full
  IORING_E_SUBMISSION_QUEUE_FULL = HRESULT($80460002);
  // The version specified is not known or supported
  IORING_E_VERSION_NOT_SUPPORTED = HRESULT($80460003);
  // The submission queue size specified for the IoRing is too big
  IORING_E_SUBMISSION_QUEUE_TOO_BIG = HRESULT($80460004);
  // The completion queue size specified for the IoRing is too big
  IORING_E_COMPLETION_QUEUE_TOO_BIG = HRESULT($80460005);
  // A submit operation is already in progress for this IoRing on another thread
  IORING_E_SUBMIT_IN_PROGRESS = HRESULT($80460006);
  // The shared ring buffers of the IoRing are corrupt
  IORING_E_CORRUPT = HRESULT($80460007);
  // The completion queue does not have enough free space, to post completions, for all entries being submitted
  IORING_E_COMPLETION_QUEUE_TOO_FULL = HRESULT($80460008);

{ ---------------------------------------------------------------------------- }
{ Structures                                                                   }
{ ---------------------------------------------------------------------------- }

type
  PIORING_CREATE_FLAGS = ^IORING_CREATE_FLAGS;
  IORING_CREATE_FLAGS = record
    Required: IORING_CREATE_REQUIRED_FLAGS;
    Advisory: IORING_CREATE_ADVISORY_FLAGS;
  end;

  PIORING_INFO = ^IORING_INFO;
  IORING_INFO = record
    IoRingVersion: IORING_VERSION;
    Flags: IORING_CREATE_FLAGS;
    SubmissionQueueSize: UInt32;
    CompletionQueueSize: UInt32;
  end;

  PIORING_CAPABILITIES = ^IORING_CAPABILITIES;
  IORING_CAPABILITIES = record
    MaxVersion: IORING_VERSION;
    MaxSubmissionQueueSize: UInt32;
    MaxCompletionQueueSize: UInt32;
    FeatureFlags: IORING_FEATURE_FLAGS;
  end;

  // Win32: 8 bytes, Win64: 16 bytes
  PIORING_HANDLE_REF = ^IORING_HANDLE_REF;
  IORING_HANDLE_REF = record
    Kind: IORING_REF_KIND;
    case Integer of
      0: (Handle: THandle);   // Kind = IORING_REF_RAW
      1: (Index: UInt32);     // Kind = IORING_REF_REGISTERED
  end;

  PIORING_REGISTERED_BUFFER = ^IORING_REGISTERED_BUFFER;
  IORING_REGISTERED_BUFFER = record
    BufferIndex: UInt32;      // index of the pre-registered buffer
    Offset: UInt32;           // offset into the pre-registered buffer
  end;

  // Win32: 12 bytes, Win64: 16 bytes
  PIORING_BUFFER_REF = ^IORING_BUFFER_REF;
  IORING_BUFFER_REF = record
    Kind: IORING_REF_KIND;
    case Integer of
      0: (Address: Pointer);                            // Kind = IORING_REF_RAW
      1: (IndexAndOffset: IORING_REGISTERED_BUFFER);    // Kind = IORING_REF_REGISTERED
  end;

  // Address = nil and Length = 0 is a "sparse" entry in BuildIoRingRegisterBuffers
  PIORING_BUFFER_INFO = ^IORING_BUFFER_INFO;
  IORING_BUFFER_INFO = record
    Address: Pointer;
    Length: UInt32;
  end;

  // Win32: 12 bytes, Win64: 24 bytes
  PIORING_CQE = ^IORING_CQE;
  IORING_CQE = record
    UserData: NativeUInt;     // UINT_PTR, as given to the Build* function
    ResultCode: HRESULT;
    Information: NativeUInt;  // ULONG_PTR, e.g. bytes transferred
  end;

  // winnt.h. Buffer is a PVOID64: a 64-bit value even in 32-bit programs (store the pointer zero-extended).
  PFILE_SEGMENT_ELEMENT = ^FILE_SEGMENT_ELEMENT;
  FILE_SEGMENT_ELEMENT = record
    case Integer of
      0: (Buffer: UInt64);
      1: (Alignment: UInt64);
  end;

  { ---------------------------------------------------------------------------- }
  { Helpers (macros / C++ constructors in ioringapi.h)                           }
  { ---------------------------------------------------------------------------- }

  function IoRingHandleRefFromHandle(const h: THandle): IORING_HANDLE_REF; inline;
  function IoRingHandleRefFromIndex(const i: UInt32): IORING_HANDLE_REF; inline;
  function IoRingBufferRefFromPointer(const p: Pointer): IORING_BUFFER_REF; inline;
  function IoRingBufferRefFromIndexAndOffset(const i, o: UInt32): IORING_BUFFER_REF; inline;

  { ---------------------------------------------------------------------------- }
  { Functions. Record parameters are passed by value like in C: do not change    }
  { them to const (Delphi may then pass them by reference).                      }
  { ---------------------------------------------------------------------------- }

  { Version 1. Queries the OS for the supported IoRing capabilities.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-queryioringcapabilities }
  function QueryIoRingCapabilities(out capabilities: IORING_CAPABILITIES): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'QueryIoRingCapabilities' delayed;{$ENDIF}

  { Version 1. Is the operation supported by this ring?
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-isioringopsupported }
  function IsIoRingOpSupported(ioRing: HIORING; op: IORING_OP_CODE): BOOL;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'IsIoRingOpSupported' delayed;{$ENDIF}

  { Version 1. Creates a ring. Queue sizes are rounded up to powers of two; the completion queue is at least twice the
    submission queue. https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-createioring }
  function CreateIoRing(ioringVersion: IORING_VERSION; flags: IORING_CREATE_FLAGS;
    submissionQueueSize: UInt32; completionQueueSize: UInt32; out h: HIORING): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'CreateIoRing' delayed;{$ENDIF}

  { Version 1. Version and actual queue sizes of a ring.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-getioringinfo }
  function GetIoRingInfo(ioRing: HIORING; out info: IORING_INFO): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'GetIoRingInfo' delayed;{$ENDIF}

  {
    Version 1. Submits all built entries; optionally waits for waitOperations completions (0 = no wait;
    IORING_SUBMIT_WAIT_ALL = all). submittedEntries may be nil. On failure (other than a wait timeout) all entries stay
    queued. A wait timeout returns HRESULT_FROM_WIN32(ERROR_TIMEOUT): the entries were submitted, but submittedEntries
    is not written. https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-submitioring
  }
  function SubmitIoRing(ioRing: HIORING; waitOperations: UInt32; milliseconds: UInt32;
    submittedEntries: PCardinal): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'SubmitIoRing' delayed;{$ENDIF}

  // Version 1. Closes a ring. https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-closeioring
  function CloseIoRing(ioRing: HIORING): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'CloseIoRing' delayed;{$ENDIF}

  {
    Version 1. Pops one completion: S_OK, or S_FALSE if the queue is empty (do not use cqe then; it is zeroed although
    Learn says "unmodified").
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-popioringcompletion
  }
  function PopIoRingCompletion(ioRing: HIORING; out cqe: IORING_CQE): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'PopIoRingCompletion' delayed;{$ENDIF}

  {
    Version 1. Event signalled when the completion queue goes from empty to non-empty. Pop until S_FALSE before waiting
    on it. 0 clears the event.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-setioringcompletionevent
  }
  function SetIoRingCompletionEvent(ioRing: HIORING; hEvent: THandle): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'SetIoRingCompletionEvent' delayed;{$ENDIF}

  { Version 1. Requests cancellation of the operation built with userData = opToCancel.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringcancelrequest }
  function BuildIoRingCancelRequest(ioRing: HIORING; file_: IORING_HANDLE_REF;
    opToCancel: NativeUInt; userData: NativeUInt): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingCancelRequest' delayed;{$ENDIF}

  { Version 1. Read from a file.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringreadfile }
  function BuildIoRingReadFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    dataRef: IORING_BUFFER_REF; numberOfBytesToRead: UInt32; fileOffset: UInt64;
    userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingReadFile' delayed;{$ENDIF}

  {
    Version 1. Registers file handles (replaces any earlier registration). INVALID_HANDLE_VALUE entries are sparse. The
    array must stay valid until the operation completes.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringregisterfilehandles
  }
  function BuildIoRingRegisterFileHandles(ioRing: HIORING; count: UInt32;
    handles: PHandle; userData: NativeUInt): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingRegisterFileHandles' delayed;{$ENDIF}

  {
    Version 1. Registers buffers (replaces any earlier registration). Entries with Address = nil and Length = 0 are
    sparse. The array must stay valid until the operation completes.
    https://learn.microsoft.com/en-us/windows/win32/api/ioringapi/nf-ioringapi-buildioringregisterbuffers
  }
  function BuildIoRingRegisterBuffers(ioRing: HIORING; count: UInt32;
    buffers: PIORING_BUFFER_INFO; userData: NativeUInt): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingRegisterBuffers' delayed;{$ENDIF}

  // Version 3 (api-ms-win-core-ioring-l1-1-1). Write to a file.
  function BuildIoRingWriteFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    bufferRef: IORING_BUFFER_REF; numberOfBytesToWrite: UInt32; fileOffset: UInt64;
    writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingWriteFile' delayed;{$ENDIF}

  // Version 3 (api-ms-win-core-ioring-l1-1-1). Flush a file.
  function BuildIoRingFlushFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    flushMode: FILE_FLUSH_MODE; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingFlushFile' delayed;{$ENDIF}

  // Version 4 (api-ms-win-core-ioring-l1-1-2). Read from a file into buffer segments.
  function BuildIoRingReadFileScatter(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    segmentCount: UInt32; segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToRead: UInt32;
    fileOffset: UInt64; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingReadFileScatter' delayed;{$ENDIF}

  // Version 4 (api-ms-win-core-ioring-l1-1-2). Write to a file from buffer segments.
  function BuildIoRingWriteFileGather(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    segmentCount: UInt32; segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToWrite: UInt32;
    fileOffset: UInt64; writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt;
    sqeFlags: IORING_SQE_FLAGS): HRESULT;
    stdcall;{$IFNDEF FPC} external IORING_DLL name 'BuildIoRingWriteFileGather' delayed;{$ENDIF}

implementation

function IoRingHandleRefFromHandle(const h: THandle): IORING_HANDLE_REF;
begin
  Result := Default(IORING_HANDLE_REF);
  Result.Kind := IORING_REF_RAW;
  Result.Handle := h;
end;

function IoRingHandleRefFromIndex(const i: UInt32): IORING_HANDLE_REF;
begin
  Result := Default(IORING_HANDLE_REF);
  Result.Kind := IORING_REF_REGISTERED;
  Result.Index := i;
end;

function IoRingBufferRefFromPointer(const p: Pointer): IORING_BUFFER_REF;
begin
  Result := Default(IORING_BUFFER_REF);
  Result.Kind := IORING_REF_RAW;
  Result.Address := p;
end;

function IoRingBufferRefFromIndexAndOffset(const i, o: UInt32): IORING_BUFFER_REF;
begin
  Result := Default(IORING_BUFFER_REF);
  Result.Kind := IORING_REF_REGISTERED;
  Result.IndexAndOffset.BufferIndex := i;
  Result.IndexAndOffset.Offset := o;
end;

{$IFDEF FPC}
{
  Free Pascal has no "delayed" imports. Each function is looked up in kernel32.dll when it is called the first time, so
  a program still starts on Windows without IoRing. A function Windows does not have returns E_NOTIMPL
  (IsIoRingOpSupported: False) - Delphi raises a delay-load error instead.
}

type
  TQueryIoRingCapabilities = function(out capabilities: IORING_CAPABILITIES): HRESULT; stdcall;
  TIsIoRingOpSupported = function(ioRing: HIORING; op: IORING_OP_CODE): BOOL; stdcall;
  TCreateIoRing = function(ioringVersion: IORING_VERSION; flags: IORING_CREATE_FLAGS;
    submissionQueueSize: UInt32; completionQueueSize: UInt32; out h: HIORING): HRESULT; stdcall;
  TGetIoRingInfo = function(ioRing: HIORING; out info: IORING_INFO): HRESULT; stdcall;
  TSubmitIoRing = function(ioRing: HIORING; waitOperations: UInt32; milliseconds: UInt32;
    submittedEntries: PCardinal): HRESULT; stdcall;
  TCloseIoRing = function(ioRing: HIORING): HRESULT; stdcall;
  TPopIoRingCompletion = function(ioRing: HIORING; out cqe: IORING_CQE): HRESULT; stdcall;
  TSetIoRingCompletionEvent = function(ioRing: HIORING; hEvent: THandle): HRESULT; stdcall;
  TBuildIoRingCancelRequest = function(ioRing: HIORING; file_: IORING_HANDLE_REF;
    opToCancel: NativeUInt; userData: NativeUInt): HRESULT; stdcall;
  TBuildIoRingReadFile = function(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    dataRef: IORING_BUFFER_REF; numberOfBytesToRead: UInt32; fileOffset: UInt64;
    userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
  TBuildIoRingRegisterFileHandles = function(ioRing: HIORING; count: UInt32;
    handles: PHandle; userData: NativeUInt): HRESULT; stdcall;
  TBuildIoRingRegisterBuffers = function(ioRing: HIORING; count: UInt32;
    buffers: PIORING_BUFFER_INFO; userData: NativeUInt): HRESULT; stdcall;
  TBuildIoRingWriteFile = function(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    bufferRef: IORING_BUFFER_REF; numberOfBytesToWrite: UInt32; fileOffset: UInt64;
    writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
  TBuildIoRingFlushFile = function(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    flushMode: FILE_FLUSH_MODE; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
  TBuildIoRingReadFileScatter = function(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    segmentCount: UInt32; segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToRead: UInt32;
    fileOffset: UInt64; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
  TBuildIoRingWriteFileGather = function(ioRing: HIORING; fileRef: IORING_HANDLE_REF;
    segmentCount: UInt32; segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToWrite: UInt32;
    fileOffset: UInt64; writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt;
    sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;

const
  E_NOTIMPL_RESULT = HRESULT($80004001);

var
  GQueryIoRingCapabilities: TQueryIoRingCapabilities = nil;
  GIsIoRingOpSupported: TIsIoRingOpSupported = nil;
  GCreateIoRing: TCreateIoRing = nil;
  GGetIoRingInfo: TGetIoRingInfo = nil;
  GSubmitIoRing: TSubmitIoRing = nil;
  GCloseIoRing: TCloseIoRing = nil;
  GPopIoRingCompletion: TPopIoRingCompletion = nil;
  GSetIoRingCompletionEvent: TSetIoRingCompletionEvent = nil;
  GBuildIoRingCancelRequest: TBuildIoRingCancelRequest = nil;
  GBuildIoRingReadFile: TBuildIoRingReadFile = nil;
  GBuildIoRingRegisterFileHandles: TBuildIoRingRegisterFileHandles = nil;
  GBuildIoRingRegisterBuffers: TBuildIoRingRegisterBuffers = nil;
  GBuildIoRingWriteFile: TBuildIoRingWriteFile = nil;
  GBuildIoRingFlushFile: TBuildIoRingFlushFile = nil;
  GBuildIoRingReadFileScatter: TBuildIoRingReadFileScatter = nil;
  GBuildIoRingWriteFileGather: TBuildIoRingWriteFileGather = nil;

{ Looks the function up once; False if this Windows does not have it. Several threads may do this at the same time: they
  all store the same value. }
function Resolve(var AFunction; const AName: PAnsiChar): Boolean;
begin
  if Pointer(AFunction) = nil then
    Pointer(AFunction) := GetProcAddress(GetModuleHandle(IORING_DLL), AName);

  Result := Pointer(AFunction) <> nil;
end;

function QueryIoRingCapabilities(out capabilities: IORING_CAPABILITIES): HRESULT; stdcall;
begin
  if Resolve(GQueryIoRingCapabilities, 'QueryIoRingCapabilities') then
    Result := GQueryIoRingCapabilities(capabilities)
  else
    Result := E_NOTIMPL_RESULT;
end;

function IsIoRingOpSupported(ioRing: HIORING; op: IORING_OP_CODE): BOOL; stdcall;
begin
  if Resolve(GIsIoRingOpSupported, 'IsIoRingOpSupported') then
    Result := GIsIoRingOpSupported(ioRing, op)
  else
    Result := False;
end;

function CreateIoRing(ioringVersion: IORING_VERSION; flags: IORING_CREATE_FLAGS;
  submissionQueueSize: UInt32; completionQueueSize: UInt32; out h: HIORING): HRESULT; stdcall;
begin
  if Resolve(GCreateIoRing, 'CreateIoRing') then
    Result := GCreateIoRing(ioringVersion, flags, submissionQueueSize, completionQueueSize, h)
  else
  begin
    h := 0;

    Result := E_NOTIMPL_RESULT;
  end;
end;

function GetIoRingInfo(ioRing: HIORING; out info: IORING_INFO): HRESULT; stdcall;
begin
  if Resolve(GGetIoRingInfo, 'GetIoRingInfo') then
    Result := GGetIoRingInfo(ioRing, info)
  else
    Result := E_NOTIMPL_RESULT;
end;

function SubmitIoRing(ioRing: HIORING; waitOperations: UInt32; milliseconds: UInt32;
  submittedEntries: PCardinal): HRESULT; stdcall;
begin
  if Resolve(GSubmitIoRing, 'SubmitIoRing') then
    Result := GSubmitIoRing(ioRing, waitOperations, milliseconds, submittedEntries)
  else
    Result := E_NOTIMPL_RESULT;
end;

function CloseIoRing(ioRing: HIORING): HRESULT; stdcall;
begin
  if Resolve(GCloseIoRing, 'CloseIoRing') then
    Result := GCloseIoRing(ioRing)
  else
    Result := E_NOTIMPL_RESULT;
end;

function PopIoRingCompletion(ioRing: HIORING; out cqe: IORING_CQE): HRESULT; stdcall;
begin
  if Resolve(GPopIoRingCompletion, 'PopIoRingCompletion') then
    Result := GPopIoRingCompletion(ioRing, cqe)
  else
    Result := E_NOTIMPL_RESULT;
end;

function SetIoRingCompletionEvent(ioRing: HIORING; hEvent: THandle): HRESULT; stdcall;
begin
  if Resolve(GSetIoRingCompletionEvent, 'SetIoRingCompletionEvent') then
    Result := GSetIoRingCompletionEvent(ioRing, hEvent)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingCancelRequest(ioRing: HIORING; file_: IORING_HANDLE_REF;
  opToCancel: NativeUInt; userData: NativeUInt): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingCancelRequest, 'BuildIoRingCancelRequest') then
    Result := GBuildIoRingCancelRequest(ioRing, file_, opToCancel, userData)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingReadFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF; dataRef: IORING_BUFFER_REF;
  numberOfBytesToRead: UInt32; fileOffset: UInt64; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingReadFile, 'BuildIoRingReadFile') then
    Result := GBuildIoRingReadFile(ioRing, fileRef, dataRef, numberOfBytesToRead, fileOffset, userData, sqeFlags)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingRegisterFileHandles(ioRing: HIORING; count: UInt32; handles: PHandle;
  userData: NativeUInt): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingRegisterFileHandles, 'BuildIoRingRegisterFileHandles') then
    Result := GBuildIoRingRegisterFileHandles(ioRing, count, handles, userData)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingRegisterBuffers(ioRing: HIORING; count: UInt32; buffers: PIORING_BUFFER_INFO;
  userData: NativeUInt): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingRegisterBuffers, 'BuildIoRingRegisterBuffers') then
    Result := GBuildIoRingRegisterBuffers(ioRing, count, buffers, userData)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingWriteFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF; bufferRef: IORING_BUFFER_REF;
  numberOfBytesToWrite: UInt32; fileOffset: UInt64; writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt;
  sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingWriteFile, 'BuildIoRingWriteFile') then
    Result := GBuildIoRingWriteFile(ioRing, fileRef, bufferRef, numberOfBytesToWrite, fileOffset, writeFlags,
      userData, sqeFlags)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingFlushFile(ioRing: HIORING; fileRef: IORING_HANDLE_REF; flushMode: FILE_FLUSH_MODE;
  userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingFlushFile, 'BuildIoRingFlushFile') then
    Result := GBuildIoRingFlushFile(ioRing, fileRef, flushMode, userData, sqeFlags)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingReadFileScatter(ioRing: HIORING; fileRef: IORING_HANDLE_REF; segmentCount: UInt32;
  segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToRead: UInt32; fileOffset: UInt64; userData: NativeUInt;
  sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingReadFileScatter, 'BuildIoRingReadFileScatter') then
    Result := GBuildIoRingReadFileScatter(ioRing, fileRef, segmentCount, segmentArray, numberOfBytesToRead,
      fileOffset, userData, sqeFlags)
  else
    Result := E_NOTIMPL_RESULT;
end;

function BuildIoRingWriteFileGather(ioRing: HIORING; fileRef: IORING_HANDLE_REF; segmentCount: UInt32;
  segmentArray: PFILE_SEGMENT_ELEMENT; numberOfBytesToWrite: UInt32; fileOffset: UInt64;
  writeFlags: FILE_WRITE_FLAGS; userData: NativeUInt; sqeFlags: IORING_SQE_FLAGS): HRESULT; stdcall;
begin
  if Resolve(GBuildIoRingWriteFileGather, 'BuildIoRingWriteFileGather') then
    Result := GBuildIoRingWriteFileGather(ioRing, fileRef, segmentCount, segmentArray, numberOfBytesToWrite,
      fileOffset, writeFlags, userData, sqeFlags)
  else
    Result := E_NOTIMPL_RESULT;
end;
{$ENDIF}

end.
