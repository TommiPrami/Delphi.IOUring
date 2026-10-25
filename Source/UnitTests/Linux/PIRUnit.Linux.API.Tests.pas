unit PIRUnit.Linux.API.Tests;

{
  Calls the real kernel through PIRUnit.Linux.API: sets up
  rings, maps their memory, sends requests through them, registers files and
  buffers, asks the kernel which opcodes it has, and checks the errors.
  Besides the three system call wrappers this checks the records with the
  kernel itself: a wrong field would send a wrong request.

  The rings are used the plain way, without liburing (TTestRing): an SQE is
  written, then the SQ tail is stored; a CQE is read, then the CQ head is
  stored; with the memory barriers of the RTL in between.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Linux.API, PIRUnit.Test.Support;

type
  // A ring of a test, with its memory mapped
  TTestRing = record
  private
    FSqTail: Cardinal;      // SQEs taken so far (the SQ tail stored at the next Submit)
    FToSubmit: Cardinal;    // SQEs taken and not yet submitted
    function SqWord(const AOffset: Cardinal): PCardinal;
    function CqWord(const AOffset: Cardinal): PCardinal;
    function Map(const ASize: NativeUInt; const AOffset: Int64): PByte;
  public
    Fd: Integer;
    Params: io_uring_params;  // as the kernel returned them
    SqRing: PByte;
    SqRingSize: NativeUInt;
    CqRing: PByte;
    CqRingSize: NativeUInt;
    Sqes: PByte;
    SqesSize: NativeUInt;
    // Not open (Close does nothing)
    procedure Init;
    { io_uring_setup with AParams, then maps the memory of the ring. Result: the result of io_uring_setup;
      on failure nothing is open. }
    function Open(const AEntries: Cardinal; const AParams: io_uring_params): Integer;
    procedure Close;
    // The next free SQE, zeroed; nil if the SQ is full
    function NextSqe: Pio_uring_sqe;
    { Stores the SQ tail and calls io_uring_enter for the SQEs taken since the last Submit; AWaitFor > 0: and waits for
      that many CQEs. Result: the result of io_uring_enter. }
    function Submit(const AWaitFor: Cardinal): Integer;
    function TryPopCqe(out ACqe: io_uring_cqe): Boolean;
  end;

  TLinuxApiTests = class(TIORingTestCase)
  private
    FRing: TTestRing;
    FFiles: array of string;
    FFds: array of Integer;
    procedure OpenRing(const AEntries: Cardinal);
    function PopCqe: io_uring_cqe;
    // A pattern file of ASize bytes, opened read-only; deleted and closed in TearDown
    function OpenPatternFile(const ASize: Int64): Integer;
    function KeepFd(const AFd: Integer): Integer;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Setup_FillsParams;
    procedure Setup_RoundsEntriesUpToPowerOfTwo;
    procedure Setup_CQSize;
    procedure Setup_ZeroEntries_EINVAL;
    procedure Setup_UnknownFlag_EINVAL;
    procedure Setup_ReservedNotZero_EINVAL;
    procedure Setup_TooManyEntries_EINVALOrClamped;
    procedure MapRings_RingMemoryHoldsSizes;
    procedure Nop_ReturnsUserData;
    procedure Nop_SeveralInOneCall;
    procedure Read_ReadsRightData;
    procedure Read_AtEndOfFile_ReturnsZero;
    procedure Read_BadFd_ErrorInCompletion;
    procedure Write_WritesRightData;
    procedure RegisterFiles_ReadThroughFixedFile;
    procedure RegisterBuffers_ReadFixed;
    procedure RegisterProbe_ReportsOpcodes;
    procedure Register_UnknownOpcode_EINVAL;
    procedure Enter_BadFd_EBADF;
    procedure Enter_NotARing_EOPNOTSUPP;
    procedure Enter_ExtArgTimeout_ETIME;
    procedure Timeout_CompletesWithETIME;
    procedure SqPoll_NopsComplete;
  end;

implementation

uses
  SysUtils, BaseUnix, PIRUnit.Types, PIRUnit.Test.FileHelpers;

const
  // The features the 6.8 header names (IORING_FEAT_SINGLE_MMAP .. IORING_FEAT_REG_REG_RING)
  FEATURES_OF_THE_HEADER = (1 shl 14) - 1;
  // A file descriptor no process has
  BAD_FD = 1000000;

type
  // struct iovec (sys/uio.h)
  TIOVec = record
    iov_base: Pointer;
    iov_len: NativeUInt;
  end;

// A pointer as a __u64 of a record (sqe.addr and others)
function AddressOf(const APointer: Pointer): UInt64;
begin
  Result := PByte(APointer) - PByte(nil);
end;

// ops[AIndex] of an io_uring_probe: the ops start right after the record
function ProbeOp(const AProbe: Pio_uring_probe; const AIndex: Integer): Pio_uring_probe_op;
begin
  Result := Pio_uring_probe_op(PByte(AProbe) + SizeOf(io_uring_probe) + AIndex * SizeOf(io_uring_probe_op));
end;

function TimeSpec(const AMilliseconds: Int64): __kernel_timespec;
begin
  Result.tv_sec := AMilliseconds div 1000;
  Result.tv_nsec := (AMilliseconds mod 1000) * 1000000;
end;

{ TTestRing }

procedure TTestRing.Init;
begin
  Self := Default(TTestRing);
  Fd := -1;
end;

function TTestRing.SqWord(const AOffset: Cardinal): PCardinal;
begin
  Result := PCardinal(SqRing + AOffset);
end;

function TTestRing.CqWord(const AOffset: Cardinal): PCardinal;
begin
  Result := PCardinal(CqRing + AOffset);
end;

function TTestRing.Map(const ASize: NativeUInt; const AOffset: Int64): PByte;

  procedure RaiseMapFailed(const AValue: Int64); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'mmap of offset $%x failed: errno %d', [AValue, fpgeterrno]);
  end;

