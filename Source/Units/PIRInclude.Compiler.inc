(*
  PIRInclude.Compiler.inc - shared compiler switches.

  Included by every unit of the library, right after the "unit" line:

    unit PIRUnit.Something;

    {$I PIRInclude.Compiler.inc}

  Keep this file small. Only switches that every unit needs belong here.
*)

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MODESWITCH ADVANCEDRECORDS}
  (*
    Debug builds: no inlining, so that the debugger can step into every routine. Build-FPC.ps1 defines IORING_NO_INLINE
    unless -Optimize is given. (FPC's -Si- does not help: {$MODE DELPHI} above turns inlining on again.) Delphi: the
    Debug configurations set "inlining off".
  *)
  {$IFDEF IORING_NO_INLINE}
    {$INLINE OFF}
  {$ENDIF}
{$ENDIF}

{$SCOPEDENUMS OFF}
