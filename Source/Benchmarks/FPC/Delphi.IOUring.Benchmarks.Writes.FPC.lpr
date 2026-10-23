program Delphi.IOUring.Benchmarks.Writes.FPC;

{
  Free Pascal build of the write benchmark: the same code as the Delphi one
  (Bench.Writes). What is measured, and the options: see Bench.Writes.

  Build and run: Source\Build-FPC.ps1 -Project Writes -Platform Win64 -Run
}

{$I Delphi.IOUring.inc}

uses
  SysUtils,
  Bench.Writes;

begin
  try
    RunWriteBenchmarks;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
