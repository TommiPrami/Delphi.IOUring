unit PIRUnit.Streams.Tests;

{
  Tests for TSequentialReadOnlyFileStream (PIRUnit.Streams): same
  content as TFileStream, the seek and write rules, and use through the
  usual RTL helpers (CopyFrom, LoadFromStream, TStreamReader).
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes,
{$ELSE}
  System.Classes,
{$ENDIF}
  PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TSequentialReadOnlyFileStreamTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    FStream: TStream;   // the stream the Raises* helpers act on
    procedure CheckSameAsFileStream(const ASize: Int64; const AChunkSize: Integer; const ABufferCount: Cardinal);
    procedure CheckRaisesStreamError(const AMessage: string; const AMethod: TRunMethod);
    // Methods for CheckRaisesStreamError (FPC 3.2.2 has no anonymous methods)
    procedure SeekBackward;
    procedure SeekForward;
    procedure SeekToStart;
    procedure SeekToEnd;
    procedure SetPositionZero;
    procedure SeekOld32;
    procedure WriteBytes;
    procedure WriteBufferBytes;
{$IFNDEF FPC}
    procedure WriteTBytes;
    procedure Write64TBytes;
{$ENDIF}
    procedure SetSizeTen;
    procedure SetSizeSame;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure Content_SameAsFileStream;
    procedure Content_Unbuffered;
{$IFNDEF FPC}
    // TStream.Read(TBytes, ...), Read64 and ReadData: Free Pascal 3.2.2's TStream does not have them
    procedure ReadOverloads_Work;
{$ENDIF}
    procedure ReadBuffer_PastEnd_RaisesEReadError;
    procedure PositionAndSize_AtAllTimes;
    procedure SeekToCurrentPosition_IsAllowed;
    procedure SeekElsewhere_Raises;
    procedure Write_Raises;
    procedure SetSize_Raises;
    procedure StreamError_IsAnEStreamError;
    procedure MemoryStream_CopyFromWholeStream;
    procedure MemoryStream_CopyFromPartsThenRest;
    procedure BytesStream_LoadFromStream;
    procedure MemoryStream_LoadFromStream_ReadsDirectly;
    procedure StreamReader_ReadsLines;
    procedure Create_MissingFile_RaisesEFOpenError;
    procedure Create_BadBufferSize_RaisesEIORingError;
    procedure Stats_AreAvailable;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils,
  streamex,             // TStreamReader
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.SequentialReader, PIRUnit.Streams, PIRUnit.Test.FileHelpers;

const
  SMALL_BUFFER = 64 * 1024;

{ Helpers }

procedure TSequentialReadOnlyFileStreamTests.SetUp;
begin
  FResources := TTestResources.Create;
  FStream := nil;
end;

procedure TSequentialReadOnlyFileStreamTests.TearDown;
begin
  FreeAndNil(FStream);
  FreeAndNil(FResources);
end;

procedure TSequentialReadOnlyFileStreamTests.CheckRaisesStreamError(const AMessage: string; const AMethod: TRunMethod);
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    AMethod;
  except
    on EIORingStreamError do
      LRaised := True;
  end;

  AssertTrue(AMessage + ' must raise EIORingStreamError', LRaised);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekBackward;
begin
  FStream.Seek(-1, soCurrent);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekForward;
begin
  FStream.Seek(1, soCurrent);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekToStart;
begin
  FStream.Seek(0, soBeginning);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekToEnd;
begin
  FStream.Seek(0, soEnd);
end;

procedure TSequentialReadOnlyFileStreamTests.SetPositionZero;
begin
  FStream.Position := 0;
end;

procedure TSequentialReadOnlyFileStreamTests.SeekOld32;
begin
  FStream.Seek(Longint(10), Word(soFromCurrent));
end;

procedure TSequentialReadOnlyFileStreamTests.WriteBytes;
var
  LByte: Byte;
begin
  LByte := 0;
  FStream.Write(LByte, 1);
end;

procedure TSequentialReadOnlyFileStreamTests.WriteBufferBytes;
var
  LBytes: array[0..9] of Byte;
begin
  FillChar(LBytes, SizeOf(LBytes), 0);
  FStream.WriteBuffer(LBytes, SizeOf(LBytes));
end;

{$IFNDEF FPC}
procedure TSequentialReadOnlyFileStreamTests.WriteTBytes;
var
  LBytes: TBytes;
begin
  SetLength(LBytes, 10);
  FStream.Write(LBytes, 0, 10);
end;

procedure TSequentialReadOnlyFileStreamTests.Write64TBytes;
var
  LBytes: TBytes;
begin
  SetLength(LBytes, 10);
  FStream.Write64(LBytes, 0, 10);
end;
{$ENDIF}

procedure TSequentialReadOnlyFileStreamTests.SetSizeTen;
begin
  FStream.Size := 10;
end;

procedure TSequentialReadOnlyFileStreamTests.SetSizeSame;
begin
  FStream.Size := FStream.Size;
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

  LExpected := TFileStream.Create(SharedPatternFile(ASize), fmOpenRead or fmShareDenyNone);
  try
    LActual := TSequentialReadOnlyFileStream.Create(SharedPatternFile(ASize), [], SMALL_BUFFER, ABufferCount);
    try
      AssertEquals(LContext + ': Size', LExpected.Size, LActual.Size);

      repeat
        LExpectedRead := LExpected.Read(LExpectedBuffer[0], AChunkSize);
        LActualRead := LActual.Read(LActualBuffer[0], AChunkSize);
        AssertEquals(LContext + ': bytes read', LExpectedRead, LActualRead);
        AssertTrue(LContext + ': different data', CompareMem(@LExpectedBuffer[0], @LActualBuffer[0], LActualRead));
        AssertEquals(LContext + ': Position', LExpected.Position, LActual.Position);
      until LActualRead = 0;
    finally
      LActual.Free;
    end;
  finally
    LExpected.Free;
  end;
end;

{ Content }

procedure TSequentialReadOnlyFileStreamTests.Content_SameAsFileStream;
const
  B = SMALL_BUFFER;
  COUNTS: array[0..2] of Cardinal = (1, 2, 8);
  CHUNKS: array[0..4] of Integer = (1, 4095, 4096, B, B + 1);
var
  LCountIndex: Integer;
  LCount: Cardinal;
  LSizes: array[0..6] of Int64;
  LSizeIndex: Integer;
  LChunkIndex: Integer;
begin
  for LCountIndex := Low(COUNTS) to High(COUNTS) do
  begin
    LCount := COUNTS[LCountIndex];
    LSizes[0] := 0;
    LSizes[1] := 1;
    LSizes[2] := B - 1;
    LSizes[3] := B;
    LSizes[4] := B + 1;
    LSizes[5] := Int64(B) * LCount;
    LSizes[6] := Int64(B) * LCount + 1;

    for LSizeIndex := 0 to High(LSizes) do
    begin
      for LChunkIndex := Low(CHUNKS) to High(CHUNKS) do
        CheckSameAsFileStream(LSizes[LSizeIndex], CHUNKS[LChunkIndex], LCount);

      CheckSameAsFileStream(LSizes[LSizeIndex], Integer(LSizes[LSizeIndex]) + 10, LCount);
    end;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.Content_Unbuffered;
const
  FILE_SIZE = 3 * SMALL_BUFFER + 77;
var
  LBuffer: TBytes;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [sroUnbuffered], SMALL_BUFFER, 2);
  SetLength(LBuffer, FILE_SIZE);
  FStream.ReadBuffer(LBuffer[0], FILE_SIZE);
  CheckPattern(0, @LBuffer[0], FILE_SIZE);
  AssertEquals('Read after the end', 0, FStream.Read(LBuffer[0], 1));