begin
  Result := fpmmap(nil, ASize, PROT_READ or PROT_WRITE, MAP_SHARED, Fd, AOffset);

  if Pointer(Result) = MAP_FAILED then
    RaiseMapFailed(AOffset);
end;

function TTestRing.Open(const AEntries: Cardinal; const AParams: io_uring_params): Integer;
begin
  Init;
  Params := AParams;
  Result := io_uring_setup(AEntries, @Params);

  if Result < 0 then
    Exit;

  Fd := Result;

  try
    // The sizes as liburing computes them
    SqRingSize := Params.sq_off.&array + Params.sq_entries * SizeOf(Cardinal);
    CqRingSize := Params.cq_off.cqes + Params.cq_entries * SizeOf(io_uring_cqe);
    SqesSize := Params.sq_entries * SizeOf(io_uring_sqe);
    SqRing := Map(SqRingSize, IORING_OFF_SQ_RING);
    CqRing := Map(CqRingSize, IORING_OFF_CQ_RING);
    Sqes := Map(SqesSize, IORING_OFF_SQES);
  except
    Close;
    raise;
  end;
end;

procedure TTestRing.Close;
begin
  if Sqes <> nil then
    fpmunmap(Sqes, SqesSize);

  if CqRing <> nil then
    fpmunmap(CqRing, CqRingSize);

  if SqRing <> nil then
    fpmunmap(SqRing, SqRingSize);

  if Fd >= 0 then
    FpClose(Fd);

  Init;
end;

function TTestRing.NextSqe: Pio_uring_sqe;
var
  LHead: Cardinal;
  LIndex: Cardinal;
begin
  LHead := SqWord(Params.sq_off.head)^;  // the kernel moves the head
  ReadBarrier;

  if FSqTail - LHead >= Params.sq_entries then
    Exit(nil);

  LIndex := FSqTail and SqWord(Params.sq_off.ring_mask)^;
  Result := Pio_uring_sqe(Sqes + LIndex * SizeOf(io_uring_sqe));
  FillChar(Result^, SizeOf(io_uring_sqe), 0);
  // The SQ array: which SQE is in this slot of the ring
  PCardinal(SqRing + Params.sq_off.&array + LIndex * SizeOf(Cardinal))^ := LIndex;
  Inc(FSqTail);
  Inc(FToSubmit);
end;

function TTestRing.Submit(const AWaitFor: Cardinal): Integer;
var
  LFlags: Cardinal;
