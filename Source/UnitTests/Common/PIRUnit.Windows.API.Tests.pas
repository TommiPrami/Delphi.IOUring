unit PIRUnit.Windows.API.Tests;

{
  Calls the real Windows IoRing API through PIRUnit.Windows.API.

  Besides checking the translation, several tests answer the [VERIFY]
  questions of Docs/Design.md. Their findings are written to the test log
  (lines starting with "VERIFY:"), so run the tests with console output to
  see them.

  Requires Windows with IoRing version 4 (Windows 11 24H2 or newer).
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Windows,
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  PIRUnit.Windows.API, PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TCompletionArray = array of IORING_CQE;

  TWindowsIoRingApiTests = class(TIORingTestCase)
  private
    FRing: HIORING;
    FResources: TTestResources;
    function NewRing(const ASubmissionQueueSize: UInt32 = 32; const ACompletionQueueSize: UInt32 = 0): HIORING;
    function PopAll(const ARing: HIORING): TCompletionArray;
    function FindCompletion(const ACompletions: TCompletionArray; const AUserData: NativeUInt): IORING_CQE;
    procedure CheckResult(const AMessage: string; const AExpected, AActual: HRESULT);
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure QueryIoRingCapabilities_ReportsVersion4;
    procedure CreateIoRing_RoundsQueueSizesToPowersOfTwo;
    procedure CreateIoRing_UnknownVersion_Fails;
    procedure CreateIoRing_TooBigSubmissionQueue_Fails;
    procedure IsIoRingOpSupported_AllOperations;
    procedure SetIoRingCompletionEvent_SignalsOnFirstCompletion;
    procedure ReadFile_RawRefs_ReadsRightData;
    procedure PopIoRingCompletion_EmptyQueue_ReturnsSFalse;
    procedure ReadFile_RegisteredFileAndBuffers_ReadsRightData;
    procedure RegisterBuffers_SparseEntry_Succeeds;
    procedure WriteFlushRead_WithDrain_RoundTrip;
    procedure ReadFileScatter_Unbuffered_ReadsRightData;
    procedure WriteFileGather_Unbuffered_WritesRightData;
    procedure ReadFileScatter_Buffered_FailsWithInvalidParameter;
    procedure CancelRequest_CancelsPendingPipeRead;
    procedure SubmitIoRing_WaitTimeout_Result;
    procedure BuildIoRingReadFile_SubmissionQueueFull;
    procedure SubmitIoRing_CompletionQueueTooFull;
    procedure SubmitIoRing_WhileOtherThreadWaits_SubmitInProgress;
    procedure ReadFile_AtAndAfterEndOfFile;
    procedure ReadFile_NonOverlappedHandle_Works;
    procedure CloseIoRing_WithPendingRead_DoesNotCancelIt;
    procedure CancelIoEx_CancelsPendingRingRead;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.Test.FileHelpers;

const
  PATTERN_FILE_SIZE = 256 * 1024;
  WAIT_TIMEOUT_MS = 5000;

  // Not (all) declared in FPC's Windows unit
  RESULT_E_INVALIDARG = HRESULT($80070057);
  WIN32_ERROR_TIMEOUT = 1460;

function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall; external 'kernel32.dll';

type
  // Thread that submits and waits inside SubmitIoRing (no anonymous methods in FPC 3.2.2)
  TSubmitWaitThread = class(TThread)
  private
    FRing: HIORING;
  public
    Result: HRESULT;
    constructor Create(const ARing: HIORING);
  protected
    procedure Execute; override;
  end;

constructor TSubmitWaitThread.Create(const ARing: HIORING);
begin
  FRing := ARing;
  Result := E_PENDING;

  inherited Create(True);
end;

procedure TSubmitWaitThread.Execute;
begin
  Result := SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil);
end;

{ TWindowsIoRingApiTests - helpers }

procedure TWindowsIoRingApiTests.SetUp;
begin
  FRing := 0;
  FResources := TTestResources.Create;
end;

procedure TWindowsIoRingApiTests.TearDown;
begin
  { CloseIoRing does not cancel operations still in flight, so every test completes or cancels
    its own I/O before it ends }
  if FRing <> 0 then
    CloseIoRing(FRing);

  FRing := 0;
  FreeAndNil(FResources);
end;