end;

{$IFNDEF FPC}
procedure TSequentialReadOnlyFileStreamTests.ReadOverloads_Work;
const
  FILE_SIZE = 10000;
var
  LBytes: TBytes;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  SetLength(LBytes, 3000);

  // TBytes + offset
  AssertEquals('Read(TBytes, Offset, Count)', 1000, FStream.Read(LBytes, 500, 1000));
  CheckPattern(0, @LBytes[500], 1000, 'Read(TBytes, Offset, Count)');

  AssertEquals('Read64', 2000, FStream.Read64(LBytes, 0, 2000));
  CheckPattern(1000, @LBytes[0], 2000, 'Read64');

  AssertEquals('ReadData', 100, FStream.ReadData(LBytes, 100));
  CheckPattern(3000, @LBytes[0], 100, 'ReadData');

  AssertEquals('Position', 3100, FStream.Position);
end;
{$ENDIF}

procedure TSequentialReadOnlyFileStreamTests.ReadBuffer_PastEnd_RaisesEReadError;
var
  LBuffer: array[0..199] of Byte;
  LRaised: Boolean;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(100), [], SMALL_BUFFER, 1);
  LRaised := False;

  try
    FStream.ReadBuffer(LBuffer, SizeOf(LBuffer));
  except
    on EReadError do
      LRaised := True;
  end;

  AssertTrue('ReadBuffer must raise EReadError when the data ends', LRaised);
