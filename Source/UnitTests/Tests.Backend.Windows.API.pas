unit Tests.Backend.Windows.API;

{
  Calls the real Windows IoRing API through Delphi.IOUring.Backend.Windows.API.

  Besides checking the translation, several tests answer the [VERIFY]
  questions of Docs/Design.md. Their findings are written to the test log
  (lines starting with "VERIFY:"), so run the tests with console output to
  see them.

  Requires Windows with IoRing version 4 (Windows 11 24H2 or newer).
}

interface

uses
  Winapi.Windows,
  DUnitX.TestFramework,
  Delphi.IOUring.Backend.Windows.API,
  TestPlatformHelpers;

type
  [TestFixture]
  TWindowsIoRingApiTests = class
  private
    FPatternFileName: string;
    FRing: HIORING;
    FResources: TTestResources;

    function NewRing(const ASubmissionQueueSize: UInt32 = 32; const ACompletionQueueSize: UInt32 = 0): HIORING;
    function PopAll(const ARing: HIORING): TArray<IORING_CQE>;
    function FindCompletion(const ACompletions: TArray<IORING_CQE>; const AUserData: NativeUInt): IORING_CQE;
    procedure CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt);
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure QueryIoRingCapabilities_ReportsVersion4;
    [Test]
    procedure CreateIoRing_RoundsQueueSizesToPowersOfTwo;
    [Test]
    procedure CreateIoRing_UnknownVersion_Fails;
    [Test]
    procedure CreateIoRing_TooBigSubmissionQueue_Fails;
    [Test]
    procedure IsIoRingOpSupported_AllOperations;
    [Test]
    procedure SetIoRingCompletionEvent_SignalsOnFirstCompletion;
    [Test]
    procedure ReadFile_RawRefs_ReadsRightData;
    [Test]
    procedure PopIoRingCompletion_EmptyQueue_ReturnsSFalse;
    [Test]
    procedure ReadFile_RegisteredFileAndBuffers_ReadsRightData;
    [Test]
    procedure RegisterBuffers_SparseEntry_Succeeds;
    [Test]
    procedure WriteFlushRead_WithDrain_RoundTrip;
    [Test]
    procedure ReadFileScatter_Unbuffered_ReadsRightData;
    [Test]
    procedure WriteFileGather_Unbuffered_WritesRightData;
    [Test]
    procedure ReadFileScatter_Buffered_FailsWithInvalidParameter;
    [Test]
    procedure CancelRequest_CancelsPendingPipeRead;
    [Test]
    procedure SubmitIoRing_WaitTimeout_Result;
    [Test]
    procedure BuildIoRingReadFile_SubmissionQueueFull;
    [Test]
    procedure SubmitIoRing_CompletionQueueTooFull;
    [Test]
    procedure SubmitIoRing_WhileOtherThreadWaits_SubmitInProgress;
    [Test]
    procedure ReadFile_AtAndAfterEndOfFile;
    [Test]
    procedure ReadFile_NonOverlappedHandle_Works;
    [Test]
    procedure CloseIoRing_WithPendingRead_DoesNotCancelIt;
    [Test]
    procedure CancelIoEx_CancelsPendingRingRead;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  TestFileHelpers;

const
  PATTERN_FILE_SIZE = 256 * 1024;
  WAIT_TIMEOUT_MS = 5000;

{ TWindowsIoRingApiTests - helpers }

function TWindowsIoRingApiTests.NewRing(const ASubmissionQueueSize, ACompletionQueueSize: UInt32): HIORING;
var
  LFlags: IORING_CREATE_FLAGS;
  LResult: HRESULT;
begin
  LFlags.Required := IORING_CREATE_REQUIRED_FLAGS_NONE;
  LFlags.Advisory := IORING_CREATE_ADVISORY_FLAGS_NONE;

  LResult := CreateIoRing(IORING_VERSION_4, LFlags, ASubmissionQueueSize, ACompletionQueueSize, Result);
  Assert.AreEqual(S_OK, LResult, 'CreateIoRing ' + HrToStr(LResult));
end;

function TWindowsIoRingApiTests.PopAll(const ARing: HIORING): TArray<IORING_CQE>;
var
  LCqe: IORING_CQE;
begin
  Result := nil;
  while PopIoRingCompletion(ARing, LCqe) = S_OK do
    Result := Result + [LCqe];
end;

function TWindowsIoRingApiTests.FindCompletion(const ACompletions: TArray<IORING_CQE>;
  const AUserData: NativeUInt): IORING_CQE;
