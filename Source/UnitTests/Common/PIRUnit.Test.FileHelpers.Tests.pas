unit PIRUnit.Test.FileHelpers.Tests;

{
  Tests for the test-file helpers themselves. If these fail, every later test
  that checks file contents would give wrong answers.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Test.Support;

type
  TTestFileHelpersTests = class(TIORingTestCase)
  published
    procedure PatternWord_IsDeterministic;
    procedure PatternWord_NeighboursDiffer;
    procedure FillPattern_MatchesExpectedByte;
    procedure CheckPattern_AcceptsCorrectData;
    procedure CheckPattern_DetectsShiftedData;
    procedure CheckPattern_ReportsFirstBadOffset;
    procedure CreatePatternFile_HasRightSizeAndContent;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.Test.FileHelpers;

procedure TTestFileHelpersTests.PatternWord_IsDeterministic;
begin
  CheckEqualsU64('Same index', TTestFileHelpers.PatternWord(12345), TTestFileHelpers.PatternWord(12345));
end;

procedure TTestFileHelpersTests.PatternWord_NeighboursDiffer;
var
  LIndex: Integer;   // FPC on 32-bit: no 64-bit loop counters
begin
  for LIndex := 0 to 1000 do
    AssertTrue(Format('Words %d and %d', [LIndex, LIndex + 1]),
      TTestFileHelpers.PatternWord(UInt64(LIndex)) <> TTestFileHelpers.PatternWord(UInt64(LIndex) + 1));
end;

procedure TTestFileHelpersTests.FillPattern_MatchesExpectedByte;
const
  OFFSETS: array[0..4] of UInt64 = (0, 1, 7, 4095, 4294967291);
  COUNTS: array[0..4] of Integer = (64, 64, 1, 4099, 37);
var
  LCase: Integer;
  LBuffer: TBytes;
  LIndex: Integer;
begin
  for LCase := Low(OFFSETS) to High(OFFSETS) do
  begin
    SetLength(LBuffer, COUNTS[LCase]);
    TTestFileHelpers.FillPattern(OFFSETS[LCase], LBuffer[0], COUNTS[LCase]);

    for LIndex := 0 to COUNTS[LCase] - 1 do
      AssertEquals(Format('Byte at offset %d', [OFFSETS[LCase] + UInt64(LIndex)]),
        Integer(TTestFileHelpers.ExpectedByte(OFFSETS[LCase] + UInt64(LIndex))), Integer(LBuffer[LIndex]));
  end;
end;

procedure TTestFileHelpersTests.CheckPattern_AcceptsCorrectData;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  SetLength(LBuffer, 1000);
  TTestFileHelpers.FillPattern(3, LBuffer[0], Length(LBuffer));

  AssertTrue(TTestFileHelpers.CheckPattern(3, LBuffer[0], Length(LBuffer), LBadOffset));
end;

procedure TTestFileHelpersTests.CheckPattern_DetectsShiftedData;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  SetLength(LBuffer, 64);
  TTestFileHelpers.FillPattern(1, LBuffer[0], Length(LBuffer));

  AssertFalse(TTestFileHelpers.CheckPattern(0, LBuffer[0], Length(LBuffer), LBadOffset));
end;

procedure TTestFileHelpersTests.CheckPattern_ReportsFirstBadOffset;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  SetLength(LBuffer, 100);
  TTestFileHelpers.FillPattern(1000, LBuffer[0], Length(LBuffer));
  LBuffer[42] := not LBuffer[42];

  AssertFalse(TTestFileHelpers.CheckPattern(1000, LBuffer[0], Length(LBuffer), LBadOffset));
  CheckEqualsU64('First bad offset', 1042, LBadOffset);
end;

procedure TTestFileHelpersTests.CreatePatternFile_HasRightSizeAndContent;
const
  SIZES: array[0..3] of Int64 = (0, 1, 4097, 1048579);
var
  LSize: Int64;
  LFileName: string;
  LStream: TFileStream;
  LBuffer: TBytes;
begin
  for LSize in SIZES do
  begin
    LFileName := TTestFileHelpers.CreatePatternFile(LSize);
    try
      LStream := TFileStream.Create(LFileName, fmOpenRead or fmShareDenyWrite);
      try
        AssertEquals('Size', LSize, LStream.Size);

        if LSize > 0 then
        begin
          SetLength(LBuffer, LSize);
          LStream.ReadBuffer(LBuffer[0], LSize);
          CheckPattern(0, @LBuffer[0], LSize, Format('File of %d bytes', [LSize]));
        end;
      finally
        LStream.Free;
      end;
    finally
      TTestFileHelpers.DeleteTestFile(LFileName);
    end;
  end;
end;

initialization
  RegisterTests(TTestFileHelpersTests);

end.
