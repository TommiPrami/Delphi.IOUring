unit Tests.Linux.Backend.Posix.API.Layout;

{
  The translation Delphi.IOUring.Backend.Posix.API against the C header
  linux/io_uring.h: every record size, field offset and constant value must
  be the one of C.

  The checks are generated: Generate-PosixApiLayout.sh builds a C program
  with gcc, which writes them into Tests.Linux.Backend.Posix.API.Layout.inc
  with the C values. A name the Pascal unit does not have does not compile.
  Each test lists all mismatches at once.
}

{$I Delphi.IOUring.inc}

interface

uses
  Tests.Support;

type
  TPosixApiLayoutTests = class(TIORingTestCase)
  private
    FMismatches: string;
    FChecks: Integer;
    procedure CheckLayout(const AName: string; const AExpected, AActual: Int64);
    procedure CheckNoMismatches;
  protected
    procedure SetUp; override;
  published
    procedure Sizes;
    procedure Offsets;
    procedure Constants;
  end;

implementation

uses
  SysUtils,
  Delphi.IOUring.Backend.Posix.API;

type
  TLayoutCheck = procedure(const AName: string; const AExpected, AActual: Int64) of object;

// The offset of a field: OffsetOf(@P<record>(nil)^.<field>)
function OffsetOf(const AField: Pointer): Int64;
begin
  Result := PByte(AField) - PByte(nil);
end;

{$I Tests.Linux.Backend.Posix.API.Layout.inc}

procedure TPosixApiLayoutTests.SetUp;
begin
  inherited;
  FMismatches := '';
  FChecks := 0;
end;

procedure TPosixApiLayoutTests.CheckLayout(const AName: string; const AExpected, AActual: Int64);
begin
  Inc(FChecks);
  if AActual <> AExpected then
    FMismatches := FMismatches + Format('%s  %s: C %d, Pascal %d', [LineEnding, AName, AExpected, AActual]);
end;

procedure TPosixApiLayoutTests.CheckNoMismatches;
begin
  AssertTrue('No checks', FChecks > 0);
  if FMismatches <> '' then
    Fail('Differs from the C header:' + FMismatches);
end;

procedure TPosixApiLayoutTests.Sizes;
begin
  CheckSizes(CheckLayout);
  CheckNoMismatches;
end;

procedure TPosixApiLayoutTests.Offsets;
begin
  CheckOffsets(CheckLayout);
  CheckNoMismatches;
end;

procedure TPosixApiLayoutTests.Constants;
begin
  CheckConstants(CheckLayout);
  CheckNoMismatches;
end;

initialization
  RegisterTests(TPosixApiLayoutTests);

end.