var
  LCqe: IORING_CQE;
begin
  for LCqe in ACompletions do
    if LCqe.UserData = AUserData then
      Exit(LCqe);

  Assert.Fail(Format('No completion with UserData %d', [AUserData]));
end;

procedure TWindowsIoRingApiTests.CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer;
  const ACount: NativeInt);
var
  LBadOffset: UInt64;
begin
  Assert.IsTrue(TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset),
    Format('Wrong data at file offset %d', [LBadOffset]));
end;

{ TWindowsIoRingApiTests - set-up }

procedure TWindowsIoRingApiTests.SetupFixture;
begin
  FPatternFileName := TTestFileHelpers.CreatePatternFile(PATTERN_FILE_SIZE, 'ApiPattern');
end;

procedure TWindowsIoRingApiTests.TearDownFixture;
begin
  TTestFileHelpers.DeleteTestFile(FPatternFileName);
end;

procedure TWindowsIoRingApiTests.Setup;
begin
  FRing := 0;
  FResources := TTestResources.Create;
end;

procedure TWindowsIoRingApiTests.TearDown;
begin
  // CloseIoRing does not cancel operations still in flight, so every test
  // completes or cancels its own I/O before it ends
  if FRing <> 0 then
    CloseIoRing(FRing);
  FRing := 0;

  FResources.Free;
  FResources := nil;
end;

{ TWindowsIoRingApiTests - tests }

procedure TWindowsIoRingApiTests.QueryIoRingCapabilities_ReportsVersion4;
var
  LCapabilities: IORING_CAPABILITIES;
  LResult: HRESULT;
begin
  LResult := QueryIoRingCapabilities(LCapabilities);

  Assert.AreEqual(S_OK, LResult);
  Log(Format('Capabilities: MaxVersion=%d MaxSQ=%d MaxCQ=%d FeatureFlags=0x%x',
    [LCapabilities.MaxVersion, LCapabilities.MaxSubmissionQueueSize,
     LCapabilities.MaxCompletionQueueSize, LCapabilities.FeatureFlags]));
  Assert.IsTrue(LCapabilities.MaxVersion >= IORING_VERSION_4, 'IoRing version 4 required');
  Assert.AreEqual(Cardinal(0), LCapabilities.FeatureFlags and IORING_FEATURE_UM_EMULATION,
    'IoRing is user-mode emulated');
end;

procedure TWindowsIoRingApiTests.CreateIoRing_RoundsQueueSizesToPowersOfTwo;
var
  LInfo: IORING_INFO;
  LRing: HIORING;
begin
  FRing := NewRing(10, 0);
  Assert.AreEqual(S_OK, GetIoRingInfo(FRing, LInfo));
  Log(Format('Requested SQ=10 CQ=0 -> version=%d SQ=%d CQ=%d',
    [LInfo.IoRingVersion, LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize]));
  Assert.AreEqual(Cardinal(IORING_VERSION_4), LInfo.IoRingVersion);
  Assert.AreEqual(UInt32(16), LInfo.SubmissionQueueSize);
  Assert.AreEqual(UInt32(32), LInfo.CompletionQueueSize);

  LRing := NewRing(10, 100);
  try
    Assert.AreEqual(S_OK, GetIoRingInfo(LRing, LInfo));
    Log(Format('Requested SQ=10 CQ=100 -> SQ=%d CQ=%d',
      [LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize]));
    Assert.AreEqual(UInt32(16), LInfo.SubmissionQueueSize);
    Assert.AreEqual(UInt32(128), LInfo.CompletionQueueSize);
  finally
    Assert.AreEqual(S_OK, CloseIoRing(LRing));
  end;
end;

procedure TWindowsIoRingApiTests.CreateIoRing_UnknownVersion_Fails;
var
  LFlags: IORING_CREATE_FLAGS;
  LResult: HRESULT;
begin
  LFlags := Default(IORING_CREATE_FLAGS);

  LResult := CreateIoRing(12345, LFlags, 16, 0, FRing);

  Log('VERIFY: CreateIoRing with unknown version returns ' + HrToStr(LResult));
  Assert.AreEqual(IORING_E_VERSION_NOT_SUPPORTED, LResult);
  FRing := 0;
end;

procedure TWindowsIoRingApiTests.CreateIoRing_TooBigSubmissionQueue_Fails;
var
  LCapabilities: IORING_CAPABILITIES;
  LFlags: IORING_CREATE_FLAGS;
  LResult: HRESULT;