end;

{ Position, Size and Seek }

procedure TSequentialReadOnlyFileStreamTests.PositionAndSize_AtAllTimes;
const
  FILE_SIZE = 3 * SMALL_BUFFER + 5;
var
  LBuffer: TBytes;
begin
  SetLength(LBuffer, SMALL_BUFFER);
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  AssertEquals('Position at start', Int64(0), FStream.Position);
  AssertEquals('Size at start', Int64(FILE_SIZE), FStream.Size);

  FStream.ReadBuffer(LBuffer[0], 12345);
  AssertEquals('Position after read', Int64(12345), FStream.Position);
  AssertEquals('Size after read', Int64(FILE_SIZE), FStream.Size);

  while FStream.Read(LBuffer[0], Length(LBuffer)) > 0 do
    ;

  AssertEquals('Position at end', Int64(FILE_SIZE), FStream.Position);
  AssertEquals('Size at end', Int64(FILE_SIZE), FStream.Size);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekToCurrentPosition_IsAllowed;
const
  FILE_SIZE = 2 * SMALL_BUFFER;
var
  LBuffer: TBytes;
  LStep: Integer;
begin
  SetLength(LBuffer, FILE_SIZE);
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);

  for LStep := 0 to 2 do
  begin
    AssertEquals('soCurrent', FStream.Position, FStream.Seek(Int64(0), soCurrent));
    AssertEquals('soBeginning', FStream.Position, FStream.Seek(FStream.Position, soBeginning));
    AssertEquals('soEnd', FStream.Position, FStream.Seek(FStream.Position - FStream.Size, soEnd));
    FStream.Position := FStream.Position;

    if LStep < 2 then
      FStream.ReadBuffer(LBuffer[0], FILE_SIZE div 2);
  end;

  AssertEquals('At the end', Int64(FILE_SIZE), FStream.Position);
end;

procedure TSequentialReadOnlyFileStreamTests.SeekElsewhere_Raises;
var
  LBuffer: array[0..999] of Byte;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(4 * SMALL_BUFFER), [], SMALL_BUFFER, 2);
  FStream.ReadBuffer(LBuffer, SizeOf(LBuffer));

  CheckRaisesStreamError('Backward', SeekBackward);
  CheckRaisesStreamError('Forward', SeekForward);
  CheckRaisesStreamError('To the start', SeekToStart);
  CheckRaisesStreamError('To the end', SeekToEnd);
  CheckRaisesStreamError('Position := 0', SetPositionZero);
  CheckRaisesStreamError('Old 32-bit Seek', SeekOld32);

  AssertEquals('Position unchanged', Int64(SizeOf(LBuffer)), FStream.Position);
  FStream.ReadBuffer(LBuffer, SizeOf(LBuffer));
  AssertEquals('Still reads', Int64(2 * SizeOf(LBuffer)), FStream.Position);