procedure TWindowsIoRingApiTests.CheckResult(const AMessage: string; const AExpected, AActual: HRESULT);
begin
  if AExpected = AActual then
    AssertTrue(True)
  else
    Fail(Format('%s: expected %s but was %s', [AMessage, HrToStr(AExpected), HrToStr(AActual)]));
end;

function TWindowsIoRingApiTests.NewRing(const ASubmissionQueueSize, ACompletionQueueSize: UInt32): HIORING;
var
  LFlags: IORING_CREATE_FLAGS;
begin
  LFlags.Required := IORING_CREATE_REQUIRED_FLAGS_NONE;
  LFlags.Advisory := IORING_CREATE_ADVISORY_FLAGS_NONE;
  CheckResult('CreateIoRing', S_OK, CreateIoRing(IORING_VERSION_4, LFlags, ASubmissionQueueSize,
    ACompletionQueueSize, Result));
end;

function TWindowsIoRingApiTests.PopAll(const ARing: HIORING): TCompletionArray;
var
  LCqe: IORING_CQE;
begin
  Result := nil;

  while PopIoRingCompletion(ARing, LCqe) = S_OK do
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := LCqe;
  end;
end;

function TWindowsIoRingApiTests.FindCompletion(const ACompletions: TCompletionArray;
  const AUserData: NativeUInt): IORING_CQE;
var
  LIndex: Integer;
begin
  Result := Default(IORING_CQE);

  for LIndex := 0 to High(ACompletions) do
    if ACompletions[LIndex].UserData = AUserData then
      Exit(ACompletions[LIndex]);

  Fail(Format('No completion with UserData %d', [AUserData]));
end;

{ Tests }

procedure TWindowsIoRingApiTests.QueryIoRingCapabilities_ReportsVersion4;
var
  LCapabilities: IORING_CAPABILITIES;
begin
  CheckResult('QueryIoRingCapabilities', S_OK, QueryIoRingCapabilities(LCapabilities));
  Log(Format('Capabilities: MaxVersion=%d MaxSQ=%d MaxCQ=%d FeatureFlags=0x%x',
    [LCapabilities.MaxVersion, LCapabilities.MaxSubmissionQueueSize,
     LCapabilities.MaxCompletionQueueSize, LCapabilities.FeatureFlags]));
  AssertTrue('IoRing version 4 required', LCapabilities.MaxVersion >= IORING_VERSION_4);
  AssertEquals('Not emulated', Int64(0), Int64(LCapabilities.FeatureFlags and IORING_FEATURE_UM_EMULATION));
end;

procedure TWindowsIoRingApiTests.CreateIoRing_RoundsQueueSizesToPowersOfTwo;
var
  LInfo: IORING_INFO;
  LRing: HIORING;
begin
  FRing := NewRing(10, 0);
  CheckResult('GetIoRingInfo', S_OK, GetIoRingInfo(FRing, LInfo));
  Log(Format('Requested SQ=10 CQ=0 -> version=%d SQ=%d CQ=%d',
    [LInfo.IoRingVersion, LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize]));
  AssertEquals('Version', Int64(IORING_VERSION_4), Int64(LInfo.IoRingVersion));
  AssertEquals('SQ', Int64(16), Int64(LInfo.SubmissionQueueSize));
  AssertEquals('CQ', Int64(32), Int64(LInfo.CompletionQueueSize));

  LRing := NewRing(10, 100);
  try
    CheckResult('GetIoRingInfo', S_OK, GetIoRingInfo(LRing, LInfo));
    Log(Format('Requested SQ=10 CQ=100 -> SQ=%d CQ=%d', [LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize]));
    AssertEquals('SQ', Int64(16), Int64(LInfo.SubmissionQueueSize));
    AssertEquals('CQ', Int64(128), Int64(LInfo.CompletionQueueSize));
  finally
    CheckResult('CloseIoRing', S_OK, CloseIoRing(LRing));
  end;
end;

procedure TWindowsIoRingApiTests.CreateIoRing_UnknownVersion_Fails;
var
  LFlags: IORING_CREATE_FLAGS;
  LResult: HRESULT;
begin
  LFlags := Default(IORING_CREATE_FLAGS);
  LResult := CreateIoRing(12345, LFlags, 16, 0, FRing);
  FRing := 0;
  Log('VERIFY: CreateIoRing with unknown version returns ' + HrToStr(LResult));
  CheckResult('Unknown version', IORING_E_VERSION_NOT_SUPPORTED, LResult);
end;

