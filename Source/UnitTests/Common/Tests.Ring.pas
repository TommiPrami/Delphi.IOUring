unit Tests.Ring;

{
  Tests for the core ring (TIORing in Delphi.IOUring).

  The ring API is used only through Delphi.IOUring, so the tests can later run
  on Linux too. Files, pipes and memory come from TestPlatformHelpers (Windows
  for now); a few layout checks are Windows-only and marked so.
}

{$I Delphi.IOUring.inc}

interface

uses
  TestPlatformHelpers,
  Tests.Support;

type
  TIORingTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    function PatternFile: string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // Life cycle
    procedure Available_AndCapabilities;
    procedure Open_RoundsQueueSizes;
    procedure Open_Twice_Raises;
    procedure Close_Twice_DoesNothing;
    procedure PrepareRead_OnClosedRing_Raises;
    procedure EndOfScope_ClosesRing;
    procedure Copy_Raises;
    procedure ConstParameter_DoesNotCopy;
    // Queue limits
    procedure PrepareRead_FullSubmissionQueue_ReturnsFalse;
    procedure Prepare_NeverOverfillsCompletionQueue;
    // Operations
    procedure RandomReads_EveryCompletionVerified;
    procedure RegisterFilesAndBuffers_ArraysAreCopied;
    procedure WriteFlushRead_WithDrain;
    procedure ReadScatter_UsesOnlySegmentCountEntries;
    procedure PrepareCancel_CancelsPendingPipeRead;
    procedure ReadOnWriteOnlyHandle_GivesFailedCompletion;
    // Waiting and closing
    procedure CompletionEvent_SignalsAfterSubmit;
    procedure WaitForCompletions_CountsCompletionsAlreadyInQueue;
    procedure Close_WaitsForPendingOperations;
    // Blocking helpers
    procedure ReadAt_ReadsData;
    procedure ReadAt_AtAndAfterEndOfFile;
    procedure ReadAt_OnBusyRing_Raises;
    procedure WriteAt_ThenReadAt_RoundTrip;
    // Types and errors
    procedure Completion_HasLayoutOfIoRingCqe;
    procedure BufferInfo_HasLayoutOfIoRingBufferInfo;
    procedure ErrorMessage_DescribesCodes;
  end;

implementation

uses
{$IFDEF FPC}
  Windows,
  SysUtils,
  Classes,
{$ELSE}
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Delphi.IOUring,
  Delphi.IOUring.Backend.Windows.API,
  TestFileHelpers;

const
  PATTERN_FILE_SIZE = 1024 * 1024;
  RESULT_E_ACCESSDENIED = HRESULT($80070005);

function CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall; external 'kernel32.dll';

function AddressByConst(const ARing: TIORing): Pointer;
begin
  Result := @ARing;
end;

function AddressByConstRef({$IFDEF FPC}constref{$ELSE}const [ref]{$ENDIF} ARing: TIORing): Pointer;
begin
  Result := @ARing;
end;

// Leaves a pipe read pending in a local ring and returns without Close: the
// end of scope must close the ring and so wait for the read
procedure LeaveScopeWithPendingRead(const AClient: THandle; var ABuffer: Byte);
var
  LRing: TIORing;
begin
  LRing.Open(8);
  LRing.PrepareRead(TIORingFileRef.FromHandle(AClient), TIORingBufferRef.FromPointer(@ABuffer), 1, 0, 1);
  LRing.Submit;
end;

{ Set-up }

procedure TIORingTests.SetUp;
begin
  FResources := TTestResources.Create;
end;

procedure TIORingTests.TearDown;
begin
  FreeAndNil(FResources);
end;

function TIORingTests.PatternFile: string;
begin
  Result := SharedPatternFile(PATTERN_FILE_SIZE);
end;

{ Life cycle }

procedure TIORingTests.Available_AndCapabilities;
var
  LCapabilities: TIORingCapabilities;
