unit Tests.SequentialWriter;

{
  Tests for TIORingSequentialWriter (Delphi.IOUring.SequentialWriter) and
  TSequentialWriteOnlyFileStream (Delphi.IOUring.Streams): written data read
  back (pattern bytes: every file offset has its own expected byte), sizes
  around the buffer size, pieces of every size, the zero-copy API, Flush,
  unbuffered writing with a cut last buffer, failed writes, a shared engine,
  and TStream use.

  Failed writes are made with a byte-range lock: the test locks a part of the
  file through a second handle, and Windows refuses writes there.
}

interface

uses
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework,
  Delphi.IOUring,
  Delphi.IOUring.Engine,
  Delphi.IOUring.SequentialWriter,
  Delphi.IOUring.Streams,
  TestPlatformHelpers;

type
  // Shared helpers of both fixtures
  TWriterTestsBase = class
  protected
    FResources: TTestResources;
    // A new file name in the test folder; the file is deleted after the test
    function NewFileName: string;
    // Fails unless the file has exactly ASize bytes of the pattern
    procedure CheckFile(const AFileName: string; const ASize: Int64);
    // Locks bytes [AOffset, AOffset + ALength) of the file through a handle
    // of its own (closed after the test): writes there fail
    procedure LockRegion(const AFileName: string; const AOffset, ALength: UInt64);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
  end;

  [TestFixture]
  TSequentialWriterTests = class(TWriterTestsBase)
  private
    FFailures: Integer;
    // Writes the pattern bytes of file offsets [AStart, AStart + ASize) in
    // pieces of APiece bytes
    procedure WritePattern(var AWriter: TIORingSequentialWriter; const AStart, ASize, APiece: Int64);
    procedure WriteWithoutClose(const AFileName: string);
  public
    [Test]
    procedure RoundTrip_SizesAroundTheBufferSize;
    [Test]
    procedure Pieces_OfEverySize;
    [Test]
    procedure DefaultBuffers_SeveralMiB;
    [Test]
    procedure ZeroCopy_AcquireAndCommit;
    [Test]
    procedure Flush_PutsAPartlyFilledBufferIntoTheFile;
    [Test]
    procedure FlushToDisk_Works;
    [Test]
    procedure Unbuffered_CutsTheLastBuffer;
    [Test]
    procedure Unbuffered_FlushInBetween;
    [Test]
    procedure FailedWrite_RaisesAtALaterWrite;
    [Test]
    procedure FailedWrite_RaisesAtFlushAndAgain;
    [Test]
    procedure FailedWrite_CloseRaises;
    [Test]
    procedure BadArguments_Raise;
    [Test]
    procedure WrongCallOrder_Raises;
    [Test]
    procedure EndOfScope_WritesTheRest;
    [Test]
    procedure Stats_CountWrites;
    [Test]
    procedure SharedEngine_SeveralWriters;
  end;

  [TestFixture]
  TWriteStreamTests = class(TWriterTestsBase)
  public
    [Test]
    procedure WriteBufferAndCopyFrom_RoundTrip;
    [Test]
    procedure SaveToStream_Text;
    [Test]
    procedure PositionSizeAndSeek;
    [Test]
    procedure ReadAndSetSize_Raise;
    [Test]
    procedure CannotCreate_RaisesEFCreateError;
    [Test]
    procedure FailedWrite_FlushRaisesEWriteError_FreeDoesNot;
    [Test]
    procedure FailedWrite_FreeRaisesEWriteError;
    [Test]
    procedure SharedEngine;
    [Test]
    procedure Unbuffered_RoundTrip;
  end;

implementation

uses
  Winapi.Windows,
  Delphi.IOUring.Atomics,
  TestFileHelpers,
  TestThreadHelpers;

const
  SMALL_BUFFER = 4096;

// Writes the pattern bytes of [AStart, AStart + ASize) to a stream, in pieces
procedure WritePatternToStream(const AStream: TStream; const AStart, ASize, APiece: Int64);
var
  LPiece: TBytes;
  LDone: Int64;
  LLength: Int64;