procedure TWindowsIoRingApiTests.CreateIoRing_TooBigSubmissionQueue_Fails;
var
  LCapabilities: IORING_CAPABILITIES;
  LFlags: IORING_CREATE_FLAGS;
  LResult: HRESULT;
begin
  CheckResult('QueryIoRingCapabilities', S_OK, QueryIoRingCapabilities(LCapabilities));
  LFlags := Default(IORING_CREATE_FLAGS);
  LResult := CreateIoRing(IORING_VERSION_4, LFlags, LCapabilities.MaxSubmissionQueueSize * 2, 0, FRing);
  Log('VERIFY: CreateIoRing with SQ = 2 x max returns ' + HrToStr(LResult));

  if Succeeded(LResult) then
    CloseIoRing(FRing);

  FRing := 0;
  CheckResult('SQ too big', IORING_E_SUBMISSION_QUEUE_TOO_BIG, LResult);
end;

procedure TWindowsIoRingApiTests.IsIoRingOpSupported_AllOperations;
var
  LOp: IORING_OP_CODE;
  LSupported: Boolean;
begin
  FRing := NewRing;

  for LOp := IORING_OP_NOP to IORING_OP_WRITE_GATHER do
  begin
    LSupported := IsIoRingOpSupported(FRing, LOp);
    Log(Format('VERIFY: IsIoRingOpSupported(%d) = %s', [LOp, BoolToStr(LSupported, True)]));
    AssertTrue(Format('Operation %d', [LOp]), LSupported);
  end;
end;

procedure TWindowsIoRingApiTests.SetIoRingCompletionEvent_SignalsOnFirstCompletion;
var
  LEvent: THandle;
  LFile: THandle;
  LBuffer: array[0..511] of Byte;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  LEvent := CreateEvent(nil, False, False, nil);
  FResources.AddHandle(LEvent);
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));

  CheckResult('Set event', S_OK, SetIoRingCompletionEvent(FRing, LEvent));
  AssertEquals('Signalled before any I/O', Int64(WAIT_TIMEOUT), Int64(WaitForSingleObject(LEvent, 0)));

  CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 0, 0, nil));

  AssertEquals('Event signalled', Int64(WAIT_OBJECT_0), Int64(WaitForSingleObject(LEvent, WAIT_TIMEOUT_MS)));
  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  CheckResult('Read', S_OK, LCompletions[0].ResultCode);
  CheckPattern(0, @LBuffer, SizeOf(LBuffer));

  CheckResult('Clear event', S_OK, SetIoRingCompletionEvent(FRing, 0));
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
  LCompletions: TCompletionArray;
  LCqe: IORING_CQE;
begin
  // With FPC on Win32 this is the proof that IORING_HANDLE_REF and IORING_BUFFER_REF are passed by value correctly
  FRing := NewRing;
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));

  for LIndex := Low(OFFSETS) to High(OFFSETS) do
    CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
      IoRingBufferRefFromPointer(@LBuffers[LIndex]), READ_SIZE, OFFSETS[LIndex], NativeUInt(LIndex + 1),
      IOSQE_FLAGS_NONE));

  LSubmitted := 0;
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, @LSubmitted));
  AssertEquals('Submitted', Int64(Length(OFFSETS)), Int64(LSubmitted));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', Length(OFFSETS), Length(LCompletions));

  for LIndex := Low(OFFSETS) to High(OFFSETS) do
  begin
    LCqe := FindCompletion(LCompletions, NativeUInt(LIndex + 1));
    CheckResult('Read', S_OK, LCqe.ResultCode);
    AssertEquals('Bytes', Int64(READ_SIZE), Int64(LCqe.Information));
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
  CheckResult('Empty queue', S_FALSE, PopIoRingCompletion(FRing, LCqe));

  { Learn says the cqe is not modified on S_FALSE; Windows 11 build 26300 zeroes it. Either way: do not use the cqe
    when the result is S_FALSE. }
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
  LCompletions: TCompletionArray;
  LCqe: IORING_CQE;