begin
  AssertTrue('Available', IORingAvailable);
  LCapabilities := TIORing.QueryCapabilities;
  Log(Format('Backend "%s", version %d, max SQ %d, max CQ %d',
    [LCapabilities.BackendName, LCapabilities.NativeVersion, LCapabilities.MaxSubmissionQueueSize,
     LCapabilities.MaxCompletionQueueSize]));
  AssertEquals('Backend', 'Windows IoRing', LCapabilities.BackendName);
  AssertFalse('Emulated', LCapabilities.Emulated);
  AssertTrue('All operations', LCapabilities.SupportedOps = [ioRead, ioWrite, ioFlush, ioCancel, ioRegisterFiles,
    ioRegisterBuffers, ioReadScatter, ioWriteGather]);
end;

procedure TIORingTests.Open_RoundsQueueSizes;
var
  LRing: TIORing;
begin
  AssertFalse('Closed at start', LRing.IsOpen);
  LRing.Open(10);
  AssertTrue('Open', LRing.IsOpen);
  AssertEquals('SQ', Int64(16), Int64(LRing.SubmissionQueueSize));
  AssertEquals('CQ', Int64(32), Int64(LRing.CompletionQueueSize));
  AssertEquals('Prepared', Int64(0), Int64(LRing.PreparedCount));
  AssertEquals('Pending', Int64(0), Int64(LRing.PendingCount));
end;

procedure TIORingTests.Open_Twice_Raises;
var
  LRing: TIORing;
  LRaised: Boolean;
begin
  LRing.Open(8);
  LRaised := False;
  try
    LRing.Open(8);
  except
    on EIORingError do
      LRaised := True;
  end;
  AssertTrue('Second Open raises', LRaised);
  AssertTrue('Still open', LRing.IsOpen);
end;

procedure TIORingTests.Close_Twice_DoesNothing;
var
  LRing: TIORing;
begin
  LRing.Open(8);
  LRing.Close;
  LRing.Close;
  AssertFalse(LRing.IsOpen);
end;

procedure TIORingTests.PrepareRead_OnClosedRing_Raises;
var
  LRing: TIORing;
  LBuffer: array[0..15] of Byte;
  LRaised: Boolean;
begin
  LRaised := False;
  try
    LRing.PrepareRead(TIORingFileRef.FromHandle(0), TIORingBufferRef.FromPointer(@LBuffer), 16, 0, 1);
  except
    on EIORingError do
      LRaised := True;
  end;
  AssertTrue('PrepareRead on a closed ring must raise, not return False', LRaised);
end;

procedure TIORingTests.EndOfScope_ClosesRing;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LWriter: TDelayedPipeWriter;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;
  LWriter := TDelayedPipeWriter.Create(LServer, 300, 42);
  try
    LWriter.Start;
    LStart := TThread.GetTickCount64;
    LeaveScopeWithPendingRead(LClient, LByte);
    LElapsed := TThread.GetTickCount64 - LStart;
  finally
    LWriter.WaitFor;
    LWriter.Free;
  end;

  Log(Format('Leaving the scope waited %d ms for the pending read', [LElapsed]));
  AssertTrue(Format('The end of scope did not close (and wait for) the ring: %d ms', [LElapsed]), LElapsed >= 200);
  AssertEquals('Byte read', 42, LByte);
end;

procedure TIORingTests.Copy_Raises;
var
  LRing1: TIORing;
  LRing2: TIORing;
  LRaised: Boolean;
begin
  LRing1.Open(8);
  LRaised := False;
  try
    LRing2 := LRing1;
  except
    on EInvalidOpException do
      LRaised := True;
  end;
  AssertTrue('Copying a ring must raise', LRaised);
  AssertTrue('Source still open', LRing1.IsOpen);
  AssertFalse('Target not open', LRing2.IsOpen);
end;

procedure TIORingTests.ConstParameter_DoesNotCopy;
var
  LRing: TIORing;
begin
  // A copy would raise (Copy operator). Both forms must pass the original.
  LRing.Open(8);
  AssertTrue('const', AddressByConst(LRing) = @LRing);
  AssertTrue('constref', AddressByConstRef(LRing) = @LRing);