begin
  Assert.AreEqual(S_OK, QueryIoRingCapabilities(LCapabilities));
  LFlags := Default(IORING_CREATE_FLAGS);

  LResult := CreateIoRing(IORING_VERSION_4, LFlags, LCapabilities.MaxSubmissionQueueSize * 2, 0, FRing);

  Log('VERIFY: CreateIoRing with SQ = 2 x max returns ' + HrToStr(LResult));
  if Succeeded(LResult) then
    CloseIoRing(FRing);
  FRing := 0;
  Assert.AreEqual(IORING_E_SUBMISSION_QUEUE_TOO_BIG, LResult);
end;

procedure TWindowsIoRingApiTests.IsIoRingOpSupported_AllOperations;
var
  LOp: IORING_OP_CODE;
  LSupported: BOOL;
begin
  FRing := NewRing;

  for LOp := IORING_OP_NOP to IORING_OP_WRITE_GATHER do
  begin
    LSupported := IsIoRingOpSupported(FRing, LOp);
    Log(Format('VERIFY: IsIoRingOpSupported(%d) = %s', [LOp, BoolToStr(LSupported, True)]));
    if LOp <> IORING_OP_NOP then
      Assert.IsTrue(LSupported, Format('Operation %d', [LOp]));
  end;
end;

procedure TWindowsIoRingApiTests.SetIoRingCompletionEvent_SignalsOnFirstCompletion;
var
  LEvent: THandle;
  LFile: THandle;
  LBuffer: array[0..511] of Byte;
  LCompletions: TArray<IORING_CQE>;
begin
  FRing := NewRing;
  LEvent := CreateEvent(nil, False, False, nil);
  FResources.AddHandle(LEvent);
  LFile := FResources.OpenFile(FPatternFileName);

  Assert.AreEqual(S_OK, SetIoRingCompletionEvent(FRing, LEvent));
  Assert.AreEqual(WAIT_TIMEOUT, WaitForSingleObject(LEvent, 0), 'Signalled before any I/O');

  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 0, 0, nil));

  Assert.AreEqual(WAIT_OBJECT_0, WaitForSingleObject(LEvent, WAIT_TIMEOUT_MS), 'Event not signalled');
  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Assert.AreEqual(S_OK, LCompletions[0].ResultCode);
  CheckPattern(0, @LBuffer, SizeOf(LBuffer));

  // 0 clears the event
  Assert.AreEqual(S_OK, SetIoRingCompletionEvent(FRing, 0));
end;

procedure TWindowsIoRingApiTests.ReadFile_RawRefs_ReadsRightData;
const
  OFFSETS: array[0..4] of UInt64 = (0, 1, 4095, 12345, 200000);
  READ_SIZE = 4096;
var
  LFile: THandle;
  LBuffers: array[0..4] of array[0..READ_SIZE - 1] of Byte;
  LIndex: Integer;
  LSubmitted: Cardinal;
  LCompletions: TArray<IORING_CQE>;
  LCqe: IORING_CQE;
begin
  FRing := NewRing;
  LFile := FResources.OpenFile(FPatternFileName);

  for LIndex := Low(OFFSETS) to High(OFFSETS) do
    Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
      IoRingBufferRefFromPointer(@LBuffers[LIndex]), READ_SIZE, OFFSETS[LIndex],
      NativeUInt(LIndex + 1), IOSQE_FLAGS_NONE));

  LSubmitted := 0;
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, @LSubmitted));
  Assert.AreEqual(Cardinal(Length(OFFSETS)), LSubmitted);

  LCompletions := PopAll(FRing);
  Assert.AreEqual(Length(OFFSETS), Length(LCompletions));

  for LIndex := Low(OFFSETS) to High(OFFSETS) do
  begin
    LCqe := FindCompletion(LCompletions, NativeUInt(LIndex + 1));
    Assert.AreEqual(S_OK, LCqe.ResultCode, HrToStr(LCqe.ResultCode));
    Assert.AreEqual(NativeUInt(READ_SIZE), LCqe.Information);
    CheckPattern(OFFSETS[LIndex], @LBuffers[LIndex], READ_SIZE);
  end;
end;

procedure TWindowsIoRingApiTests.PopIoRingCompletion_EmptyQueue_ReturnsSFalse;
var
  LCqe: IORING_CQE;
