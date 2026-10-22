unit Tests.Ring;

{
  Tests for the core ring (TIORing in Delphi.IOUring).

  The ring API is used only through Delphi.IOUring, so the tests can later run
  on Linux too. Files, pipes and memory come from TestPlatformHelpers (Windows
  for now); a few layout checks are Windows-only and marked so.
}

interface

uses
  DUnitX.TestFramework,
  TestPlatformHelpers;

type
  [TestFixture]
  TIORingTests = class
  private
    FPatternFileName: string;
    FResources: TTestResources;
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

    // Life cycle
    [Test]
    procedure Available_AndCapabilities;
    [Test]
    procedure Open_RoundsQueueSizes;
    [Test]
    procedure Open_Twice_Raises;
    [Test]
    procedure Close_Twice_DoesNothing;
    [Test]
    procedure PrepareRead_OnClosedRing_Raises;
    [Test]
    procedure EndOfScope_ClosesRing;
    [Test]
    procedure Assign_Raises;
    [Test]
    procedure ConstParameter_DoesNotCopy;

    // Queue limits
    [Test]
    procedure PrepareRead_FullSubmissionQueue_ReturnsFalse;
    [Test]
    procedure Prepare_NeverOverfillsCompletionQueue;

    // Operations
    [Test]
    procedure RandomReads_EveryCompletionVerified;
    [Test]
    procedure RegisterFilesAndBuffers_ArraysAreCopied;
    [Test]
    procedure WriteFlushRead_WithDrain;
    [Test]
    procedure ReadScatter_UsesOnlySegmentCountEntries;
    [Test]
    procedure PrepareCancel_CancelsPendingPipeRead;
    [Test]
    procedure ReadOnWriteOnlyHandle_GivesFailedCompletion;

    // Waiting and closing
    [Test]
    procedure CompletionEvent_SignalsAfterSubmit;
    [Test]
    procedure WaitForCompletions_CountsCompletionsAlreadyInQueue;
    [Test]
    procedure Close_WaitsForPendingOperations;

    // Blocking helpers
    [Test]
    procedure ReadAt_ReadsData;
    [Test]
    procedure ReadAt_AtAndAfterEndOfFile;
    [Test]
    procedure ReadAt_OnBusyRing_Raises;
    [Test]
    procedure WriteAt_ThenReadAt_RoundTrip;

    // Types and errors
    [Test]
    procedure Completion_HasLayoutOfIoRingCqe;
    [Test]
    procedure BufferInfo_HasLayoutOfIoRingBufferInfo;
    [Test]
    procedure ErrorMessage_DescribesCodes;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Delphi.IOUring,
  Delphi.IOUring.Backend.Windows.API,
  TestFileHelpers;

const
  PATTERN_FILE_SIZE = 1024 * 1024;

function AddressByConst(const ARing: TIORing): Pointer;
begin
  Result := @ARing;
end;

function AddressByConstRef(const [ref] ARing: TIORing): Pointer;
begin
  Result := @ARing;
end;

// Leaves a pipe read pending in a local ring and returns without calling
// Close. If the end of scope closes the ring, it waits for that read, so this
// returns only after the read has completed.
procedure LeaveScopeWithPendingRead(const AClient: THandle; var ABuffer: Byte);
var
  LRing: TIORing;
begin
  LRing.Open(8);
  LRing.PrepareRead(TIORingFileRef.FromHandle(AClient), TIORingBufferRef.FromPointer(@ABuffer), 1, 0, 1);
  LRing.Submit;
end;

{ TIORingTests - set-up }

procedure TIORingTests.CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt);
var
  LBadOffset: UInt64;
begin
  Assert.IsTrue(TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset),
    Format('Wrong data at file offset %d', [LBadOffset]));
end;

procedure TIORingTests.SetupFixture;
begin
  FPatternFileName := TTestFileHelpers.CreatePatternFile(PATTERN_FILE_SIZE, 'RingPattern');
