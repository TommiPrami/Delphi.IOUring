program Delphi.IOUring.Benchmarks.Writes;

{
  Writing a file front to back: TSequentialWriteOnlyFileStream against
  TFileStream and TBufferedFileStream (Docs/Plan.md, Phase 17). What is
  measured, and the options: see Bench.Writes.

  Delphi.IOUring.Benchmarks.Writes [--dir <folder>] [--sizes <GiB,...>] [--runs <n>] [--work-us <n>] [--csv <file>]
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Bench.Common in 'Bench.Common.pas',
  Bench.Writes in 'Bench.Writes.pas';

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