begin
  FRing := NewRing;
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));
  LMemory := FResources.AllocPages(2 * HALF);

  LBufferInfos[0].Address := LMemory;
  LBufferInfos[0].Length := HALF;
  LBufferInfos[1].Address := LMemory + HALF;
  LBufferInfos[1].Length := HALF;

  CheckResult('Register files', S_OK, BuildIoRingRegisterFileHandles(FRing, 1, @LFile, 100));
  CheckResult('Register buffers', S_OK, BuildIoRingRegisterBuffers(FRing, 2, @LBufferInfos[0], 101));
  CheckResult('Read 1', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromIndex(0),
    IoRingBufferRefFromIndexAndOffset(0, 0), HALF, 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Read 2', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromIndex(0),
    IoRingBufferRefFromIndexAndOffset(1, 100), 1000, 5000, 2, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 4, Length(LCompletions));
  CheckResult('Register files done', S_OK, FindCompletion(LCompletions, 100).ResultCode);
  CheckResult('Register buffers done', S_OK, FindCompletion(LCompletions, 101).ResultCode);

  LCqe := FindCompletion(LCompletions, 1);
  CheckResult('Read 1 done', S_OK, LCqe.ResultCode);
  AssertEquals('Read 1 bytes', Int64(HALF), Int64(LCqe.Information));
  CheckPattern(0, LMemory, HALF);

  LCqe := FindCompletion(LCompletions, 2);
  CheckResult('Read 2 done', S_OK, LCqe.ResultCode);
  AssertEquals('Read 2 bytes', Int64(1000), Int64(LCqe.Information));
  CheckPattern(5000, LMemory + HALF + 100, 1000);
end;

procedure TWindowsIoRingApiTests.RegisterBuffers_SparseEntry_Succeeds;
var
  LMemory: Pointer;
  LBufferInfos: array[0..1] of IORING_BUFFER_INFO;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  LMemory := FResources.AllocPages(PageSize);
  LBufferInfos[0].Address := LMemory;
  LBufferInfos[0].Length := PageSize;
  LBufferInfos[1].Address := nil;
  LBufferInfos[1].Length := 0;

  CheckResult('Build', S_OK, BuildIoRingRegisterBuffers(FRing, 2, @LBufferInfos[0], 1));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));
  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  CheckResult('Registration', S_OK, LCompletions[0].ResultCode);
end;

procedure TWindowsIoRingApiTests.WriteFlushRead_WithDrain_RoundTrip;
const
  DATA_SIZE = 8192;
var
  LFile: THandle;
  LWriteBuffer: array[0..DATA_SIZE - 1] of Byte;
  LReadBuffer: array[0..DATA_SIZE - 1] of Byte;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  LFile := FResources.CreateNewFile;
  TTestFileHelpers.FillPattern(0, LWriteBuffer, DATA_SIZE);
  FillChar(LReadBuffer, SizeOf(LReadBuffer), 0);

  CheckResult('Write', S_OK, BuildIoRingWriteFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LWriteBuffer), DATA_SIZE, 0, FILE_WRITE_FLAGS_NONE, 1, IOSQE_FLAGS_NONE));
  CheckResult('Flush', S_OK, BuildIoRingFlushFile(FRing, IoRingHandleRefFromHandle(LFile),
    FILE_FLUSH_DEFAULT, 2, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));
  CheckResult('Read', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LReadBuffer), DATA_SIZE, 0, 3, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 3, Length(LCompletions));
  CheckResult('Write done', S_OK, FindCompletion(LCompletions, 1).ResultCode);
  CheckResult('Flush done', S_OK, FindCompletion(LCompletions, 2).ResultCode);
  CheckResult('Read done', S_OK, FindCompletion(LCompletions, 3).ResultCode);
  CheckPattern(0, @LReadBuffer, DATA_SIZE);
end;

procedure TWindowsIoRingApiTests.ReadFileScatter_Unbuffered_ReadsRightData;
const
  SEGMENT_COUNT = 4;
var
  LPage: NativeUInt;
  LFile: THandle;
  LMemory: PByte;
  LSegments: array[0..SEGMENT_COUNT] of FILE_SEGMENT_ELEMENT;
  LIndex: Integer;
  LCompletions: TCompletionArray;
