program Pascal.IOUring.Benchmarks.Writes;

{
  Writing a file front to back: TSequentialWriteOnlyFileStream against
  TFileStream and TBufferedFileStream (Docs/Plan.md, Phase 17). What is
  measured, and the options: see PIRUnit.Benchmark.Writes.

  Pascal.IOUring.Benchmarks.Writes [--dir <folder>] [--sizes <GiB,...>] [--runs <n>] [--work-us <n>] [--csv <file>]
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils, PIRUnit.Benchmark.Common in '..\PIRUnit.Benchmark.Common.pas', PIRUnit.Benchmark.Writes in '..\PIRUnit.Benchmark.Writes.pas';

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