end;

{ Queue limits }

procedure TIORingTests.PrepareRead_FullSubmissionQueue_ReturnsFalse;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..15] of Byte;
  LCompletions: array[0..63] of TIORingCompletion;
  LPrepared: Cardinal;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);

  LPrepared := 0;
  while LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, LPrepared) do
    Inc(LPrepared);

  AssertEquals('Accepted before full', Int64(LRing.SubmissionQueueSize), Int64(LPrepared));
  AssertEquals('Submitted', Int64(LPrepared), Int64(LRing.Submit(LPrepared)));
  AssertEquals('Popped', Int64(LPrepared), Int64(LRing.PopCompletions(LCompletions)));
end;

procedure TIORingTests.Prepare_NeverOverfillsCompletionQueue;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..15] of Byte;
  LCompletions: array[0..63] of TIORingCompletion;
  LAccepted: Cardinal;
  LUserData: TIORingUserData;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);

  LAccepted := 0;
  LUserData := 0;
  repeat
    while LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, LUserData) do
    begin
      Inc(LAccepted);
      Inc(LUserData);
    end;
  until LRing.Submit = 0;

  AssertEquals('Accepted without popping', Int64(LRing.CompletionQueueSize), Int64(LAccepted));
  AssertTrue('Wait', LRing.WaitForCompletions(LAccepted, 5000));
  AssertEquals('Popped', Int64(LAccepted), Int64(LRing.PopCompletions(LCompletions)));
  AssertTrue('Room again', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 0));
  LRing.Submit(1);
end;

{ Operations }

procedure TIORingTests.RandomReads_EveryCompletionVerified;
const
  READ_COUNT = 1000;
  SLOT_COUNT = 64;
  MAX_READ_SIZE = 8192;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffers: array of TBytes;
  LOffsets: array[0..SLOT_COUNT - 1] of UInt64;
  LLengths: array[0..SLOT_COUNT - 1] of Cardinal;
  LBusy: array[0..SLOT_COUNT - 1] of Boolean;
  LFreeSlots: array[0..SLOT_COUNT - 1] of Integer;
  LFreeCount: Integer;
  LIssued: Integer;
  LCompleted: Integer;
  LSlot: Integer;
  LLength: Cardinal;
  LOffset: UInt64;
  LCompletion: TIORingCompletion;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(SLOT_COUNT);

  SetLength(LBuffers, SLOT_COUNT);
  for LSlot := 0 to SLOT_COUNT - 1 do
  begin
    SetLength(LBuffers[LSlot], MAX_READ_SIZE);
    LOffsets[LSlot] := 0;
    LLengths[LSlot] := 0;
    LBusy[LSlot] := False;
    LFreeSlots[LSlot] := LSlot;
  end;
  LFreeCount := SLOT_COUNT;

  RandSeed := 20261022;
  LIssued := 0;
  LCompleted := 0;
  while LCompleted < READ_COUNT do
  begin
    while (LIssued < READ_COUNT) and (LFreeCount > 0) do
    begin
      LSlot := LFreeSlots[LFreeCount - 1];
      LLength := 1 + Cardinal(Random(MAX_READ_SIZE));
      LOffset := UInt64(Random(PATTERN_FILE_SIZE - Integer(LLength) + 1));
      if not LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffers[LSlot][0]), LLength, LOffset,
        TIORingUserData(LSlot)) then
        Break;
      Dec(LFreeCount);
      LBusy[LSlot] := True;
      LOffsets[LSlot] := LOffset;
      LLengths[LSlot] := LLength;
      Inc(LIssued);
    end;

    LRing.Submit(1);

    while LRing.TryPopCompletion(LCompletion) do
    begin
      LSlot := Integer(LCompletion.UserData);
      AssertTrue(Format('Unexpected completion %d', [LSlot]), (LSlot >= 0) and (LSlot < SLOT_COUNT) and LBusy[LSlot]);
      AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
      AssertEquals('Bytes', Int64(LLengths[LSlot]), Int64(LCompletion.BytesTransferred));
      CheckPattern(LOffsets[LSlot], @LBuffers[LSlot][0], LLengths[LSlot]);
      LBusy[LSlot] := False;
      LFreeSlots[LFreeCount] := LSlot;
      Inc(LFreeCount);
      Inc(LCompleted);
    end;
  end;

  AssertEquals('Completed', READ_COUNT, LCompleted);
  AssertEquals('Pending', Int64(0), Int64(LRing.PendingCount));
