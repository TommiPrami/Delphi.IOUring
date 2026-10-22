unit Tests.Streams;

{
  Tests for TSequentialReadOnlyFileStream (Delphi.IOUring.Streams): same
  content as TFileStream, the seek and write rules, and use through the
  usual RTL helpers (CopyFrom, LoadFromStream, TStreamReader).
}

interface

uses
  System.Generics.Collections,
  DUnitX.TestFramework,
  TestPlatformHelpers;

type
  [TestFixture]
  TSequentialReadOnlyFileStreamTests = class
  private
    FFiles: TDictionary<Int64, string>;
    FResources: TTestResources;
    function PatternFile(const ASize: Int64): string;
    procedure CheckSameAsFileStream(const ASize: Int64; const AChunkSize: Integer; const ABufferCount: Cardinal);
  public
    [SetupFixture]
    procedure SetupFixture;
    [TearDownFixture]
    procedure TearDownFixture;
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    // Content
    [Test]
    procedure Content_SameAsFileStream;
    [Test]
    procedure Content_Unbuffered;
    [Test]
    procedure ReadOverloads_Work;
    [Test]
    procedure ReadBuffer_PastEnd_RaisesEReadError;

    // Position, Size and Seek
    [Test]
    procedure PositionAndSize_AtAllTimes;
    [Test]
    procedure SeekToCurrentPosition_IsAllowed;
    [Test]
    procedure SeekElsewhere_Raises;
    [Test]
    procedure Write_Raises;
    [Test]
    procedure SetSize_Raises;
    [Test]
    procedure StreamError_IsAnEStreamError;

    // RTL helpers
    [Test]
    procedure MemoryStream_CopyFromWholeStream;
    [Test]
    procedure MemoryStream_CopyFromPartsThenRest;
    [Test]
    procedure BytesStream_LoadFromStream;
    [Test]
    procedure StreamReader_ReadsLines;

    // Creation
    [Test]
    procedure Create_MissingFile_RaisesEFOpenError;
    [Test]
    procedure Create_BadBufferSize_RaisesEIORingError;
    [Test]
    procedure Stats_AreAvailable;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Delphi.IOUring,
  Delphi.IOUring.SequentialReader,
  Delphi.IOUring.Streams,
  TestFileHelpers;

const
  SMALL_BUFFER = 64 * 1024;

type
  TStreamProc = reference to procedure;

function RaisesStreamError(const AProc: TStreamProc): Boolean;
begin
  Result := False;
  try
    AProc();
  except
    on EIORingStreamError do
      Result := True;
  end;
end;

{ Helpers }

function TSequentialReadOnlyFileStreamTests.PatternFile(const ASize: Int64): string;
begin
  if not FFiles.TryGetValue(ASize, Result) then
  begin
    Result := TTestFileHelpers.CreatePatternFile(ASize, 'Stream');
    FFiles.Add(ASize, Result);
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.CheckSameAsFileStream(const ASize: Int64; const AChunkSize: Integer;
  const ABufferCount: Cardinal);
var
  LExpected: TFileStream;
  LActual: TSequentialReadOnlyFileStream;
  LExpectedBuffer: TBytes;
  LActualBuffer: TBytes;
  LExpectedRead: Integer;
  LActualRead: Integer;
  LContext: string;
begin
  LContext := Format('size %d, chunk %d, buffers %d', [ASize, AChunkSize, ABufferCount]);
  SetLength(LExpectedBuffer, AChunkSize);
  SetLength(LActualBuffer, AChunkSize);

  LExpected := TFileStream.Create(PatternFile(ASize), fmOpenRead or fmShareDenyNone);
  try
    LActual := TSequentialReadOnlyFileStream.Create(PatternFile(ASize), [], SMALL_BUFFER, ABufferCount);
    try
      Assert.AreEqual(LExpected.Size, LActual.Size, LContext + ': Size');
      repeat
        LExpectedRead := LExpected.Read(LExpectedBuffer[0], AChunkSize);
        LActualRead := LActual.Read(LActualBuffer[0], AChunkSize);
        Assert.AreEqual(LExpectedRead, LActualRead, LContext + ': bytes read');
        Assert.IsTrue(CompareMem(@LExpectedBuffer[0], @LActualBuffer[0], LActualRead),
          Format('%s: different data before position %d', [LContext, LActual.Position]));
        Assert.AreEqual(LExpected.Position, LActual.Position, LContext + ': Position');
      until LActualRead = 0;
    finally
      LActual.Free;
    end;
  finally
    LExpected.Free;
  end;
