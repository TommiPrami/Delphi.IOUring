unit PIRUnit.SequentialReader.Tests;

{
  Tests for TIORingSequentialReader (PIRUnit.SequentialReader).

  The main tests read pattern files of awkward sizes (around buffer and queue
  boundaries) with awkward read sizes, in every reader mode, and check every
  byte.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.SequentialReader, PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TSequentialReaderTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    function CheckReadAll(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
      const ABufferSize, ABufferCount: Cardinal; const AChunkSize: Integer): TIORingSequentialReaderStats;
    procedure CheckSizeAndChunkMatrix(const AOptions: TIORingSequentialReaderOptions;
      const ABufferCounts: array of Cardinal);
    procedure CheckZeroCopyReadAll(const ASize: Int64; const ABufferSize, ABufferCount: Cardinal);
    function CheckBigReads(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
      const ABufferCount: Cardinal; const AChunkSize, AMisalign: Integer): TIORingSequentialReaderStats;
    function OpenRaisesIORingError(const AFileName: string; const ABufferSize, ABufferCount: Cardinal): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Read_SizeAndChunkMatrix_Buffered;
    procedure Read_SizeAndChunkMatrix_Unbuffered;
    procedure Read_SizeAndChunkMatrix_FixedReadAheadNoRegistration;
    procedure Read_LargeFile_Buffered;
    procedure Read_LargeFile_Unbuffered;
    procedure ZeroCopy_DeliversSameContent;
    procedure ReadAndZeroCopy_Mixed;
    procedure EmptyFile_IsEndOfFileAtOnce;
    procedure BigReads_GoStraightIntoTheCallersMemory;
    procedure SmallReads_UseOnlyTheBuffers;
    procedure BigReads_Unbuffered_OnlyIntoSectorAlignedMemory;
    procedure BigReads_MixedWithSmallReadsAndChunks;
    procedure AppendedWhileReading_StopsAtSizeAtOpen;
    procedure ShortenedWhileReading_EndsAtNewEnd;
    procedure ShortenedWhileBigReads_EndsAtNewEnd;
    procedure Close_InTheMiddle_IsClean;
    procedure EndOfScope_ClosesFile;
    procedure OpenHandle_NotOwned_KeepsHandleOpen;
    procedure Open_BadArguments_Raise;
    procedure Open_MissingFile_Raises;
    procedure Open_Twice_Raises;
    procedure Copy_Raises;
    procedure Read_WithChunkAcquired_Raises;
    procedure ReleaseChunk_WithoutChunk_Raises;
    procedure TryAcquireChunk_WithoutWait_GetsDataEventually;
    procedure Stats_AreConsistent;
  end;

implementation

uses
{$IFDEF FPC}
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils, Classes,
{$ELSE}
  Winapi.Windows, System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Test.FileHelpers;

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

{ Helpers }

procedure TSequentialReaderTests.SetUp;
begin
  FResources := TTestResources.Create;
end;

procedure TSequentialReaderTests.TearDown;
begin
  FreeAndNil(FResources);
end;

function TSequentialReaderTests.CheckReadAll(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal; const AChunkSize: Integer): TIORingSequentialReaderStats;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
  LRead: NativeInt;
  LTotal: Int64;
  LContext: string;
begin
  LContext := Format('size %d, buffers %d x %d, chunk %d', [ASize, ABufferCount, ABufferSize, AChunkSize]);
  LReader.Open(SharedPatternFile(ASize), AOptions, ABufferSize, ABufferCount);
  AssertEquals(LContext + ': size', ASize, LReader.Size);

  SetLength(LBuffer, AChunkSize);
  LTotal := 0;

  repeat
    LRead := LReader.Read(LBuffer[0], AChunkSize);

    if LRead > 0 then
      CheckPattern(UInt64(LTotal), @LBuffer[0], LRead, LContext);

    Inc(LTotal, LRead);
  until LRead < AChunkSize;

  AssertEquals(LContext + ': total', ASize, LTotal);
  AssertEquals(LContext + ': position', ASize, LReader.Position);
  AssertTrue(LContext + ': Eof', LReader.Eof);
  AssertEquals(LContext + ': read after EOF', Int64(0), Int64(LReader.Read(LBuffer[0], AChunkSize)));

  Result := LReader.Stats;
end;

procedure TSequentialReaderTests.CheckSizeAndChunkMatrix(const AOptions: TIORingSequentialReaderOptions;
  const ABufferCounts: array of Cardinal);
const
  B = SMALL_BUFFER;
var
  LCountIndex: Integer;
  LCount: Cardinal;
  LSizes: array[0..6] of Int64;
  LChunks: array[0..6] of Integer;
  LSizeIndex: Integer;
  LChunkIndex: Integer;
begin
  for LCountIndex := 0 to High(ABufferCounts) do
  begin
    LCount := ABufferCounts[LCountIndex];
    LSizes[0] := 0;
    LSizes[1] := 1;
    LSizes[2] := B - 1;
    LSizes[3] := B;
    LSizes[4] := B + 1;
    LSizes[5] := Int64(B) * LCount;
    LSizes[6] := Int64(B) * LCount + 1;

    for LSizeIndex := 0 to High(LSizes) do
    begin
      LChunks[0] := 1;
      LChunks[1] := 7;
      LChunks[2] := 4095;
      LChunks[3] := 4096;
      LChunks[4] := B;
      LChunks[5] := B + 1;
      LChunks[6] := Integer(LSizes[LSizeIndex]) + 10;

      for LChunkIndex := 0 to High(LChunks) do
        CheckReadAll(LSizes[LSizeIndex], AOptions, B, LCount, LChunks[LChunkIndex]);
    end;
  end;
end;

procedure TSequentialReaderTests.CheckZeroCopyReadAll(const ASize: Int64; const ABufferSize, ABufferCount: Cardinal);
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
  LTotal: Int64;
  LContext: string;
begin
  LContext := Format('zero-copy, size %d, buffers %d x %d', [ASize, ABufferCount, ABufferSize]);
  LReader.Open(SharedPatternFile(ASize), [], ABufferSize, ABufferCount);

  LTotal := 0;

  while LReader.TryAcquireChunk(LData, LLength) do
  begin
    AssertTrue(LContext + ': empty chunk', LLength > 0);
    AssertTrue(LContext + ': chunk larger than a buffer', LLength <= NativeInt(ABufferSize));
    CheckPattern(UInt64(LTotal), LData, LLength, LContext);
    Inc(LTotal, LLength);
    LReader.ReleaseChunk;
  end;

  AssertEquals(LContext + ': total', ASize, LTotal);
  AssertTrue(LContext + ': Eof', LReader.Eof);
end;

{ Reads the whole file in calls of AChunkSize into page-aligned memory moved by AMisalign bytes (unbuffered, the reader
  reads straight into the caller's memory only when it starts on a sector boundary). SMALL_BUFFER buffers. }
function TSequentialReaderTests.CheckBigReads(const ASize: Int64; const AOptions: TIORingSequentialReaderOptions;
  const ABufferCount: Cardinal; const AChunkSize, AMisalign: Integer): TIORingSequentialReaderStats;
var
  LReader: TIORingSequentialReader;
  LMemory: PByte;
  LMemorySize: NativeUInt;
  LBuffer: PByte;
  LRead: NativeInt;
  LTotal: Int64;
  LContext: string;
begin
  LContext := Format('big reads, size %d, %d buffers, chunk %d, misaligned by %d',
    [ASize, ABufferCount, AChunkSize, AMisalign]);
  LMemorySize := NativeUInt(AChunkSize + AMisalign);
  LMemory := TIORingPlatform.AllocPages(LMemorySize);
  try
    LBuffer := LMemory + AMisalign;
    LReader.Open(SharedPatternFile(ASize), AOptions, SMALL_BUFFER, ABufferCount);
    LTotal := 0;

    repeat
      LRead := LReader.Read(LBuffer^, AChunkSize);

      if LRead > 0 then
        CheckPattern(UInt64(LTotal), LBuffer, LRead, LContext);

      Inc(LTotal, LRead);
    until LRead < AChunkSize;

    AssertEquals(LContext + ': total', ASize, LTotal);
    AssertEquals(LContext + ': position', ASize, LReader.Position);
    AssertTrue(LContext + ': Eof', LReader.Eof);
    AssertEquals(LContext + ': read after EOF', Int64(0), Int64(LReader.Read(LBuffer^, AChunkSize)));
    Result := LReader.Stats;
    // The buffers and the direct reads never read the same bytes
    CheckEqualsU64(LContext + ': bytes from disk', UInt64(ASize), Result.BytesFromDisk);
    LReader.Close;
  finally
    TIORingPlatform.FreePages(LMemory, LMemorySize);
  end;
end;

function TSequentialReaderTests.OpenRaisesIORingError(const AFileName: string;
  const ABufferSize, ABufferCount: Cardinal): Boolean;
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

  AssertFalse('A failed Open must leave the reader closed', LReader.IsOpen);
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
  LStats: TIORingSequentialReaderStats;
begin
  LStart := TThread.GetTickCount64;
  LStats := CheckReadAll(LARGE_FILE_SIZE, [], IORING_READER_DEFAULT_BUFFER_SIZE,
    IORING_READER_DEFAULT_BUFFER_COUNT, 64 * 1024);
  Log(Format('100 MB buffered (incl. pattern checks): %d ms; stalls %d (%d us), max read-ahead %d',
    [TThread.GetTickCount64 - LStart, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
end;

procedure TSequentialReaderTests.Read_LargeFile_Unbuffered;
var
  LStart: UInt64;
  LStats: TIORingSequentialReaderStats;
begin
  LStart := TThread.GetTickCount64;
  LStats := CheckReadAll(LARGE_FILE_SIZE, [sroUnbuffered], IORING_READER_DEFAULT_BUFFER_SIZE,
    IORING_READER_DEFAULT_BUFFER_COUNT, 64 * 1024);
  Log(Format('100 MB unbuffered (incl. pattern checks): %d ms; stalls %d (%d us), max read-ahead %d',
    [TThread.GetTickCount64 - LStart, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
end;

procedure TSequentialReaderTests.ZeroCopy_DeliversSameContent;
const
  B = SMALL_BUFFER;
  COUNTS: array[0..2] of Cardinal = (1, 2, 8);
var
  LCountIndex: Integer;
  LCount: Cardinal;
begin
  for LCountIndex := Low(COUNTS) to High(COUNTS) do
  begin
    LCount := COUNTS[LCountIndex];
    CheckZeroCopyReadAll(0, B, LCount);
    CheckZeroCopyReadAll(1, B, LCount);
    CheckZeroCopyReadAll(B - 1, B, LCount);
    CheckZeroCopyReadAll(B, B, LCount);
    CheckZeroCopyReadAll(B + 1, B, LCount);
    CheckZeroCopyReadAll(Int64(B) * LCount, B, LCount);
    CheckZeroCopyReadAll(Int64(B) * LCount + 1, B, LCount);
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
  LUseChunk: Boolean;
begin
  LReader.Open(SharedPatternFile(FILE_SIZE), [], B, 2);
  LTotal := 0;
  LUseChunk := False;

  repeat
    if LUseChunk then
    begin
      if not LReader.TryAcquireChunk(LData, LLength) then
        Break;

      CheckPattern(UInt64(LTotal), LData, LLength, 'Chunk');
      Inc(LTotal, LLength);
      LReader.ReleaseChunk;
    end
    else
    begin
      LRead := LReader.Read(LBuffer, SizeOf(LBuffer));

      if LRead = 0 then
        Break;

      CheckPattern(UInt64(LTotal), @LBuffer, LRead, 'Read');
      Inc(LTotal, LRead);
    end;

    LUseChunk := not LUseChunk;
  until False;

  AssertEquals('Total', Int64(FILE_SIZE), LTotal);
  AssertEquals('Position', Int64(FILE_SIZE), LReader.Position);
end;

procedure TSequentialReaderTests.EmptyFile_IsEndOfFileAtOnce;
var
  LReader: TIORingSequentialReader;
  LBuffer: array[0..15] of Byte;
  LData: PByte;
  LLength: NativeInt;
begin
  LReader.Open(SharedPatternFile(0));
  AssertTrue('Eof', LReader.Eof);
  AssertTrue('DataReady', LReader.DataReady);
  AssertEquals('Read', Int64(0), Int64(LReader.Read(LBuffer, SizeOf(LBuffer))));
  AssertFalse('TryAcquireChunk', LReader.TryAcquireChunk(LData, LLength));
  AssertEquals('Size', Int64(0), LReader.Size);
end;

{ Big Read calls (straight into the caller's memory) }

procedure TSequentialReaderTests.BigReads_GoStraightIntoTheCallersMemory;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 20 * B + 123;
var
  LStats: TIORingSequentialReaderStats;
begin
  // Calls of 8 buffers: what the buffers have not asked for is read directly
  LStats := CheckBigReads(FILE_SIZE, [], 4, 8 * B, 0);
  Log(Format('Calls of 8 buffers: %d direct reads, %d bytes; %d reads into the buffers',
    [LStats.DirectReads, LStats.DirectBytes, LStats.ReadsIssued]));
  { At least 6 buffers in the first call (2 asked for at open) and 4 in the second (at most 4 asked for ahead); how
    many more depends on timing }
  AssertTrue('Bytes read directly', LStats.DirectBytes >= 10 * B);

  // Odd call sizes and memory, one buffer, a call bigger than the file
  AssertTrue('Odd calls: direct reads', CheckBigReads(FILE_SIZE, [], 4, 3 * B + 1, 1).DirectReads > 0);
  AssertTrue('One buffer: direct reads', CheckBigReads(FILE_SIZE, [sroFixedReadAhead], 1, 5 * B, 0).DirectReads > 0);
  AssertTrue('Whole file: direct reads', CheckBigReads(FILE_SIZE, [], 8, 30 * B, 0).DirectReads > 0);
  AssertTrue('No registration: direct reads',
    CheckBigReads(FILE_SIZE, [sroNoRegistration], 2, 8 * B, 0).DirectReads > 0);
end;

procedure TSequentialReaderTests.SmallReads_UseOnlyTheBuffers;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 20 * B + 123;
begin
  // The buffers always have at least one buffer asked for ahead
  CheckEqualsU64('Calls of one buffer', 0, CheckBigReads(FILE_SIZE, [], 4, B, 0).DirectReads);
  CheckEqualsU64('Calls of 4 KiB', 0, CheckBigReads(FILE_SIZE, [], 4, 4096, 0).DirectReads);
  CheckEqualsU64('One buffer, calls of one buffer', 0,
    CheckBigReads(FILE_SIZE, [sroFixedReadAhead], 1, B, 0).DirectReads);
end;

procedure TSequentialReaderTests.BigReads_Unbuffered_OnlyIntoSectorAlignedMemory;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 20 * B + 123;
begin
  AssertTrue('Page-aligned memory: direct reads',
    CheckBigReads(FILE_SIZE, [sroUnbuffered], 4, 8 * B, 0).DirectReads > 0);
  CheckEqualsU64('One byte off: only the buffers', 0,
    CheckBigReads(FILE_SIZE, [sroUnbuffered], 4, 8 * B, 1).DirectReads);
  // Calls that end inside a sector: the direct part stops at a sector boundary, the buffers deliver the rest
  AssertTrue('Calls ending inside a sector: direct reads',
    CheckBigReads(FILE_SIZE, [sroUnbuffered], 4, 8 * B + 1000, 0).DirectReads > 0);
  AssertTrue('Whole file: direct reads', CheckBigReads(FILE_SIZE, [sroUnbuffered], 8, 30 * B, 0).DirectReads > 0);
end;

procedure TSequentialReaderTests.BigReads_MixedWithSmallReadsAndChunks;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 40 * B + 77;
  BIG = 6 * B + 3;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
  LData: PByte;
  LLength: NativeInt;
  LRead: NativeInt;
  LTotal: Int64;
  LStep: Integer;
begin
  SetLength(LBuffer, BIG);
  LReader.Open(SharedPatternFile(FILE_SIZE), [], B, 4);
  LTotal := 0;
  LStep := 0;

  repeat
    case LStep mod 3 of
      0: LRead := LReader.Read(LBuffer[0], BIG);
      1: LRead := LReader.Read(LBuffer[0], 1000);
      else
        if LReader.TryAcquireChunk(LData, LLength) then
        begin
          CheckPattern(UInt64(LTotal), LData, LLength, 'Chunk');
          Inc(LTotal, LLength);
          LReader.ReleaseChunk;
          LRead := LLength;
        end
        else
          LRead := 0;
    end;

    if (LStep mod 3 <> 2) and (LRead > 0) then
    begin
      CheckPattern(UInt64(LTotal), @LBuffer[0], LRead, 'Read');
      Inc(LTotal, LRead);
    end;

    Inc(LStep);
  until LRead = 0;

  AssertEquals('Total', Int64(FILE_SIZE), LTotal);
  AssertEquals('Position', Int64(FILE_SIZE), LReader.Position);
  AssertTrue('Direct reads', LReader.Stats.DirectReads > 0);
  CheckEqualsU64('Bytes from disk', FILE_SIZE, LReader.Stats.BytesFromDisk);
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
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Append');
  FResources.AddFile(LFileName);
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

    if LRead > 0 then
      CheckPattern(UInt64(LTotal), @LBuffer[0], LRead);

    Inc(LTotal, LRead);
  until LRead = 0;

  AssertEquals('Bytes read', Int64(FILE_SIZE), LTotal);
  AssertTrue('Eof', LReader.Eof);
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
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'Shorten');
  FResources.AddFile(LFileName);
  LReader.Open(LFileName, [sroFixedReadAhead], B, 1);

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

    if LRead > 0 then
      CheckPattern(UInt64(LTotal), @LBuffer[0], LRead);

    Inc(LTotal, LRead);
  until LRead = 0;

  AssertEquals('Bytes read', Int64(NEW_SIZE), LTotal);
  AssertTrue('Eof', LReader.Eof);
  AssertEquals('Size stays the size at open', Int64(FILE_SIZE), LReader.Size);
end;

procedure TSequentialReaderTests.ShortenedWhileBigReads_EndsAtNewEnd;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 40 * B;
  { After the two buffers asked for at open, so the result does not depend on whether they were read
    before the file got shorter }
  NEW_SIZE = 10 * B + B div 2;
var
  LFileName: string;
  LReader: TIORingSequentialReader;
  LWriter: TFileStream;
  LBuffer: TBytes;
  LTotal: Int64;
  LRead: NativeInt;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(FILE_SIZE, 'ShortenBig');
  FResources.AddFile(LFileName);
  LReader.Open(LFileName, [], B, 2);

  LWriter := TFileStream.Create(LFileName, fmOpenReadWrite or fmShareDenyNone);
  try
    LWriter.Size := NEW_SIZE;
  finally
    LWriter.Free;
  end;

  SetLength(LBuffer, 8 * B);
  LTotal := 0;

  repeat
    LRead := LReader.Read(LBuffer[0], Length(LBuffer));

    if LRead > 0 then
      CheckPattern(UInt64(LTotal), @LBuffer[0], LRead);

    Inc(LTotal, LRead);
  until LRead = 0;

  AssertEquals('Bytes read', Int64(NEW_SIZE), LTotal);
  AssertTrue('Eof', LReader.Eof);
  AssertTrue('Direct reads', LReader.Stats.DirectReads > 0);
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
  LReader.Open(SharedPatternFile(FILE_SIZE), [sroFixedReadAhead], SMALL_BUFFER, 16);
  AssertEquals('First read', Int64(Length(LBuffer)), Int64(LReader.Read(LBuffer[0], Length(LBuffer))));
  LReader.Close;
  AssertFalse('Closed', LReader.IsOpen);

  CheckReadAll(FILE_SIZE, [], SMALL_BUFFER, 4, 100 * 1024);
  LReader.Open(SharedPatternFile(FILE_SIZE));
  AssertTrue('Opened again', LReader.IsOpen);
end;

procedure TSequentialReaderTests.EndOfScope_ClosesFile;
var
  LFileName: string;
{$IFNDEF MSWINDOWS}
  LOpenFiles: Integer;
{$ENDIF}
begin
  LFileName := TTestFileHelpers.CreatePatternFile(1024 * 1024, 'Scope');
  FResources.AddFile(LFileName);

{$IFDEF MSWINDOWS}
  ReadALittleAndLeaveScope(LFileName);
  AssertTrue('The file is still open: ' + SysErrorMessage(GetLastError), DeleteFile(LFileName));
{$ELSE}
  // Linux deletes open files too: count the open file descriptors instead
  LOpenFiles := OpenFileDescriptorCount;
  ReadALittleAndLeaveScope(LFileName);
  AssertEquals('The file is still open', LOpenFiles, OpenFileDescriptorCount);
{$ENDIF}
end;

procedure TSequentialReaderTests.OpenHandle_NotOwned_KeepsHandleOpen;
var
  LHandle: THandle;
  LReader: TIORingSequentialReader;
  LBuffer: array[0..999] of Byte;
begin
  LHandle := FResources.OpenFile(SharedPatternFile(3 * SMALL_BUFFER));
  LReader.Open(LHandle, False, [], SMALL_BUFFER, 2);
  AssertEquals('Read', Int64(SizeOf(LBuffer)), Int64(LReader.Read(LBuffer, SizeOf(LBuffer))));
  LReader.Close;

  // GetFileSize raises if the reader closed the handle
  AssertEquals('Size', Int64(3 * SMALL_BUFFER), TIORingPlatform.GetFileSize(LHandle));
end;

procedure TSequentialReaderTests.Open_BadArguments_Raise;
var
  LFileName: string;
begin
  LFileName := SharedPatternFile(SMALL_BUFFER);
  AssertTrue('Buffer size 0', OpenRaisesIORingError(LFileName, 0, 4));
  AssertTrue('Buffer size not a multiple of 4096', OpenRaisesIORingError(LFileName, 1000, 4));
  AssertTrue('No buffers', OpenRaisesIORingError(LFileName, SMALL_BUFFER, 0));
  AssertTrue('Too many buffers', OpenRaisesIORingError(LFileName, SMALL_BUFFER, IORING_READER_MAX_BUFFER_COUNT + 1));
end;

procedure TSequentialReaderTests.Open_MissingFile_Raises;
begin
  AssertTrue(OpenRaisesIORingError(TTestFileHelpers.NewTestFileName('Missing'), SMALL_BUFFER, 4));
end;

procedure TSequentialReaderTests.Open_Twice_Raises;
var
  LReader: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader.Open(SharedPatternFile(SMALL_BUFFER));
  LRaised := False;

  try
    LReader.Open(SharedPatternFile(SMALL_BUFFER));
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Second Open raises', LRaised);
  AssertTrue('The first Open stays usable', LReader.IsOpen);
end;

procedure TSequentialReaderTests.Copy_Raises;
var
  LReader1: TIORingSequentialReader;
  LReader2: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader1.Open(SharedPatternFile(SMALL_BUFFER));
  LRaised := False;

  try
    LReader2 := LReader1;
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  AssertTrue('Copy raises', LRaised);
  AssertFalse('Target not open', LReader2.IsOpen);
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
  LReader.Open(SharedPatternFile(SMALL_BUFFER));
  AssertTrue('Acquire', LReader.TryAcquireChunk(LData, LLength));
  LRaised := False;

  try
    LReader.Read(LBuffer, SizeOf(LBuffer));
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  AssertTrue('Read raises', LRaised);
end;

procedure TSequentialReaderTests.ReleaseChunk_WithoutChunk_Raises;
var
  LReader: TIORingSequentialReader;
  LRaised: Boolean;
begin
  LReader.Open(SharedPatternFile(SMALL_BUFFER));
  LRaised := False;

  try
    LReader.ReleaseChunk;
  except
    on EInvalidOpException do
      LRaised := True;
  end;

  AssertTrue('ReleaseChunk raises', LRaised);
end;

procedure TSequentialReaderTests.TryAcquireChunk_WithoutWait_GetsDataEventually;
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
  LStart: UInt64;
  LGot: Boolean;
begin
  LReader.Open(SharedPatternFile(4 * SMALL_BUFFER), [], SMALL_BUFFER, 4);
  LStart := TThread.GetTickCount64;

  repeat
    LGot := LReader.TryAcquireChunk(LData, LLength, False);

    if not LGot then
    begin
      AssertFalse('No data must not mean end of file here', LReader.Eof);
      Sleep(1);
    end;
  until LGot or (TThread.GetTickCount64 - LStart > 5000);

  AssertTrue('Data within 5 s', LGot);
  AssertEquals('Chunk', Int64(SMALL_BUFFER), Int64(LLength));
  LReader.ReleaseChunk;
  AssertEquals('Position', Int64(SMALL_BUFFER), LReader.Position);
end;

procedure TSequentialReaderTests.Stats_AreConsistent;
const
  B = SMALL_BUFFER;
  FILE_SIZE = 10 * B + 5;
var
  LReader: TIORingSequentialReader;
  LBuffer: TBytes;
  LStats: TIORingSequentialReaderStats;
begin
  SetLength(LBuffer, B);
  LReader.Open(SharedPatternFile(FILE_SIZE), [], B, 4);

  while LReader.Read(LBuffer[0], B) > 0 do
    ;

  LStats := LReader.Stats;
  Log(Format('Adaptive: reads %d, bytes %d, stalls %d (%d us), max read-ahead %d',
    [LStats.ReadsIssued, LStats.BytesFromDisk, LStats.Stalls, LStats.StallMicroseconds, LStats.MaxReadAhead]));
  CheckEqualsU64('Reads', 11, LStats.ReadsIssued);
  CheckEqualsU64('Bytes', FILE_SIZE, LStats.BytesFromDisk);
  AssertTrue('Adaptive read-ahead between 2 and 4', (LStats.MaxReadAhead >= 2) and (LStats.MaxReadAhead <= 4));
  LReader.Close;

  LReader.Open(SharedPatternFile(FILE_SIZE), [sroFixedReadAhead], B, 4);

  while LReader.Read(LBuffer[0], B) > 0 do
    ;

  LStats := LReader.Stats;
  AssertEquals('Fixed read-ahead', Int64(4), Int64(LStats.MaxReadAhead));
  CheckEqualsU64('Bytes', FILE_SIZE, LStats.BytesFromDisk);
end;

initialization
  RegisterTests(TSequentialReaderTests);

end.