begin
  FRing := NewRing;
  LCqe.UserData := 4711;
  LCqe.ResultCode := 4712;
  LCqe.Information := 4713;

  Assert.AreEqual(S_FALSE, PopIoRingCompletion(FRing, LCqe));

  // Learn says the cqe is not modified on S_FALSE; Windows 11 build 26300 zeroes it.
  // Either way: do not use the cqe when the result is S_FALSE.
  Log(Format('VERIFY: cqe after S_FALSE: UserData=%d ResultCode=%d Information=%d',
    [LCqe.UserData, LCqe.ResultCode, LCqe.Information]));
end;

procedure TWindowsIoRingApiTests.ReadFile_RegisteredFileAndBuffers_ReadsRightData;
const
  HALF = 32 * 1024;
var
  LFile: THandle;
  LMemory: PByte;
  LBufferInfos: array[0..1] of IORING_BUFFER_INFO;
  LCompletions: TArray<IORING_CQE>;
  LCqe: IORING_CQE;
begin
  FRing := NewRing;
  LFile := FResources.OpenFile(FPatternFileName);
  LMemory := FResources.AllocPages(2 * HALF);

  LBufferInfos[0].Address := LMemory;
  LBufferInfos[0].Length := HALF;
  LBufferInfos[1].Address := LMemory + HALF;
  LBufferInfos[1].Length := HALF;

  Assert.AreEqual(S_OK, BuildIoRingRegisterFileHandles(FRing, 1, @LFile, 100));
  Assert.AreEqual(S_OK, BuildIoRingRegisterBuffers(FRing, 2, @LBufferInfos[0], 101));

  // Registration acts as a barrier, so these can follow in the same submit
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromIndex(0),
    IoRingBufferRefFromIndexAndOffset(0, 0), HALF, 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromIndex(0),
    IoRingBufferRefFromIndexAndOffset(1, 100), 1000, 5000, 2, IOSQE_FLAGS_NONE));

  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  LCompletions := PopAll(FRing);
  Assert.AreEqual(4, Length(LCompletions));

  Assert.AreEqual(S_OK, FindCompletion(LCompletions, 100).ResultCode, 'Register files');
  Assert.AreEqual(S_OK, FindCompletion(LCompletions, 101).ResultCode, 'Register buffers');

  LCqe := FindCompletion(LCompletions, 1);
  Assert.AreEqual(S_OK, LCqe.ResultCode, HrToStr(LCqe.ResultCode));
  Assert.AreEqual(NativeUInt(HALF), LCqe.Information);
  CheckPattern(0, LMemory, HALF);

  LCqe := FindCompletion(LCompletions, 2);
  Assert.AreEqual(S_OK, LCqe.ResultCode, HrToStr(LCqe.ResultCode));
  Assert.AreEqual(NativeUInt(1000), LCqe.Information);
  CheckPattern(5000, LMemory + HALF + 100, 1000);
end;

procedure TWindowsIoRingApiTests.RegisterBuffers_SparseEntry_Succeeds;
var
  LMemory: Pointer;
  LBufferInfos: array[0..1] of IORING_BUFFER_INFO;
  LCompletions: TArray<IORING_CQE>;
begin
  FRing := NewRing;
  LMemory := FResources.AllocPages(PageSize);

  LBufferInfos[0].Address := LMemory;
  LBufferInfos[0].Length := PageSize;
  LBufferInfos[1].Address := nil;   // sparse
  LBufferInfos[1].Length := 0;

  Assert.AreEqual(S_OK, BuildIoRingRegisterBuffers(FRing, 2, @LBufferInfos[0], 1));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Assert.AreEqual(S_OK, LCompletions[0].ResultCode, HrToStr(LCompletions[0].ResultCode));
end;

procedure TWindowsIoRingApiTests.WriteFlushRead_WithDrain_RoundTrip;
const
  DATA_SIZE = 8192;
var
  LFile: THandle;
  LWriteBuffer: array[0..DATA_SIZE - 1] of Byte;
  LReadBuffer: array[0..DATA_SIZE - 1] of Byte;
  LCompletions: TArray<IORING_CQE>;
  LCqe: IORING_CQE;