end;

procedure TIORingTests.RegisterFilesAndBuffers_ArraysAreCopied;
const
  MEMORY_SIZE = 64 * 1024;
var
  LRing: TIORing;
  LFile: THandle;
  LMemory: PByte;
  LHandles: array of THandle;
  LInfos: array of TIORingBufferInfo;
  LCompletions: array[0..7] of TIORingCompletion;
  LCount: Integer;
  LIndex: Integer;
begin
  LFile := FResources.OpenFile(PatternFile);
  LMemory := FResources.AllocPages(MEMORY_SIZE);
  LRing.Open(16);

  SetLength(LHandles, 1);
  LHandles[0] := LFile;
  SetLength(LInfos, 1);
  LInfos[0].Address := LMemory;
  LInfos[0].Length := MEMORY_SIZE;

  AssertTrue('Register files', LRing.PrepareRegisterFiles(LHandles, 100));
  AssertTrue('Register buffers', LRing.PrepareRegisterBuffers(LInfos, 101));

  // Spoil the caller's arrays before the kernel reads them
  LHandles[0] := INVALID_HANDLE_VALUE;
  LInfos[0].Address := nil;
  LInfos[0].Length := 0;
  LHandles := nil;
  LInfos := nil;

  AssertTrue('Read', LRing.PrepareRead(TIORingFileRef.FromIndex(0), TIORingBufferRef.FromRegistered(0, 4096),
    1000, 3000, 1));
  LRing.Submit(3);

  LCount := LRing.PopCompletions(LCompletions);
  AssertEquals('Completions', 3, LCount);
  for LIndex := 0 to LCount - 1 do
    AssertTrue(Format('UserData %d: %s', [LCompletions[LIndex].UserData, LCompletions[LIndex].ErrorMessage]),
      LCompletions[LIndex].Succeeded);
  CheckPattern(3000, LMemory + 4096, 1000);
end;

procedure TIORingTests.WriteFlushRead_WithDrain;
const
  DATA_SIZE = 8192;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LWriteBuffer: array[0..DATA_SIZE - 1] of Byte;
  LReadBuffer: array[0..DATA_SIZE - 1] of Byte;
  LCompletions: array[0..7] of TIORingCompletion;
  LIndex: Integer;