begin
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE), FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING);
  LMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  FillChar(LSegments, SizeOf(LSegments), 0);

  for LIndex := 0 to SEGMENT_COUNT - 1 do
    LSegments[LIndex].Buffer := UInt64(NativeUInt(LMemory + NativeUInt(SEGMENT_COUNT - 1 - LIndex) * LPage));

  CheckResult('Build', S_OK, BuildIoRingReadFileScatter(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, LPage, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  CheckResult('Scatter read', S_OK, LCompletions[0].ResultCode);
  AssertEquals('Bytes', Int64(SEGMENT_COUNT) * Int64(LPage), Int64(LCompletions[0].Information));

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
  LCompletions: TCompletionArray;
begin
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.CreateNewFile([tofUnbuffered]);
  LWriteMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);
  LReadMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  FillChar(LSegments, SizeOf(LSegments), 0);

  for LIndex := 0 to SEGMENT_COUNT - 1 do
  begin
    TTestFileHelpers.FillPattern(UInt64(LIndex) * LPage, (LWriteMemory + NativeUInt(LIndex) * LPage)^, LPage);
    LSegments[LIndex].Buffer := UInt64(NativeUInt(LWriteMemory + NativeUInt(LIndex) * LPage));
  end;

  CheckResult('Gather', S_OK, BuildIoRingWriteFileGather(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, 0, FILE_WRITE_FLAGS_NONE, 1, IOSQE_FLAGS_NONE));
  CheckResult('Read back', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(LReadMemory), SEGMENT_COUNT * LPage, 0, 2, IOSQE_FLAGS_DRAIN_PRECEDING_OPS));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 2, Length(LCompletions));
  CheckResult('Gather write done', S_OK, FindCompletion(LCompletions, 1).ResultCode);
  CheckResult('Read back done', S_OK, FindCompletion(LCompletions, 2).ResultCode);
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
  LCompletions: TCompletionArray;
begin
  LPage := PageSize;
  FRing := NewRing;
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));
  LMemory := FResources.AllocPages(SEGMENT_COUNT * LPage);

  FillChar(LSegments, SizeOf(LSegments), 0);
  LSegments[0].Buffer := UInt64(NativeUInt(LMemory));
  LSegments[1].Buffer := UInt64(NativeUInt(LMemory + LPage));

  CheckResult('Build', S_OK, BuildIoRingReadFileScatter(FRing, IoRingHandleRefFromHandle(LFile),
    SEGMENT_COUNT, @LSegments[0], SEGMENT_COUNT * LPage, 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  Log(Format('VERIFY: scatter read on buffered handle: %s, %d bytes',
    [HrToStr(LCompletions[0].ResultCode), LCompletions[0].Information]));
  CheckResult('Scatter on buffered handle', RESULT_E_INVALIDARG, LCompletions[0].ResultCode);
end;

procedure TWindowsIoRingApiTests.CancelRequest_CancelsPendingPipeRead;
var
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..63] of Byte;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);

  CheckResult('Build read', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 0, 0, nil));
  Sleep(50);
  LCompletions := PopAll(FRing);

  if Length(LCompletions) > 0 then
    Log('VERIFY: pipe read completed at once with ' + HrToStr(LCompletions[0].ResultCode));

  AssertEquals('Pipe read pending', 0, Length(LCompletions));

  CheckResult('Build cancel', S_OK, BuildIoRingCancelRequest(FRing, IoRingHandleRefFromHandle(LClient), 1, 2));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 2, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 2, Length(LCompletions));
  Log(Format('VERIFY: cancelled read completes with %s, cancel request with %s',
    [HrToStr(FindCompletion(LCompletions, 1).ResultCode), HrToStr(FindCompletion(LCompletions, 2).ResultCode)]));
  CheckResult('Cancelled read', HResultFromWin32(ERROR_OPERATION_ABORTED), FindCompletion(LCompletions, 1).ResultCode);
  CheckResult('Cancel request', S_OK, FindCompletion(LCompletions, 2).ResultCode);
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

  CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  LSubmitted := 4711;
  LResult := SubmitIoRing(FRing, 1, 50, @LSubmitted);
  Log(Format('VERIFY: SubmitIoRing wait timeout returns %s, submittedEntries %d', [HrToStr(LResult), LSubmitted]));
  CheckResult('Wait timeout', HResultFromWin32(WIN32_ERROR_TIMEOUT), LResult);

  // The entry was submitted: nothing is left to submit
  LSubmitted := 4711;
  CheckResult('Second submit', S_OK, SubmitIoRing(FRing, 0, 0, @LSubmitted));
  Log(Format('VERIFY: next SubmitIoRing submits %d entries', [LSubmitted]));
  AssertEquals('Left to submit', Int64(0), Int64(LSubmitted));

  CheckResult('Build cancel', S_OK, BuildIoRingCancelRequest(FRing, IoRingHandleRefFromHandle(LClient), 1, 2));
  CheckResult('Submit cancel', S_OK, SubmitIoRing(FRing, 2, WAIT_TIMEOUT_MS, nil));
  CheckResult('Cancelled read', HResultFromWin32(ERROR_OPERATION_ABORTED), FindCompletion(PopAll(FRing), 1).ResultCode);