end;

procedure TSequentialReadOnlyFileStreamTests.Write_Raises;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  CheckRaisesStreamError('Write', WriteBytes);
  CheckRaisesStreamError('WriteBuffer', WriteBufferBytes);
{$IFNDEF FPC}
  CheckRaisesStreamError('Write(TBytes)', WriteTBytes);
  CheckRaisesStreamError('Write64', Write64TBytes);
{$ENDIF}
  AssertEquals('Position', Int64(0), FStream.Position);
end;

procedure TSequentialReadOnlyFileStreamTests.SetSize_Raises;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  CheckRaisesStreamError('Size := 10', SetSizeTen);
  CheckRaisesStreamError('Size := Size', SetSizeSame);
  AssertEquals('Size', Int64(SMALL_BUFFER), FStream.Size);
end;

procedure TSequentialReadOnlyFileStreamTests.StreamError_IsAnEStreamError;
var
  LCaught: Boolean;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(SMALL_BUFFER), [], SMALL_BUFFER, 1);
  LCaught := False;

  try
    WriteBytes;
  except
    on EStreamError do
      LCaught := True;
  end;

  AssertTrue('Code that catches EStreamError must catch it', LCaught);
end;

{ RTL helpers }

procedure TSequentialReadOnlyFileStreamTests.MemoryStream_CopyFromWholeStream;
const
  FILE_SIZE = 5 * SMALL_BUFFER + 3;
var
  LTarget: TMemoryStream;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TMemoryStream.Create;
  try
    AssertEquals('Copied', Int64(FILE_SIZE), LTarget.CopyFrom(FStream, 0));
    AssertEquals('Size', Int64(FILE_SIZE), LTarget.Size);
    CheckPattern(0, LTarget.Memory, FILE_SIZE);
  finally
    LTarget.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.MemoryStream_CopyFromPartsThenRest;
const
  FILE_SIZE = 3 * SMALL_BUFFER;
var
  LTarget: TMemoryStream;
  LRaised: Boolean;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TMemoryStream.Create;
  try
    LTarget.CopyFrom(FStream, 1000);
    LTarget.CopyFrom(FStream, 50000);
    LTarget.CopyFrom(FStream, FStream.Size - FStream.Position);
    AssertEquals('Size', Int64(FILE_SIZE), LTarget.Size);
    CheckPattern(0, LTarget.Memory, FILE_SIZE);

    // A second CopyFrom(Source, 0) would have to rewind
    LRaised := False;

    try
      LTarget.CopyFrom(FStream, 0);
    except
      on EIORingStreamError do
        LRaised := True;
    end;

    AssertTrue('Rewind raises', LRaised);
  finally
    LTarget.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.BytesStream_LoadFromStream;
const
  FILE_SIZE = 2 * SMALL_BUFFER + 999;
var
  LTarget: TBytesStream;
begin
  FStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 2);
  LTarget := TBytesStream.Create;
  try
    LTarget.LoadFromStream(FStream);
    AssertEquals('Size', Int64(FILE_SIZE), LTarget.Size);
    CheckPattern(0, @LTarget.Bytes[0], FILE_SIZE);
  finally
    LTarget.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.MemoryStream_LoadFromStream_ReadsDirectly;
const
  FILE_SIZE = 20 * SMALL_BUFFER + 77;
var
  LStream: TSequentialReadOnlyFileStream;
  LTarget: TMemoryStream;