begin
  LFile := TIORingFileRef.FromHandle(FResources.CreateNewFile);
  TTestFileHelpers.FillPattern(0, LWriteBuffer, DATA_SIZE);
  FillChar(LReadBuffer, SizeOf(LReadBuffer), 0);
  LRing.Open(8);

  AssertTrue('Write', LRing.PrepareWrite(LFile, TIORingBufferRef.FromPointer(@LWriteBuffer), DATA_SIZE, 0, 1));
  AssertTrue('Flush', LRing.PrepareFlush(LFile, rfmDefault, 2, [sfDrainPreceding]));
  AssertTrue('Read', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LReadBuffer), DATA_SIZE, 0, 3,
    [sfDrainPreceding]));
  AssertEquals('Submitted', Int64(3), Int64(LRing.Submit(3)));

  AssertEquals('Completions', 3, LRing.PopCompletions(LCompletions));
  for LIndex := 0 to 2 do
    AssertTrue(LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
  CheckPattern(0, @LReadBuffer, DATA_SIZE);
end;

procedure TIORingTests.ReadScatter_UsesOnlySegmentCountEntries;
const
  SEGMENT_COUNT = 3;
var
  LRing: TIORing;
  LPage: NativeUInt;
  LFile: TIORingFileRef;
  LMemory: PByte;
  LGuard: PByte;
  LSegments: array[0..SEGMENT_COUNT] of TIORingSegment;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
begin
  LPage := PageSize;
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile, FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING));
  LMemory := FResources.AllocPages((SEGMENT_COUNT + 1) * LPage);
  LGuard := LMemory + SEGMENT_COUNT * LPage;
  FillChar(LGuard^, LPage, $AA);
  for LIndex := 0 to SEGMENT_COUNT do
    LSegments[LIndex] := IORingSegment(LMemory + NativeUInt(LIndex) * LPage);

  LRing.Open(8);
  AssertTrue('Prepare', LRing.PrepareReadScatter(LFile, @LSegments[0], SEGMENT_COUNT, SEGMENT_COUNT * LPage, LPage, 1));
  LRing.Submit(1);

  AssertTrue('Completion', LRing.TryPopCompletion(LCompletion));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
  AssertEquals('Bytes', Int64(SEGMENT_COUNT) * Int64(LPage), Int64(LCompletion.BytesTransferred));
  CheckPattern(LPage, LMemory, SEGMENT_COUNT * LPage);
  for LIndex := 0 to Integer(LPage) - 1 do
    if LGuard[LIndex] <> $AA then
      Fail(Format('Guard page changed at byte %d', [LIndex]));
end;

procedure TIORingTests.PrepareCancel_CancelsPendingPipeRead;
var
  LRing: TIORing;
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..15] of Byte;
  LCompletions: array[0..7] of TIORingCompletion;
  LIndex: Integer;
  LReadSeen: Boolean;
begin
  FResources.OpenPipePair(LServer, LClient);
  LRing.Open(8);
  try
    AssertTrue('Read', LRing.PrepareRead(TIORingFileRef.FromHandle(LClient), TIORingBufferRef.FromPointer(@LBuffer),
      SizeOf(LBuffer), 0, 1));
    LRing.Submit;
    Sleep(20);
    AssertTrue('Cancel', LRing.PrepareCancel(TIORingFileRef.FromHandle(LClient), 1, 2));
    LRing.Submit(2);

    AssertEquals('Completions', 2, LRing.PopCompletions(LCompletions));
    LReadSeen := False;
    for LIndex := 0 to 1 do
      if LCompletions[LIndex].UserData = 1 then
      begin
        LReadSeen := True;
        AssertEquals('Cancelled read', Int64(HResultFromWin32(ERROR_OPERATION_ABORTED)),
          Int64(LCompletions[LIndex].NativeResult));
      end
      else
        AssertTrue('Cancel request: ' + LCompletions[LIndex].ErrorMessage, LCompletions[LIndex].Succeeded);
    AssertTrue('Read completion seen', LReadSeen);
  finally
    // Never leave the ring waiting for a pipe read in Close
    CancelIoEx(LClient, nil);
  end;
end;

procedure TIORingTests.ReadOnWriteOnlyHandle_GivesFailedCompletion;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
  LRaised: Boolean;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile, FILE_FLAG_OVERLAPPED, GENERIC_WRITE));
  LRing.Open(8);
  AssertTrue('Prepare', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));
  LRing.Submit(1);

  AssertTrue('Completion', LRing.TryPopCompletion(LCompletion));
  Log('Read on write-only handle: ' + LCompletion.ErrorMessage);
  AssertFalse('Succeeded', LCompletion.Succeeded);
  AssertEquals('Access denied', Int64(RESULT_E_ACCESSDENIED), Int64(LCompletion.NativeResult));

  LRaised := False;
  try
    LCompletion.RaiseIfFailed('Read');
  except
    on E: EIORingError do
    begin
      LRaised := True;
      AssertEquals('NativeCode', Int64(RESULT_E_ACCESSDENIED), Int64(E.NativeCode));
    end;
  end;
  AssertTrue('RaiseIfFailed raises', LRaised);