end;

{ Set-up }

procedure TSequentialReadOnlyFileStreamTests.SetupFixture;
begin
  FFiles := TDictionary<Int64, string>.Create;
end;

procedure TSequentialReadOnlyFileStreamTests.TearDownFixture;
var
  LFileName: string;
begin
  for LFileName in FFiles.Values do
    TTestFileHelpers.DeleteTestFile(LFileName);
  FFiles.Free;
end;

procedure TSequentialReadOnlyFileStreamTests.Setup;
begin
  FResources := TTestResources.Create;
end;

procedure TSequentialReadOnlyFileStreamTests.TearDown;
begin
  FResources.Free;
  FResources := nil;
end;

{ Content }

procedure TSequentialReadOnlyFileStreamTests.Content_SameAsFileStream;
const
  B = SMALL_BUFFER;
  COUNTS: array[0..2] of Cardinal = (1, 2, 8);
  CHUNKS: array[0..4] of Integer = (1, 4095, 4096, B, B + 1);
var
  LCount: Cardinal;
  LSizes: array[0..6] of Int64;
  LSize: Int64;
  LChunk: Integer;
begin
  for LCount in COUNTS do
  begin
    LSizes[0] := 0;
    LSizes[1] := 1;
    LSizes[2] := B - 1;
    LSizes[3] := B;
    LSizes[4] := B + 1;
    LSizes[5] := Int64(B) * LCount;
    LSizes[6] := Int64(B) * LCount + 1;

    for LSize in LSizes do
    begin
      for LChunk in CHUNKS do
        CheckSameAsFileStream(LSize, LChunk, LCount);
      CheckSameAsFileStream(LSize, Integer(LSize) + 10, LCount);   // one read larger than the file
    end;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.Content_Unbuffered;
const
  FILE_SIZE = 3 * SMALL_BUFFER + 77;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [sroUnbuffered], SMALL_BUFFER, 2);
  try
    SetLength(LBuffer, FILE_SIZE);
    LStream.ReadBuffer(LBuffer[0], FILE_SIZE);
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LBuffer[0], FILE_SIZE, LBadOffset),
      Format('Wrong data at %d', [LBadOffset]));
    Assert.AreEqual(0, LStream.Read(LBuffer[0], 1), 'Read after the end');
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.ReadOverloads_Work;
const
  FILE_SIZE = 10000;
var
  LStream: TSequentialReadOnlyFileStream;
  LBytes: TBytes;
  LBadOffset: UInt64;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  try
    SetLength(LBytes, 3000);

    // TBytes + offset
    Assert.AreEqual(1000, LStream.Read(LBytes, 500, 1000));
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LBytes[500], 1000, LBadOffset), 'Read(TBytes, Offset, Count)');

    // Read64
    Assert.AreEqual(Int64(2000), LStream.Read64(LBytes, 0, 2000));
    Assert.IsTrue(TTestFileHelpers.CheckPattern(1000, LBytes[0], 2000, LBadOffset), 'Read64');

    // ReadData
    Assert.AreEqual(NativeInt(100), LStream.ReadData(LBytes, 100));
    Assert.IsTrue(TTestFileHelpers.CheckPattern(3000, LBytes[0], 100, LBadOffset), 'ReadData');

    Assert.AreEqual(Int64(3100), LStream.Position);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.ReadBuffer_PastEnd_RaisesEReadError;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: array[0..199] of Byte;
  LRaised: Boolean;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(100), [], SMALL_BUFFER, 1);
  try
    LRaised := False;
    try
      LStream.ReadBuffer(LBuffer, SizeOf(LBuffer));
    except
      on EReadError do
        LRaised := True;
    end;
    Assert.IsTrue(LRaised, 'ReadBuffer must raise EReadError when the data ends');
  finally
    LStream.Free;
  end;
end;

{ Position, Size and Seek }

procedure TSequentialReadOnlyFileStreamTests.PositionAndSize_AtAllTimes;
const
  FILE_SIZE = 3 * SMALL_BUFFER + 5;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
