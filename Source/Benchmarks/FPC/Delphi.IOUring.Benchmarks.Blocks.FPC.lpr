program Delphi.IOUring.Benchmarks.Blocks.FPC;

{
  Free Pascal build of the "blocks known in advance" benchmark: the same code
  as the Delphi one (Bench.Blocks). What is measured, and the options: see
  Bench.Blocks.

  Build and run: Source\Build-FPC.ps1 -Project Blocks -Platform Win64 -Run
                 (Win32, or Linux64: built and run in WSL)
}

{$I Delphi.IOUring.inc}

uses
{$IFDEF UNIX}
  cthreads,           // threads on Linux: must come first
{$ENDIF}
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