end;

{ Waiting and closing }

procedure TIORingTests.CompletionEvent_SignalsAfterSubmit;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);
  AssertTrue('Event handle', LRing.CompletionEventHandle <> 0);
  AssertFalse('Queue empty at start', LRing.TryPopCompletion(LCompletion));

  AssertTrue('Prepare', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));
  LRing.Submit;
  AssertEquals('Event', Int64(WAIT_OBJECT_0), Int64(WaitForSingleObject(LRing.CompletionEventHandle, 5000)));
  AssertTrue('Completion', LRing.TryPopCompletion(LCompletion));
  AssertTrue(LCompletion.ErrorMessage, LCompletion.Succeeded);
end;

procedure TIORingTests.WaitForCompletions_CountsCompletionsAlreadyInQueue;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffers: array[0..2] of array[0..511] of Byte;
  LCompletions: array[0..7] of TIORingCompletion;
  LIndex: Integer;
  LStart: UInt64;
  LElapsed: UInt64;
  LWaited: Boolean;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);
  for LIndex := 0 to 2 do
    AssertTrue('Prepare', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffers[LIndex]), 512, 0, LIndex));
  LRing.Submit(3);

  LStart := TThread.GetTickCount64;
  LWaited := LRing.WaitForCompletions(3, 2000);
  LElapsed := TThread.GetTickCount64 - LStart;
  Log(Format('VERIFY: WaitForCompletions(3) with 3 completions already queued: %s after %d ms',
    [BoolToStr(LWaited, True), LElapsed]));
  AssertTrue('Waited', LWaited);
  AssertTrue('Returned at once', LElapsed < 1000);
  AssertEquals('Popped', 3, LRing.PopCompletions(LCompletions));
end;

procedure TIORingTests.Close_WaitsForPendingOperations;
var
  LRing: TIORing;
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..15] of Byte;
  LWriter: TDelayedPipeWriter;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  FResources.OpenPipePair(LServer, LClient);
  FillChar(LBuffer, SizeOf(LBuffer), 0);
  LRing.Open(8);
  AssertTrue('Prepare', LRing.PrepareRead(TIORingFileRef.FromHandle(LClient), TIORingBufferRef.FromPointer(@LBuffer),
    SizeOf(LBuffer), 0, 1));
  LRing.Submit;

  LWriter := TDelayedPipeWriter.Create(LServer, 300, 42);
  try
    LWriter.Start;
    LStart := TThread.GetTickCount64;
    LRing.Close;
    LElapsed := TThread.GetTickCount64 - LStart;
  finally
    LWriter.WaitFor;
    LWriter.Free;
  end;

  Log(Format('Close waited %d ms for the pending read', [LElapsed]));
  AssertFalse('Closed', LRing.IsOpen);
  AssertTrue(Format('Close returned before the read completed: %d ms', [LElapsed]), LElapsed >= 200);
  AssertEquals('Byte read', 42, LBuffer[0]);
end;

{ Blocking helpers }

procedure TIORingTests.ReadAt_ReadsData;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..4095] of Byte;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);
  AssertEquals('Bytes', Int64(SizeOf(LBuffer)), Int64(ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 12345)));
  CheckPattern(12345, @LBuffer, SizeOf(LBuffer));
end;

procedure TIORingTests.ReadAt_AtAndAfterEndOfFile;
const
  FILE_SIZE = 100;
var
  LRing: TIORing;
  LFileName: string;
  LFile: TIORingFileRef;
  LBuffer: array[0..4095] of Byte;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'RingEof');
  FResources.AddFile(LFileName);
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(LFileName));
  LRing.Open(8);

  AssertEquals('Crossing EOF', Int64(FILE_SIZE - 50), Int64(ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 50)));
  CheckPattern(50, @LBuffer, FILE_SIZE - 50);
  AssertEquals('At EOF', Int64(0), Int64(ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), FILE_SIZE)));
  AssertEquals('After EOF', Int64(0), Int64(ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 10 * FILE_SIZE)));
