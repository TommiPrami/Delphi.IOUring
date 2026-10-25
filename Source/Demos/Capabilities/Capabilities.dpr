program Capabilities;

{
  What the I/O ring offers on this system: the API and its version, the
  system itself, the queue sizes, the operations, and the extras beyond what
  Windows and Linux have in common. Exit code 1 if the ring cannot be used
  here (the text then says why).
}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,          // Free Pascal on Linux: threads (the library uses them)
{$ENDIF}
  PIRUnit.IORing;

begin
  Writeln(IORingCapabilities.ToString);

  if not IORingAvailable then
    ExitCode := 1;
end.
