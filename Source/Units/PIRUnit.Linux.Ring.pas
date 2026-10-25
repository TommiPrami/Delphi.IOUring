unit PIRUnit.Linux.Ring;

{
  The Linux ring: TLinuxIORing, built on PIRUnit.Linux.API (the io_uring system calls, no C library;
  Docs/Design.md §5.7). User code normally uses it through the TIORing alias in PIRUnit.IORing. Free Pascal, Linux 5.11
  or newer, x86-64 and AArch64.

  TLinuxIORing is a custom managed record, like TWindowsIORing: it owns the ring and closes it automatically at the end
  of the variable's scope. It cannot be copied; pass it as var or constref.

  Rules for the caller (the same as on Windows):
  - One thread at a time. A ring has no locks.
  - Buffers, file descriptors and scatter/gather segment arrays must stay
    valid until the operation's completion has been popped.
  - Close (and the end of scope) waits until every submitted operation has
    completed. Operations that may never complete (pipe reads etc.) must be
    cancelled first: PrepareCancel.

  Differences to Windows:
  - Registering files and buffers is a system call, not a ring operation: it
    takes effect at once in PrepareRegisterFiles / PrepareRegisterBuffers,
    and its completion is the first one TryPopCompletion returns.
  - A read at or after the end of the file succeeds with 0 bytes
    (IsEndOfFile).
  - A scatter/gather segment is an iovec (address and length); no
    unbuffered file is needed.
  - PrepareCancel finds the operation by its user data only (AFile is not
    needed).
  - Linux only: PrepareSqe (any io_uring operation, for example sockets) and
    LinkToNext (linked operations).
}

{$I PIRInclude.Compiler.inc}

{$IFNDEF LINUX}
  {$MESSAGE FATAL 'PIRUnit.Linux.Ring is for Linux.'}
{$ENDIF}
{$IF not (defined(CPUX86_64) or defined(CPUAARCH64))}
  {$MESSAGE FATAL 'PIRUnit.Linux.Ring is for x86-64 and AArch64.'}
{$ENDIF}

interface

uses
  SysUtils, PIRUnit.Types, PIRUnit.Linux.API;

type
  // One scatter/gather segment: struct iovec. IORingSegment gives one page.
  TIORingSegment = record
    Address: Pointer;     // iov_base
    Length: NativeUInt;   // iov_len
  end;

  PIORingSegment = ^TIORingSegment;

  function IORingSegment(const AAddress: Pointer): TIORingSegment;

