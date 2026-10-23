program Delphi.IOUring.UnitTests.FPC;

{
  Free Pascal test runner (FPCUnit, console).

  The Delphi tests use DUnitX, which Free Pascal cannot compile, so the FPC
  tests are separate units (Tests.FPC.*) that check the same things.
  The helpers TestFileHelpers and TestPlatformHelpers are shared.

  Build and run:  Source\Build-FPC.ps1 -Project Tests -Platform Win32 -Run
  Runs all tests, prints every test and failure, and exits with 1 if anything
  failed (a small runner of its own, so the exit code does not depend on the
  FPCUnit console runner's version).
}

{$I Delphi.IOUring.inc}

uses
  SysUtils,
  Classes,
  fpcunit,
  testregistry,
  Tests.FPC.Support,
  Tests.FPC.TestFileHelpers,
  Tests.FPC.Backend.Windows.API.Layout,
  Tests.FPC.Backend.Windows.API,
  Tests.FPC.Ring,
  Tests.FPC.SequentialReader,
  Tests.FPC.Streams,
  Tests.FPC.Atomics,
  Tests.FPC.RequestPool,
  Tests.FPC.RequestQueue,
  Tests.FPC.Engine;

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

var
  LResult: TTestResult;
  LListener: TConsoleListener;
begin
  Writeln('Delphi.IOUring tests (Free Pascal ', {$I %FPCVERSION%}, ', ', {$I %FPCTARGETCPU%}, ')');
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
