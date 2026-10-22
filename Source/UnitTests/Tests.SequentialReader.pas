unit Tests.SequentialReader;

{
  Tests for TIORingSequentialReader (Delphi.IOUring.SequentialReader).

  The main tests read pattern files of awkward sizes (around buffer and queue
  boundaries) with awkward read sizes, in every reader mode, and check every
  byte.
}

interface

uses
  System.Generics.Collections,
  DUnitX.TestFramework,
  Delphi.IOUring.SequentialReader,
  TestPlatformHelpers;

type
  [TestFixture]
  TSequentialReaderTests = class
  private
    FFiles: TDictionary<Int64, string>;
    FResources: TTestResources;
    function PatternFile(const ASize: Int64): string;
    function CheckReadAll(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
      const ABufferSize, ABufferCount: Cardinal; const AChunkSize: Integer): TIORingReaderStats;
    procedure CheckSizeAndChunkMatrix(const AOptions: TIORingSequentialReaderOptions;
      const ABufferCounts: array of Cardinal);
    procedure CheckZeroCopyReadAll(const ASize: Int64; const ABufferSize, ABufferCount: Cardinal);
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
    procedure Read_SizeAndChunkMatrix_Buffered;
    [Test]
    procedure Read_SizeAndChunkMatrix_Unbuffered;
    [Test]
    procedure Read_SizeAndChunkMatrix_FixedReadAheadNoRegistration;
    [Test]
    procedure Read_LargeFile_Buffered;
    [Test]
    procedure Read_LargeFile_Unbuffered;
    [Test]
    procedure ZeroCopy_DeliversSameContent;
    [Test]
    procedure ReadAndZeroCopy_Mixed;
    [Test]
    procedure EmptyFile_IsEndOfFileAtOnce;

    // Files that change while being read
    [Test]
    procedure AppendedWhileReading_StopsAtSizeAtOpen;
    [Test]
    procedure ShortenedWhileReading_EndsAtNewEnd;

    // Life cycle
    [Test]
    procedure Close_InTheMiddle_IsClean;
    [Test]
    procedure EndOfScope_ClosesFile;
    [Test]
    procedure OpenHandle_NotOwned_KeepsHandleOpen;
    [Test]
    procedure Open_BadArguments_Raise;
    [Test]
    procedure Open_MissingFile_Raises;
    [Test]
    procedure Open_Twice_Raises;
    [Test]
    procedure Copy_Raises;

    // API rules and statistics
    [Test]
    procedure Read_WithChunkAcquired_Raises;
    [Test]
    procedure ReleaseChunk_WithoutChunk_Raises;
    [Test]
    procedure TryAcquireChunk_WithoutWait_GetsDataEventually;
    [Test]
    procedure Stats_AreConsistent;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Delphi.IOUring,
  TestFileHelpers;

const
  SMALL_BUFFER = 64 * 1024;
  LARGE_FILE_SIZE = 100 * 1024 * 1024;

procedure ReadALittleAndLeaveScope(const AFileName: string);
var
  LReader: TIORingSequentialReader;
  LBuffer: array[0..99] of Byte;
begin
  LReader.Open(AFileName, [sroFixedReadAhead], SMALL_BUFFER, 8);
  LReader.Read(LBuffer, SizeOf(LBuffer));
  // No Close: the end of scope must close the reader (and its file)
end;

function OpenRaisesIORingError(const AFileName: string; const ABufferSize, ABufferCount: Cardinal): Boolean;
var
  LReader: TIORingSequentialReader;
begin
  Result := False;
  try
    LReader.Open(AFileName, [], ABufferSize, ABufferCount);
  except
    on EIORingError do
      Result := True;
  end;
  Assert.IsFalse(LReader.IsOpen, 'A failed Open must leave the reader closed');
end;

{ Helpers }

function TSequentialReaderTests.PatternFile(const ASize: Int64): string;
begin
  if not FFiles.TryGetValue(ASize, Result) then
  begin
    Result := TTestFileHelpers.CreatePatternFile(ASize, 'Reader');
    FFiles.Add(ASize, Result);
  end;
end;

function TSequentialReaderTests.CheckReadAll(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal; const AChunkSize: Integer): TIORingReaderStats;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
  LRead: NativeInt;
  LTotal: Int64;
  LBadOffset: UInt64;
  LContext: string;