begin
  LStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 4);
  FStream := LStream;
  LTarget := TMemoryStream.Create;
  try
    LTarget.LoadFromStream(LStream);
    AssertEquals('Size', Int64(FILE_SIZE), LTarget.Size);
    CheckPattern(0, LTarget.Memory, FILE_SIZE);
    // One big Read: most of the file goes straight into the memory stream
    AssertTrue('Read directly', LStream.Stats.DirectBytes > FILE_SIZE div 2);
    CheckEqualsU64('Bytes', FILE_SIZE, LStream.Stats.BytesFromDisk);
  finally
    LTarget.Free;
  end;
end;

procedure TSequentialReadOnlyFileStreamTests.StreamReader_ReadsLines;
const
  LINE_COUNT = 20000;
var
  LFileName: string;
  LLines: TStringList;
  LIndex: Integer;
  LReader: TStreamReader;
begin
  LFileName := TTestFileHelpers.NewTestFileName('Lines');
  FResources.AddFile(LFileName);

  LLines := TStringList.Create;

  try
    for LIndex := 1 to LINE_COUNT do
      LLines.Add(Format('Line %d: %s', [LIndex, StringOfChar(Char(Ord('a') + LIndex mod 26), LIndex mod 97)]));

{$IFDEF FPC}
    LLines.SaveToFile(LFileName);
{$ELSE}
    LLines.WriteBOM := False;
    LLines.SaveToFile(LFileName, TEncoding.UTF8);
{$ENDIF}

    FStream := TSequentialReadOnlyFileStream.Create(LFileName, [], SMALL_BUFFER, 2);
    // The two RTLs have different TStreamReader classes (FPC: unit streamex)
{$IFDEF FPC}
    LReader := TStreamReader.Create(FStream, 4096, False);
{$ELSE}
    LReader := TStreamReader.Create(FStream, TEncoding.UTF8);
{$ENDIF}

    try
      for LIndex := 0 to LINE_COUNT - 1 do
        AssertEquals(Format('Line %d', [LIndex + 1]), LLines[LIndex], LReader.ReadLine);

{$IFDEF FPC}
      AssertTrue('End', LReader.EOF);
{$ELSE}
      AssertTrue('End', LReader.EndOfStream);
{$ENDIF}
    finally
      LReader.Free;
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

  AssertTrue('Like TFileStream, a missing file raises EFOpenError', LRaised);
end;

procedure TSequentialReadOnlyFileStreamTests.Create_BadBufferSize_RaisesEIORingError;
var
  LRaised: Boolean;
begin
  LRaised := False;

  try
    TSequentialReadOnlyFileStream.Create(SharedPatternFile(SMALL_BUFFER), [], 1000, 2).Free;
  except
    on EIORingError do
      LRaised := True;
  end;

  AssertTrue('Bad buffer size raises EIORingError', LRaised);

  // The failed constructor released the file handle: an exclusive open works
  TFileStream.Create(SharedPatternFile(SMALL_BUFFER), fmOpenRead or fmShareExclusive).Free;
end;

procedure TSequentialReadOnlyFileStreamTests.Stats_AreAvailable;
const
  FILE_SIZE = 4 * SMALL_BUFFER;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
begin
  SetLength(LBuffer, FILE_SIZE);
  LStream := TSequentialReadOnlyFileStream.Create(SharedPatternFile(FILE_SIZE), [], SMALL_BUFFER, 4);
  FStream := LStream;
  LStream.ReadBuffer(LBuffer[0], FILE_SIZE);
  // The two buffers asked for at open, then the rest straight into LBuffer
  CheckEqualsU64('Reads into the buffers', 2, LStream.Stats.ReadsIssued);
  CheckEqualsU64('Reads straight into the caller''s memory', 2, LStream.Stats.DirectReads);
  CheckEqualsU64('Bytes', FILE_SIZE, LStream.Stats.BytesFromDisk);
  CheckEqualsU64('Bytes read directly', 2 * SMALL_BUFFER, LStream.Stats.DirectBytes);
end;

initialization
  RegisterTests(TSequentialReadOnlyFileStreamTests);

end.