begin
  FRing := NewRing;
  LFile := FResources.CreateNewFile;
  TTestFileHelpers.FillPattern(0, LWriteBuffer, DATA_SIZE);
  FillChar(LReadBuffer, SizeOf(LReadBuffer), 0);

  Assert.AreEqual(S_OK, BuildIoRingWriteFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LWriteBuffer), DATA_SIZE, 0, FILE_WRITE_FLAGS_NONE, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, BuildIoRingFlushFile(FRing, IoRingHandleRefFromHandle(LFile),
    FILE_FLUSH_DEFAULT, 2, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LReadBuffer), DATA_SIZE, 0, 3, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));

  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  LCompletions := PopAll(FRing);
  Assert.AreEqual(3, Length(LCompletions));

  LCqe := FindCompletion(LCompletions, 1);
  Assert.AreEqual(S_OK, LCqe.ResultCode, 'Write ' + HrToStr(LCqe.ResultCode));
  Assert.AreEqual(NativeUInt(DATA_SIZE), LCqe.Information);
  LCqe := FindCompletion(LCompletions, 2);
  Assert.AreEqual(S_OK, LCqe.ResultCode, 'Flush ' + HrToStr(LCqe.ResultCode));
  LCqe := FindCompletion(LCompletions, 3);
  Assert.AreEqual(S_OK, LCqe.ResultCode, 'Read ' + HrToStr(LCqe.ResultCode));
  Assert.AreEqual(NativeUInt(DATA_SIZE), LCqe.Information);

  CheckPattern(0, @LReadBuffer, DATA_SIZE);
end;

procedure TWindowsIoRingApiTests.ReadFileScatter_Unbuffered_ReadsRightData;
const
  SEGMENT_COUNT = 4;
var
  LPage: NativeUInt;
  LFile: THandle;
  LMemory: PByte;
  LSegments: array[0..SEGMENT_COUNT] of FILE_SEGMENT_ELEMENT;  // + terminating zero element
  LIndex: Integer;
  LCompletions: TArray<IORING_CQE>;
begin
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.OpenFile(FPatternFileName, FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING);
  LMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  // Segments in reverse memory order, to prove the data really is scattered
  FillChar(LSegments, SizeOf(LSegments), 0);
  for LIndex := 0 to SEGMENT_COUNT - 1 do
    LSegments[LIndex].Buffer := UInt64(NativeUInt(LMemory + NativeUInt(SEGMENT_COUNT - 1 - LIndex) * LPage));

  Assert.AreEqual(S_OK, BuildIoRingReadFileScatter(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, LPage, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Assert.AreEqual(S_OK, LCompletions[0].ResultCode, HrToStr(LCompletions[0].ResultCode));
  Assert.AreEqual(NativeUInt(SEGMENT_COUNT * LPage), LCompletions[0].Information);

  for LIndex := 0 to SEGMENT_COUNT - 1 do
    CheckPattern(LPage + UInt64(LIndex) * LPage, LMemory + NativeUInt(SEGMENT_COUNT - 1 - LIndex) * LPage, LPage);
end;

procedure TWindowsIoRingApiTests.WriteFileGather_Unbuffered_WritesRightData;
const
  SEGMENT_COUNT = 3;
var
  LPage: NativeUInt;
  LFile: THandle;
  LWriteMemory: PByte;
  LReadMemory: PByte;
  LSegments: array[0..SEGMENT_COUNT] of FILE_SEGMENT_ELEMENT;
  LIndex: Integer;
  LCompletions: TArray<IORING_CQE>;
begin
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.CreateNewFile(FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING);
  LWriteMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);
  LReadMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  FillChar(LSegments, SizeOf(LSegments), 0);
  for LIndex := 0 to SEGMENT_COUNT - 1 do
  begin
    TTestFileHelpers.FillPattern(UInt64(LIndex) * LPage, (LWriteMemory + NativeUInt(LIndex) * LPage)^, LPage);
    LSegments[LIndex].Buffer := UInt64(NativeUInt(LWriteMemory + NativeUInt(LIndex) * LPage));
  end;

  Assert.AreEqual(S_OK, BuildIoRingWriteFileGather(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, 0, FILE_WRITE_FLAGS_NONE, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(LReadMemory), SEGMENT_COUNT * LPage, 0, 2, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(2, Length(LCompletions));
  Assert.AreEqual(S_OK, FindCompletion(LCompletions, 1).ResultCode, 'Gather write');
  Assert.AreEqual(S_OK, FindCompletion(LCompletions, 2).ResultCode, 'Read back');
  CheckPattern(0, LReadMemory, SEGMENT_COUNT * LPage);
end;

procedure TWindowsIoRingApiTests.ReadFileScatter_Buffered_FailsWithInvalidParameter;
const
  SEGMENT_COUNT = 2;
var
  LPage: NativeUInt;
  LFile: THandle;
  LMemory: PByte;
  LSegments: array[0..SEGMENT_COUNT] of FILE_SEGMENT_ELEMENT;
  LCompletions: TArray<IORING_CQE>;
begin
  // Like the classic ReadFileScatter, the IoRing version needs FILE_FLAG_NO_BUFFERING.
  // Building the entry succeeds; the operation itself fails.
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.OpenFile(FPatternFileName);  // buffered
  LMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  FillChar(LSegments, SizeOf(LSegments), 0);
  LSegments[0].Buffer := UInt64(NativeUInt(LMemory));
  LSegments[1].Buffer := UInt64(NativeUInt(LMemory + LPage));

  Assert.AreEqual(S_OK, BuildIoRingReadFileScatter(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Log(Format('VERIFY: scatter read on buffered handle: %s, %d bytes',
    [HrToStr(LCompletions[0].ResultCode), LCompletions[0].Information]));
  Assert.AreEqual(E_INVALIDARG, LCompletions[0].ResultCode);
end;

procedure TWindowsIoRingApiTests.CancelRequest_CancelsPendingPipeRead;
var
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..63] of Byte;
  LCompletions: TArray<IORING_CQE>;
  LTarget: IORING_CQE;
  LCancel: IORING_CQE;
begin
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);

  // Nobody writes to the pipe, so this read stays pending
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 0, 0, nil));
  Sleep(50);

  LCompletions := PopAll(FRing);
  if Length(LCompletions) > 0 then
    Log('VERIFY: pipe read completed at once with ' + HrToStr(LCompletions[0].ResultCode));
  Assert.AreEqual(0, Length(LCompletions), 'Pipe read should be pending');

  Assert.AreEqual(S_OK, BuildIoRingCancelRequest(FRing, IoRingHandleRefFromHandle(LClient), 1, 2));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 2, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(2, Length(LCompletions));
  LTarget := FindCompletion(LCompletions, 1);
  LCancel := FindCompletion(LCompletions, 2);
  Log(Format('VERIFY: cancelled read completes with %s, cancel request with %s',
    [HrToStr(LTarget.ResultCode), HrToStr(LCancel.ResultCode)]));

  Assert.AreEqual(HResultFromWin32(ERROR_OPERATION_ABORTED), LTarget.ResultCode);
  Assert.AreEqual(S_OK, LCancel.ResultCode);
end;

procedure TWindowsIoRingApiTests.SubmitIoRing_WaitTimeout_Result;
var
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..63] of Byte;
  LSubmitted: Cardinal;
  LResult: HRESULT;