type
  TLinuxIORing = record
  private
    FFd: Integer;                   // the ring's file descriptor; -1 = closed
    FParams: io_uring_params;
    FRingMemory: PByte;             // SQ and CQ ring (one mapping)
    FRingMemorySize: NativeUInt;
    FSqes: PByte;
    FSqesSize: NativeUInt;
    FSqTail: PCardinal;             // in the ring memory
    FSqMask: Cardinal;
    FCqHead: PCardinal;
    FCqTail: PCardinal;
    FCqMask: Cardinal;
    FCqes: PByte;
    FSqLocalTail: Cardinal;         // SQEs written; given to the kernel at Submit
    FSubmissionQueueSize: Cardinal;
    FCompletionQueueSize: Cardinal;
    FPreparedCount: Cardinal;       // written, not yet submitted
    FPendingCount: Cardinal;        // submitted (or registered), completion not yet popped
    FEventFd: Integer;              // -1 until CompletionEventHandle is called
    // Addresses of the registered buffers: READ_FIXED / WRITE_FIXED need them
    FRegisteredBuffers: array of PByte;
    // Completions of the registrations (system calls, not ring operations); TryPopCompletion returns them first
    FLocalCompletions: array of TIORingCompletion;
    FLocalFirst: Integer;
    // Copies of scatter/gather segment arrays (cut to the byte count), kept until nothing is in flight
    FKeepAlive: array of TBytes;

    function Map(const ASize: NativeUInt; const AOffset: Int64): PByte;
    procedure Unmap;
    function NextSqe: Pio_uring_sqe;
    function PrepareReadWrite(const AOpcode, AFixedOpcode: Byte; const AFile: TIORingFileRef;
      const ABuffer: TIORingBufferRef; const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags; const ARwFlags: Cardinal): Boolean;
    function PrepareVectored(const AOpcode: Byte; const AFile: TIORingFileRef; const ASegments: PIORingSegment;
      const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags; const ARwFlags: Cardinal): Boolean;
    function LocalCompletionCount: Cardinal;
    procedure AddLocalCompletion(const AUserData: TIORingUserData; const AResult: Integer);
    function ReadyCount: Cardinal;
    function SubmitAndWait(const AWaitCount, ATimeoutMilliseconds: Cardinal): Boolean;
    procedure WaitForAllPending;
  public
    class operator Initialize(var ADest: TLinuxIORing);
    class operator Finalize(var ADest: TLinuxIORing);
    class operator Copy(constref ASource: TLinuxIORing; var ADest: TLinuxIORing);

    { Creates the ring. The kernel rounds the sizes up to powers of two; the completion queue is at least twice the
      submission queue (0 = minimum). }
    procedure Open(const ASubmissionQueueSize: Cardinal = 256; const ACompletionQueueSize: Cardinal = 0);
    { Waits for all submitted operations, then closes. Prepared but not submitted entries are dropped. Does
      nothing if the ring is not open. }
    procedure Close;
    function IsOpen: Boolean;

    {
      --- Prepare: no system call (except the registrations). False = no room
      (submission queue full, or the completion queue could not take one more
      completion): pop completions, Submit and try again.
    }
    function PrepareRead(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef; const ACount: Cardinal;
      const AOffset: UInt64; const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = []): Boolean;
    function PrepareWrite(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef; const ACount: Cardinal;
      const AOffset: UInt64; const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags = [];
      const AWriteThrough: Boolean = False): Boolean;
    function PrepareFlush(const AFile: TIORingFileRef; const AMode: TIORingFlushMode; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []): Boolean;
    { ASegments: ASegmentCount segments; ACount = bytes to transfer (at most the sum of the segment lengths). The array
      must stay valid until the completion is popped. }
    function PrepareReadScatter(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
      const ASegmentCount: Cardinal; const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []): Boolean;
    function PrepareWriteGather(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
      const ASegmentCount: Cardinal; const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
      const AFlags: TIORingSubmitFlags = []; const AWriteThrough: Boolean = False): Boolean;
    // Requests cancellation of the operation with ATargetUserData. Both operations produce a completion.
    function PrepareCancel(const AFile: TIORingFileRef; const ATargetUserData: TIORingUserData;
      const AUserData: TIORingUserData): Boolean;
    // Replaces all registered files / buffers, at once (a system call). A failure comes back in the completion.
    function PrepareRegisterFiles(const AHandles: array of THandle; const AUserData: TIORingUserData): Boolean;
    function PrepareRegisterBuffers(const ABuffers: array of TIORingBufferInfo;
      const AUserData: TIORingUserData): Boolean;

    {
      --- Linux only (Docs/Design.md §5.8): code that uses these is Linux code.
      Any operation of io_uring: the next entry of the submission queue,
      zeroed, with the user data set; the caller fills in the rest with the
      names of PIRUnit.Linux.API (opcode, fd, addr, len ...;
      for a registered file IOSQE_FIXED_FILE and the index as fd). False = no
      room, as for the other Prepare methods. The rule: one entry, one
      completion - no multishot operations, no zero-copy send
      (IORING_OP_SEND_ZC), no IOSQE_CQE_SKIP_SUCCESS.
    }
    function PrepareSqe(const AUserData: TIORingUserData; out ASqe: Pio_uring_sqe): Boolean;
    {
      Links the entry prepared last to the next one: the next starts only after this one has completed, and is cancelled
      (-ECANCELED) if this one fails - a short read or write counts as a failure. AHard: the next runs anyway. Both must
      go to the kernel in the same Submit. Raises if no entry is prepared.
    }
    procedure LinkToNext(const AHard: Boolean = False);

    {
      --- Submit: one system call. Submits all prepared entries and, if
      AWaitCount > 0, waits until that many completions are available (at most
      the number of outstanding operations) or the timeout ends. A timeout is
      not an error. Returns the number of entries submitted.
    }
    function Submit(const AWaitCount: Cardinal = 0; const ATimeoutMilliseconds: Cardinal = IORING_INFINITE): Cardinal;

    // --- Reap: no system call
    function TryPopCompletion(out ACompletion: TIORingCompletion): Boolean;
    function PopCompletions(var ACompletions: array of TIORingCompletion): Integer;

    { Waits until ACount completions are available (at most the number of outstanding operations). False on timeout.
      Uses the same system call as Submit, so it also submits prepared entries. }
    function WaitForCompletions(const ACount: Cardinal; const ATimeoutMilliseconds: Cardinal = IORING_INFINITE): Boolean;

    { An eventfd that the kernel signals for every completion (created and registered with the ring on the first call).
      Read it to reset it; pop until TryPopCompletion returns False before waiting on it. Call it first before anything
      is submitted: a completion posted before the first call never signals it. }
    function CompletionEventHandle: THandle;

    class function Available: Boolean; static;
    class function QueryCapabilities: TIORingCapabilities; static;

    // The ring's file descriptor, for calls into PIRUnit.Linux.API
    property Handle: Integer read FFd;
    property SubmissionQueueSize: Cardinal read FSubmissionQueueSize;
    property CompletionQueueSize: Cardinal read FCompletionQueueSize;
    property PreparedCount: Cardinal read FPreparedCount;
    property PendingCount: Cardinal read FPendingCount;
  end;

implementation

uses
  BaseUnix, Linux, Syscall, PIRUnit.Atomics, PIRUnit.Linux.Platform;

{ Pointers go to the kernel as system call arguments and in SQE fields. The unit is for 64-bit CPUs
  only, where both are 64 bits. }
{$WARN 4055 OFF}

const
  // A system call that FPC 3.2.2 has no number for (it differs per CPU)
{$IF defined(CPUX86_64)}
  SYSCALL_EVENTFD2 = 290;
{$ELSE}
  SYSCALL_EVENTFD2 = 19;
{$ENDIF}

  // linux/fs.h, fcntl.h, mman.h, eventfd.h
  RWF_DSYNC = 2;
  SYNC_FILE_RANGE_WAIT_BEFORE = 1;
  SYNC_FILE_RANGE_WRITE = 2;
  SYNC_FILE_RANGE_WAIT_AFTER = 4;
  O_CLOEXEC_FLAG = &02000000;
  MAP_POPULATE_FLAG = $8000;
  EFD_CLOEXEC = O_CLOEXEC_FLAG;

  // The kernel's limits (IORING_MAX_ENTRIES, IORING_MAX_CQ_ENTRIES)
  MAX_SUBMISSION_QUEUE_SIZE = 32768;
  MAX_COMPLETION_QUEUE_SIZE = 2 * MAX_SUBMISSION_QUEUE_SIZE;

  // The opcodes the ring uses, and the kernel that has them all
  REQUIRED_OPS: array[0..7] of Byte = (IORING_OP_READ, IORING_OP_WRITE, IORING_OP_READ_FIXED,
    IORING_OP_WRITE_FIXED, IORING_OP_FSYNC, IORING_OP_SYNC_FILE_RANGE, IORING_OP_ASYNC_CANCEL,
    IORING_OP_READV);
  REQUIRED_FEATURES = IORING_FEAT_SINGLE_MMAP or IORING_FEAT_NODROP or IORING_FEAT_EXT_ARG;

