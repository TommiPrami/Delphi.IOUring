unit PIRUnit.Linux.API.Layout.Tests;

{
  The translation PIRUnit.Linux.API against the C header
  linux/io_uring.h: every record size, field offset and constant value must
  be the one of C.

  The checks are generated: Generate-LinuxApiLayout.sh builds a C program
  with gcc, which writes them into PIRInclude.Linux.API.Layout.inc
  with the C values. A name the Pascal unit does not have does not compile.
  Each test lists all mismatches at once.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Test.Support;

type
  TLinuxApiLayoutTests = class(TIORingTestCase)
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
  SysUtils, PIRUnit.Linux.API;

type
  TLayoutCheck = procedure(const AName: string; const AExpected, AActual: Int64) of object;

// The offset of a field: OffsetOf(@P<record>(nil)^.<field>)
function OffsetOf(const AField: Pointer): Int64;
begin
  Result := PByte(AField) - PByte(nil);
end;

{$I PIRInclude.Linux.API.Layout.inc}

procedure TLinuxApiLayoutTests.SetUp;
begin
  inherited SetUp;

  FMismatches := '';
  FChecks := 0;
end;

procedure TLinuxApiLayoutTests.CheckLayout(const AName: string; const AExpected, AActual: Int64);
begin
  Inc(FChecks);

  if AActual <> AExpected then
    FMismatches := FMismatches + Format('%s  %s: C %d, Pascal %d', [LineEnding, AName, AExpected, AActual]);
end;

procedure TLinuxApiLayoutTests.CheckNoMismatches;
begin
  AssertTrue('No checks', FChecks > 0);

  if FMismatches <> '' then
    Fail('Differs from the C header:' + FMismatches);
end;

procedure TLinuxApiLayoutTests.Sizes;
begin
  CheckSizes(CheckLayout);
  CheckNoMismatches;
end;

procedure TLinuxApiLayoutTests.Offsets;
begin
  CheckOffsets(CheckLayout);
  CheckNoMismatches;
end;

procedure TLinuxApiLayoutTests.Constants;
begin
  CheckConstants(CheckLayout);
  CheckNoMismatches;
end;

initialization
  RegisterTests(TLinuxApiLayoutTests);

end.