begin
  LContext := Format('size %d, buffers %d x %d, chunk %d', [ASize, ABufferCount, ABufferSize, AChunkSize]);

  LReader.Open(PatternFile(ASize), AOptions, ABufferSize, ABufferCount);
  Assert.AreEqual(ASize, LReader.Size, LContext);

  SetLength(LBuffer, AChunkSize);
  LTotal := 0;
  repeat
    LRead := LReader.Read(LBuffer[0], AChunkSize);
    if (LRead > 0) and not TTestFileHelpers.CheckPattern(UInt64(LTotal), LBuffer[0], LRead, LBadOffset) then
      Assert.Fail(Format('%s: wrong data at offset %d', [LContext, LBadOffset]));
    Inc(LTotal, LRead);
  until LRead < AChunkSize;

  Assert.AreEqual(ASize, LTotal, LContext + ': total');
  Assert.AreEqual(ASize, LReader.Position, LContext + ': position');
  Assert.IsTrue(LReader.Eof, LContext + ': Eof');
  Assert.AreEqual(NativeInt(0), LReader.Read(LBuffer[0], AChunkSize), LContext + ': read after EOF');
  Result := LReader.Stats;
end;

procedure TSequentialReaderTests.CheckSizeAndChunkMatrix(const AOptions: TIORingSequentialReaderOptions;
  const ABufferCounts: array of Cardinal);
const
  B = SMALL_BUFFER;
var
  LCount: Cardinal;
  LSizes: array[0..6] of Int64;
  LChunks: array[0..6] of Integer;
  LSize: Int64;
  LChunk: Integer;
begin
  for LCount in ABufferCounts do
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
      LChunks[0] := 1;
      LChunks[1] := 7;
      LChunks[2] := 4095;
      LChunks[3] := 4096;
      LChunks[4] := B;
      LChunks[5] := B + 1;
      LChunks[6] := Integer(LSize) + 10;   // larger than the file

      for LChunk in LChunks do
        CheckReadAll(LSize, AOptions, B, LCount, LChunk);
    end;
  end;
end;

procedure TSequentialReaderTests.CheckZeroCopyReadAll(const ASize: Int64; const ABufferSize, ABufferCount: Cardinal);
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
  LTotal: Int64;
  LBadOffset: UInt64;
  LContext: string;
begin
  LContext := Format('zero-copy, size %d, buffers %d x %d', [ASize, ABufferCount, ABufferSize]);
  LReader.Open(PatternFile(ASize), [], ABufferSize, ABufferCount);

  LTotal := 0;
  while LReader.TryAcquireChunk(LData, LLength) do
  begin
    Assert.IsTrue(LLength > 0, LContext + ': empty chunk');
    Assert.IsTrue(LLength <= NativeInt(ABufferSize), LContext + ': chunk larger than a buffer');
    if not TTestFileHelpers.CheckPattern(UInt64(LTotal), LData^, LLength, LBadOffset) then
      Assert.Fail(Format('%s: wrong data at offset %d', [LContext, LBadOffset]));
    Inc(LTotal, LLength);
    LReader.ReleaseChunk;
  end;

  Assert.AreEqual(ASize, LTotal, LContext + ': total');
  Assert.IsTrue(LReader.Eof, LContext + ': Eof');
end;

{ Set-up }

procedure TSequentialReaderTests.SetupFixture;
begin
  FFiles := TDictionary<Int64, string>.Create;
end;

procedure TSequentialReaderTests.TearDownFixture;
var
  LFileName: string;
begin
  for LFileName in FFiles.Values do
    TTestFileHelpers.DeleteTestFile(LFileName);
  FFiles.Free;
end;

procedure TSequentialReaderTests.Setup;
begin
  FResources := TTestResources.Create;
end;

procedure TSequentialReaderTests.TearDown;
begin
  FResources.Free;
  FResources := nil;
end;

{ Content }

procedure TSequentialReaderTests.Read_SizeAndChunkMatrix_Buffered;
begin
  CheckSizeAndChunkMatrix([], [1, 2, 8]);
end;

procedure TSequentialReaderTests.Read_SizeAndChunkMatrix_Unbuffered;
begin
  CheckSizeAndChunkMatrix([sroUnbuffered], [1, 2, 8]);
end;

procedure TSequentialReaderTests.Read_SizeAndChunkMatrix_FixedReadAheadNoRegistration;
begin
  CheckSizeAndChunkMatrix([sroFixedReadAhead, sroNoRegistration, sroNoSequentialScanHint], [3]);
end;

procedure TSequentialReaderTests.Read_LargeFile_Buffered;
var
  LStart: UInt64;
  LStats: TIORingReaderStats;