var
  // 0 = not checked yet, 1 = available, -1 = not available
  GAvailability: Integer = 0;
  GNotAvailableReason: string;
  GSupportedOps: TIORingOps;
  GKernelVersion: Cardinal;
  GNativeOps: TIORingNativeOps;
  GNativeFeatures: UInt64;
  // 0 = not checked yet, 1 = a SQPOLL ring can be set up, -1 = not
  GSqPollAllowed: Integer = 0;

function AddressOf(const APointer: Pointer): UInt64; inline;
begin
  Result := UInt64(PByte(APointer) - PByte(nil));
end;

// uname's release, e.g. '6.18.54.1-microsoft-standard-WSL2'
function KernelRelease: string;
var
  LName: UtsName;
begin
  if FpUname(LName) = 0 then
    Result := PChar(@LName.Release[0])
  else
    Result := '';
end;

// The kernel version as major * 100 + minor (6.18 = 618)
function KernelVersion: Cardinal;
var
  LRelease: string;
  LMajor: Integer;
  LMinor: Integer;
  LPosition: Integer;
begin
  Result := 0;
  LRelease := KernelRelease;
  LPosition := Pos('.', LRelease);

  if LPosition = 0 then
    Exit;

  LMajor := StrToIntDef(Copy(LRelease, 1, LPosition - 1), 0);
  Delete(LRelease, 1, LPosition);
  LPosition := 1;

  while (LPosition <= Length(LRelease)) and (LRelease[LPosition] in ['0'..'9']) do
    Inc(LPosition);

  LMinor := StrToIntDef(Copy(LRelease, 1, LPosition - 1), 0);

  Result := Cardinal(LMajor * 100 + LMinor);
end;

procedure CheckAvailability;
var
  LParams: io_uring_params;
  LFd: Integer;
  LProbe: array of Byte;
  LOps: Pio_uring_probe_op;
  LCount: Integer;
  LIndex: Integer;
begin
  GKernelVersion := KernelVersion;
  GSupportedOps := [];
  GNativeOps := [];
  GNativeFeatures := 0;
  GNotAvailableReason := '';

  FillChar(LParams, SizeOf(LParams), 0);
  LFd := io_uring_setup(4, @LParams);

  if LFd < 0 then
  begin
    if LFd = -ESysENOSYS then
      GNotAvailableReason := 'This Linux kernel has no io_uring. Linux 5.11 or newer is required.'
    else if LFd = -ESysEPERM then
      GNotAvailableReason := 'io_uring is switched off on this system (kernel.io_uring_disabled, ' +
        'or seccomp in a container).'
    else
      GNotAvailableReason := 'io_uring_setup failed: ' + IORingErrorMessage(LFd);

    GAvailability := -1;

    Exit;
  end;

  try
    GNativeFeatures := LParams.features;
    // The kernel wants the probe memory zeroed (SetLength does that)
    SetLength(LProbe, SizeOf(io_uring_probe) + 256 * SizeOf(io_uring_probe_op));

    if io_uring_register(LFd, IORING_REGISTER_PROBE, @LProbe[0], 256) = 0 then
    begin
      LOps := Pio_uring_probe_op(@LProbe[SizeOf(io_uring_probe)]);
      LCount := Pio_uring_probe(@LProbe[0])^.ops_len;

      for LIndex := 0 to LCount - 1 do
        if Pio_uring_probe_op(PByte(LOps) + LIndex * SizeOf(io_uring_probe_op))^.flags and IO_URING_OP_SUPPORTED <> 0 then
          Include(GNativeOps, Byte(LIndex));

      // Registration is a system call (Linux 5.1)
      GSupportedOps := [ioRegisterFiles, ioRegisterBuffers];

      if IORING_OP_READ in GNativeOps then
        Include(GSupportedOps, ioRead);

      if IORING_OP_WRITE in GNativeOps then
        Include(GSupportedOps, ioWrite);

      if (IORING_OP_FSYNC in GNativeOps) and (IORING_OP_SYNC_FILE_RANGE in GNativeOps) then
        Include(GSupportedOps, ioFlush);

      if IORING_OP_ASYNC_CANCEL in GNativeOps then
        Include(GSupportedOps, ioCancel);

      if IORING_OP_READV in GNativeOps then
        Include(GSupportedOps, ioReadScatter);

      if IORING_OP_WRITEV in GNativeOps then
        Include(GSupportedOps, ioWriteGather);

      GAvailability := 1;

      for LIndex := Low(REQUIRED_OPS) to High(REQUIRED_OPS) do
        if not (REQUIRED_OPS[LIndex] in GNativeOps) then
          GAvailability := -1;
    end
    else
      GAvailability := -1;

    if (LParams.features and REQUIRED_FEATURES) <> REQUIRED_FEATURES then
      GAvailability := -1;

    if GAvailability < 0 then
      GNotAvailableReason := Format('This Linux kernel (%d.%d) lacks io_uring features the library needs. ' +
        'Linux 5.11 or newer is required.', [GKernelVersion div 100, GKernelVersion mod 100]);
  finally
    FpClose(LFd);
  end;
end;

// Not in CheckAvailability: a SQPOLL ring starts a kernel thread, and most programs never ask
function SqPollAllowed: Boolean;
var
  LParams: io_uring_params;
  LFd: Integer;
begin
  if GSqPollAllowed = 0 then
  begin
    FillChar(LParams, SizeOf(LParams), 0);
    LParams.flags := IORING_SETUP_SQPOLL;
    LParams.sq_thread_idle := 1;
    LFd := io_uring_setup(1, @LParams);

    if LFd >= 0 then
    begin
      FpClose(LFd);
      GSqPollAllowed := 1;
    end
    else
      GSqPollAllowed := -1;
  end;

  Result := GSqPollAllowed > 0;
