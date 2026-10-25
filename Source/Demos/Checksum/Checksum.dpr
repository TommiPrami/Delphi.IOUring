program Checksum;

{
  The Adler-32 checksum of a file (as zlib computes it), read with the
  zero-copy reader TIORingSequentialReader: the checksum is computed right in
  the reader's buffers, while the next buffers are being read.

    Checksum [<file>] [--unbuffered]

  Without a file name it uses a temporary file of 64 MiB and deletes it
  afterwards. --unbuffered reads past the file cache. For comparison the same
  checksum is computed once more with a plain TFileStream.
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
  PIRUnit.SequentialReader, PIRUnit.Demo.Common in '..\Common\PIRUnit.Demo.Common.pas';

type
  TAdler32 = record
    A: Cardinal;
    B: Cardinal;
    procedure Init;
    procedure Add(AData: PByte; ALength: NativeInt);
    function Value: Cardinal;
  end;

procedure TAdler32.Init;
begin
  A := 1;
  B := 0;
end;

procedure TAdler32.Add(AData: PByte; ALength: NativeInt);
const
  MOD_ADLER = 65521;
  // The most bytes that can be added before B could overflow 32 bits
  NMAX = 5552;
var
  LCount: NativeInt;
begin
  while ALength > 0 do
  begin
    LCount := ALength;

    if LCount > NMAX then
      LCount := NMAX;

    Dec(ALength, LCount);

    while LCount > 0 do
    begin
      Inc(A, AData^);
      Inc(B, A);
      Inc(AData);
      Dec(LCount);
    end;

    A := A mod MOD_ADLER;
    B := B mod MOD_ADLER;
  end;
end;

function TAdler32.Value: Cardinal;
begin
  Result := (B shl 16) or A;
end;

{ The library's way: the reader hands out its own buffers (no copy) in file order; give each one back with ReleaseChunk
  so it can be read into again }
function ChecksumWithReader(const AFileName: string; const AUnbuffered: Boolean;
  out ABytes: Int64; out AStalls: UInt64): Cardinal;
var
  LReader: TIORingSequentialReader;    // a record: closed at the end of the scope
  LOptions: TIORingSequentialReaderOptions;
  LData: PByte;
  LLength: NativeInt;
  LAdler: TAdler32;
begin
  LOptions := [];

  if AUnbuffered then
    Include(LOptions, sroUnbuffered);

  LAdler.Init;
  ABytes := 0;
  LReader.Open(AFileName, LOptions);   // default: 8 buffers of 1 MiB

  while LReader.TryAcquireChunk(LData, LLength) do
  begin
    LAdler.Add(LData, LLength);
    Inc(ABytes, LLength);
    LReader.ReleaseChunk;
  end;

  // How often the checksum had to wait for data
  AStalls := LReader.Stats.Stalls;

  Result := LAdler.Value;
end;

// The usual way, for comparison
function ChecksumWithFileStream(const AFileName: string): Cardinal;
const
  CHUNK = 1024 * 1024;
var
  LStream: TFileStream;
  LBuffer: TBytes;
  LRead: Integer;
  LAdler: TAdler32;
begin
  SetLength(LBuffer, CHUNK);
  LAdler.Init;
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    repeat
      LRead := LStream.Read(LBuffer[0], CHUNK);
      LAdler.Add(@LBuffer[0], LRead);
    until LRead = 0;
  finally
    LStream.Free;
  end;

  Result := LAdler.Value;
end;

var
  LFileName: string;
  LTemporary: Boolean;
  LUnbuffered: Boolean;
  LIndex: Integer;
  LStart: UInt64;
  LMilliseconds: UInt64;
  LBytes: Int64;
  LStalls: UInt64;
  LReaderSum: Cardinal;
  LStreamSum: Cardinal;
begin
  try
    LFileName := '';
    LUnbuffered := False;

    for LIndex := 1 to ParamCount do
      if ParamStr(LIndex) = '--unbuffered' then
        LUnbuffered := True
      else
        LFileName := ParamStr(LIndex);

    LTemporary := LFileName = '';

    if LTemporary then
    begin
      LFileName := DemoFileName('Checksum.dat');
      CreateDemoFile(LFileName, 64 * 1024 * 1024);
    end;

    try
      LStart := DemoMilliseconds;
      LReaderSum := ChecksumWithReader(LFileName, LUnbuffered, LBytes, LStalls);
      LMilliseconds := DemoMilliseconds - LStart;
      Writeln(Format('Adler-32 of %s: %.8x', [LFileName, LReaderSum]));
      Writeln(Format('Zero-copy reader: %d bytes in %d ms (%s), waited for data %d times',
        [LBytes, LMilliseconds, MiBPerSecond(LBytes, LMilliseconds), LStalls]));

      LStart := DemoMilliseconds;
      LStreamSum := ChecksumWithFileStream(LFileName);
      LMilliseconds := DemoMilliseconds - LStart;
      Writeln(Format('TFileStream:      the same %d bytes in %d ms (%s)',
        [LBytes, LMilliseconds, MiBPerSecond(LBytes, LMilliseconds)]));

      if LStreamSum <> LReaderSum then
      begin
        Writeln(Format('Different checksums: %.8x with TFileStream!', [LStreamSum]));
        ExitCode := 1;
      end;
    finally
      if LTemporary then
        DeleteFile(LFileName);
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