begin
  WriteBarrier;  // the SQEs before the tail
  SqWord(Params.sq_off.tail)^ := FSqTail;

  LFlags := 0;

  if AWaitFor > 0 then
    LFlags := IORING_ENTER_GETEVENTS;

  if (Params.flags and IORING_SETUP_SQPOLL) <> 0 then
  begin
    { The polling thread takes the SQEs by itself; it needs a wake-up only when it has gone to sleep. The kernel
      returns the count it was given. }
    ReadWriteBarrier;  // the tail before the flags

    if (SqWord(Params.sq_off.flags)^ and IORING_SQ_NEED_WAKEUP) <> 0 then
      LFlags := LFlags or IORING_ENTER_SQ_WAKEUP;
  end;

  Result := io_uring_enter(Fd, FToSubmit, AWaitFor, LFlags, nil);

  if Result > 0 then
    Dec(FToSubmit, Result);
end;

function TTestRing.TryPopCqe(out ACqe: io_uring_cqe): Boolean;
var
  LHead: Cardinal;
  LTail: Cardinal;
begin
  LHead := CqWord(Params.cq_off.head)^;
  LTail := CqWord(Params.cq_off.tail)^;  // the kernel moves the tail
  ReadBarrier;                            // the CQE after the tail
  Result := LHead <> LTail;

  if Result then
  begin
    ACqe := Pio_uring_cqe(CqRing + Params.cq_off.cqes +
      (LHead and CqWord(Params.cq_off.ring_mask)^) * SizeOf(io_uring_cqe))^;
    ReadWriteBarrier;  // read the CQE before its slot is given back
    CqWord(Params.cq_off.head)^ := LHead + 1;
  end;
end;

{ TLinuxApiTests }

procedure TLinuxApiTests.SetUp;
begin
  inherited SetUp;

  FRing.Init;
  FFiles := nil;
  FFds := nil;
end;

procedure TLinuxApiTests.TearDown;
var
  I: Integer;
begin
  FRing.Close;

  for I := 0 to High(FFds) do
    FpClose(FFds[I]);

  for I := 0 to High(FFiles) do
    TTestFileHelpers.DeleteTestFile(FFiles[I]);

  inherited TearDown;
end;

procedure TLinuxApiTests.OpenRing(const AEntries: Cardinal);
var
  LResult: Integer;
begin
  LResult := FRing.Open(AEntries, Default(io_uring_params));
  AssertTrue('io_uring_setup: ' + IntToStr(LResult), LResult >= 0);
end;

function TLinuxApiTests.PopCqe: io_uring_cqe;
begin
  AssertTrue('A completion', FRing.TryPopCqe(Result));
end;

function TLinuxApiTests.KeepFd(const AFd: Integer): Integer;
begin
  AssertTrue('open: errno ' + IntToStr(fpgeterrno), AFd >= 0);
  SetLength(FFds, Length(FFds) + 1);
  FFds[High(FFds)] := AFd;

  Result := AFd;
end;

function TLinuxApiTests.OpenPatternFile(const ASize: Int64): Integer;
var
  LFileName: string;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(ASize, 'Posix');
  SetLength(FFiles, Length(FFiles) + 1);
  FFiles[High(FFiles)] := LFileName;

  Result := KeepFd(FpOpen(LFileName, O_RDONLY));
end;

procedure TLinuxApiTests.Setup_FillsParams;
var
  LParams: io_uring_params;
  LFd: Integer;
begin
  LParams := Default(io_uring_params);
  LFd := io_uring_setup(8, @LParams);
  AssertTrue('io_uring_setup: ' + IntToStr(LFd), LFd >= 0);

  try
    AssertEquals('sq_entries', 8, LParams.sq_entries);
    AssertEquals('cq_entries (twice sq_entries)', 16, LParams.cq_entries);
    AssertTrue('IORING_FEAT_SINGLE_MMAP', LParams.features and IORING_FEAT_SINGLE_MMAP <> 0);
    AssertTrue('IORING_FEAT_NODROP', LParams.features and IORING_FEAT_NODROP <> 0);
    AssertTrue('sq_off.array', LParams.sq_off.&array > 0);
    AssertTrue('cq_off.cqes', LParams.cq_off.cqes > 0);
    Log(Format('features $%x; not named in the 6.8 header: $%x',
      [LParams.features, LParams.features and not Cardinal(FEATURES_OF_THE_HEADER)]));
  finally
    FpClose(LFd);
  end;
end;