begin
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);

  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));

  LSubmitted := 4711;
  LResult := SubmitIoRing(FRing, 1, 50, @LSubmitted);
  Log(Format('VERIFY: SubmitIoRing wait timeout returns %s, submittedEntries %d', [HrToStr(LResult), LSubmitted]));
  Assert.AreEqual(HResultFromWin32(ERROR_TIMEOUT), LResult);

  // Was the entry submitted anyway? Then the queue is empty now and nothing more gets submitted.
  LSubmitted := 4711;
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 0, 0, @LSubmitted));
  Log(Format('VERIFY: next SubmitIoRing submits %d entries', [LSubmitted]));

  // Cancel the read and wait for both completions: proves the read was in flight
  Assert.AreEqual(S_OK, BuildIoRingCancelRequest(FRing, IoRingHandleRefFromHandle(LClient), 1, 2));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 2, WAIT_TIMEOUT_MS, nil));
  Assert.AreEqual(HResultFromWin32(ERROR_OPERATION_ABORTED), FindCompletion(PopAll(FRing), 1).ResultCode);
end;

procedure TWindowsIoRingApiTests.BuildIoRingReadFile_SubmissionQueueFull;
var
  LInfo: IORING_INFO;
  LFile: THandle;
  LBuffer: array[0..15] of Byte;
  LIndex: Integer;
  LResult: HRESULT;
begin
  FRing := NewRing(8);
  Assert.AreEqual(S_OK, GetIoRingInfo(FRing, LInfo));
  LFile := FResources.OpenFile(FPatternFileName);

  for LIndex := 1 to Integer(LInfo.SubmissionQueueSize) do
    Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
      IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, LIndex, IOSQE_FLAGS_NONE),
      Format('Entry %d', [LIndex]));

  LResult := BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 999, IOSQE_FLAGS_NONE);
  Assert.AreEqual(IORING_E_SUBMISSION_QUEUE_FULL, LResult, HrToStr(LResult));

  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  Assert.AreEqual(Integer(LInfo.SubmissionQueueSize), Length(PopAll(FRing)));
