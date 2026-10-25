program Pascal.IOUring.UnitTests.FPC;

{
  Free Pascal test runner (FPCUnit, console), for Windows and Linux.

  The tests are the same units as for Delphi (Source\UnitTests\Common: the
  base class in PIRUnit.Test.Support hides the difference between FPCUnit and
  DUnitX). Linux-only tests are in Source\UnitTests\Linux; the Windows API
  tests run on Windows only.

  Build and run:  Source\Build-FPC.ps1 -Project Tests -Platform Win32 -Run
                  (Win64, or Linux64: built and run in WSL; on a Linux
                  machine: pwsh Source/Build-FPC.ps1 -Project Tests -Run)
  Prints what the system offers (IORingCapabilities), runs all tests, prints
  every test and failure, and exits with 1 if anything failed (a small runner
  of its own, so the exit code does not depend on the FPCUnit console
  runner's version).
}

{$I PIRInclude.Compiler.inc}

uses
{$IFDEF UNIX}
  cthreads,           // threads on Linux: must come first
{$ENDIF}
  SysUtils, Classes,
{$IFDEF UNIX}
  BaseUnix,
{$ENDIF}
  fpcunit, testregistry, PIRUnit.IORing, PIRUnit.Test.Support,
{$IFDEF MSWINDOWS}
  PIRUnit.Windows.API.Layout.Tests, PIRUnit.Windows.API.Tests,
{$ENDIF}
  PIRUnit.IORing.Tests, PIRUnit.SequentialReader.Tests, PIRUnit.Streams.Tests, PIRUnit.Atomics.Tests, PIRUnit.RequestPool.Tests, PIRUnit.RequestQueue.Tests, PIRUnit.Engine.Tests,
  PIRUnit.BlockReader.Tests, PIRUnit.EngineOverlap.Tests, PIRUnit.SequentialWriter.Tests,
{$IFDEF LINUX}
  PIRUnit.Linux.API.Layout.Tests, PIRUnit.Linux.API.Tests, PIRUnit.Linux.Extras.Tests,
{$ENDIF}
  PIRUnit.Test.FileHelpers.Tests;

type
  // TComponent: interface without reference counting, as TTestResult expects
  TConsoleListener = class(TComponent, ITestListener)
  private
    FTestFailed: Boolean;
  public
    procedure AddFailure(ATest: TTest; AFailure: TTestFailure);
    procedure AddError(ATest: TTest; AError: TTestFailure);
    procedure StartTest(ATest: TTest);
    procedure EndTest(ATest: TTest);
    procedure StartTestSuite(ATestSuite: TTestSuite);
    procedure EndTestSuite(ATestSuite: TTestSuite);
  end;

procedure TConsoleListener.AddFailure(ATest: TTest; AFailure: TTestFailure);
begin
  FTestFailed := True;
  Writeln('  FAILED: ', AFailure.ExceptionMessage);
end;

procedure TConsoleListener.AddError(ATest: TTest; AError: TTestFailure);
begin
  FTestFailed := True;
  Writeln('  ERROR: ', AError.ExceptionClassName, ': ', AError.ExceptionMessage);

  if AError.LocationInfo <> '' then
    Writeln('    at ', AError.LocationInfo);
end;

procedure TConsoleListener.StartTest(ATest: TTest);
begin
  FTestFailed := False;
  Writeln(ATest.TestSuiteName, '.', ATest.TestName);
end;

procedure TConsoleListener.EndTest(ATest: TTest);
begin
end;

procedure TConsoleListener.StartTestSuite(ATestSuite: TTestSuite);
begin
end;

procedure TConsoleListener.EndTestSuite(ATestSuite: TTestSuite);
begin
end;

{$IFDEF UNIX}
function KernelRelease: string;
var
  LName: UtsName;
begin
  if FpUname(LName) = 0 then
    Result := PChar(@LName.Release[0])
  else
    Result := '?';
end;
{$ENDIF}

var
  LResult: TTestResult;
  LListener: TConsoleListener;
begin
  Writeln('Pascal.IOUring tests (Free Pascal ', {$I %FPCVERSION%}, ', ', {$I %FPCTARGETCPU%}, '-',
    {$I %FPCTARGETOS%}, {$IFDEF UNIX}', kernel ', KernelRelease, {$ENDIF}')');
  Writeln;
  // What this system offers (in CI: what each runner has; the reason, if the ring is not available)
  Writeln(IORingCapabilities.ToString);
  Writeln;

  LResult := TTestResult.Create;
  LListener := TConsoleListener.Create(nil);
  try
    LResult.AddListener(LListener);
    GetTestRegistry.Run(LResult);

    Writeln;
    Writeln('Tests run: ', LResult.RunTests);
    Writeln('Failures:  ', LResult.NumberOfFailures);
    Writeln('Errors:    ', LResult.NumberOfErrors);

    if (LResult.NumberOfFailures > 0) or (LResult.NumberOfErrors > 0) then
      ExitCode := 1;
  finally
    LResult.Free;
    LListener.Free;
  end;
end.