begin
  SetLength(LPiece, APiece);
  LDone := 0;
  while LDone < ASize do
  begin
    LLength := APiece;
    if LLength > ASize - LDone then
      LLength := ASize - LDone;
    TTestFileHelpers.FillPattern(AStart + LDone, LPiece[0], LLength);
    AStream.WriteBuffer(LPiece[0], LLength);
    Inc(LDone, LLength);
  end;
end;

{ TWriterTestsBase }

procedure TWriterTestsBase.Setup;
begin
  FResources := TTestResources.Create;
end;

procedure TWriterTestsBase.TearDown;
begin
  FResources.Free;
  FResources := nil;
end;

function TWriterTestsBase.NewFileName: string;
begin
  Result := TTestFileHelpers.NewTestFileName('Writer');
  FResources.AddFile(Result);
end;

procedure TWriterTestsBase.CheckFile(const AFileName: string; const ASize: Int64);
var
  LStream: TFileStream;
  LData: TBytes;
  LBadOffset: UInt64;
begin
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Assert.AreEqual<Int64>(ASize, LStream.Size, 'File size');
    SetLength(LData, ASize);
    if ASize > 0 then
      LStream.ReadBuffer(LData[0], ASize);
  finally
    LStream.Free;
  end;
  if ASize > 0 then
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LData[0], ASize, LBadOffset),
      Format('Wrong data at file offset %d', [LBadOffset]));
end;

procedure TWriterTestsBase.LockRegion(const AFileName: string; const AOffset, ALength: UInt64);
var
  LHandle: THandle;
  LOverlapped: TOverlapped;
begin
  // The writer lets others read; this handle lets the writer write
  LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if LHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
  FResources.AddHandle(LHandle);
  FillChar(LOverlapped, SizeOf(LOverlapped), 0);
  LOverlapped.Offset := DWORD(AOffset);
  LOverlapped.OffsetHigh := DWORD(AOffset shr 32);
  if not LockFileEx(LHandle, LOCKFILE_EXCLUSIVE_LOCK or LOCKFILE_FAIL_IMMEDIATELY, 0, DWORD(ALength),
    DWORD(ALength shr 32), LOverlapped) then
    RaiseLastOSError;
end;

{ TSequentialWriterTests }

procedure TSequentialWriterTests.WritePattern(var AWriter: TIORingSequentialWriter;
  const AStart, ASize, APiece: Int64);
var
  LPiece: TBytes;
  LDone: Int64;
  LLength: Int64;
begin
  SetLength(LPiece, APiece);
  LDone := 0;
  while LDone < ASize do
  begin
    LLength := APiece;
    if LLength > ASize - LDone then
      LLength := ASize - LDone;
    TTestFileHelpers.FillPattern(AStart + LDone, LPiece[0], LLength);
    AWriter.Write(LPiece[0], LLength);
    Inc(LDone, LLength);
  end;
end;

procedure TSequentialWriterTests.RoundTrip_SizesAroundTheBufferSize;
const
  SIZES: array[0..8] of Int64 = (0, 1, SMALL_BUFFER - 1, SMALL_BUFFER, SMALL_BUFFER + 1, 3 * SMALL_BUFFER,
    3 * SMALL_BUFFER + 17, 10 * SMALL_BUFFER, 1024 * 1024 + 5);
var
  LSize: Int64;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  // 3 small buffers: they are used again and again
  for LSize in SIZES do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [], SMALL_BUFFER, 3);
    WritePattern(LWriter, 0, LSize, 1000);
    Assert.AreEqual<Int64>(LSize, LWriter.Position, 'Position');
    LWriter.Close;
    CheckFile(LName, LSize);
  end;
end;

procedure TSequentialWriterTests.Pieces_OfEverySize;
const
  PIECES: array[0..5] of Int64 = (1, 7, SMALL_BUFFER, 10000, 3 * SMALL_BUFFER, 50000);
  SIZE = 50000;
var
  LPiece: Int64;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  for LPiece in PIECES do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [], SMALL_BUFFER, 4);
    WritePattern(LWriter, 0, SIZE, LPiece);
    LWriter.Close;
    CheckFile(LName, SIZE);
  end;