end;

procedure TWindowsIoRingApiTests.SubmitIoRing_CompletionQueueTooFull;
var
  LInfo: IORING_INFO;
  LFile: THandle;
  LBuffer: array[0..15] of Byte;
  LRound: Integer;
  LIndex: Integer;
  LResult: HRESULT;
  LUserData: NativeUInt;

  procedure BuildFullSubmissionQueue;
  var
    LEntry: Integer;
  begin
    for LEntry := 1 to Integer(LInfo.SubmissionQueueSize) do
    begin
      Inc(LUserData);
      Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
        IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, LUserData, IOSQE_FLAGS_NONE));
    end;
  end;

begin
  FRing := NewRing(8);
  Assert.AreEqual(S_OK, GetIoRingInfo(FRing, LInfo));
  LFile := FResources.OpenFile(FPatternFileName);
  LUserData := 0;

  // Fill the completion queue without popping anything
  for LRound := 1 to Integer(LInfo.CompletionQueueSize div LInfo.SubmissionQueueSize) do
  begin
    BuildFullSubmissionQueue;
    Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil),
      Format('Round %d', [LRound]));
  end;

  BuildFullSubmissionQueue;
  LResult := SubmitIoRing(FRing, 0, 0, nil);
  Log(Format('VERIFY: submit with full CQ (SQ=%d CQ=%d) returns %s',
    [LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize, HrToStr(LResult)]));
  Assert.AreEqual(IORING_E_COMPLETION_QUEUE_TOO_FULL, LResult);

  // After popping, the entries that stayed in the SQ can be submitted
  Assert.AreEqual(Integer(LInfo.CompletionQueueSize), Length(PopAll(FRing)));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  LIndex := Length(PopAll(FRing));
  Assert.AreEqual(Integer(LInfo.SubmissionQueueSize), LIndex);
end;

procedure TWindowsIoRingApiTests.SubmitIoRing_WhileOtherThreadWaits_SubmitInProgress;
var
  LServer: THandle;
  LClient: THandle;
  LPipeBuffer: array[0..63] of Byte;
  LThread: TThread;
  LThreadResult: HRESULT;
  LMainResult: HRESULT;
  LRing: HIORING;
begin
  FRing := NewRing;
  LRing := FRing;
  FResources.OpenPipePair(LServer, LClient);

  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LPipeBuffer), SizeOf(LPipeBuffer), 0, 1, IOSQE_FLAGS_NONE));

  // Thread 1 submits and waits for the pipe read, which does not complete yet
  LThreadResult := E_PENDING;
  LThread := TThread.CreateAnonymousThread(
    procedure
    begin
      LThreadResult := SubmitIoRing(LRing, 1, WAIT_TIMEOUT_MS, nil);
    end);
  LThread.FreeOnTerminate := False;
  try
    LThread.Start;
    Sleep(200);

    // Main thread submits while thread 1 is waiting inside SubmitIoRing
    LMainResult := SubmitIoRing(FRing, 0, 0, nil);
    Log('VERIFY: SubmitIoRing while another thread waits in SubmitIoRing returns ' + HrToStr(LMainResult));

    // Complete the pipe read so thread 1 returns
    WriteByteToPipe(LServer, 42);

    LThread.WaitFor;
    Log('VERIFY: waiting SubmitIoRing on the other thread returned ' + HrToStr(LThreadResult));
  finally
    LThread.Free;
  end;

  // A thread waiting inside SubmitIoRing blocks every other submit on the ring
  Assert.AreEqual(IORING_E_SUBMIT_IN_PROGRESS, LMainResult);
  Assert.AreEqual(S_OK, LThreadResult);
  Assert.AreEqual(1, Length(PopAll(FRing)));
end;

procedure TWindowsIoRingApiTests.ReadFile_AtAndAfterEndOfFile;
const
  FILE_SIZE = 100;