procedure TLinuxApiTests.Setup_RoundsEntriesUpToPowerOfTwo;
begin
  OpenRing(5);
  AssertEquals('sq_entries', 8, FRing.Params.sq_entries);
  AssertEquals('cq_entries', 16, FRing.Params.cq_entries);
end;

procedure TLinuxApiTests.Setup_CQSize;
var
  LParams: io_uring_params;
  LResult: Integer;
begin
  LParams := Default(io_uring_params);
  LParams.flags := IORING_SETUP_CQSIZE;
  LParams.cq_entries := 100;
  LResult := FRing.Open(8, LParams);
  AssertTrue('io_uring_setup: ' + IntToStr(LResult), LResult >= 0);
  AssertEquals('sq_entries', 8, FRing.Params.sq_entries);
  AssertEquals('cq_entries (100 rounded up)', 128, FRing.Params.cq_entries);
end;

procedure TLinuxApiTests.Setup_ZeroEntries_EINVAL;
var
  LParams: io_uring_params;
begin
  LParams := Default(io_uring_params);
  AssertEquals('io_uring_setup', -ESysEINVAL, io_uring_setup(0, @LParams));
end;

procedure TLinuxApiTests.Setup_UnknownFlag_EINVAL;
var
  LParams: io_uring_params;
begin
  LParams := Default(io_uring_params);
  LParams.flags := 1 shl 30;
  AssertEquals('io_uring_setup', -ESysEINVAL, io_uring_setup(8, @LParams));
end;

procedure TLinuxApiTests.Setup_ReservedNotZero_EINVAL;
var
  LParams: io_uring_params;
begin
  LParams := Default(io_uring_params);
  LParams.resv[2] := 1;
  AssertEquals('io_uring_setup', -ESysEINVAL, io_uring_setup(8, @LParams));
end;

procedure TLinuxApiTests.Setup_TooManyEntries_EINVALOrClamped;
var
  LParams: io_uring_params;
  LResult: Integer;
begin
  // The kernel's limit is 32768 SQ entries (IORING_MAX_ENTRIES)
  LParams := Default(io_uring_params);
  AssertEquals('io_uring_setup', -ESysEINVAL, io_uring_setup(65536, @LParams));

  LParams := Default(io_uring_params);
  LParams.flags := IORING_SETUP_CLAMP;
  LResult := FRing.Open(65536, LParams);
  AssertTrue('io_uring_setup with IORING_SETUP_CLAMP: ' + IntToStr(LResult), LResult >= 0);
  AssertEquals('sq_entries', 32768, FRing.Params.sq_entries);
  AssertEquals('cq_entries', 65536, FRing.Params.cq_entries);
end;

procedure TLinuxApiTests.MapRings_RingMemoryHoldsSizes;
begin
  OpenRing(16);
  AssertEquals('SQ ring_mask', 15, FRing.SqWord(FRing.Params.sq_off.ring_mask)^);
  AssertEquals('SQ ring_entries', 16, FRing.SqWord(FRing.Params.sq_off.ring_entries)^);
  AssertEquals('SQ head', 0, FRing.SqWord(FRing.Params.sq_off.head)^);
  AssertEquals('SQ tail', 0, FRing.SqWord(FRing.Params.sq_off.tail)^);
  AssertEquals('CQ ring_mask', 31, FRing.CqWord(FRing.Params.cq_off.ring_mask)^);
  AssertEquals('CQ ring_entries', 32, FRing.CqWord(FRing.Params.cq_off.ring_entries)^);
  AssertEquals('CQ head', 0, FRing.CqWord(FRing.Params.cq_off.head)^);
  AssertEquals('CQ tail', 0, FRing.CqWord(FRing.Params.cq_off.tail)^);
end;

procedure TLinuxApiTests.Nop_ReturnsUserData;
var
  LSqe: Pio_uring_sqe;
  LCqe: io_uring_cqe;
begin
  OpenRing(8);
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_NOP;
  LSqe^.user_data := UInt64($FEDCBA9876543210);
  AssertEquals('submitted', 1, FRing.Submit(1));

  LCqe := PopCqe;
  AssertTrue('user_data', LCqe.user_data = UInt64($FEDCBA9876543210));
  AssertEquals('res', 0, LCqe.res);
  AssertEquals('flags', 0, LCqe.flags);
  AssertFalse('One completion only', FRing.TryPopCqe(LCqe));
end;

