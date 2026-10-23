program Delphi.IOUring.Benchmarks.Blocks.FPC;

{
  Free Pascal build of the "blocks known in advance" benchmark: the same code
  as the Delphi one (Bench.Blocks). What is measured, and the options: see
  Bench.Blocks.

  Build and run: Source\Build-FPC.ps1 -Project Blocks -Platform Win64 -Run
}

{$I Delphi.IOUring.inc}

uses
  SysUtils,
  Bench.Blocks;

begin
  try
    RunBlockBenchmarks;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