end;

procedure TSequentialWriterTests.DefaultBuffers_SeveralMiB;
const
  SIZE = 20 * 1024 * 1024 + 333;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName);
  WritePattern(LWriter, 0, SIZE, 100000);
  LWriter.Close;
  CheckFile(LName, SIZE);
end;

procedure TSequentialWriterTests.ZeroCopy_AcquireAndCommit;
const
  SIZE = 100000;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
  LData: PByte;
  LCapacity: NativeInt;
  LLength: NativeInt;
  LDone: Int64;
  LRound: Integer;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 3);
  LDone := 0;
  LRound := 0;
  while LDone < SIZE do
  begin
    LWriter.AcquireBuffer(LData, LCapacity);
    Assert.IsTrue(LCapacity > 0, 'Room in the buffer');
    // Sometimes nothing, sometimes all of it, mostly a part
    case LRound mod 4 of
      0: LLength := 0;
      1: LLength := LCapacity;
    else
      LLength := 1 + LRound mod 3000;
    end;
    if LLength > LCapacity then
      LLength := LCapacity;
    if LLength > SIZE - LDone then
      LLength := SIZE - LDone;
    TTestFileHelpers.FillPattern(LDone, LData^, LLength);
    LWriter.CommitBuffer(LLength);
    Inc(LDone, LLength);
    Inc(LRound);
  end;
  LWriter.Close;
  CheckFile(LName, SIZE);
end;

procedure TSequentialWriterTests.Flush_PutsAPartlyFilledBufferIntoTheFile;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], 64 * 1024, 4);
  WritePattern(LWriter, 0, 1000, 1000);
  LWriter.Flush;
  CheckFile(LName, 1000);
  // The buffer stays the current one: the rest follows right after it
  WritePattern(LWriter, 1000, 200000, 7000);
  LWriter.Flush;
  CheckFile(LName, 201000);
  WritePattern(LWriter, 201000, 5, 5);
  LWriter.Close;
  CheckFile(LName, 201005);
end;

procedure TSequentialWriterTests.FlushToDisk_Works;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  WritePattern(LWriter, 0, 50000, 3000);
  LWriter.Flush(True);
  CheckFile(LName, 50000);
  LWriter.Close;
end;

procedure TSequentialWriterTests.Unbuffered_CutsTheLastBuffer;
const
  SIZES: array[0..3] of Int64 = (1, 10000, 64 * 1024, 3 * 64 * 1024 + 123);
var
  LSize: Int64;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  for LSize in SIZES do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [swoUnbuffered], 64 * 1024, 4);
    WritePattern(LWriter, 0, LSize, 5000);
    LWriter.Close;
    CheckFile(LName, LSize);
  end;
end;

procedure TSequentialWriterTests.Unbuffered_FlushInBetween;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [swoUnbuffered], 64 * 1024, 4);
  WritePattern(LWriter, 0, 5000, 5000);
  LWriter.Flush;
  // Whole sectors were written; the file has its right size anyway
  CheckFile(LName, 5000);
  WritePattern(LWriter, 5000, 70000, 3333);
  LWriter.Close;
  CheckFile(LName, 75000);
end;

procedure TSequentialWriterTests.FailedWrite_RaisesAtALaterWrite;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  // 2 buffers: the third one waits for the first write, which failed
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LockRegion(LName, 0, SMALL_BUFFER);
  Assert.WillRaise(
    procedure
    begin
      WritePattern(LWriter, 0, 3 * SMALL_BUFFER, SMALL_BUFFER);
    end, EIORingError, 'A later Write raises');
  Assert.IsTrue(LWriter.Failed, 'Failed');
  Assert.IsTrue(LWriter.ErrorReported, 'Reported');
  Assert.WillRaise(
    procedure
    begin
      WritePattern(LWriter, 0, 1, 1);
    end, EIORingError, 'And again');
  LWriter.Close(False);
end;