procedure TLinuxApiTests.Nop_SeveralInOneCall;
var
  I: Integer;
  LSqe: Pio_uring_sqe;
  LCqe: io_uring_cqe;
  LSeen: Cardinal;
begin
  OpenRing(8);

  for I := 1 to 8 do
  begin
    LSqe := FRing.NextSqe;
    LSqe^.opcode := IORING_OP_NOP;
    LSqe^.user_data := I;
  end;

  AssertTrue('The SQ is full', FRing.NextSqe = nil);
  AssertEquals('submitted', 8, FRing.Submit(8));

  LSeen := 0;

  for I := 1 to 8 do
  begin
    LCqe := PopCqe;
    AssertEquals('res', 0, LCqe.res);
    LSeen := LSeen or (Cardinal(1) shl LCqe.user_data);
  end;

  AssertEquals('user_data 1..8', $1FE, LSeen);
end;

procedure TLinuxApiTests.Read_ReadsRightData;
var
  LFile: Integer;
  LBuffer: array[0..4095] of Byte;
  LSqe: Pio_uring_sqe;
  LCqe: io_uring_cqe;
begin
  OpenRing(8);
  LFile := OpenPatternFile(65536);
  FillChar(LBuffer, SizeOf(LBuffer), 0);

  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  LSqe^.off := 12345;
  LSqe^.user_data := 1;
  AssertEquals('submitted', 1, FRing.Submit(1));

  LCqe := PopCqe;
  AssertEquals('res (bytes read)', SizeOf(LBuffer), LCqe.res);
  CheckPattern(12345, @LBuffer, SizeOf(LBuffer));
end;

procedure TLinuxApiTests.Read_AtEndOfFile_ReturnsZero;
var
  LFile: Integer;
  LBuffer: array[0..4095] of Byte;
  LSqe: Pio_uring_sqe;
begin
  OpenRing(8);
  LFile := OpenPatternFile(65536);

  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  LSqe^.off := 65536;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (bytes read)', 0, PopCqe.res);

  // Crossing the end: the bytes up to the end
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  LSqe^.off := 65536 - 100;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (bytes read)', 100, PopCqe.res);
end;

procedure TLinuxApiTests.Read_BadFd_ErrorInCompletion;
var
  LBuffer: array[0..511] of Byte;
  LSqe: Pio_uring_sqe;
begin
  OpenRing(8);
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.fd := BAD_FD;
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  // The request is submitted; its error comes in the completion
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res', -ESysEBADF, PopCqe.res);
end;

procedure TLinuxApiTests.Write_WritesRightData;
var
  LFileName: string;
  LFile: Integer;
  LData: array[0..8191] of Byte;
  LBack: array[0..8191] of Byte;
  LSqe: Pio_uring_sqe;
  LCheck: THandle;
begin
  OpenRing(8);
  LFileName := TTestFileHelpers.NewTestFileName('PosixWrite');
  SetLength(FFiles, Length(FFiles) + 1);
  FFiles[High(FFiles)] := LFileName;
  LFile := KeepFd(FpOpen(LFileName, O_RDWR or O_CREAT or O_TRUNC, &644));
  TTestFileHelpers.FillPattern(4096, LData, SizeOf(LData));

  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_WRITE;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LData);
  LSqe^.len := SizeOf(LData);
  LSqe^.off := 4096;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (bytes written)', SizeOf(LData), PopCqe.res);

  LCheck := FileOpen(LFileName, fmOpenRead or fmShareDenyNone);
  AssertTrue('FileOpen', LCheck <> THandle(-1));

  try
    AssertEquals('file size', 4096 + SizeOf(LData), FileSeek(LCheck, Int64(0), fsFromEnd));
    FileSeek(LCheck, 4096, fsFromBeginning);
    AssertEquals('FileRead', SizeOf(LBack), FileRead(LCheck, LBack, SizeOf(LBack)));
  finally
    FileClose(LCheck);
  end;

  CheckPattern(4096, @LBack, SizeOf(LBack));
end;

procedure TLinuxApiTests.RegisterFiles_ReadThroughFixedFile;
var
  LFds: array[0..1] of Integer;
  LBuffer: array[0..4095] of Byte;
  LSqe: Pio_uring_sqe;