end;

procedure TIORingTests.TearDownFixture;
begin
  TTestFileHelpers.DeleteTestFile(FPatternFileName);
end;

procedure TIORingTests.Setup;
begin
  FResources := TTestResources.Create;
end;

procedure TIORingTests.TearDown;
begin
  FResources.Free;
  FResources := nil;
end;

{ Life cycle }

procedure TIORingTests.Available_AndCapabilities;
var
  LCapabilities: TIORingCapabilities;
begin
  Assert.IsTrue(IORingAvailable);

  LCapabilities := TIORing.QueryCapabilities;
  Log(Format('Backend "%s", version %d, max SQ %d, max CQ %d',
    [LCapabilities.BackendName, LCapabilities.NativeVersion, LCapabilities.MaxSubmissionQueueSize,
     LCapabilities.MaxCompletionQueueSize]));
  Assert.AreEqual('Windows IoRing', LCapabilities.BackendName);
  Assert.IsFalse(LCapabilities.Emulated);
  Assert.IsTrue(LCapabilities.SupportedOps = [ioRead, ioWrite, ioFlush, ioCancel, ioRegisterFiles,
    ioRegisterBuffers, ioReadScatter, ioWriteGather], 'All operations');
end;

procedure TIORingTests.Open_RoundsQueueSizes;
var
  LRing: TIORing;
begin
  Assert.IsFalse(LRing.IsOpen);

  LRing.Open(10);

  Assert.IsTrue(LRing.IsOpen);
  Assert.AreEqual(Cardinal(16), LRing.SubmissionQueueSize);
  Assert.AreEqual(Cardinal(32), LRing.CompletionQueueSize);
  Assert.AreEqual(Cardinal(0), LRing.PreparedCount);
  Assert.AreEqual(Cardinal(0), LRing.PendingCount);
end;

procedure TIORingTests.Open_Twice_Raises;
var
  LRing: TIORing;
begin
  LRing.Open(8);

  Assert.WillRaise(
    procedure
    var
      LOther: TIORing;
    begin
      LOther.Open(8);
      LOther.Open(8);
    end, EIORingError);
end;

procedure TIORingTests.Close_Twice_DoesNothing;
var
  LRing: TIORing;
begin
  LRing.Open(8);
  LRing.Close;
  LRing.Close;

  Assert.IsFalse(LRing.IsOpen);
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

  Assert.IsTrue(LRaised, 'PrepareRead on a closed ring must raise, not return False');
end;

procedure TIORingTests.EndOfScope_ClosesRing;
var
  LServer: THandle;
  LClient: THandle;
  LByte: Byte;
  LWriter: TThread;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  // (GetIoRingInfo on a closed ring handle still returns S_OK, so it cannot
  // prove the close; the wait for a pending read can.)
  FResources.OpenPipePair(LServer, LClient);
  LByte := 0;

  LWriter := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(300);
      WriteByteToPipe(LServer, 42);
    end);
  LWriter.FreeOnTerminate := False;
  try
    LWriter.Start;
    LStart := GetTickCount64;
    LeaveScopeWithPendingRead(LClient, LByte);
    LElapsed := GetTickCount64 - LStart;
  finally
    LWriter.WaitFor;
    LWriter.Free;
  end;

  Log(Format('Leaving the scope waited %d ms for the pending read', [LElapsed]));
  Assert.IsTrue(LElapsed >= 200, 'The end of scope did not close (and wait for) the ring');
  Assert.AreEqual(Byte(42), LByte);
end;

procedure TIORingTests.Assign_Raises;
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

  Assert.IsTrue(LRaised, 'Copying a ring must raise');
  Assert.IsTrue(LRing1.IsOpen);
  Assert.IsFalse(LRing2.IsOpen);
end;

procedure TIORingTests.ConstParameter_DoesNotCopy;
var
  LRing: TIORing;
