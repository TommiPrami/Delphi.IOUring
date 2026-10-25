unit PIRUnit.Demo.Common;

{
  Small helpers of the demos: a temporary test file and a clock. Nothing here
  uses PIRUnit.IORing - the demos show the library, this only sets the stage.
}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

  // <temp folder>/Pascal.IOUring.Demo.<AName>
  function DemoFileName(const AName: string): string;

  // Writes ASize bytes of changing data into AFileName (an existing file is replaced), with a plain TFileStream
  procedure CreateDemoFile(const AFileName: string; const ASize: Int64);

  // The size of a file in bytes
  function DemoFileSize(const AFileName: string): Int64;

  // Milliseconds from some fixed point in time (for measuring)
  function DemoMilliseconds: UInt64;

  // "123.4 MiB/s" (or "-" if no time has passed)
  function MiBPerSecond(const ABytes: Int64; const AMilliseconds: UInt64): string;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.IOUtils;
{$ENDIF}

function DemoFileName(const AName: string): string;
begin
{$IFDEF FPC}
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'Pascal.IOUring.Demo.' + AName;
{$ELSE}
  Result := TPath.Combine(TPath.GetTempPath, 'Pascal.IOUring.Demo.' + AName);
{$ENDIF}
end;

procedure CreateDemoFile(const AFileName: string; const ASize: Int64);
const
  CHUNK = 1024 * 1024;
var
  LStream: TFileStream;
  LBuffer: TBytes;
  LValue: Cardinal;
  LIndex: Integer;
  LLeft: Int64;
  LCount: Integer;
begin
  SetLength(LBuffer, CHUNK);
  LValue := 1;
  LStream := TFileStream.Create(AFileName, fmCreate);
  try
    LLeft := ASize;

    while LLeft > 0 do
    begin
      // xorshift: bytes that change all the time, so a wrong offset shows
      for LIndex := 0 to CHUNK - 1 do
      begin
        LValue := LValue xor (LValue shl 13);
        LValue := LValue xor (LValue shr 17);
        LValue := LValue xor (LValue shl 5);
        LBuffer[LIndex] := Byte(LValue);
      end;

      if LLeft < CHUNK then
        LCount := LLeft
      else
        LCount := CHUNK;

      LStream.WriteBuffer(LBuffer[0], LCount);
      Dec(LLeft, LCount);
    end;
  finally
    LStream.Free;
  end;
end;

function DemoFileSize(const AFileName: string): Int64;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Result := LStream.Size;
  finally
    LStream.Free;
  end;
end;

function DemoMilliseconds: UInt64;
begin
  Result := TThread.GetTickCount64;
end;

function MiBPerSecond(const ABytes: Int64; const AMilliseconds: UInt64): string;
begin
  if AMilliseconds = 0 then
    Result := '-'
  else
    Result := FormatFloat('0.0', ABytes / (1024 * 1024) / (AMilliseconds / 1000)) + ' MiB/s';
end;

end.
