unit PIRUnit.SequentialWriter.Tests;

{
  Tests for TIORingSequentialWriter (PIRUnit.SequentialWriter) and
  TSequentialWriteOnlyFileStream (PIRUnit.Streams): written data read
  back (pattern bytes: every file offset has its own expected byte), sizes
  around the buffer size, pieces of every size, the zero-copy API, Flush,
  unbuffered writing with a cut last buffer, failed writes, a shared engine,
  and TStream use.

  Failed writes are made by TTestResources.MakeWritesFail: a byte-range lock
  on Windows, a read-only descriptor in place of the writer's on Linux.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils,
{$ELSE}
  System.Classes, System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.SequentialWriter, PIRUnit.Streams, PIRUnit.Test.PlatformHelpers,
  PIRUnit.Test.Support;

type
  // Shared helpers of both test cases
  TWriterTestsBase = class(TIORingTestCase)
  protected
    FResources: TTestResources;
    procedure SetUp; override;
    procedure TearDown; override;
    // A new file name in the test folder; the file is deleted after the test
    function NewFileName: string;
    // Fails unless the file has exactly ASize bytes of the pattern
    procedure CheckFile(const AFileName: string; const ASize: Int64);
  end;

  TSequentialWriterTests = class(TWriterTestsBase)
  private
    FFailures: Integer;
    FEngine: TIORingEngine;
    FNames: array of string;
    // Writes the pattern bytes of file offsets [AStart, AStart + ASize) in pieces of APiece bytes
    procedure WritePattern(var AWriter: TIORingSequentialWriter; const AStart, ASize, APiece: Int64);
    procedure WriteWithoutClose(const AFileName: string);
    procedure WorkWriter(AIndex: Integer);
  published
    procedure RoundTrip_SizesAroundTheBufferSize;
    procedure Pieces_OfEverySize;
    procedure DefaultBuffers_SeveralMiB;
    procedure ZeroCopy_AcquireAndCommit;
    procedure Flush_PutsAPartlyFilledBufferIntoTheFile;
    procedure FlushToDisk_Works;
    procedure Unbuffered_CutsTheLastBuffer;
    procedure Unbuffered_FlushInBetween;
    procedure FailedWrite_RaisesAtALaterWrite;
    procedure FailedWrite_RaisesAtFlushAndAgain;
    procedure FailedWrite_CloseRaises;
    procedure BadArguments_Raise;
    procedure WrongCallOrder_Raises;
    procedure EndOfScope_WritesTheRest;
    procedure Stats_CountWrites;
    procedure SharedEngine_SeveralWriters;
  end;

  TWriteStreamTests = class(TWriterTestsBase)
  published
    procedure WriteBufferAndCopyFrom_RoundTrip;
    procedure SaveToStream_Text;
    procedure PositionSizeAndSeek;
    procedure ReadAndSetSize_Raise;
    procedure CannotCreate_RaisesEFCreateError;
    procedure FailedWrite_FlushRaisesEWriteError_FreeDoesNot;
    procedure FailedWrite_FreeRaisesEWriteError;
    procedure SharedEngine;
    procedure Unbuffered_RoundTrip;
  end;

implementation

uses
  PIRUnit.Atomics, PIRUnit.Test.FileHelpers;

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

procedure TWriterTestsBase.SetUp;
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
begin
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    CheckEqualsU64('File size', UInt64(ASize), UInt64(LStream.Size));
    SetLength(LData, ASize);

    if ASize > 0 then
      LStream.ReadBuffer(LData[0], ASize);
  finally
    LStream.Free;
  end;

  if ASize > 0 then
    CheckPattern(0, @LData[0], ASize, 'File data');
end;

{ TSequentialWriterTests }

procedure TSequentialWriterTests.WritePattern(var AWriter: TIORingSequentialWriter; const AStart, ASize, APiece: Int64);
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
  LIndex: Integer;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  // 3 small buffers: they are used again and again
  for LIndex := Low(SIZES) to High(SIZES) do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [], SMALL_BUFFER, 3);
    WritePattern(LWriter, 0, SIZES[LIndex], 1000);
    CheckEqualsU64('Position', UInt64(SIZES[LIndex]), UInt64(LWriter.Position));
    LWriter.Close;
    CheckFile(LName, SIZES[LIndex]);
  end;
