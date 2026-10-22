// Delphi.IOUring.inc - shared compiler switches.
//
// Included by every unit of the library, right after the "unit" line:
//
//   unit Delphi.IOUring.Something;
//
//   {$I Delphi.IOUring.inc}
//
// Keep this file small. Only switches that every unit needs belong here.

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MODESWITCH ADVANCEDRECORDS}
{$ENDIF}

{$SCOPEDENUMS OFF}