begin
  // A copy would raise (Assign operator). Both forms must pass the original.
  LRing.Open(8);

  Assert.AreEqual(Pointer(@LRing), AddressByConst(LRing), 'const');
  Assert.AreEqual(Pointer(@LRing), AddressByConstRef(LRing), 'const [ref]');
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
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(8);

  LPrepared := 0;
  while LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, LPrepared) do
    Inc(LPrepared);

  Assert.AreEqual(LRing.SubmissionQueueSize, LPrepared, 'Entries accepted before "full"');
  Assert.AreEqual(LPrepared, LRing.Submit(LPrepared));
  Assert.AreEqual(Integer(LPrepared), LRing.PopCompletions(LCompletions));
  Assert.AreEqual(Cardinal(0), LRing.PendingCount);
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
  // Prepare and submit again and again without popping anything: the ring
  // must stop accepting entries when the completion queue would be full,
  // instead of letting SubmitIoRing fail with IORING_E_COMPLETION_QUEUE_TOO_FULL.
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
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

  Assert.AreEqual(LRing.CompletionQueueSize, LAccepted, 'Entries accepted without popping');

  Assert.IsTrue(LRing.WaitForCompletions(LAccepted, 5000));
  Assert.AreEqual(Integer(LAccepted), LRing.PopCompletions(LCompletions));
  Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 0),
    'Room again after popping');
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
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(SLOT_COUNT);

  SetLength(LBuffers, SLOT_COUNT);
  for LSlot := 0 to SLOT_COUNT - 1 do
  begin
    SetLength(LBuffers[LSlot], MAX_READ_SIZE);
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
      Assert.IsTrue((LSlot >= 0) and (LSlot < SLOT_COUNT) and LBusy[LSlot], Format('Unexpected completion %d', [LSlot]));
      Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
      Assert.AreEqual(NativeUInt(LLengths[LSlot]), LCompletion.BytesTransferred);
      CheckPattern(LOffsets[LSlot], @LBuffers[LSlot][0], LLengths[LSlot]);

      LBusy[LSlot] := False;
      LFreeSlots[LFreeCount] := LSlot;
      Inc(LFreeCount);
      Inc(LCompleted);
    end;
  end;

  Assert.AreEqual(READ_COUNT, LCompleted);
  Assert.AreEqual(Cardinal(0), LRing.PendingCount);
end;

procedure TIORingTests.RegisterFilesAndBuffers_ArraysAreCopied;
const
  MEMORY_SIZE = 64 * 1024;
var
  LRing: TIORing;
  LFile: THandle;
  LMemory: PByte;
  LHandles: TArray<THandle>;
  LInfos: TArray<TIORingBufferInfo>;
  LCompletions: array[0..7] of TIORingCompletion;
  LCount: Integer;
  LIndex: Integer;