procedure TSequentialWriterTests.FailedWrite_RaisesAtFlushAndAgain;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LockRegion(LName, 0, SMALL_BUFFER);
  WritePattern(LWriter, 0, 1000, 1000);    // only in the buffer: no write yet
  Assert.IsFalse(LWriter.Failed, 'Nothing written yet');
  Assert.WillRaise(
    procedure
    begin
      LWriter.Flush;
    end, EIORingError, 'Flush raises');
  Assert.WillRaise(
    procedure
    begin
      LWriter.Flush;
    end, EIORingError, 'And again');
  Assert.WillRaise(
    procedure
    begin
      LWriter.Close;
    end, EIORingError, 'Close too');
  Assert.IsFalse(LWriter.IsOpen, 'Closed anyway');
end;

procedure TSequentialWriterTests.FailedWrite_CloseRaises;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LockRegion(LName, 0, SMALL_BUFFER);
  WritePattern(LWriter, 0, 1000, 1000);
  Assert.WillRaise(
    procedure
    begin
      LWriter.Close;
    end, EIORingError, 'Close writes the rest, which fails');
  Assert.IsFalse(LWriter.IsOpen, 'Closed anyway');
end;

procedure TSequentialWriterTests.BadArguments_Raise;
var
  LName: string;
  LSmall: TIORingEngine;
begin
  LName := NewFileName;
  Assert.WillRaise(
    procedure
    var
      LWriter: TIORingSequentialWriter;
    begin
      LWriter.Open(LName, [], 1000);
    end, EIORingError, 'Buffer size not a multiple of 4096');
  Assert.WillRaise(
    procedure
    var
      LWriter: TIORingSequentialWriter;
    begin
      LWriter.Open(LName, [], SMALL_BUFFER, 0);
    end, EIORingError, 'No buffers');
  Assert.WillRaise(
    procedure
    var
      LWriter: TIORingSequentialWriter;
    begin
      LWriter.Open(LName, [], SMALL_BUFFER, IORING_WRITER_MAX_BUFFER_COUNT + 1);
    end, EIORingError, 'Too many buffers');
  LSmall := TIORingEngine.Create(4, 4);
  try
    Assert.WillRaise(
      procedure
      var
        LWriter: TIORingSequentialWriter;
      begin
        LWriter.Open(LName, [], SMALL_BUFFER, 8, LSmall);
      end, EIORingError, 'An engine with too few requests');
  finally
    LSmall.Free;
  end;
  Assert.WillRaise(
    procedure
    var
      LWriter: TIORingSequentialWriter;
    begin
      LWriter.Open(LName, [], SMALL_BUFFER, 2);
      LWriter.Open(LName, [], SMALL_BUFFER, 2);
    end, EIORingError, 'Opened twice');
end;

procedure TSequentialWriterTests.WrongCallOrder_Raises;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
  LData: PByte;
  LCapacity: NativeInt;
  LByte: Byte;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LByte := 1;
  Assert.WillRaise(
    procedure
    begin
      LWriter.CommitBuffer(1);
    end, EInvalidOpException, 'Commit without Acquire');
  LWriter.AcquireBuffer(LData, LCapacity);
  Assert.AreEqual<NativeInt>(SMALL_BUFFER, LCapacity, 'A whole buffer');
  Assert.WillRaise(
    procedure
    begin
      LWriter.Write(LByte, 1);
    end, EInvalidOpException, 'Write while a buffer is acquired');
  Assert.WillRaise(
    procedure
    begin
      LWriter.CommitBuffer(SMALL_BUFFER + 1);
    end, EIORingError, 'More than the buffer holds');
  LWriter.CommitBuffer(0);
  LWriter.Close;
  Assert.WillRaise(
    procedure
    begin
      LWriter.Write(LByte, 1);
    end, EIORingError, 'Write after Close');
end;

procedure TSequentialWriterTests.WriteWithoutClose(const AFileName: string);
var
  LWriter: TIORingSequentialWriter;
begin
  LWriter.Open(AFileName, [], SMALL_BUFFER, 2);
  WritePattern(LWriter, 0, 10000, 999);
end;

procedure TSequentialWriterTests.EndOfScope_WritesTheRest;
var
  LName: string;