end;

procedure TSequentialWriterTests.Pieces_OfEverySize;
const
  PIECES: array[0..5] of Int64 = (1, 7, SMALL_BUFFER, 10000, 3 * SMALL_BUFFER, 50000);
  SIZE = 50000;
var
  LIndex: Integer;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  for LIndex := Low(PIECES) to High(PIECES) do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [], SMALL_BUFFER, 4);
    WritePattern(LWriter, 0, SIZE, PIECES[LIndex]);
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
    AssertTrue('Room in the buffer', LCapacity > 0);

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
  LIndex: Integer;
  LName: string;
  LWriter: TIORingSequentialWriter;
begin
  for LIndex := Low(SIZES) to High(SIZES) do
  begin
    LName := NewFileName;
    LWriter.Open(LName, [swoUnbuffered], 64 * 1024, 4);
    WritePattern(LWriter, 0, SIZES[LIndex], 5000);
    LWriter.Close;
    CheckFile(LName, SIZES[LIndex]);
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
  LRaised: Boolean;
begin
  // 2 buffers: the third one waits for the first write, which failed
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  FResources.MakeWritesFail(LName);
  LRaised := False;

  try
    WritePattern(LWriter, 0, 3 * SMALL_BUFFER, SMALL_BUFFER);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('A later Write raises', LRaised);
  AssertTrue('Failed', LWriter.Failed);
  AssertTrue('Reported', LWriter.ErrorReported);
  LRaised := False;

  try
    WritePattern(LWriter, 0, 1, 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('And again', LRaised);
  LWriter.Close(False);
end;

procedure TSequentialWriterTests.FailedWrite_RaisesAtFlushAndAgain;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
  LRaised: Integer;
  LIndex: Integer;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  FResources.MakeWritesFail(LName);
  WritePattern(LWriter, 0, 1000, 1000);    // only in the buffer: no write yet
  AssertFalse('Nothing written yet', LWriter.Failed);
  LRaised := 0;

  for LIndex := 1 to 2 do
    try
      LWriter.Flush;
    except
      on EIORingError do
        Inc(LRaised);
    end;

  AssertEquals('Flush raises, and again', 2, LRaised);

  try
    LWriter.Close;
  except
    on EIORingError do
      Inc(LRaised);
  end;

  AssertEquals('Close too', 3, LRaised);
  AssertFalse('Closed anyway', LWriter.IsOpen);
end;

procedure TSequentialWriterTests.FailedWrite_CloseRaises;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
  LRaised: Boolean;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  FResources.MakeWritesFail(LName);
  WritePattern(LWriter, 0, 1000, 1000);
  LRaised := False;

  try
    LWriter.Close;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Close writes the rest, which fails', LRaised);
  AssertFalse('Closed anyway', LWriter.IsOpen);
end;

procedure TSequentialWriterTests.BadArguments_Raise;

  // True if Open of a new writer raises EIORingError
  function OpenRaises(const AFileName: string; const ABufferSize, ABufferCount: Cardinal;
    const AEngine: TIORingEngine): Boolean;
  var
    LWriter: TIORingSequentialWriter;
  begin
    Result := False;

    try
      LWriter.Open(AFileName, [], ABufferSize, ABufferCount, AEngine);
    except
      on EIORingError do
        Result := True;
    end;
  end;

var
  LName: string;
  LSmall: TIORingEngine;
  LWriter: TIORingSequentialWriter;
  LRaised: Boolean;
begin
  LName := NewFileName;
  AssertTrue('Buffer size not a multiple of 4096', OpenRaises(LName, 1000, 2, nil));
  AssertTrue('No buffers', OpenRaises(LName, SMALL_BUFFER, 0, nil));
  AssertTrue('Too many buffers', OpenRaises(LName, SMALL_BUFFER, IORING_WRITER_MAX_BUFFER_COUNT + 1, nil));
  LSmall := TIORingEngine.Create(4, 4);
  try
    AssertTrue('Engine with too few requests', OpenRaises(LName, SMALL_BUFFER, 8, LSmall));
  finally
    LSmall.Free;
  end;

  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LRaised := False;

  try
    LWriter.Open(LName, [], SMALL_BUFFER, 2);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Opened twice', LRaised);
  LWriter.Close;
end;

procedure TSequentialWriterTests.WrongCallOrder_Raises;
var
  LName: string;
  LWriter: TIORingSequentialWriter;
  LData: PByte;
  LCapacity: NativeInt;
  LByte: Byte;
  LRaised: Boolean;
begin
  LName := NewFileName;
  LWriter.Open(LName, [], SMALL_BUFFER, 2);
  LByte := 1;
  LRaised := False;

  try
    LWriter.CommitBuffer(1);
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  AssertTrue('Commit without Acquire', LRaised);
  LWriter.AcquireBuffer(LData, LCapacity);
  AssertEquals('A whole buffer', SMALL_BUFFER, LCapacity);
  LRaised := False;

  try
    LWriter.Write(LByte, 1);
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  AssertTrue('Write while a buffer is acquired', LRaised);
  LRaised := False;

  try
    LWriter.CommitBuffer(SMALL_BUFFER + 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('More than the buffer holds', LRaised);
  LWriter.CommitBuffer(0);
  LWriter.Close;
  LRaised := False;

  try
    LWriter.Write(LByte, 1);
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Write after Close', LRaised);
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
  CheckEqualsU64('Ten full buffers and the rest', 11, LWriter.Stats.WritesIssued);
  CheckEqualsU64('Bytes', 10 * SMALL_BUFFER + 100, LWriter.Stats.BytesWritten);
  CheckFile(LName, 10 * SMALL_BUFFER + 100);
end;

const
  SHARED_WRITERS = 4;
  SHARED_SIZE = 3 * 1024 * 1024 + 77;

procedure TSequentialWriterTests.WorkWriter(AIndex: Integer);
var
  LWriter: TIORingSequentialWriter;
begin
  try
    LWriter.Open(FNames[AIndex], [], 64 * 1024, 8, FEngine);
    WritePattern(LWriter, 0, SHARED_SIZE, 10000 + Int64(AIndex) * 1000);
    LWriter.Close;
  except
    TAtomic.Increment(FFailures);
  end;
end;

procedure TSequentialWriterTests.SharedEngine_SeveralWriters;
var
  LIndex: Integer;
begin
  SetLength(FNames, SHARED_WRITERS);

  for LIndex := 0 to SHARED_WRITERS - 1 do
    FNames[LIndex] := NewFileName;

  FFailures := 0;
  FEngine := TIORingEngine.Create(SHARED_WRITERS * 8 + 4, 64, 2);
  try
    RunThreads(SHARED_WRITERS, WorkWriter);
  finally
    FreeAndNil(FEngine);
  end;

  AssertEquals('Writers that failed', 0, FFailures);

  for LIndex := 0 to SHARED_WRITERS - 1 do
    CheckFile(FNames[LIndex], SHARED_SIZE);
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
      CheckEqualsU64('Position', 400000, UInt64(LStream.Position));
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
      { The bytes of the text: Free Pascal's strings are UTF-8 already; Delphi's are UTF-16, so
        write UTF-8 (with its BOM) }
{$IFDEF FPC}
      LLines.SaveToStream(LStream);
{$ELSE}
      LLines.SaveToStream(LStream, TEncoding.UTF8);
{$ENDIF}
    finally
      LStream.Free;
    end;

{$IFDEF FPC}
    LExpected := BytesOf(LLines.Text);
{$ELSE}
    LExpected := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(LLines.Text);
{$ENDIF}
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

  AssertEquals('File size', Length(LExpected), Length(LRead));
  AssertTrue('Same text', CompareMem(@LExpected[0], @LRead[0], Length(LExpected)));
end;

procedure TWriteStreamTests.PositionSizeAndSeek;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
  LRaised: Integer;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  try
    CheckEqualsU64('Start', 0, UInt64(LStream.Position));
    WritePatternToStream(LStream, 0, 10000, 3000);
    CheckEqualsU64('Position', 10000, UInt64(LStream.Position));
    CheckEqualsU64('Size = Position', 10000, UInt64(LStream.Size));
    CheckEqualsU64('Seek to here', 10000, UInt64(LStream.Seek(0, soCurrent)));
    CheckEqualsU64('The end is here', 10000, UInt64(LStream.Seek(0, soEnd)));
    LStream.Position := 10000;
    LRaised := 0;

    try
      LStream.Position := 0;
    except
      on EIORingStreamError do
        Inc(LRaised);
    end;

    try
      LStream.Seek(10, soCurrent);
    except
      on EIORingStreamError do
        Inc(LRaised);
    end;

    AssertEquals('Back and forward raise', 2, LRaised);
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
  LRaised: Integer;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName);
  try
    LRaised := 0;

    try
      LStream.Read(LByte, 1);
    except
      on EIORingStreamError do
        Inc(LRaised);
    end;

    try
      LStream.Size := 100;
    except
      on EIORingStreamError do
        Inc(LRaised);
    end;

    AssertEquals('Read and Size raise', 2, LRaised);
  finally
    LStream.Free;
  end;
end;

procedure TWriteStreamTests.CannotCreate_RaisesEFCreateError;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    TSequentialWriteOnlyFileStream.Create(TTestFileHelpers.TestFolder + 'no such folder' + PathDelim + 'file.dat').Free;
  except
    on EFCreateError do
      LRaised := True;
  end;

  AssertTrue('A folder that does not exist', LRaised);
end;

procedure TWriteStreamTests.FailedWrite_FlushRaisesEWriteError_FreeDoesNot;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
  LRaised: Integer;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  try
    FResources.MakeWritesFail(LName);
    WritePatternToStream(LStream, 0, 1000, 1000);
    LRaised := 0;

    try
      LStream.Flush;
    except
      on EWriteError do
        Inc(LRaised);
    end;

    try
      WritePatternToStream(LStream, 1000, 1, 1);
    except
      on EWriteError do
        Inc(LRaised);
    end;

    AssertEquals('Flush and a later Write raise', 2, LRaised);
  finally
    // Reported already: Free does not raise it again
    LStream.Free;
  end;
end;

procedure TWriteStreamTests.FailedWrite_FreeRaisesEWriteError;
var
  LName: string;
  LStream: TSequentialWriteOnlyFileStream;
  LRaised: Boolean;
begin
  LName := NewFileName;
  LStream := TSequentialWriteOnlyFileStream.Create(LName, [], SMALL_BUFFER, 2);
  FResources.MakeWritesFail(LName);
  WritePatternToStream(LStream, 0, 1000, 1000);    // only in the buffer
  // Free writes it, which fails, and nobody has seen that yet
  LRaised := False;

  try
    LStream.Free;
  except
    on EWriteError do
      LRaised := True;
  end;

  AssertTrue('Free raises', LRaised);
end;

procedure TWriteStreamTests.SharedEngine;
var
  LName: string;
  LEngine: TIORingEngine;
  LStream: TSequentialWriteOnlyFileStream;
  LRaised: Boolean;
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

    LRaised := False;

    try
      TSequentialWriteOnlyFileStream.Create(LName, TIORingEngine(nil)).Free;
    except
      on EIORingError do
        LRaised := True;
    end;

    AssertTrue('No engine', LRaised);
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
  RegisterTests(TSequentialWriterTests);
  RegisterTests(TWriteStreamTests);

end.