begin
  LFile := FResources.OpenFile(FPatternFileName);
  LMemory := FResources.AllocPages(MEMORY_SIZE);
  LRing.Open(16);

  SetLength(LHandles, 1);
  LHandles[0] := LFile;
  SetLength(LInfos, 1);
  LInfos[0].Address := LMemory;
  LInfos[0].Length := MEMORY_SIZE;

  Assert.IsTrue(LRing.PrepareRegisterFiles(LHandles, 100));
  Assert.IsTrue(LRing.PrepareRegisterBuffers(LInfos, 101));

  // Spoil the caller's arrays before the kernel reads them: the ring must have copies
  LHandles[0] := INVALID_HANDLE_VALUE;
  LInfos[0].Address := nil;
  LInfos[0].Length := 0;
  LHandles := nil;
  LInfos := nil;

  Assert.IsTrue(LRing.PrepareRead(TIORingFileRef.FromIndex(0), TIORingBufferRef.FromRegistered(0, 4096),
    1000, 3000, 1));
  LRing.Submit(3);

  LCount := LRing.PopCompletions(LCompletions);
  Assert.AreEqual(3, LCount);
  for LIndex := 0 to LCount - 1 do
    Assert.IsTrue(LCompletions[LIndex].Succeeded,
      Format('UserData %d: %s', [LCompletions[LIndex].UserData, LCompletions[LIndex].ErrorMessage]));
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

  Assert.IsTrue(LRing.PrepareWrite(LFile, TIORingBufferRef.FromPointer(@LWriteBuffer), DATA_SIZE, 0, 1));
  Assert.IsTrue(LRing.PrepareFlush(LFile, rfmDefault, 2, [sfDrainPreceding]));
  Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LReadBuffer), DATA_SIZE, 0, 3,
    [sfDrainPreceding]));
  Assert.AreEqual(Cardinal(3), LRing.Submit(3));

  Assert.AreEqual(3, LRing.PopCompletions(LCompletions));
  for LIndex := 0 to 2 do
    Assert.IsTrue(LCompletions[LIndex].Succeeded,
      Format('UserData %d: %s', [LCompletions[LIndex].UserData, LCompletions[LIndex].ErrorMessage]));
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
  // One extra segment after the counted ones points to a guard page: Windows
  // must not use it (so no terminating entry is needed).
  LPage := PageSize;
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName,
    FILE_FLAG_OVERLAPPED or FILE_FLAG_NO_BUFFERING));
  LMemory := FResources.AllocPages((SEGMENT_COUNT + 1) * LPage);
  LGuard := LMemory + SEGMENT_COUNT * LPage;
  FillChar(LGuard^, LPage, $AA);

  for LIndex := 0 to SEGMENT_COUNT do
    LSegments[LIndex] := IORingSegment(LMemory + NativeUInt(LIndex) * LPage);

  LRing.Open(8);
  Assert.IsTrue(LRing.PrepareReadScatter(LFile, @LSegments[0], SEGMENT_COUNT, SEGMENT_COUNT * LPage, LPage, 1));
  LRing.Submit(1);

  Assert.IsTrue(LRing.TryPopCompletion(LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
  Assert.AreEqual(NativeUInt(SEGMENT_COUNT * LPage), LCompletion.BytesTransferred);
  CheckPattern(LPage, LMemory, SEGMENT_COUNT * LPage);

  for LIndex := 0 to Integer(LPage) - 1 do
    if LGuard[LIndex] <> $AA then
      Assert.Fail(Format('Guard page changed at byte %d', [LIndex]));
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
    Assert.IsTrue(LRing.PrepareRead(TIORingFileRef.FromHandle(LClient), TIORingBufferRef.FromPointer(@LBuffer),
      SizeOf(LBuffer), 0, 1));
    LRing.Submit;
    Sleep(20);

    Assert.IsTrue(LRing.PrepareCancel(TIORingFileRef.FromHandle(LClient), 1, 2));
    LRing.Submit(2);

    Assert.AreEqual(2, LRing.PopCompletions(LCompletions));
    LReadSeen := False;
    for LIndex := 0 to 1 do
      if LCompletions[LIndex].UserData = 1 then
      begin
        LReadSeen := True;
        Assert.AreEqual(HResultFromWin32(ERROR_OPERATION_ABORTED), LCompletions[LIndex].NativeResult);
      end
      else
        Assert.IsTrue(LCompletions[LIndex].Succeeded, 'Cancel request: ' + LCompletions[LIndex].ErrorMessage);
    Assert.IsTrue(LReadSeen);
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
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName, FILE_FLAG_OVERLAPPED, GENERIC_WRITE));
  LRing.Open(8);

  Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));
  LRing.Submit(1);

  Assert.IsTrue(LRing.TryPopCompletion(LCompletion));
  Log('Read on write-only handle: ' + LCompletion.ErrorMessage);
  Assert.IsFalse(LCompletion.Succeeded);
  Assert.AreEqual(E_ACCESSDENIED, LCompletion.NativeResult);

  LRaised := False;
  try
    LCompletion.RaiseIfFailed('Read');
  except
    on E: EIORingError do
    begin
      LRaised := True;
      Assert.AreEqual(E_ACCESSDENIED, E.NativeCode);
    end;
  end;
  Assert.IsTrue(LRaised);