begin
  LStart := GetTickCount64;
  LStats := CheckReadAll(LARGE_FILE_SIZE, [], IORING_READER_DEFAULT_BUFFER_SIZE,
    IORING_READER_DEFAULT_BUFFER_COUNT, 64 * 1024);
  Log(Format('100 MB buffered (incl. pattern checks): %d ms; stalls %d (%d us), max read-ahead %d',
    [GetTickCount64 - LStart, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
end;

procedure TSequentialReaderTests.Read_LargeFile_Unbuffered;
var
  LStart: UInt64;
  LStats: TIORingReaderStats;
begin
  LStart := GetTickCount64;
  LStats := CheckReadAll(LARGE_FILE_SIZE, [sroUnbuffered], IORING_READER_DEFAULT_BUFFER_SIZE,
    IORING_READER_DEFAULT_BUFFER_COUNT, 64 * 1024);
  Log(Format('100 MB unbuffered (incl. pattern checks): %d ms; stalls %d (%d us), max read-ahead %d',
    [GetTickCount64 - LStart, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
end;

procedure TSequentialReaderTests.ZeroCopy_DeliversSameContent;
const
  B = SMALL_BUFFER;
  COUNTS: array[0..2] of Cardinal = (1, 2, 8);
var
  LCount: Cardinal;
  LSizes: array[0..6] of Int64;
  LSize: Int64;
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
      CheckZeroCopyReadAll(LSize, B, LCount);
  end;
end;

procedure TSequentialReaderTests.ReadAndZeroCopy_Mixed;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 5 * B + 123;
var
  LReader: TIORingSequentialReader;
  LBuffer: array[0..999] of Byte;
  LData: PByte;
  LLength: NativeInt;
  LRead: NativeInt;
  LTotal: Int64;
  LBadOffset: UInt64;
  LUseChunk: Boolean;
begin
  // Alternate: Read 1000 bytes, then take the rest of that buffer as a chunk
  LReader.Open(PatternFile(FILE_SIZE), [], B, 2);
  LTotal := 0;
  LUseChunk := False;
  repeat
    if LUseChunk then
    begin
      if not LReader.TryAcquireChunk(LData, LLength) then
        Break;
      Assert.IsTrue(TTestFileHelpers.CheckPattern(UInt64(LTotal), LData^, LLength, LBadOffset),
        Format('Chunk: wrong data at %d', [LBadOffset]));
      Inc(LTotal, LLength);
      LReader.ReleaseChunk;
    end
    else
    begin
      LRead := LReader.Read(LBuffer, SizeOf(LBuffer));
      if LRead = 0 then
        Break;
      Assert.IsTrue(TTestFileHelpers.CheckPattern(UInt64(LTotal), LBuffer, LRead, LBadOffset),
        Format('Read: wrong data at %d', [LBadOffset]));
      Inc(LTotal, LRead);
    end;
    LUseChunk := not LUseChunk;
  until False;

  Assert.AreEqual(Int64(FILE_SIZE), LTotal);
  Assert.AreEqual(Int64(FILE_SIZE), LReader.Position);
end;

procedure TSequentialReaderTests.EmptyFile_IsEndOfFileAtOnce;
var
  LReader: TIORingSequentialReader;
  LBuffer: array[0..15] of Byte;
  LData: PByte;
  LLength: NativeInt;
begin
  LReader.Open(PatternFile(0));

  Assert.IsTrue(LReader.Eof);
  Assert.IsTrue(LReader.DataReady);
  Assert.AreEqual(NativeInt(0), LReader.Read(LBuffer, SizeOf(LBuffer)));
  Assert.IsFalse(LReader.TryAcquireChunk(LData, LLength));
  Assert.AreEqual(Int64(0), LReader.Size);
end;

{ Files that change while being read }

procedure TSequentialReaderTests.AppendedWhileReading_StopsAtSizeAtOpen;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 2 * B + 100;
var
  LFileName: string;
  LReader: TIORingSequentialReader;
  LWriter: TFileStream;
  LExtra: TBytes;
  LBuffer: TBytes;
  LTotal: Int64;
  LRead: NativeInt;
  LBadOffset: UInt64;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Append');
  FResources.AddFile(LFileName);

  // One buffer in flight, so the last buffer is read after the append
  LReader.Open(LFileName, [sroFixedReadAhead], B, 1);

  SetLength(LExtra, 1024 * 1024);
  FillChar(LExtra[0], Length(LExtra), $EE);
  LWriter := TFileStream.Create(LFileName, fmOpenReadWrite or fmShareDenyNone);
  try
    LWriter.Seek(0, soEnd);
    LWriter.WriteBuffer(LExtra[0], Length(LExtra));
  finally
    LWriter.Free;
  end;

  SetLength(LBuffer, 4096);
  LTotal := 0;
  repeat
    LRead := LReader.Read(LBuffer[0], Length(LBuffer));
    if (LRead > 0) and not TTestFileHelpers.CheckPattern(UInt64(LTotal), LBuffer[0], LRead, LBadOffset) then
      Assert.Fail(Format('Wrong data at %d', [LBadOffset]));
    Inc(LTotal, LRead);
  until LRead = 0;

  Assert.AreEqual(Int64(FILE_SIZE), LTotal, 'Bytes read');
  Assert.IsTrue(LReader.Eof);
end;

procedure TSequentialReaderTests.ShortenedWhileReading_EndsAtNewEnd;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 4 * B;
  NEW_SIZE = B + B div 2;
var
  LFileName: string;
  LReader: TIORingSequentialReader;
  LWriter: TFileStream;
  LBuffer: TBytes;
  LTotal: Int64;
  LRead: NativeInt;
  LBadOffset: UInt64;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Shorten');
  FResources.AddFile(LFileName);

  LReader.Open(LFileName, [sroFixedReadAhead], B, 1);
  Assert.AreEqual(Int64(FILE_SIZE), LReader.Size);

  LWriter := TFileStream.Create(LFileName, fmOpenReadWrite or fmShareDenyNone);
  try
    LWriter.Size := NEW_SIZE;
  finally
    LWriter.Free;
  end;

  SetLength(LBuffer, 4096);
  LTotal := 0;
  repeat
    LRead := LReader.Read(LBuffer[0], Length(LBuffer));
    if (LRead > 0) and not TTestFileHelpers.CheckPattern(UInt64(LTotal), LBuffer[0], LRead, LBadOffset) then
      Assert.Fail(Format('Wrong data at %d', [LBadOffset]));
    Inc(LTotal, LRead);
  until LRead = 0;

  Assert.AreEqual(Int64(NEW_SIZE), LTotal, 'Bytes read');
  Assert.IsTrue(LReader.Eof);
  Assert.AreEqual(Int64(FILE_SIZE), LReader.Size, 'Size stays the size at open');
end;

{ Life cycle }

procedure TSequentialReaderTests.Close_InTheMiddle_IsClean;
const
  FILE_SIZE = 8 * 1024 * 1024;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
begin
  SetLength(LBuffer, 100 * 1024);
  LReader.Open(PatternFile(FILE_SIZE), [sroFixedReadAhead], SMALL_BUFFER, 16);
  Assert.AreEqual(NativeInt(Length(LBuffer)), LReader.Read(LBuffer[0], Length(LBuffer)));

  LReader.Close;   // reads still in flight
  Assert.IsFalse(LReader.IsOpen);

  // The same variable can be opened again
  CheckReadAll(FILE_SIZE, [], SMALL_BUFFER, 4, 100 * 1024);
  LReader.Open(PatternFile(FILE_SIZE));
  Assert.IsTrue(LReader.IsOpen);
end;

procedure TSequentialReaderTests.EndOfScope_ClosesFile;
var
  LFileName: string;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(1024 * 1024, 'Scope');
  FResources.AddFile(LFileName);

  ReadALittleAndLeaveScope(LFileName);

  // The reader opens without FILE_SHARE_DELETE, so this fails while it is open
  Assert.IsTrue(System.SysUtils.DeleteFile(LFileName), 'The file is still open: ' + SysErrorMessage(GetLastError));
end;

procedure TSequentialReaderTests.OpenHandle_NotOwned_KeepsHandleOpen;
var
  LHandle: THandle;
  LReader: TIORingSequentialReader;
  LBuffer: array[0..999] of Byte;
  LSize: Int64;
begin
  LHandle := FResources.OpenFile(PatternFile(3 * SMALL_BUFFER));

  LReader.Open(LHandle, False, [], SMALL_BUFFER, 2);
  Assert.AreEqual(NativeInt(SizeOf(LBuffer)), LReader.Read(LBuffer, SizeOf(LBuffer)));
  LReader.Close;

  Assert.IsTrue(GetFileSizeEx(LHandle, LSize), 'The handle was closed by the reader');
  Assert.AreEqual(Int64(3 * SMALL_BUFFER), LSize);
end;

procedure TSequentialReaderTests.Open_BadArguments_Raise;
var
  LFileName: string;
begin
  LFileName := PatternFile(SMALL_BUFFER);

  Assert.IsTrue(OpenRaisesIORingError(LFileName, 0, 4), 'Buffer size 0');
  Assert.IsTrue(OpenRaisesIORingError(LFileName, 1000, 4), 'Buffer size not a multiple of 4096');
  Assert.IsTrue(OpenRaisesIORingError(LFileName, SMALL_BUFFER, 0), 'No buffers');
  Assert.IsTrue(OpenRaisesIORingError(LFileName, SMALL_BUFFER, IORING_READER_MAX_BUFFER_COUNT + 1), 'Too many buffers');
end;

procedure TSequentialReaderTests.Open_MissingFile_Raises;
begin
  Assert.IsTrue(OpenRaisesIORingError(TTestFileHelpers.NewTestFileName('Missing'), SMALL_BUFFER, 4));
end;

procedure TSequentialReaderTests.Open_Twice_Raises;
var
  LReader: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader.Open(PatternFile(SMALL_BUFFER));

  LRaised := False;
  try
    LReader.Open(PatternFile(SMALL_BUFFER));
  except
    on EIORingError do
      LRaised := True;
  end;

  Assert.IsTrue(LRaised);
  Assert.IsTrue(LReader.IsOpen, 'The first Open must stay usable');
end;

procedure TSequentialReaderTests.Copy_Raises;
var
  LReader1: TIORingSequentialReader;
  LReader2: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader1.Open(PatternFile(SMALL_BUFFER));

  LRaised := False;
  try
    LReader2 := LReader1;
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  Assert.IsTrue(LRaised);
  Assert.IsFalse(LReader2.IsOpen);
end;

{ API rules and statistics }

procedure TSequentialReaderTests.Read_WithChunkAcquired_Raises;
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
  LBuffer: array[0..15] of Byte;
  LRaised: Boolean;
begin
  LReader.Open(PatternFile(SMALL_BUFFER));
  Assert.IsTrue(LReader.TryAcquireChunk(LData, LLength));

  LRaised := False;
  try
    LReader.Read(LBuffer, SizeOf(LBuffer));
  except
    on EInvalidOpException do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised);
end;

procedure TSequentialReaderTests.ReleaseChunk_WithoutChunk_Raises;
var
  LReader: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader.Open(PatternFile(SMALL_BUFFER));

  LRaised := False;
  try
    LReader.ReleaseChunk;
  except
    on EInvalidOpException do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised);
end;

procedure TSequentialReaderTests.TryAcquireChunk_WithoutWait_GetsDataEventually;
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
  LStart: UInt64;
  LGot: Boolean;
begin
  LReader.Open(PatternFile(4 * SMALL_BUFFER), [], SMALL_BUFFER, 4);

  LStart := GetTickCount64;
  repeat
    LGot := LReader.TryAcquireChunk(LData, LLength, False);
    if not LGot then
    begin
      Assert.IsFalse(LReader.Eof, 'No data must not mean end of file here');
      Sleep(1);
    end;
  until LGot or (GetTickCount64 - LStart > 5000);

  Assert.IsTrue(LGot, 'No data within 5 s');
  Assert.AreEqual(NativeInt(SMALL_BUFFER), LLength);
  LReader.ReleaseChunk;
  Assert.AreEqual(Int64(SMALL_BUFFER), LReader.Position);
end;

procedure TSequentialReaderTests.Stats_AreConsistent;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 10 * B + 5;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
  LStats: TIORingReaderStats;
begin
  SetLength(LBuffer, B);

  LReader.Open(PatternFile(FILE_SIZE), [], B, 4);
  while LReader.Read(LBuffer[0], B) > 0 do
    ;
  LStats := LReader.Stats;
  Log(Format('Adaptive: reads %d, bytes %d, stalls %d (%d us), max read-ahead %d',
    [LStats.ReadsIssued, LStats.BytesFromDisk, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
  Assert.AreEqual(UInt64(11), LStats.ReadsIssued);
  Assert.AreEqual(UInt64(FILE_SIZE), LStats.BytesFromDisk);
  Assert.IsTrue((LStats.MaxReadAhead >= 2) and (LStats.MaxReadAhead <= 4), 'Adaptive read-ahead between 2 and 4');
  LReader.Close;

  LReader.Open(PatternFile(FILE_SIZE), [sroFixedReadAhead], B, 4);
  while LReader.Read(LBuffer[0], B) > 0 do
    ;
  LStats := LReader.Stats;
  Assert.AreEqual(Cardinal(4), LStats.MaxReadAhead, 'Fixed read-ahead');
  Assert.AreEqual(UInt64(FILE_SIZE), LStats.BytesFromDisk);
end;

initialization
  TDUnitX.RegisterTestFixture(TSequentialReaderTests);

end.