end;

procedure TWindowsIoRingApiTests.BuildIoRingReadFile_SubmissionQueueFull;
var
  LInfo: IORING_INFO;
  LFile: THandle;
  LBuffer: array[0..15] of Byte;
  LIndex: Integer;
begin
  FRing := NewRing(8);
  CheckResult('Info', S_OK, GetIoRingInfo(FRing, LInfo));
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));

  for LIndex := 1 to Integer(LInfo.SubmissionQueueSize) do
    CheckResult(Format('Entry %d', [LIndex]), S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
      IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, LIndex, IOSQE_FLAGS_NONE));

  CheckResult('One more', IORING_E_SUBMISSION_QUEUE_FULL, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 999, IOSQE_FLAGS_NONE));

  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  AssertEquals('Completions', Integer(LInfo.SubmissionQueueSize), Length(PopAll(FRing)));
end;

procedure TWindowsIoRingApiTests.SubmitIoRing_CompletionQueueTooFull;
var
  LInfo: IORING_INFO;
  LFile: THandle;
  LBuffer: array[0..15] of Byte;
  LRound: Integer;
  LEntry: Integer;
  LUserData: NativeUInt;
  LResult: HRESULT;
begin
  FRing := NewRing(8);
  CheckResult('Info', S_OK, GetIoRingInfo(FRing, LInfo));
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE));
  LUserData := 0;

  // Fill the completion queue without popping, then submit one more full SQ
  for LRound := 0 to Integer(LInfo.CompletionQueueSize div LInfo.SubmissionQueueSize) do
  begin
    for LEntry := 1 to Integer(LInfo.SubmissionQueueSize) do
    begin
      Inc(LUserData);
      CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
        IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, LUserData, IOSQE_FLAGS_NONE));
    end;

    if LRound < Integer(LInfo.CompletionQueueSize div LInfo.SubmissionQueueSize) then
      CheckResult(Format('Round %d', [LRound]), S_OK,
        SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  end;

  LResult := SubmitIoRing(FRing, 0, 0, nil);
  Log(Format('VERIFY: submit with full CQ (SQ=%d CQ=%d) returns %s',
    [LInfo.SubmissionQueueSize, LInfo.CompletionQueueSize, HrToStr(LResult)]));
  CheckResult('CQ full', IORING_E_COMPLETION_QUEUE_TOO_FULL, LResult);

  AssertEquals('Popped', Integer(LInfo.CompletionQueueSize), Length(PopAll(FRing)));
  CheckResult('Submit after popping', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));
  AssertEquals('Rest', Integer(LInfo.SubmissionQueueSize), Length(PopAll(FRing)));
end;

procedure TWindowsIoRingApiTests.SubmitIoRing_WhileOtherThreadWaits_SubmitInProgress;
var
  LServer: THandle;
  LClient: THandle;
  LPipeBuffer: array[0..63] of Byte;
  LThread: TSubmitWaitThread;
  LMainResult: HRESULT;
begin
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);
  CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LPipeBuffer), SizeOf(LPipeBuffer), 0, 1, IOSQE_FLAGS_NONE));

  LThread := TSubmitWaitThread.Create(FRing);
  try
    LThread.Start;
    Sleep(200);
    // Main thread submits while the thread is waiting inside SubmitIoRing
    LMainResult := SubmitIoRing(FRing, 0, 0, nil);
    Log('VERIFY: SubmitIoRing while another thread waits in SubmitIoRing returns ' + HrToStr(LMainResult));
    // Complete the pipe read so the thread returns
    WriteByteToPipe(LServer, 42);
    LThread.WaitFor;
    Log('VERIFY: waiting SubmitIoRing on the other thread returned ' + HrToStr(LThread.Result));

    CheckResult('Submit while the other thread waits', IORING_E_SUBMIT_IN_PROGRESS, LMainResult);
    CheckResult('Waiting thread', S_OK, LThread.Result);
  finally
    LThread.Free;
  end;

  AssertEquals('Completions', 1, Length(PopAll(FRing)));
end;

procedure TWindowsIoRingApiTests.ReadFile_AtAndAfterEndOfFile;
const
  FILE_SIZE = 100;