end;

{ Waiting and closing }

procedure TIORingTests.CompletionEvent_SignalsAfterSubmit;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..511] of Byte;
  LCompletion: TIORingCompletion;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(8);
  Assert.AreNotEqual(THandle(0), LRing.CompletionEventHandle);

  Assert.IsFalse(LRing.TryPopCompletion(LCompletion), 'Queue must start empty');
  Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));
  LRing.Submit;

  Assert.AreEqual(WAIT_OBJECT_0, WaitForSingleObject(LRing.CompletionEventHandle, 5000));
  Assert.IsTrue(LRing.TryPopCompletion(LCompletion));
  Assert.IsTrue(LCompletion.Succeeded, LCompletion.ErrorMessage);
end;

procedure TIORingTests.WaitForCompletions_CountsCompletionsAlreadyInQueue;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffers: array[0..2] of array[0..511] of Byte;
  LCompletions: array[0..7] of TIORingCompletion;
  LIndex: Integer;
  LStart: UInt64;
  LWaited: Boolean;
  LElapsed: UInt64;
begin
  // Three completions wait in the queue, nothing else is in flight. Does a wait
  // for 3 return at once (counts what is there) or wait for 3 new ones?
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(8);
  for LIndex := 0 to 2 do
    Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffers[LIndex]), 512, 0, LIndex));
  LRing.Submit(3);

  LStart := GetTickCount64;
  LWaited := LRing.WaitForCompletions(3, 2000);
  LElapsed := GetTickCount64 - LStart;
  Log(Format('VERIFY: WaitForCompletions(3) with 3 completions already queued: %s after %d ms',
    [BoolToStr(LWaited, True), LElapsed]));

  Assert.IsTrue(LWaited, 'Timed out');
  Assert.IsTrue(LElapsed < 1000, 'Waited although the completions were there');
  Assert.AreEqual(3, LRing.PopCompletions(LCompletions));
end;

procedure TIORingTests.Close_WaitsForPendingOperations;
var
  LRing: TIORing;
  LServer: THandle;
  LClient: THandle;
  LBuffer: array[0..15] of Byte;
  LWriter: TThread;
  LStart: UInt64;
  LElapsed: UInt64;
begin
  // CloseIoRing alone does not cancel a pending read; TIORing.Close must wait
  // until the read has completed, so the buffer is safe once Close returns.
  FResources.OpenPipePair(LServer, LClient);
  FillChar(LBuffer, SizeOf(LBuffer), 0);
  LRing.Open(8);
  Assert.IsTrue(LRing.PrepareRead(TIORingFileRef.FromHandle(LClient), TIORingBufferRef.FromPointer(@LBuffer),
    SizeOf(LBuffer), 0, 1));
  LRing.Submit;

  LWriter := TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep(300);
      WriteByteToPipe(LServer, 42);
    end);
  LWriter.FreeOnTerminate := False;
  try
    LWriter.Start;
    LStart := GetTickCount64;
    LRing.Close;
    LElapsed := GetTickCount64 - LStart;
  finally
    LWriter.WaitFor;
    LWriter.Free;
  end;

  Log(Format('Close waited %d ms for the pending read', [LElapsed]));
  Assert.IsFalse(LRing.IsOpen);
  Assert.IsTrue(LElapsed >= 200, 'Close returned before the read completed');
  Assert.AreEqual(Byte(42), LBuffer[0]);
end;

{ Blocking helpers }

procedure TIORingTests.ReadAt_ReadsData;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..4095] of Byte;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(8);

  Assert.AreEqual(Cardinal(SizeOf(LBuffer)), ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 12345));
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

  Assert.AreEqual(Cardinal(FILE_SIZE - 50), ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 50), 'Crossing EOF');
  CheckPattern(50, @LBuffer, FILE_SIZE - 50);
  Assert.AreEqual(Cardinal(0), ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), FILE_SIZE), 'At EOF');
  Assert.AreEqual(Cardinal(0), ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 10 * FILE_SIZE), 'After EOF');