begin
  LName := NewFileName;
  WriteWithoutClose(LName);
  CheckFile(LName, 10000);
end;

procedure TSequentialWriterTests.Stats_CountWrites;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  WritePattern(LWriter, 0, 10 * SMALL_BUFFER + 100, 10 * SMALL_BUFFER + 100);
  LWriter.Close;
  Assert.AreEqual<UInt64>(11, LWriter.Stats.WritesIssued, 'Ten full buffers and the rest');
  Assert.AreEqual<UInt64>(10 * SMALL_BUFFER + 100, LWriter.Stats.BytesWritten, 'Bytes');
  CheckFile(LName, 10 * SMALL_BUFFER + 100);
end;

procedure TSequentialWriterTests.SharedEngine_SeveralWriters;
const
  WRITERS = 4;
  SIZE = 3 * 1024 * 1024 + 77;
var
  LEngine: TIORingEngine;
  LNames: array[0..WRITERS - 1] of string;
  LIndex: Integer;
begin
  for LIndex := 0 to WRITERS - 1 do
    LNames[LIndex] := NewFileName;
  FFailures := 0;
  LEngine := TIORingEngine.Create(WRITERS * 8 + 4, 64, 2);
  try
    RunThreads(WRITERS,
      procedure(AThread: Integer)
      var
        LWriter: TIORingSequentialWriter;
      begin
        try
          LWriter.Open(LNames[AThread], [], 64 * 1024, 8, LEngine);
          WritePattern(LWriter, 0, SIZE, 10000 + AThread * 1000);
          LWriter.Close;
        except
          TAtomic.Increment(FFailures);
        end;
      end);
  finally
    LEngine.Free;
  end;
  Assert.AreEqual(0, FFailures, 'Writers that failed');
  for LIndex := 0 to WRITERS - 1 do
    CheckFile(LNames[LIndex], SIZE);
end;

{ TWriteStreamTests }

procedure TWriteStreamTests.WriteBufferAndCopyFrom_RoundTrip;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
  LSource: TMemoryStream;
begin
  LName := NewFileName;
  LSource := TMemoryStream.Create;
  try
    LSource.Size := 300000;
    TTestFileHelpers.FillPattern(100000, LSource.Memory^, LSource.Size);
    LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 4);
    try
      WritePatternToStream(LStream, 0, 100000, 4321);
      LStream.CopyFrom(LSource, 0);    // from the source's start
      Assert.AreEqual<Int64>(400000, LStream.Position, 'Position');
    finally
      LStream.Free;
    end;
  finally
    LSource.Free;
  end;
  CheckFile(LName, 400000);
end;

procedure TWriteStreamTests.SaveToStream_Text;
var
  LName: string;
  LLines: TStringList;
  LStream: TSequentialWriteOnlyFileStream;
  LExpected: TBytes;
  LRead: TBytes;
  LFile: TFileStream;
  LIndex: Integer;
begin
  LName := NewFileName;
  LLines := TStringList.Create;
  try
    for LIndex := 1 to 20000 do
      LLines.Add(Format('Line %d of the test', [LIndex]));
    LStream := TSequentialWriteOnlyFileStream.Create(LName);
    try
      LLines.SaveToStream(LStream, TEncoding.UTF8);
    finally
      LStream.Free;
    end;
    LExpected := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(LLines.Text);
  finally
    LLines.Free;
  end;
  LFile := TFileStream.Create(LName, fmOpenRead or fmShareDenyNone);
  try
    SetLength(LRead, LFile.Size);
    LFile.ReadBuffer(LRead[0], Length(LRead));
  finally
    LFile.Free;
  end;
  Assert.AreEqual(Length(LExpected), Length(LRead), 'File size');
  Assert.IsTrue(CompareMem(@LExpected[0], @LRead[0], Length(LExpected)), 'Same text');
end;