var
  LFileName: string;
  LFile: THandle;
  LBuffers: array[0..2] of array[0..4095] of Byte;
  LCompletions: TArray<IORING_CQE>;
  LCqe: IORING_CQE;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Eof');
  FResources.AddFile(LFileName);
  FRing := NewRing;
  LFile := FResources.OpenFile(LFileName);

  // 1: crosses EOF, 2: starts at EOF, 3: starts after EOF
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[0]), 4096, 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[1]), 4096, FILE_SIZE, 2, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[2]), 16, 2 * FILE_SIZE, 3, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(3, Length(LCompletions));

  LCqe := FindCompletion(LCompletions, 1);
  Log(Format('VERIFY: read crossing EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  Assert.AreEqual(S_OK, LCqe.ResultCode);
  Assert.AreEqual(NativeUInt(FILE_SIZE), LCqe.Information);
  CheckPattern(0, @LBuffers[0], FILE_SIZE);

  LCqe := FindCompletion(LCompletions, 2);
  Log(Format('VERIFY: read starting at EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  Assert.AreEqual(HResultFromWin32(ERROR_HANDLE_EOF), LCqe.ResultCode);
  Assert.AreEqual(NativeUInt(0), LCqe.Information);

  LCqe := FindCompletion(LCompletions, 3);
  Log(Format('VERIFY: read starting after EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  Assert.AreEqual(HResultFromWin32(ERROR_HANDLE_EOF), LCqe.ResultCode);
  Assert.AreEqual(NativeUInt(0), LCqe.Information);
end;

procedure TWindowsIoRingApiTests.ReadFile_NonOverlappedHandle_Works;
var
  LFile: THandle;
  LBuffer: array[0..4095] of Byte;
  LCompletions: TArray<IORING_CQE>;
begin
  FRing := NewRing;
  LFile := FResources.OpenFile(FPatternFileName, 0);  // no FILE_FLAG_OVERLAPPED

  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 8192, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Log(Format('VERIFY: read on non-overlapped handle: %s, %d bytes',
    [HrToStr(LCompletions[0].ResultCode), LCompletions[0].Information]));
  Assert.AreEqual(S_OK, LCompletions[0].ResultCode);
  Assert.AreEqual(NativeUInt(SizeOf(LBuffer)), LCompletions[0].Information);
  CheckPattern(8192, @LBuffer, SizeOf(LBuffer));
end;

procedure TWindowsIoRingApiTests.CloseIoRing_WithPendingRead_DoesNotCancelIt;
var
  LServer: THandle;
  LClient: THandle;
  LRing: HIORING;
  LRingBuffer: array[0..15] of Byte;
  LStart: UInt64;
  LCloseTime: UInt64;
begin
  // CloseIoRing returns at once and does NOT cancel an operation that is still
  // in flight: the kernel writes into the buffer after the ring is closed.
  // So buffers must stay valid until every submitted operation has completed.
  LRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);
  FillChar(LRingBuffer, SizeOf(LRingBuffer), 0);

  Assert.AreEqual(S_OK, BuildIoRingReadFile(LRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LRingBuffer), SizeOf(LRingBuffer), 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(LRing, 0, 0, nil));
  Sleep(50);

  LStart := GetTickCount64;
  Assert.AreEqual(S_OK, CloseIoRing(LRing));
  LCloseTime := GetTickCount64 - LStart;

  WriteByteToPipe(LServer, 42);
  Sleep(50);

  Log(Format('VERIFY: CloseIoRing with a pending read took %d ms; ring buffer[0] afterwards = %d',
    [LCloseTime, LRingBuffer[0]]));

  Assert.AreEqual(Byte(42), LRingBuffer[0], 'Expected the closed ring''s read to complete into the buffer');
end;

procedure TWindowsIoRingApiTests.CancelIoEx_CancelsPendingRingRead;
var
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..15] of Byte;
  LCompletions: TArray<IORING_CQE>;
begin
  // CancelIoEx(Handle, nil) cancels all I/O on a handle. Does that include
  // operations submitted through an IoRing?
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);

  Assert.AreEqual(S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 0, 0, nil));
  Sleep(50);

  Assert.IsTrue(CancelIoEx(LClient, nil), 'CancelIoEx: ' + SysErrorMessage(GetLastError));
  Assert.AreEqual(S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  Assert.AreEqual(1, Length(LCompletions));
  Log('VERIFY: ring read after CancelIoEx completes with ' + HrToStr(LCompletions[0].ResultCode));
  Assert.AreEqual(HResultFromWin32(ERROR_OPERATION_ABORTED), LCompletions[0].ResultCode);
end;

initialization
  TDUnitX.RegisterTestFixture(TWindowsIoRingApiTests);

end.