var
  LFileName: string;
  LFile: THandle;
  LBuffers: array[0..2] of array[0..4095] of Byte;
  LCompletions: TCompletionArray;
  LCqe: IORING_CQE;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Eof');
  FResources.AddFile(LFileName);
  FRing := NewRing;
  LFile := FResources.OpenFile(LFileName);

  CheckResult('Build 1', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[0]), 4096, 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Build 2', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[1]), 4096, FILE_SIZE, 2, IOSQE_FLAGS_NONE));
  CheckResult('Build 3', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffers[2]), 16, 2 * FILE_SIZE, 3, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, IORING_SUBMIT_WAIT_ALL, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 3, Length(LCompletions));

  LCqe := FindCompletion(LCompletions, 1);
  Log(Format('VERIFY: read crossing EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  CheckResult('Crossing EOF', S_OK, LCqe.ResultCode);
  AssertEquals('Crossing EOF bytes', Int64(FILE_SIZE), Int64(LCqe.Information));
  CheckPattern(0, @LBuffers[0], FILE_SIZE);

  LCqe := FindCompletion(LCompletions, 2);
  Log(Format('VERIFY: read starting at EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  CheckResult('At EOF', HResultFromWin32(ERROR_HANDLE_EOF), LCqe.ResultCode);
  AssertEquals('At EOF bytes', Int64(0), Int64(LCqe.Information));

  LCqe := FindCompletion(LCompletions, 3);
  Log(Format('VERIFY: read starting after EOF: %s, %d bytes', [HrToStr(LCqe.ResultCode), LCqe.Information]));
  CheckResult('After EOF', HResultFromWin32(ERROR_HANDLE_EOF), LCqe.ResultCode);
end;

procedure TWindowsIoRingApiTests.ReadFile_NonOverlappedHandle_Works;
var
  LFile: THandle;
  LBuffer: array[0..4095] of Byte;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  LFile := FResources.OpenFile(SharedPatternFile(PATTERN_FILE_SIZE), 0);

  CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LFile),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 8192, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));

  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  Log(Format('VERIFY: read on non-overlapped handle: %s, %d bytes',
    [HrToStr(LCompletions[0].ResultCode), LCompletions[0].Information]));
  CheckResult('Read', S_OK, LCompletions[0].ResultCode);
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
  LRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);
  FillChar(LRingBuffer, SizeOf(LRingBuffer), 0);

  CheckResult('Build', S_OK, BuildIoRingReadFile(LRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LRingBuffer), SizeOf(LRingBuffer), 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(LRing, 0, 0, nil));
  Sleep(50);
  LStart := TThread.GetTickCount64;
  CheckResult('Close', S_OK, CloseIoRing(LRing));
  LCloseTime := TThread.GetTickCount64 - LStart;

  WriteByteToPipe(LServer, 42);
  Sleep(50);

  Log(Format('VERIFY: CloseIoRing with a pending read took %d ms; ring buffer[0] afterwards = %d',
    [LCloseTime, LRingBuffer[0]]));

  AssertEquals('The closed ring''s read still completed into the buffer', 42, LRingBuffer[0]);
end;

procedure TWindowsIoRingApiTests.CancelIoEx_CancelsPendingRingRead;
var
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..15] of Byte;
  LCompletions: TCompletionArray;
begin
  FRing := NewRing;
  FResources.OpenPipePair(LServer, LClient);

  CheckResult('Build', S_OK, BuildIoRingReadFile(FRing, IoRingHandleRefFromHandle(LClient),
    IoRingBufferRefFromPointer(@LBuffer), SizeOf(LBuffer), 0, 1, IOSQE_FLAGS_NONE));
  CheckResult('Submit', S_OK, SubmitIoRing(FRing, 0, 0, nil));
  Sleep(50);

  AssertTrue('CancelIoEx', CancelIoEx(LClient, nil));
  CheckResult('Wait', S_OK, SubmitIoRing(FRing, 1, WAIT_TIMEOUT_MS, nil));
  LCompletions := PopAll(FRing);
  AssertEquals('Completions', 1, Length(LCompletions));
  Log('VERIFY: ring read after CancelIoEx completes with ' + HrToStr(LCompletions[0].ResultCode));
  CheckResult('Cancelled', HResultFromWin32(ERROR_OPERATION_ABORTED), LCompletions[0].ResultCode);
end;

initialization
  RegisterTests(TWindowsIoRingApiTests);

end.
