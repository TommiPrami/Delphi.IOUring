program Pascal.IOUring.Benchmarks.Structures;

{
  The engine's lock-free structures against the same structures behind a
  lock (Docs/Design.md §10.5). What is measured, and the options: see
  Bench.Structures.

  Pascal.IOUring.Benchmarks.Structures [--runs <n>] [--threads <list>] [--csv <file>]
}

{$APPTYPE CONSOLE}

uses
  System.SysUtils, Bench.Common in 'Bench.Common.pas', Bench.Structures in 'Bench.Structures.pas';

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
