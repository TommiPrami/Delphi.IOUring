unit Tests.FPC.Support;

{
  Shared pieces of the Free Pascal tests: a test case base class with a few
  helpers, and pattern files that are created once and deleted at the end.
}

{$I Delphi.IOUring.inc}

interface

uses
  SysUtils,
  Classes,
  fpcunit;

type
  // Writes one byte to a pipe after a delay (FPC 3.2.2 has no anonymous
  // methods for TThread.CreateAnonymousThread). Create, then Start; WaitFor
  // and Free when done.
  TDelayedPipeWriter = class(TThread)
  private
    FPipe: THandle;
    FDelayMilliseconds: Cardinal;
    FValue: Byte;
  protected
    procedure Execute; override;
  public
    constructor Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
  end;

  TIORingTestCase = class(TTestCase)
  protected
    // Prints a line between the test results (findings worth seeing)
    procedure Log(const AText: string);
    // Fails if ABuffer does not hold the pattern bytes of the file offsets
    procedure CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
      const AContext: string = '');
    procedure CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
  end;

// A pattern file of ASize bytes; created on first use, deleted when the
// program ends
function SharedPatternFile(const ASize: Int64): string;

implementation

uses
  TestFileHelpers,
  TestPlatformHelpers;

{ TDelayedPipeWriter }

constructor TDelayedPipeWriter.Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
begin
  FPipe := APipe;
  FDelayMilliseconds := ADelayMilliseconds;
  FValue := AValue;
  inherited Create(True);
end;

procedure TDelayedPipeWriter.Execute;
begin
  Sleep(FDelayMilliseconds);
  WriteByteToPipe(FPipe, FValue);
end;

var
  GSharedSizes: array of Int64;
  GSharedFiles: array of string;

{ TIORingTestCase }

procedure TIORingTestCase.Log(const AText: string);
begin
  Writeln('    ', AText);
end;

procedure TIORingTestCase.CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
  const AContext: string);
var
  LBadOffset: UInt64;
begin
  if not TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset) then
    Fail(Format('%s: wrong data at file offset %d', [AContext, LBadOffset]));
end;

procedure TIORingTestCase.CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
begin
  if AExpected <> AActual then
    Fail(Format('%s: expected %d but was %d', [AMessage, AExpected, AActual]));
end;

function SharedPatternFile(const ASize: Int64): string;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(GSharedSizes) do
    if GSharedSizes[LIndex] = ASize then
      Exit(GSharedFiles[LIndex]);

  Result := TTestFileHelpers.CreatePatternFile(ASize, 'FpcPattern');
  SetLength(GSharedSizes, Length(GSharedSizes) + 1);
  SetLength(GSharedFiles, Length(GSharedFiles) + 1);
  GSharedSizes[High(GSharedSizes)] := ASize;
  GSharedFiles[High(GSharedFiles)] := Result;
end;

procedure DeleteSharedFiles;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(GSharedFiles) do
    TTestFileHelpers.DeleteTestFile(GSharedFiles[LIndex]);
  GSharedFiles := nil;
  GSharedSizes := nil;
end;

finalization
  DeleteSharedFiles;

end.