end;

procedure TIORingTests.ReadAt_OnBusyRing_Raises;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..511] of Byte;
  LRaised: Boolean;
  LCompletion: TIORingCompletion;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(PatternFile));
  LRing.Open(8);
  AssertTrue('Prepare', LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));

  LRaised := False;
  try
    ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 0);
  except
    on EIORingError do
      LRaised := True;
  end;
  AssertTrue('ReadAt must refuse a ring with a prepared entry', LRaised);

  LRing.Submit(1);
  AssertTrue('Completion', LRing.TryPopCompletion(LCompletion));
end;

procedure TIORingTests.WriteAt_ThenReadAt_RoundTrip;
const
  DATA_SIZE = 5000;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LWriteBuffer: array[0..DATA_SIZE - 1] of Byte;
  LReadBuffer: array[0..DATA_SIZE - 1] of Byte;
begin
  LFile := TIORingFileRef.FromHandle(FResources.CreateNewFile);
  TTestFileHelpers.FillPattern(777, LWriteBuffer, DATA_SIZE);
  LRing.Open(8);

  AssertEquals('Written', Int64(DATA_SIZE), Int64(WriteAt(LRing, LFile, LWriteBuffer, DATA_SIZE, 777)));
  AssertEquals('Read', Int64(DATA_SIZE), Int64(ReadAt(LRing, LFile, LReadBuffer, DATA_SIZE, 777)));
  CheckPattern(777, @LReadBuffer, DATA_SIZE);
end;

{ Types and errors }

procedure TIORingTests.Completion_HasLayoutOfIoRingCqe;
var
  LCompletion: TIORingCompletion;
  LCqe: IORING_CQE;
begin
  AssertEquals('SizeOf', Int64(SizeOf(IORING_CQE)), Int64(SizeOf(TIORingCompletion)));
  AssertEquals('UserData', Int64(NativeUInt(@LCqe.UserData) - NativeUInt(@LCqe)),
    Int64(NativeUInt(@LCompletion.UserData) - NativeUInt(@LCompletion)));
  AssertEquals('NativeResult', Int64(NativeUInt(@LCqe.ResultCode) - NativeUInt(@LCqe)),
    Int64(NativeUInt(@LCompletion.NativeResult) - NativeUInt(@LCompletion)));
  AssertEquals('BytesTransferred', Int64(NativeUInt(@LCqe.Information) - NativeUInt(@LCqe)),
    Int64(NativeUInt(@LCompletion.BytesTransferred) - NativeUInt(@LCompletion)));
end;

procedure TIORingTests.BufferInfo_HasLayoutOfIoRingBufferInfo;
var
  LInfo: TIORingBufferInfo;
  LNative: IORING_BUFFER_INFO;
begin
  // Windows only: registration arrays are passed to the API without conversion
  AssertEquals('SizeOf', Int64(SizeOf(IORING_BUFFER_INFO)), Int64(SizeOf(TIORingBufferInfo)));
  AssertEquals('Length', Int64(NativeUInt(@LNative.Length) - NativeUInt(@LNative)),
    Int64(NativeUInt(@LInfo.Length) - NativeUInt(@LInfo)));
end;

procedure TIORingTests.ErrorMessage_DescribesCodes;
var
  LMessage: string;
begin
  LMessage := IORingErrorMessage(IORING_E_SUBMISSION_QUEUE_FULL);
  Log(LMessage);
  AssertTrue(LMessage, Pos('submission queue is full', LMessage) > 0);
  AssertTrue(LMessage, Pos('0x80460002', LMessage) > 0);

  LMessage := IORingErrorMessage(HResultFromWin32(ERROR_HANDLE_EOF));
  Log(LMessage);
  AssertTrue(LMessage, Pos('0x80070026', LMessage) > 0);
  AssertTrue('No text for ERROR_HANDLE_EOF', Length(LMessage) > Length(' (0x80070026)'));
end;

initialization
  RegisterTests(TIORingTests);

end.
