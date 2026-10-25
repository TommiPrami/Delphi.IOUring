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
  DUnitX.TestFramework, PIRUnit.Windows.API in '..\..\Units\PIRUnit.Windows.API.pas',
  PIRUnit.Types in '..\..\Units\PIRUnit.Types.pas',
  PIRUnit.Windows.Ring in '..\..\Units\PIRUnit.Windows.Ring.pas',
  PIRUnit.Windows.Platform in '..\..\Units\PIRUnit.Windows.Platform.pas',
  PIRUnit.IORing in '..\..\Units\PIRUnit.IORing.pas',
  PIRUnit.SequentialReader in '..\..\Units\PIRUnit.SequentialReader.pas',
  PIRUnit.Streams in '..\..\Units\PIRUnit.Streams.pas',
  PIRUnit.SequentialWriter in '..\..\Units\PIRUnit.SequentialWriter.pas',
  PIRUnit.Atomics in '..\..\Units\PIRUnit.Atomics.pas',
  PIRUnit.RequestPool in '..\..\Units\PIRUnit.RequestPool.pas',
  PIRUnit.RequestQueue in '..\..\Units\PIRUnit.RequestQueue.pas',
  PIRUnit.Engine in '..\..\Units\PIRUnit.Engine.pas',
  PIRUnit.BlockReader in '..\..\Units\PIRUnit.BlockReader.pas',
  PIRUnit.Test.FileHelpers in '..\Common\PIRUnit.Test.FileHelpers.pas', PIRUnit.Test.PlatformHelpers in '..\Common\PIRUnit.Test.PlatformHelpers.pas',
  PIRUnit.Test.Support in '..\Common\PIRUnit.Test.Support.pas', PIRUnit.Test.FileHelpers.Tests in '..\Common\PIRUnit.Test.FileHelpers.Tests.pas',
  PIRUnit.Windows.API.Layout.Tests in '..\Common\PIRUnit.Windows.API.Layout.Tests.pas',
  PIRUnit.Windows.API.Tests in '..\Common\PIRUnit.Windows.API.Tests.pas', PIRUnit.IORing.Tests in '..\Common\PIRUnit.IORing.Tests.pas',
  PIRUnit.SequentialReader.Tests in '..\Common\PIRUnit.SequentialReader.Tests.pas', PIRUnit.Streams.Tests in '..\Common\PIRUnit.Streams.Tests.pas',
  PIRUnit.Atomics.Tests in '..\Common\PIRUnit.Atomics.Tests.pas', PIRUnit.RequestPool.Tests in '..\Common\PIRUnit.RequestPool.Tests.pas',
  PIRUnit.RequestQueue.Tests in '..\Common\PIRUnit.RequestQueue.Tests.pas', PIRUnit.Engine.Tests in '..\Common\PIRUnit.Engine.Tests.pas',
  PIRUnit.BlockReader.Tests in '..\Common\PIRUnit.BlockReader.Tests.pas', PIRUnit.EngineOverlap.Tests in '..\Common\PIRUnit.EngineOverlap.Tests.pas',
  PIRUnit.SequentialWriter.Tests in '..\Common\PIRUnit.SequentialWriter.Tests.pas';

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