end;

// PRETTY_NAME of /etc/os-release (or /usr/lib/os-release), e.g. 'Ubuntu 24.04.3 LTS'; '' if there is none
function DistributionName: string;
const
  FILES: array[0..1] of string = ('/etc/os-release', '/usr/lib/os-release');
  KEY = #10'PRETTY_NAME=';
var
  LFile: Integer;
  LBuffer: array[0..4095] of AnsiChar;
  LCount: Integer;
  LText: string;
  LStart: Integer;
  LEnd: Integer;
  LIndex: Integer;
begin
  Result := '';

  for LIndex := Low(FILES) to High(FILES) do
  begin
    LFile := FpOpen(FILES[LIndex], O_RDONLY or O_CLOEXEC_FLAG);

    if LFile < 0 then
      Continue;

    try
      LCount := FpRead(LFile, LBuffer, SizeOf(LBuffer) - 1);
    finally
      FpClose(LFile);
    end;

    if LCount <= 0 then
      Continue;

    LBuffer[LCount] := #0;
    LText := #10 + string(PAnsiChar(@LBuffer[0]));
    LStart := Pos(KEY, LText);

    if LStart = 0 then
      Continue;

    Inc(LStart, Length(KEY));
    LEnd := LStart;

    while (LEnd <= Length(LText)) and (LText[LEnd] <> #10) do
      Inc(LEnd);

    Result := Trim(Copy(LText, LStart, LEnd - LStart));
    // The value is usually in quotes

    if (Length(Result) >= 2) and (Result[1] in ['"', '''']) and (Result[Length(Result)] = Result[1]) then
      Result := Copy(Result, 2, Length(Result) - 2);

    Exit;
  end;
end;

function SystemDescription: string;
begin
  Result := DistributionName;

  if Result <> '' then
    Result := Result + ', ';

  Result := Result + 'Linux ' + KernelRelease;
end;

function IORingSegment(const AAddress: Pointer): TIORingSegment;
begin
  Result.Address := AAddress;
  Result.Length := TLinuxIORingPlatform.PageSize;
end;

function ToSqeFlags(const AFlags: TIORingSubmitFlags): Byte; inline;
begin
  if sfDrainPreceding in AFlags then
    Result := IOSQE_IO_DRAIN
  else
    Result := 0;
end;

procedure SetFile(const ASqe: Pio_uring_sqe; const AFile: TIORingFileRef); inline;
begin
  if AFile.Registered then
  begin
    ASqe^.fd := Integer(AFile.Index);
    ASqe^.flags := ASqe^.flags or IOSQE_FIXED_FILE;
  end
  else
    ASqe^.fd := AFile.Handle;
end;

{ TLinuxIORing - life cycle }

class operator TLinuxIORing.Initialize(var ADest: TLinuxIORing);
begin
  ADest.FFd := -1;
  ADest.FEventFd := -1;
  ADest.FRingMemory := nil;
  ADest.FRingMemorySize := 0;
  ADest.FSqes := nil;
  ADest.FSqesSize := 0;
  ADest.FSubmissionQueueSize := 0;
  ADest.FCompletionQueueSize := 0;
  ADest.FPreparedCount := 0;
  ADest.FPendingCount := 0;
  ADest.FLocalFirst := 0;
end;

class operator TLinuxIORing.Finalize(var ADest: TLinuxIORing);
begin
  ADest.Close;
end;

class operator TLinuxIORing.Copy(constref ASource: TLinuxIORing; var ADest: TLinuxIORing);

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A ring cannot be copied. Pass it as var or constref.');
  end;

begin
  RaiseCannotCopy;
end;

function TLinuxIORing.Map(const ASize: NativeUInt; const AOffset: Int64): PByte;

  procedure RaiseMapFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'mmap of the ring');
  end;

begin
  Result := fpmmap(nil, ASize, PROT_READ or PROT_WRITE, MAP_SHARED or MAP_POPULATE_FLAG, FFd, AOffset);

  if Pointer(Result) = MAP_FAILED then
    RaiseMapFailed;
end;

procedure TLinuxIORing.Unmap;
begin
  if FSqes <> nil then
    fpmunmap(FSqes, FSqesSize);

  if FRingMemory <> nil then
    fpmunmap(FRingMemory, FRingMemorySize);

  FSqes := nil;
  FRingMemory := nil;
end;

procedure TLinuxIORing.Open(const ASubmissionQueueSize, ACompletionQueueSize: Cardinal);

  procedure RaiseAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The ring is already open');
  end;

  procedure RaiseNotAvailable; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EIORingNotSupported, GNotAvailableReason);
  end;

  procedure RaiseSetupFailed(const AResult: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(AResult, 'io_uring_setup');
  end;

var
  LEntries: Cardinal;
  LCompletionEntries: Cardinal;
  LResult: Integer;
  LSqRingSize: NativeUInt;
  LCqRingSize: NativeUInt;
  LIndex: Cardinal;
begin
  if FFd >= 0 then
    RaiseAlreadyOpen;

  if not Available then
    RaiseNotAvailable;

  LEntries := ASubmissionQueueSize;

  if LEntries = 0 then
    LEntries := 1;

  // The completion queue at least twice the submission queue, as on Windows
  LCompletionEntries := ACompletionQueueSize;

  if (LEntries <= MAX_SUBMISSION_QUEUE_SIZE) and (LCompletionEntries < 2 * LEntries) then
    LCompletionEntries := 2 * LEntries;

  FillChar(FParams, SizeOf(FParams), 0);
  FParams.flags := IORING_SETUP_CQSIZE;
  FParams.cq_entries := LCompletionEntries;
  LResult := io_uring_setup(LEntries, @FParams);

  if LResult < 0 then
    RaiseSetupFailed(LResult);

  FFd := LResult;

  try
    // One mapping for both rings (IORING_FEAT_SINGLE_MMAP)
    LSqRingSize := FParams.sq_off.&array + FParams.sq_entries * SizeOf(Cardinal);
    LCqRingSize := FParams.cq_off.cqes + FParams.cq_entries * SizeOf(io_uring_cqe);
    FRingMemorySize := LSqRingSize;

    if LCqRingSize > FRingMemorySize then
      FRingMemorySize := LCqRingSize;

    FRingMemory := Map(FRingMemorySize, IORING_OFF_SQ_RING);
    FSqesSize := FParams.sq_entries * SizeOf(io_uring_sqe);
    FSqes := Map(FSqesSize, IORING_OFF_SQES);

    FSqTail := PCardinal(FRingMemory + FParams.sq_off.tail);
    FSqMask := PCardinal(FRingMemory + FParams.sq_off.ring_mask)^;
    FCqHead := PCardinal(FRingMemory + FParams.cq_off.head);
    FCqTail := PCardinal(FRingMemory + FParams.cq_off.tail);
    FCqMask := PCardinal(FRingMemory + FParams.cq_off.ring_mask)^;
    FCqes := FRingMemory + FParams.cq_off.cqes;

    // The SQ array maps ring slot I to SQE I, for good
    for LIndex := 0 to FParams.sq_entries - 1 do
      PCardinal(FRingMemory + FParams.sq_off.&array + LIndex * SizeOf(Cardinal))^ := LIndex;

    FSqLocalTail := FSqTail^;

    FSubmissionQueueSize := FParams.sq_entries;
    FCompletionQueueSize := FParams.cq_entries;
  except
    Unmap;
    FpClose(FFd);
    FFd := -1;
    raise;
  end;
end;

procedure TLinuxIORing.WaitForAllPending;
var
  LCompletion: TIORingCompletion;
  LResult: Integer;
begin
  while FPendingCount > 0 do
  begin
    while TryPopCompletion(LCompletion) do
    begin
      // Do Nothing
    end;

    if FPendingCount > 0 then
    begin
      LResult := io_uring_enter(FFd, 0, 1, IORING_ENTER_GETEVENTS, nil);

      if (LResult < 0) and (LResult <> -ESysEINTR) then
        Break;    // cannot wait: give up rather than hang
    end;
  end;
end;

procedure TLinuxIORing.Close;
begin
  if FFd < 0 then
    Exit;

  try
    // Wait for the submitted operations, so the kernel is done with the caller's buffers before Close returns
    WaitForAllPending;
  finally
    {
      The kernel frees a closed ring later, in the background; registered buffers stay pinned and counted
      against RLIMIT_MEMLOCK until then, so readers opened one after another could run out of it. Unregistering
      gives the memory back at once.
    }
    if FRegisteredBuffers <> nil then
      io_uring_register(FFd, IORING_UNREGISTER_BUFFERS, nil, 0);

    io_uring_register(FFd, IORING_UNREGISTER_FILES, nil, 0);
    Unmap;

    if FEventFd >= 0 then
      FpClose(FEventFd);

    FpClose(FFd);
    FFd := -1;
    FEventFd := -1;
    FSubmissionQueueSize := 0;
    FCompletionQueueSize := 0;
    FPreparedCount := 0;
    FPendingCount := 0;
    FRegisteredBuffers := nil;
    FLocalCompletions := nil;
    FLocalFirst := 0;
    FKeepAlive := nil;
  end;
end;

function TLinuxIORing.IsOpen: Boolean;
begin
  Result := FFd >= 0;
end;

{ TLinuxIORing - prepare }

procedure RaiseRingNotOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseIORingError('The ring is not open');
end;

{ Room check, as on Windows: an entry needs a free submission queue slot and room for its completion. Keeping
  PreparedCount + PendingCount within the completion queue size means the completion queue never overflows. }
function TLinuxIORing.NextSqe: Pio_uring_sqe;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  if (FPreparedCount + FPendingCount >= FCompletionQueueSize) or (FPreparedCount >= FSubmissionQueueSize) then
    Exit(nil);

  Result := Pio_uring_sqe(FSqes + (FSqLocalTail and FSqMask) * SizeOf(io_uring_sqe));

  FillChar(Result^, SizeOf(io_uring_sqe), 0);
  Inc(FSqLocalTail);
  Inc(FPreparedCount);
end;

function TLinuxIORing.PrepareReadWrite(const AOpcode, AFixedOpcode: Byte; const AFile: TIORingFileRef;
  const ABuffer: TIORingBufferRef; const ACount: Cardinal; const AOffset: UInt64;
  const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags; const ARwFlags: Cardinal): Boolean;
var
  LSqe: Pio_uring_sqe;
begin
  LSqe := NextSqe;

  if LSqe = nil then
    Exit(False);

  if ABuffer.Registered then
  begin
    LSqe^.opcode := AFixedOpcode;
    LSqe^.buf_index := Word(ABuffer.Index);

    { The kernel wants the address inside the registered buffer. An index that is not registered: the kernel
      fails the operation (-EFAULT). }
    if ABuffer.Index < Cardinal(Length(FRegisteredBuffers)) then
      LSqe^.addr := AddressOf(FRegisteredBuffers[ABuffer.Index] + ABuffer.Offset)
    else
      LSqe^.addr := ABuffer.Offset;
  end
  else
  begin
    LSqe^.opcode := AOpcode;
    LSqe^.addr := AddressOf(ABuffer.Address);
  end;

  LSqe^.flags := ToSqeFlags(AFlags);
  SetFile(LSqe, AFile);
  LSqe^.len := ACount;
  LSqe^.off := AOffset;
  LSqe^.rw_flags := ARwFlags;
  LSqe^.user_data := AUserData;

  Result := True;
end;

function TLinuxIORing.PrepareSqe(const AUserData: TIORingUserData; out ASqe: Pio_uring_sqe): Boolean;
begin
  ASqe := NextSqe;
  Result := ASqe <> nil;

  if Result then
    ASqe^.user_data := AUserData;
end;

procedure TLinuxIORing.LinkToNext(const AHard: Boolean);

  procedure RaiseNothingToLink; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('LinkToNext: no prepared entry to link');
  end;

var
  LSqe: Pio_uring_sqe;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  if FPreparedCount = 0 then
    RaiseNothingToLink;

  // The entry prepared last is still in the submission queue (not submitted)
  LSqe := Pio_uring_sqe(FSqes + ((FSqLocalTail - 1) and FSqMask) * SizeOf(io_uring_sqe));

  if AHard then
    LSqe^.flags := LSqe^.flags or IOSQE_IO_HARDLINK
  else
    LSqe^.flags := LSqe^.flags or IOSQE_IO_LINK;
end;

function TLinuxIORing.PrepareRead(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef;
  const ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags): Boolean;
begin
  Result := PrepareReadWrite(IORING_OP_READ, IORING_OP_READ_FIXED, AFile, ABuffer, ACount, AOffset, AUserData, AFlags,
    0);
end;

function TLinuxIORing.PrepareWrite(const AFile: TIORingFileRef; const ABuffer: TIORingBufferRef; const ACount: Cardinal;
  const AOffset: UInt64; const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags;
  const AWriteThrough: Boolean): Boolean;
var
  LRwFlags: Cardinal;
begin
  if AWriteThrough then
    LRwFlags := RWF_DSYNC
  else
    LRwFlags := 0;

  Result := PrepareReadWrite(IORING_OP_WRITE, IORING_OP_WRITE_FIXED, AFile, ABuffer, ACount, AOffset, AUserData, AFlags,
    LRwFlags);
end;

function TLinuxIORing.PrepareFlush(const AFile: TIORingFileRef; const AMode: TIORingFlushMode;
  const AUserData: TIORingUserData; const AFlags: TIORingSubmitFlags): Boolean;
var
  LSqe: Pio_uring_sqe;
begin
  LSqe := NextSqe;

  if LSqe = nil then
    Exit(False);

  case AMode of
    rfmDefault: LSqe^.opcode := IORING_OP_FSYNC;
    rfmData, rfmMinMetadata:
      begin
        LSqe^.opcode := IORING_OP_FSYNC;
        LSqe^.fsync_flags := IORING_FSYNC_DATASYNC;
      end;
    rfmNoSync:
      begin
        // Writes the data of the whole file (off 0, len 0), no flush command to the device
        LSqe^.opcode := IORING_OP_SYNC_FILE_RANGE;
        LSqe^.sync_range_flags := SYNC_FILE_RANGE_WAIT_BEFORE or SYNC_FILE_RANGE_WRITE or SYNC_FILE_RANGE_WAIT_AFTER;
      end;
  end;

  LSqe^.flags := ToSqeFlags(AFlags);
  SetFile(LSqe, AFile);
  LSqe^.user_data := AUserData;

  Result := True;
end;

function TLinuxIORing.PrepareVectored(const AOpcode: Byte; const AFile: TIORingFileRef; const ASegments: PIORingSegment;
  const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags; const ARwFlags: Cardinal): Boolean;
var
  LSqe: Pio_uring_sqe;
  LCopy: TBytes;
  LSegments: PIORingSegment;
  LIndex: Cardinal;
  LLeft: UInt64;
  LSegment: PIORingSegment;
begin
  LSqe := NextSqe;

  if LSqe = nil then
    Exit(False);

  { The kernel transfers the segment lengths; Windows transfers ACount bytes. So a copy of the segments, cut to ACount
    bytes (kept until nothing is in flight; the caller's array stays as it is). }
  SetLength(LCopy, ASegmentCount * SizeOf(TIORingSegment));
  LSegments := nil;

  if ASegmentCount > 0 then
  begin
    Move(ASegments^, LCopy[0], Length(LCopy));
    LSegments := PIORingSegment(@LCopy[0]);
    LLeft := ACount;

    for LIndex := 0 to ASegmentCount - 1 do
    begin
      LSegment := PIORingSegment(PByte(LSegments) + LIndex * SizeOf(TIORingSegment));

      if LSegment^.Length > LLeft then
        LSegment^.Length := LLeft;

      Dec(LLeft, LSegment^.Length);
    end;

    SetLength(FKeepAlive, Length(FKeepAlive) + 1);
    FKeepAlive[High(FKeepAlive)] := LCopy;
  end;

  LSqe^.opcode := AOpcode;
  LSqe^.flags := ToSqeFlags(AFlags);
  SetFile(LSqe, AFile);
  LSqe^.addr := AddressOf(LSegments);
  LSqe^.len := ASegmentCount;
  LSqe^.off := AOffset;
  LSqe^.rw_flags := ARwFlags;
  LSqe^.user_data := AUserData;

  Result := True;
end;

function TLinuxIORing.PrepareReadScatter(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
  const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags): Boolean;
begin
  Result := PrepareVectored(IORING_OP_READV, AFile, ASegments, ASegmentCount, ACount, AOffset, AUserData, AFlags, 0);
end;

function TLinuxIORing.PrepareWriteGather(const AFile: TIORingFileRef; const ASegments: PIORingSegment;
  const ASegmentCount, ACount: Cardinal; const AOffset: UInt64; const AUserData: TIORingUserData;
  const AFlags: TIORingSubmitFlags; const AWriteThrough: Boolean): Boolean;
var
  LRwFlags: Cardinal;
begin
  if AWriteThrough then
    LRwFlags := RWF_DSYNC
  else
    LRwFlags := 0;

  Result := PrepareVectored(IORING_OP_WRITEV, AFile, ASegments, ASegmentCount, ACount, AOffset, AUserData, AFlags,
    LRwFlags);
end;

function TLinuxIORing.PrepareCancel(const AFile: TIORingFileRef; const ATargetUserData,
  AUserData: TIORingUserData): Boolean;
var
  LSqe: Pio_uring_sqe;
begin
  LSqe := NextSqe;

  if LSqe = nil then
    Exit(False);

  LSqe^.opcode := IORING_OP_ASYNC_CANCEL;
  LSqe^.fd := -1;
  LSqe^.addr := ATargetUserData;
  LSqe^.user_data := AUserData;

  Result := True;
end;

function TLinuxIORing.LocalCompletionCount: Cardinal;
begin
  Result := Cardinal(Length(FLocalCompletions) - FLocalFirst);
end;

procedure TLinuxIORing.AddLocalCompletion(const AUserData: TIORingUserData; const AResult: Integer);
var
  LIndex: Integer;
begin
  LIndex := Length(FLocalCompletions);
  SetLength(FLocalCompletions, LIndex + 1);
  FLocalCompletions[LIndex].UserData := AUserData;

  if AResult < 0 then
    FLocalCompletions[LIndex].NativeResult := AResult
  else
    FLocalCompletions[LIndex].NativeResult := 0;

  FLocalCompletions[LIndex].BytesTransferred := 0;
  Inc(FPendingCount);
end;

function TLinuxIORing.PrepareRegisterFiles(const AHandles: array of THandle; const AUserData: TIORingUserData): Boolean;
var
  LResult: Integer;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(False);

  // A second registration fails with EBUSY: remove the old one first (ENXIO when there is none)
  io_uring_register(FFd, IORING_UNREGISTER_FILES, nil, 0);

  if Length(AHandles) > 0 then
    LResult := io_uring_register(FFd, IORING_REGISTER_FILES, @AHandles[0], Length(AHandles))
  else
    LResult := 0;

  AddLocalCompletion(AUserData, LResult);

  Result := True;
end;

function TLinuxIORing.PrepareRegisterBuffers(const ABuffers: array of TIORingBufferInfo;
  const AUserData: TIORingUserData): Boolean;
var
  LSegments: array of TIORingSegment;
  LIndex: Integer;
  LResult: Integer;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  if FPreparedCount + FPendingCount >= FCompletionQueueSize then
    Exit(False);

  io_uring_register(FFd, IORING_UNREGISTER_BUFFERS, nil, 0);
  FRegisteredBuffers := nil;
  LResult := 0;

  if Length(ABuffers) > 0 then
  begin
    // Address nil and length 0: a sparse entry (Linux 5.13 and newer)
    SetLength(LSegments, Length(ABuffers));

    for LIndex := 0 to High(ABuffers) do
    begin
      LSegments[LIndex].Address := ABuffers[LIndex].Address;
      LSegments[LIndex].Length := ABuffers[LIndex].Length;
    end;

    LResult := io_uring_register(FFd, IORING_REGISTER_BUFFERS, @LSegments[0], Length(LSegments));

    if LResult >= 0 then
    begin
      SetLength(FRegisteredBuffers, Length(ABuffers));

      for LIndex := 0 to High(ABuffers) do
        FRegisteredBuffers[LIndex] := ABuffers[LIndex].Address;
    end;
  end;

  AddLocalCompletion(AUserData, LResult);

  Result := True;
end;

{ TLinuxIORing - submit and reap }

function TLinuxIORing.ReadyCount: Cardinal;
begin
  Result := LocalCompletionCount + (TAtomic.LoadAcquire(FCqTail^) - FCqHead^);
end;

function TLinuxIORing.SubmitAndWait(const AWaitCount, ATimeoutMilliseconds: Cardinal): Boolean;

  procedure RaiseEnterFailed(const AResult: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(AResult, 'io_uring_enter');
  end;

var
  LWaitCount: Cardinal;
  LMinComplete: Cardinal;
  LFlags: Cardinal;
  LTimeout: __kernel_timespec;
  LArg: io_uring_getevents_arg;
  LArgPointer: Pointer;
  LArgSize: NativeUInt;
  LResult: Integer;
  LDone: Boolean;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  // Never wait for more completions than there can be
  LWaitCount := AWaitCount;

  if LWaitCount > FPreparedCount + FPendingCount then
    LWaitCount := FPreparedCount + FPendingCount;

  if (FPreparedCount = 0) and (ReadyCount >= LWaitCount) then
    Exit(True);

  // Hand the prepared SQEs to the kernel: their contents before the tail
  TAtomic.StoreRelease(FSqTail^, FSqLocalTail);

  LTimeout.tv_sec := ATimeoutMilliseconds div 1000;
  LTimeout.tv_nsec := Int64(ATimeoutMilliseconds mod 1000) * 1000000;
  FillChar(LArg, SizeOf(LArg), 0);
  LArg.ts := AddressOf(@LTimeout);

  repeat
    LFlags := 0;
    LMinComplete := 0;
    LArgPointer := nil;
    LArgSize := 0;

    if ReadyCount < LWaitCount then
    begin
      // The kernel counts only the completions in its queue
      LFlags := IORING_ENTER_GETEVENTS;
      LMinComplete := LWaitCount - LocalCompletionCount;

      if ATimeoutMilliseconds <> IORING_INFINITE then
      begin
        LFlags := LFlags or IORING_ENTER_EXT_ARG;
        LArgPointer := @LArg;
        LArgSize := SizeOf(LArg);
      end;
    end;

    LResult := io_uring_enter2(FFd, FPreparedCount, LMinComplete, LFlags, LArgPointer, LArgSize);

    if (LResult < 0) and (LResult <> -ESysEINTR) and (LResult <> -ESysETIME) then
      RaiseEnterFailed(LResult);

    if LResult >= 0 then
    begin
      { The kernel stops at an entry that fails early (its error comes in a completion); the next
        call goes on with the rest }
      Dec(FPreparedCount, Cardinal(LResult));
      Inc(FPendingCount, Cardinal(LResult));
      LDone := (FPreparedCount = 0) or (LResult = 0);
    end
    else
      LDone := LResult = -ESysETIME;        // a signal (EINTR): again; the wait timed out: done
  until LDone;

  Result := ReadyCount >= LWaitCount;
end;

function TLinuxIORing.Submit(const AWaitCount, ATimeoutMilliseconds: Cardinal): Cardinal;
var
  LPrepared: Cardinal;
begin
  LPrepared := FPreparedCount;
  SubmitAndWait(AWaitCount, ATimeoutMilliseconds);

  Result := LPrepared - FPreparedCount;
end;

function TLinuxIORing.WaitForCompletions(const ACount, ATimeoutMilliseconds: Cardinal): Boolean;
begin
  Result := SubmitAndWait(ACount, ATimeoutMilliseconds);
end;

function TLinuxIORing.TryPopCompletion(out ACompletion: TIORingCompletion): Boolean;
var
  LHead: Cardinal;
  LCqe: Pio_uring_cqe;
begin
  if FLocalFirst < Length(FLocalCompletions) then
  begin
    ACompletion := FLocalCompletions[FLocalFirst];
    Inc(FLocalFirst);

    if FLocalFirst = Length(FLocalCompletions) then
    begin
      FLocalCompletions := nil;
      FLocalFirst := 0;
    end;

    Dec(FPendingCount);

    Exit(True);
  end;

  if FPendingCount = 0 then
    Exit(False);

  // Only this thread moves the head; the kernel moves the tail
  LHead := FCqHead^;

  if LHead = TAtomic.LoadAcquire(FCqTail^) then
    Exit(False);

  LCqe := Pio_uring_cqe(FCqes + (LHead and FCqMask) * SizeOf(io_uring_cqe));
  ACompletion.UserData := TIORingUserData(LCqe^.user_data);

  if LCqe^.res < 0 then
  begin
    ACompletion.NativeResult := LCqe^.res;
    ACompletion.BytesTransferred := 0;
  end
  else
  begin
    ACompletion.NativeResult := 0;
    ACompletion.BytesTransferred := NativeUInt(LCqe^.res);
  end;

  // The CQE is read before its slot is given back
  TAtomic.StoreRelease(FCqHead^, LHead + 1);

  Dec(FPendingCount);

  // Nothing in flight and nothing prepared: no segment copy is needed any more
  if (FPendingCount = 0) and (FPreparedCount = 0) and (FKeepAlive <> nil) then
    FKeepAlive := nil;

  Result := True;
end;

function TLinuxIORing.PopCompletions(var ACompletions: array of TIORingCompletion): Integer;
begin
  Result := 0;

  while (Result <= High(ACompletions)) and TryPopCompletion(ACompletions[Result]) do
    Inc(Result);
end;

function TLinuxIORing.CompletionEventHandle: THandle;

  procedure RaiseEventFdFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(-fpgeterrno, 'eventfd');
  end;

  procedure RaiseRegisterEventFdFailed(const AResult: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNative(AResult, 'IORING_REGISTER_EVENTFD');
  end;

var
  LFd: Integer;
  LResult: Integer;
begin
  if FFd < 0 then
    RaiseRingNotOpen;

  if FEventFd < 0 then
  begin
    LFd := Integer(do_SysCall(SYSCALL_EVENTFD2, 0, EFD_CLOEXEC));

    if LFd < 0 then
      RaiseEventFdFailed;

    LResult := io_uring_register(FFd, IORING_REGISTER_EVENTFD, @LFd, 1);

    if LResult < 0 then
    begin
      FpClose(LFd);
      RaiseRegisterEventFdFailed(LResult);
    end;

    FEventFd := LFd;
  end;

  Result := THandle(FEventFd);
end;

{ TLinuxIORing - capabilities }

class function TLinuxIORing.Available: Boolean;
begin
  if GAvailability = 0 then
    CheckAvailability;

  Result := GAvailability > 0;
end;

class function TLinuxIORing.QueryCapabilities: TIORingCapabilities;
begin
  Available;
  Result.BackendName := '';
  Result.NativeVersion := GKernelVersion;
  Result.MaxSubmissionQueueSize := 0;
  Result.MaxCompletionQueueSize := 0;
  Result.SupportedOps := GSupportedOps;
  Result.Emulated := False;
  Result.SystemDescription := SystemDescription;
  Result.NotAvailableReason := GNotAvailableReason;
  Result.NativeFeatures := GNativeFeatures;
  Result.NativeOps := GNativeOps;
  Result.Extras := [];

  if GSupportedOps <> [] then
  begin
    Result.BackendName := 'Linux io_uring';
    Result.MaxSubmissionQueueSize := MAX_SUBMISSION_QUEUE_SIZE;
    Result.MaxCompletionQueueSize := MAX_COMPLETION_QUEUE_SIZE;
  end;

  if GAvailability > 0 then
  begin
    // PrepareSqe and LinkToNext work with every kernel the library accepts
    Result.Extras := [ieLinkedOps, ieRawEntries];

    if [IORING_OP_SEND, IORING_OP_RECV, IORING_OP_ACCEPT, IORING_OP_CONNECT] <= GNativeOps then
      Include(Result.Extras, ieSockets);

    if SqPollAllowed then
      Include(Result.Extras, ieSqPoll);
  end;
end;

end.