procedure TWriteStreamTests.PositionSizeAndSeek;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  try
    Assert.AreEqual<Int64>(0, LStream.Position, 'Start');
    WritePatternToStream(LStream, 0, 10000, 3000);
    Assert.AreEqual<Int64>(10000, LStream.Position, 'Position');
    Assert.AreEqual<Int64>(10000, LStream.Size, 'Size = Position');
    Assert.AreEqual<Int64>(10000, LStream.Seek(0, soCurrent), 'Seek to here');
    Assert.AreEqual<Int64>(10000, LStream.Seek(0, soEnd), 'The end is here');
    LStream.Position := 10000;
    Assert.WillRaise(
      procedure
      begin
        LStream.Position := 0;
      end, EIORingStreamError, 'Back');
    Assert.WillRaise(
      procedure
      begin
        LStream.Seek(10, soCurrent);
      end, EIORingStreamError, 'Forward');
    WritePatternToStream(LStream, 10000, 5, 5);
  finally
    LStream.Free;
  end;
  CheckFile(LName, 10005);
end;

procedure TWriteStreamTests.ReadAndSetSize_Raise;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
  LByte: Byte;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName);
  try
    Assert.WillRaise(
      procedure
      begin
        LStream.Read(LByte, 1);
      end, EIORingStreamError, 'Read');
    Assert.WillRaise(
      procedure
      begin
        LStream.Size := 100;
      end, EIORingStreamError, 'Size');
  finally
    LStream.Free;
  end;
end;

procedure TWriteStreamTests.CannotCreate_RaisesEFCreateError;
var
  LName: string;
begin
  LName := TTestFileHelpers.TestFolder + 'no such folder\file.dat';
  Assert.WillRaise(
    procedure
    begin
      TSequentialWriteOnlyFileStream.Create(LName).Free;
    end, EFCreateError, 'A folder that does not exist');
end;

procedure TWriteStreamTests.FailedWrite_FlushRaisesEWriteError_FreeDoesNot;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  try
    LockRegion(LName, 0, SMALL_BUFFER);
    WritePatternToStream(LStream, 0, 1000, 1000);
    Assert.WillRaise(
      procedure
      begin
        LStream.Flush;
      end, EWriteError, 'Flush');
    Assert.WillRaise(
      procedure
      begin
        WritePatternToStream(LStream, 1000, 1, 1);
      end, EWriteError, 'And a later Write');
  finally
    // Reported already: Free does not raise it again
    LStream.Free;
  end;
end;

procedure TWriteStreamTests.FailedWrite_FreeRaisesEWriteError;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  LockRegion(LName, 0, SMALL_BUFFER);
  WritePatternToStream(LStream, 0, 1000, 1000);    // only in the buffer
  // Free writes it, which fails, and nobody has seen that yet
  Assert.WillRaise(
    procedure
    begin
      LStream.Free;
    end, EWriteError, 'Free raises');
  // A destructor that raises does not free the object's memory (Delphi): the
  // stream has released everything else, so only that is left to free here
  LStream.FreeInstance;
end;

procedure TWriteStreamTests.SharedEngine;
var
  LName: string;
  LEngine: TIORingEngine;
  LStream: TSequentialWriteOnlyFileStream;
begin
  LName := NewFileName;
  LEngine := TIORingEngine.Create;
  try
    LStream := TSequentialWriteOnlyFileStream.Create(LName, LEngine, [], SMALL_BUFFER, 4);
    try
      WritePatternToStream(LStream, 0, 77777, 7777);
    finally
      LStream.Free;
    end;
    Assert.WillRaise(
      procedure
      begin
        TSequentialWriteOnlyFileStream.Create(LName, TIORingEngine(nil)).Free;
      end, EIORingError, 'No engine');
  finally
    LEngine.Free;
  end;
  CheckFile(LName, 77777);
end;

procedure TWriteStreamTests.Unbuffered_RoundTrip;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [swoUnbuffered], 64 * 1024, 4);
  try
    WritePatternToStream(LStream, 0, 1000000 + 7, 12345);
  finally
    LStream.Free;
  end;
  CheckFile(LName, 1000000 + 7);
end;

initialization
  TDUnitX.RegisterTestFixture(TSequentialWriterTests);
  TDUnitX.RegisterTestFixture(TWriteStreamTests);

end.
