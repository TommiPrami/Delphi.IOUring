program CopyFile;

{
  Copies a file with the two streams of the library, then compares the copy
  with the original.

    CopyFile <source> <target>

  Without arguments it copies a temporary file of 64 MiB, compares and
  deletes both.

  TSequentialReadOnlyFileStream reads ahead in the background, and
  TSequentialWriteOnlyFileStream writes behind in the background, so the
  copying code itself is the usual TStream code: CopyFrom.
}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,          // Free Pascal on Linux: threads (the library uses them)
{$ENDIF}
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.Streams, PIRUnit.Demo.Common in '..\Common\PIRUnit.Demo.Common.pas';

procedure CopyWithStreams(const ASource, ATarget: string);
var
  LSource: TSequentialReadOnlyFileStream;
  LTarget: TSequentialWriteOnlyFileStream;
begin
  LSource := TSequentialReadOnlyFileStream.Create(ASource);
  try
    LTarget := TSequentialWriteOnlyFileStream.Create(ATarget);   // creates or empties the file
    try
      LTarget.CopyFrom(LSource, 0);      // 0: the whole stream, as with any TStream
    finally
      LTarget.Free;                      // waits for the last writes (raises if one failed)
    end;
  finally
    LSource.Free;
  end;
end;

// The same bytes in both files? Plain TFileStream: this is only the check.
function SameContent(const AFileName1, AFileName2: string): Boolean;
const
  CHUNK = 1024 * 1024;
var
  LStream1: TFileStream;
  LStream2: TFileStream;
  LBuffer1: TBytes;
  LBuffer2: TBytes;
  LRead: Integer;
begin
  SetLength(LBuffer1, CHUNK);
  SetLength(LBuffer2, CHUNK);
  LStream1 := TFileStream.Create(AFileName1, fmOpenRead or fmShareDenyWrite);
  try
    LStream2 := TFileStream.Create(AFileName2, fmOpenRead or fmShareDenyWrite);
    try
      Result := LStream1.Size = LStream2.Size;

      while Result do
      begin
        LRead := LStream1.Read(LBuffer1[0], CHUNK);

        if LRead = 0 then
          Break;

        LStream2.ReadBuffer(LBuffer2[0], LRead);
        Result := CompareMem(@LBuffer1[0], @LBuffer2[0], LRead);
      end;
    finally
      LStream2.Free;
    end;
  finally
    LStream1.Free;
  end;
end;

var
  LSource: string;
  LTarget: string;
  LTemporary: Boolean;
  LStart: UInt64;
  LMilliseconds: UInt64;
  LSize: Int64;
begin
  try
    LTemporary := ParamCount = 0;

    if LTemporary then
    begin
      LSource := DemoFileName('CopyFile.source');
      LTarget := DemoFileName('CopyFile.target');
      CreateDemoFile(LSource, 64 * 1024 * 1024);
    end
    else if ParamCount = 2 then
    begin
      LSource := ParamStr(1);
      LTarget := ParamStr(2);
    end
    else
    begin
      Writeln('Usage: CopyFile <source> <target>   (no arguments: a temporary file)');
      ExitCode := 2;

      Exit;
    end;

    try
      LStart := DemoMilliseconds;
      CopyWithStreams(LSource, LTarget);
      LMilliseconds := DemoMilliseconds - LStart;
      LSize := DemoFileSize(LSource);
      Writeln(Format('Copied %s to %s: %d bytes in %d ms (%s)',
        [LSource, LTarget, LSize, LMilliseconds, MiBPerSecond(LSize, LMilliseconds)]));

      if SameContent(LSource, LTarget) then
        Writeln('The copy has the same content.')
      else
      begin
        Writeln('The copy differs from the original!');
        ExitCode := 1;
      end;
    finally
      if LTemporary then
      begin
        DeleteFile(LSource);
        DeleteFile(LTarget);
      end;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