begin
  OpenRing(8);
  LFds[0] := -1;  // an empty slot
  LFds[1] := OpenPatternFile(65536);
  AssertEquals('IORING_REGISTER_FILES', 0, io_uring_register(FRing.Fd, IORING_REGISTER_FILES, @LFds, 2));

  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.flags := IOSQE_FIXED_FILE;
  LSqe^.fd := 1;  // the index into the registered files
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  LSqe^.off := 8192;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (bytes read)', SizeOf(LBuffer), PopCqe.res);
  CheckPattern(8192, @LBuffer, SizeOf(LBuffer));

  // The empty slot
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.flags := IOSQE_FIXED_FILE;
  LSqe^.fd := 0;
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (empty slot)', -ESysEBADF, PopCqe.res);

  AssertEquals('IORING_UNREGISTER_FILES', 0, io_uring_register(FRing.Fd, IORING_UNREGISTER_FILES, nil, 0));
end;

procedure TLinuxApiTests.RegisterBuffers_ReadFixed;
var
  LFile: Integer;
  LBuffer: array of Byte;
  LVec: TIOVec;
  LSqe: Pio_uring_sqe;
begin
  OpenRing(8);
  LFile := OpenPatternFile(65536);
  SetLength(LBuffer, 16384);
  LVec.iov_base := @LBuffer[0];
  LVec.iov_len := Length(LBuffer);
  AssertEquals('IORING_REGISTER_BUFFERS', 0, io_uring_register(FRing.Fd, IORING_REGISTER_BUFFERS, @LVec, 1));

  // Into the middle of registered buffer 0
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ_FIXED;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LBuffer[4096]);
  LSqe^.len := 8192;
  LSqe^.off := 20480;
  LSqe^.buf_index := 0;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (bytes read)', 8192, PopCqe.res);
  CheckPattern(20480, @LBuffer[4096], 8192);

  // Outside the registered buffer
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_READ_FIXED;
  LSqe^.fd := LFile;
  LSqe^.addr := AddressOf(@LBuffer[12288]);
  LSqe^.len := 8192;
  LSqe^.buf_index := 0;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertEquals('res (past the buffer)', -ESysEFAULT, PopCqe.res);

  AssertEquals('IORING_UNREGISTER_BUFFERS', 0, io_uring_register(FRing.Fd, IORING_UNREGISTER_BUFFERS, nil, 0));
end;

procedure TLinuxApiTests.RegisterProbe_ReportsOpcodes;
const
  OPS = 256;
  CORE_OPS: array[0..9] of Integer = (IORING_OP_NOP, IORING_OP_READV, IORING_OP_WRITEV, IORING_OP_FSYNC,
    IORING_OP_READ_FIXED, IORING_OP_WRITE_FIXED, IORING_OP_TIMEOUT, IORING_OP_ASYNC_CANCEL, IORING_OP_READ,
    IORING_OP_WRITE);
var
  LBuffer: array of Byte;
  LProbe: Pio_uring_probe;
  I: Integer;
  LSupported: Integer;
begin
  OpenRing(8);
  // The kernel wants the memory zeroed (SetLength does that)
  SetLength(LBuffer, SizeOf(io_uring_probe) + OPS * SizeOf(io_uring_probe_op));
  LProbe := @LBuffer[0];
  AssertEquals('IORING_REGISTER_PROBE', 0, io_uring_register(FRing.Fd, IORING_REGISTER_PROBE, LProbe, OPS));

  AssertEquals('ops_len', LProbe^.last_op + 1, LProbe^.ops_len);
  LSupported := 0;

  for I := 0 to LProbe^.ops_len - 1 do
  begin
    AssertEquals('ops[I].op', I, ProbeOp(LProbe, I)^.op);

    if ProbeOp(LProbe, I)^.flags and IO_URING_OP_SUPPORTED <> 0 then
      Inc(LSupported);
  end;

  for I := 0 to High(CORE_OPS) do
    AssertTrue('Opcode ' + IntToStr(CORE_OPS[I]) + ' supported',
      ProbeOp(LProbe, CORE_OPS[I])^.flags and IO_URING_OP_SUPPORTED <> 0);

  Log(Format('last_op %d (the 6.8 header: %d), %d opcodes supported',
    [LProbe^.last_op, IORING_OP_LAST - 1, LSupported]));
end;

