program Pascal.IOUring.Benchmarks.Blocks;

{
  Reading blocks that are known in advance: TIORingBlockReader against
  TFileStream + Seek and positioned ReadFile (Docs/Plan.md, Phase 14). What
  is measured, and the options: see PIRUnit.Benchmark.Blocks.

  Pascal.IOUring.Benchmarks.Blocks [--dir <folder>] [--size-gib <n>] [--blocks <n>] [--runs <n>] [--csv <file>] [--keep]
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PIRUnit.Benchmark.Common in '..\PIRUnit.Benchmark.Common.pas', PIRUnit.Benchmark.Blocks in '..\PIRUnit.Benchmark.Blocks.pas';

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