end;

procedure TIORingTests.ReadAt_OnBusyRing_Raises;
var
  LRing: TIORing;
  LFile: TIORingFileRef;
  LBuffer: array[0..511] of Byte;
  LRaised: Boolean;
  LCompletion: TIORingCompletion;
begin
  LFile := TIORingFileRef.FromHandle(FResources.OpenFile(FPatternFileName));
  LRing.Open(8);
  Assert.IsTrue(LRing.PrepareRead(LFile, TIORingBufferRef.FromPointer(@LBuffer), SizeOf(LBuffer), 0, 1));

  LRaised := False;
  try
    ReadAt(LRing, LFile, LBuffer, SizeOf(LBuffer), 0);
  except
    on EIORingError do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'ReadAt must refuse a ring with a prepared entry');

  LRing.Submit(1);
  Assert.IsTrue(LRing.TryPopCompletion(LCompletion));
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

  Assert.AreEqual(Cardinal(DATA_SIZE), WriteAt(LRing, LFile, LWriteBuffer, DATA_SIZE, 777));
  Assert.AreEqual(Cardinal(DATA_SIZE), ReadAt(LRing, LFile, LReadBuffer, DATA_SIZE, 777));
  CheckPattern(777, @LReadBuffer, DATA_SIZE);
end;

{ Types and errors }

procedure TIORingTests.Completion_HasLayoutOfIoRingCqe;
var
  LCompletion: TIORingCompletion;
  LCqe: IORING_CQE;
begin
  // Windows only: the ring pops IORING_CQE straight into TIORingCompletion
  Assert.AreEqual(SizeOf(IORING_CQE), SizeOf(TIORingCompletion));
  Assert.AreEqual(NativeInt(@LCqe.UserData) - NativeInt(@LCqe),
    NativeInt(@LCompletion.UserData) - NativeInt(@LCompletion));
  Assert.AreEqual(NativeInt(@LCqe.ResultCode) - NativeInt(@LCqe),
    NativeInt(@LCompletion.NativeResult) - NativeInt(@LCompletion));
  Assert.AreEqual(NativeInt(@LCqe.Information) - NativeInt(@LCqe),
    NativeInt(@LCompletion.BytesTransferred) - NativeInt(@LCompletion));
end;

procedure TIORingTests.BufferInfo_HasLayoutOfIoRingBufferInfo;
var
  LInfo: TIORingBufferInfo;
  LNative: IORING_BUFFER_INFO;
begin
  // Windows only: registration arrays are passed to the API without conversion
  Assert.AreEqual(SizeOf(IORING_BUFFER_INFO), SizeOf(TIORingBufferInfo));
  Assert.AreEqual(NativeInt(@LNative.Length) - NativeInt(@LNative),
    NativeInt(@LInfo.Length) - NativeInt(@LInfo));
end;

procedure TIORingTests.ErrorMessage_DescribesCodes;
var
  LMessage: string;
begin
  LMessage := IORingErrorMessage(IORING_E_SUBMISSION_QUEUE_FULL);
  Log(LMessage);
  Assert.IsTrue(Pos('submission queue is full', LMessage) > 0, LMessage);
  Assert.IsTrue(Pos('0x80460002', LMessage) > 0, LMessage);

  LMessage := IORingErrorMessage(HResultFromWin32(ERROR_HANDLE_EOF));
  Log(LMessage);
  Assert.IsTrue(Pos('0x80070026', LMessage) > 0, LMessage);
  Assert.IsTrue(Length(LMessage) > Length(' (0x80070026)'), 'No text for ERROR_HANDLE_EOF');
end;

initialization
  TDUnitX.RegisterTestFixture(TIORingTests);

end.
