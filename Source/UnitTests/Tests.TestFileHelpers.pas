unit Tests.TestFileHelpers;

{
  Tests for the test-file helpers themselves. If these fail, every later test
  that checks file contents would give wrong answers.
}

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TTestFileHelpersTests = class
  public
    [Test]
    procedure PatternWord_IsDeterministic;

    [Test]
    procedure PatternWord_NeighboursDiffer;

    [Test]
    [TestCase('Offset 0', '0,64')]
    [TestCase('Offset 1', '1,64')]
    [TestCase('Offset 7', '7,1')]
    [TestCase('Offset 4095', '4095,4099')]
    [TestCase('Near 4 GiB', '4294967291,37')]
    procedure FillPattern_MatchesExpectedByte(const AOffset: UInt64; const ACount: Integer);

    [Test]
    procedure CheckPattern_AcceptsCorrectData;

    [Test]
    procedure CheckPattern_DetectsShiftedData;

    [Test]
    procedure CheckPattern_ReportsFirstBadOffset;

    [Test]
    [TestCase('Empty', '0')]
    [TestCase('One byte', '1')]
    [TestCase('Odd size', '4097')]
    [TestCase('Over one chunk', '1048579')]
    procedure CreatePatternFile_HasRightSizeAndContent(const ASize: Int64);
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  TestFileHelpers;

procedure TTestFileHelpersTests.PatternWord_IsDeterministic;
begin
  Assert.AreEqual(TTestFileHelpers.PatternWord(12345), TTestFileHelpers.PatternWord(12345));
end;

procedure TTestFileHelpersTests.PatternWord_NeighboursDiffer;
var
  LIndex: UInt64;
begin
  for LIndex := 0 to 1000 do
    Assert.AreNotEqual(TTestFileHelpers.PatternWord(LIndex), TTestFileHelpers.PatternWord(LIndex + 1));
end;

procedure TTestFileHelpersTests.FillPattern_MatchesExpectedByte(const AOffset: UInt64; const ACount: Integer);
var
  LBuffer: TBytes;
  LIndex: Integer;
begin
  SetLength(LBuffer, ACount);
  TTestFileHelpers.FillPattern(AOffset, LBuffer[0], ACount);

  for LIndex := 0 to ACount - 1 do
    Assert.AreEqual(TTestFileHelpers.ExpectedByte(AOffset + UInt64(LIndex)), LBuffer[LIndex],
      Format('Byte at offset %d', [AOffset + UInt64(LIndex)]));
end;

procedure TTestFileHelpersTests.CheckPattern_AcceptsCorrectData;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  SetLength(LBuffer, 1000);
  TTestFileHelpers.FillPattern(3, LBuffer[0], Length(LBuffer));

  Assert.IsTrue(TTestFileHelpers.CheckPattern(3, LBuffer[0], Length(LBuffer), LBadOffset));
end;

procedure TTestFileHelpersTests.CheckPattern_DetectsShiftedData;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  // Data of offset 1 checked as if it came from offset 0: a classic off-by-one read
  SetLength(LBuffer, 64);
  TTestFileHelpers.FillPattern(1, LBuffer[0], Length(LBuffer));

  Assert.IsFalse(TTestFileHelpers.CheckPattern(0, LBuffer[0], Length(LBuffer), LBadOffset));
end;

procedure TTestFileHelpersTests.CheckPattern_ReportsFirstBadOffset;
var
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  SetLength(LBuffer, 100);
  TTestFileHelpers.FillPattern(1000, LBuffer[0], Length(LBuffer));
  LBuffer[42] := not LBuffer[42];

  Assert.IsFalse(TTestFileHelpers.CheckPattern(1000, LBuffer[0], Length(LBuffer), LBadOffset));
  Assert.AreEqual(UInt64(1042), LBadOffset);
end;

procedure TTestFileHelpersTests.CreatePatternFile_HasRightSizeAndContent(const ASize: Int64);
var
  LFileName: string;
  LStream: TFileStream;
  LBuffer: TBytes;
  LBadOffset: UInt64;
begin
  LFileName := TTestFileHelpers.CreatePatternFile(ASize);
  try
    LStream := TFileStream.Create(LFileName, fmOpenRead or fmShareDenyWrite);
    try
      Assert.AreEqual(ASize, LStream.Size);

      SetLength(LBuffer, ASize);
      if ASize > 0 then
      begin
        LStream.ReadBuffer(LBuffer[0], ASize);
        Assert.IsTrue(TTestFileHelpers.CheckPattern(0, LBuffer[0], ASize, LBadOffset),
          Format('First bad byte at offset %d', [LBadOffset]));
      end;
    finally
      LStream.Free;
    end;
  finally
    TTestFileHelpers.DeleteTestFile(LFileName);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TTestFileHelpersTests);

end.