begin
  SetLength(LBuffer, SMALL_BUFFER);
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  try
    Assert.AreEqual(Int64(0), LStream.Position);
    Assert.AreEqual(Int64(FILE_SIZE), LStream.Size);

    LStream.ReadBuffer(LBuffer[0], 12345);
    Assert.AreEqual(Int64(12345), LStream.Position);
    Assert.AreEqual(Int64(FILE_SIZE), LStream.Size);

    while LStream.Read(LBuffer[0], Length(LBuffer)) > 0 do
      ;
    Assert.AreEqual(Int64(FILE_SIZE), LStream.Position);
    Assert.AreEqual(Int64(FILE_SIZE), LStream.Size);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.SeekToCurrentPosition_IsAllowed;
const
  FILE_SIZE = 2 * SMALL_BUFFER;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
  LStep: Integer;
begin
  SetLength(LBuffer, FILE_SIZE);
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  try
    // At the start, in the middle and at the end
    for LStep := 0 to 2 do
    begin
      Assert.AreEqual(LStream.Position, LStream.Seek(0, soCurrent));
      Assert.AreEqual(LStream.Position, LStream.Seek(LStream.Position, soBeginning));
      Assert.AreEqual(LStream.Position, LStream.Seek(LStream.Position - LStream.Size, soEnd));
      LStream.Position := LStream.Position;

      if LStep < 2 then
        LStream.ReadBuffer(LBuffer[0], FILE_SIZE div 2);
    end;
    Assert.AreEqual(Int64(FILE_SIZE), LStream.Position);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.SeekElsewhere_Raises;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: array[0..999] of Byte;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(4 * SMALL_BUFFER), [], SMALL_BUFFER, 2);
  try
    LStream.ReadBuffer(LBuffer, SizeOf(LBuffer));

    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Seek(-1, soCurrent); end), 'Backward');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Seek(1, soCurrent); end), 'Forward');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Seek(0, soBeginning); end), 'To the start');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Seek(0, soEnd); end), 'To the end');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Position := 0; end), 'Position := 0');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Seek(Longint(10), soFromCurrent); end), 'Old 32-bit Seek');

    // The stream still works after a refused seek
    Assert.AreEqual(Int64(SizeOf(LBuffer)), LStream.Position);
    LStream.ReadBuffer(LBuffer, SizeOf(LBuffer));
    Assert.AreEqual(Int64(2 * SizeOf(LBuffer)), LStream.Position);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.Write_Raises;
var
  LStream: TSequentialReadOnlyFileStream;
  LBytes: TBytes;
begin
  SetLength(LBytes, 10);
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  try
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Write(LBytes[0], 10); end), 'Write');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.WriteBuffer(LBytes[0], 10); end), 'WriteBuffer');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Write(LBytes, 0, 10); end), 'Write(TBytes)');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Write64(LBytes, 0, 10); end), 'Write64');
    Assert.AreEqual(Int64(0), LStream.Position);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.SetSize_Raises;
var
  LStream: TSequentialReadOnlyFileStream;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  try
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Size := 10; end), 'Size := 10');
    Assert.IsTrue(RaisesStreamError(procedure begin LStream.Size := LStream.Size; end), 'Size := Size');
    Assert.AreEqual(Int64(SMALL_BUFFER), LStream.Size);
  finally
    LStream.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.StreamError_IsAnEStreamError;
var
  LStream: TSequentialReadOnlyFileStream;
  LByte: Byte;
  LCaught: Boolean;
begin
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  try
    LByte := 0;
    LCaught := False;
    try
      LStream.Write(LByte, 1);
    except
      on EStreamError do
        LCaught := True;
    end;
    Assert.IsTrue(LCaught, 'Code that catches EStreamError must catch it');
  finally
    LStream.Free;
  end;
end;

{ RTL helpers }

procedure TSequentialReadOnlyFileStreamTests.MemoryStream_CopyFromWholeStream;
const
  FILE_SIZE = 5 * SMALL_BUFFER + 3;
var
  LSource: TSequentialReadOnlyFileStream;
  LTarget: TMemoryStream;
  LBadOffset: UInt64;
begin
  LSource := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TMemoryStream.Create;
  try
    // Count = 0 makes CopyFrom set Source.Position := 0 and use Source.Size
    Assert.AreEqual(Int64(FILE_SIZE), LTarget.CopyFrom(LSource, 0));
    Assert.AreEqual(Int64(FILE_SIZE), LTarget.Size);
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LTarget.Memory^, FILE_SIZE, LBadOffset),
      Format('Wrong data at %d', [LBadOffset]));
  finally
    LTarget.Free;
    LSource.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.MemoryStream_CopyFromPartsThenRest;
const
  FILE_SIZE = 3 * SMALL_BUFFER;
