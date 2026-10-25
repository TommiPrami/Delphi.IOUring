program Pascal.IOUring.Benchmarks.Structures.FPC;

{
  Free Pascal build of the engine structure benchmark: the same code as the
  Delphi one (PIRUnit.Benchmark.Structures). What is measured, and the options: see
  PIRUnit.Benchmark.Structures.

  Build and run: Source\Build-FPC.ps1 -Project Structures -Platform Win64 -Run
                 (Win32, or Linux64: built and run in WSL)
}

{$I PIRInclude.Compiler.inc}

uses
{$IFDEF UNIX}
  cthreads,           // threads on Linux: must come first
{$ENDIF}
  SysUtils, PIRUnit.Benchmark.Structures;

begin
  try
    RunStructureBenchmarks;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
