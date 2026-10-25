program Pascal.IOUring.UnitTests;

{$IFNDEF TESTINSIGHT}
{$APPTYPE CONSOLE}
{$ENDIF}
{$STRONGLINKTYPES ON}
{$WARN SYMBOL_PLATFORM OFF} // DebugHook; the test runner is Windows-only

uses
  System.SysUtils,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ELSE}
  DUnitX.Loggers.Console, DUnitX.Loggers.Xml.NUnit,
  {$ENDIF}
  DUnitX.TestFramework, Pascal.IOUring.Backend.Windows.API in '..\Units\Pascal.IOUring.Backend.Windows.API.pas',
  Pascal.IOUring.Types in '..\Units\Pascal.IOUring.Types.pas',
  Pascal.IOUring.Backend.Windows in '..\Units\Pascal.IOUring.Backend.Windows.pas',
  Pascal.IOUring.Backend.Windows.Platform in '..\Units\Pascal.IOUring.Backend.Windows.Platform.pas',
  Pascal.IOUring in '..\Units\Pascal.IOUring.pas',
  Pascal.IOUring.SequentialReader in '..\Units\Pascal.IOUring.SequentialReader.pas',
  Pascal.IOUring.Streams in '..\Units\Pascal.IOUring.Streams.pas',
  Pascal.IOUring.SequentialWriter in '..\Units\Pascal.IOUring.SequentialWriter.pas',
  Pascal.IOUring.Atomics in '..\Units\Pascal.IOUring.Atomics.pas',
  Pascal.IOUring.RequestPool in '..\Units\Pascal.IOUring.RequestPool.pas',
  Pascal.IOUring.RequestQueue in '..\Units\Pascal.IOUring.RequestQueue.pas',
  Pascal.IOUring.Engine in '..\Units\Pascal.IOUring.Engine.pas',
  Pascal.IOUring.BlockReader in '..\Units\Pascal.IOUring.BlockReader.pas',
  TestFileHelpers in 'Common\TestFileHelpers.pas', TestPlatformHelpers in 'Common\TestPlatformHelpers.pas',
  Tests.Support in 'Common\Tests.Support.pas', Tests.TestFileHelpers in 'Common\Tests.TestFileHelpers.pas',
  Tests.Backend.Windows.API.Layout in 'Common\Tests.Backend.Windows.API.Layout.pas',
  Tests.Backend.Windows.API in 'Common\Tests.Backend.Windows.API.pas', Tests.Ring in 'Common\Tests.Ring.pas',
  Tests.SequentialReader in 'Common\Tests.SequentialReader.pas', Tests.Streams in 'Common\Tests.Streams.pas',
  Tests.Atomics in 'Common\Tests.Atomics.pas', Tests.RequestPool in 'Common\Tests.RequestPool.pas',
  Tests.RequestQueue in 'Common\Tests.RequestQueue.pas', Tests.Engine in 'Common\Tests.Engine.pas',
  Tests.BlockReader in 'Common\Tests.BlockReader.pas', Tests.EngineOverlap in 'Common\Tests.EngineOverlap.pas',
  Tests.SequentialWriter in 'Common\Tests.SequentialWriter.pas';

{$IFNDEF TESTINSIGHT}
var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
  LNUnitLogger: ITestLogger;
{$ENDIF}
begin
  ReportMemoryLeaksOnShutdown := True;
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
{$ELSE}
  try
    // Exits if the command line is invalid
    TDUnitX.CheckCommandLine;

    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI := True;
    LRunner.FailsOnNoAsserts := True;

    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      LLogger := TDUnitXConsoleLogger.Create(TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      LRunner.AddLogger(LLogger);
    end;

    // NUnit compatible XML, for CI later
    LNUnitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    LRunner.AddLogger(LNUnitLogger);

    LResults := LRunner.Execute;
    System.ExitCode := TDUnitX.ExitCodeFor(LResults);

    // Keep the console open when started from the IDE debugger, or with --exit:Pause
    if (DebugHook <> 0) or (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := EXIT_ERRORS;
    end;
  end;
{$ENDIF}
end.