var
  LSource: TSequentialReadOnlyFileStream;
  LTarget: TMemoryStream;
  LBadOffset: UInt64;
begin
  LSource := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TMemoryStream.Create;
  try
    LTarget.CopyFrom(LSource, 1000);
    LTarget.CopyFrom(LSource, 50000);
    LTarget.CopyFrom(LSource, LSource.Size - LSource.Position);

    Assert.AreEqual(Int64(FILE_SIZE), LTarget.Size);
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LTarget.Memory^, FILE_SIZE, LBadOffset),
      Format('Wrong data at %d', [LBadOffset]));

    // A second CopyFrom(Source, 0) would have to rewind: refused
    Assert.IsTrue(RaisesStreamError(procedure begin LTarget.CopyFrom(LSource, 0); end), 'Rewind');
  finally
    LTarget.Free;
    LSource.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.BytesStream_LoadFromStream;
const
  FILE_SIZE = 2 * SMALL_BUFFER + 999;
var
  LSource: TSequentialReadOnlyFileStream;
  LTarget: TBytesStream;
  LBadOffset: UInt64;
begin
  LSource := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TBytesStream.Create;
  try
    LTarget.LoadFromStream(LSource);

    Assert.AreEqual(Int64(FILE_SIZE), LTarget.Size);
    Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LTarget.Bytes[0], FILE_SIZE, LBadOffset),
      Format('Wrong data at %d', [LBadOffset]));
  finally
    LTarget.Free;
    LSource.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.StreamReader_ReadsLines;
const
  LINE_COUNT = 20000;
var
  LFileName: string;
  LLines: TStringList;
  LIndex: Integer;
  LStream: TSequentialReadOnlyFileStream;
  LReader: TStreamReader;
begin
  LFileName := TTestFileHelpers.NewTestFileName('Lines');
  FResources.AddFile(LFileName);

  LLines := TStringList.Create;
  try
    for LIndex := 1 to LINE_COUNT do
      LLines.Add(Format('Line %d: %s', [LIndex, StringOfChar(Char(Ord('a') + LIndex mod 26), LIndex mod 97)]));
    LLines.WriteBOM := False;
    LLines.SaveToFile(LFileName, TEncoding.UTF8);

    LStream := TSequentialReadOnlyFileStream.Create(LFileName, [], SMALL_BUFFER, 2);
    try
      LReader := TStreamReader.Create(LStream, TEncoding.UTF8);
      try
        for LIndex := 0 to LINE_COUNT - 1 do
          Assert.AreEqual(LLines[LIndex], LReader.ReadLine, Format('Line %d', [LIndex + 1]));
        Assert.IsTrue(LReader.EndOfStream);
      finally
        LReader.Free;
      end;
    finally
      LStream.Free;
    end;
  finally
    LLines.Free;
  end;
end;

{ Creation }

procedure TSequentialReadOnlyFileStreamTests.Create_MissingFile_RaisesEFOpenError;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TSequentialReadOnlyFileStream.Create(TTestFileHelpers.NewTestFileName('Missing')).Free;
  except
    on E: EFOpenError do
    begin
      LRaised := True;
      Log(E.Message);
    end;
  end;
  Assert.IsTrue(LRaised, 'Like TFileStream, a missing file raises EFOpenError');
end;

procedure TSequentialReadOnlyFileStreamTests.Create_BadBufferSize_RaisesEIORingError;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TSequentialReadOnlyFileStream.Create(PatternFile(SMALL_BUFFER), [], 1000, 2).Free;
  except
    on EIORingError do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised);

  // The failed constructor released the file handle: an exclusive open works
  TFileStream.Create(PatternFile(SMALL_BUFFER), fmOpenRead or fmShareExclusive).Free;
end;

procedure TSequentialReadOnlyFileStreamTests.Stats_AreAvailable;
const
  FILE_SIZE = 4 * SMALL_BUFFER;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
begin
  SetLength(LBuffer, FILE_SIZE);
  LStream := TSequentialReadOnlyFileStream.Create(PatternFile(FILE_SIZE), [], SMALL_BUFFER, 4);
  try
    LStream.ReadBuffer(LBuffer[0], FILE_SIZE);
    Assert.AreEqual(UInt64(4), LStream.Stats.ReadsIssued);
    Assert.AreEqual(UInt64(FILE_SIZE), LStream.Stats.BytesFromDisk);
  finally
    LStream.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSequentialReadOnlyFileStreamTests);

end.