procedure TLinuxApiTests.Register_UnknownOpcode_EINVAL;
begin
  OpenRing(8);
  AssertEquals('io_uring_register', -ESysEINVAL, io_uring_register(FRing.Fd, 9999, nil, 0));
end;

procedure TLinuxApiTests.Enter_BadFd_EBADF;
begin
  AssertEquals('io_uring_enter', -ESysEBADF, io_uring_enter(BAD_FD, 0, 0, 0, nil));
end;

procedure TLinuxApiTests.Enter_NotARing_EOPNOTSUPP;
begin
  AssertEquals('io_uring_enter', -ESysEOPNOTSUPP, io_uring_enter(OpenPatternFile(4096), 0, 0, 0, nil));
end;

procedure TLinuxApiTests.Enter_ExtArgTimeout_ETIME;
var
  LTimeout: __kernel_timespec;
  LArg: io_uring_getevents_arg;
  LStart: QWord;
begin
  OpenRing(8);
  LTimeout := TimeSpec(20);
  LArg := Default(io_uring_getevents_arg);
  LArg.ts := AddressOf(@LTimeout);

  // Nothing submitted: waits for one completion, until the timeout
  LStart := GetTickCount64;
  AssertEquals('io_uring_enter2', -ESysETIME, io_uring_enter2(FRing.Fd, 0, 1,
    IORING_ENTER_GETEVENTS or IORING_ENTER_EXT_ARG, @LArg, SizeOf(LArg)));
  AssertTrue('Waited', GetTickCount64 - LStart >= 15);
end;

procedure TLinuxApiTests.Timeout_CompletesWithETIME;
var
  LTimeout: __kernel_timespec;
  LSqe: Pio_uring_sqe;
  LStart: QWord;
  LCqe: io_uring_cqe;
begin
  OpenRing(8);
  LTimeout := TimeSpec(20);
  LSqe := FRing.NextSqe;
  LSqe^.opcode := IORING_OP_TIMEOUT;
  LSqe^.addr := AddressOf(@LTimeout);
  LSqe^.len := 1;
  LSqe^.off := 0;  // no completion count: only the time
  LSqe^.user_data := 42;

  LStart := GetTickCount64;
  AssertEquals('submitted', 1, FRing.Submit(1));
  AssertTrue('Waited', GetTickCount64 - LStart >= 15);
  LCqe := PopCqe;
  AssertEquals('user_data', 42, LCqe.user_data);
  AssertEquals('res', -ESysETIME, LCqe.res);
end;

{ SQPOLL is reachable through this unit only (Docs/Design.md §5.8): a kernel thread takes the submissions. Allowed
  without root since Linux 5.11. }
procedure TLinuxApiTests.SqPoll_NopsComplete;
var
  LParams: io_uring_params;
  LSqe: Pio_uring_sqe;
  LCqe: io_uring_cqe;
  LResult: Integer;
  LRound: Integer;
  LIndex: Integer;
begin
  FillChar(LParams, SizeOf(LParams), 0);
  LParams.flags := IORING_SETUP_SQPOLL;
  LParams.sq_thread_idle := 10;    // ms until the polling thread sleeps
  LResult := FRing.Open(8, LParams);

  if LResult = -ESysEPERM then
  begin
    Log('SQPOLL is not allowed here (EPERM): not tested');
    AssertTrue(True);

    Exit;
  end;

  AssertTrue('setup: ' + IntToStr(LResult), LResult >= 0);
  AssertTrue('Kept the flag', (FRing.Params.flags and IORING_SETUP_SQPOLL) <> 0);

  // Twice: the second time after the polling thread has gone to sleep, so the wake-up is needed
  for LRound := 1 to 2 do
  begin
    if LRound = 2 then
      Sleep(50);

    for LIndex := 1 to 3 do
    begin
      LSqe := FRing.NextSqe;
      LSqe^.opcode := IORING_OP_NOP;
      LSqe^.user_data := LRound * 10 + LIndex;
    end;

    AssertEquals('submitted', 3, FRing.Submit(3));

    for LIndex := 1 to 3 do
    begin
      LCqe := PopCqe;
      AssertEquals('res', 0, LCqe.res);
      AssertTrue('user_data', (LCqe.user_data > UInt64(LRound * 10)) and (LCqe.user_data <= UInt64(LRound * 10 + 3)));
    end;
  end;
end;

initialization
  RegisterTests(TLinuxApiTests);

end.
