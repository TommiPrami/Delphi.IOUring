unit PIRUnit.Test.FileHelpers;

{
  Deterministic test files.

  Every 8-byte word of a pattern file is a 64-bit hash of its word index
  (SplitMix64 finalizer, little-endian). So the expected content at any file
  offset can be computed without keeping a copy of the file, and data read
  from a wrong offset is detected (each word is different).

  No test framework and no operating system dependency: used by all tests
  (Delphi, Free Pascal on Windows and Linux).
}

{$I PIRInclude.Compiler.inc}

interface

type
  TTestFileHelpers = record
  public
    class function PatternWord(const AWordIndex: UInt64): UInt64; static;
    class function ExpectedByte(const AOffset: UInt64): Byte; static;

    // Fills ABuffer with the pattern bytes of file offsets AOffset .. AOffset + ACount - 1
    class procedure FillPattern(const AOffset: UInt64; var ABuffer; const ACount: NativeInt); static;

    { True if ABuffer holds the pattern bytes of AOffset .. AOffset + ACount - 1. On mismatch AFirstBadOffset is the
      file offset of the first wrong byte. }
    class function CheckPattern(const AOffset: UInt64; const ABuffer; const ACount: NativeInt;
      out AFirstBadOffset: UInt64): Boolean; static;

    // Folder for test files: <temp>\Pascal.IOUring.Tests\ (created if missing)
    class function TestFolder: string; static;

    // Unique file name in TestFolder (the file is not created)
    class function NewTestFileName(const APrefix: string): string; static;

    // Creates a pattern file of ASize bytes and returns its full name
    class function CreatePatternFile(const ASize: Int64; const APrefix: string = 'Pattern'): string; static;

    // Deletes the file if it exists; never raises
    class procedure DeleteTestFile(const AFileName: string); static;
  end;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes;
{$ELSE}
  System.SysUtils, System.Classes, System.IOUtils;
{$ENDIF}

{$Q-} // the hash relies on wrap-around multiplication
{$R-}

const
  CREATE_CHUNK_SIZE = 1024 * 1024;

class function TTestFileHelpers.PatternWord(const AWordIndex: UInt64): UInt64;
var
  LValue: UInt64;
begin
  LValue := AWordIndex * UInt64($9E3779B97F4A7C15);
  LValue := (LValue xor (LValue shr 30)) * UInt64($BF58476D1CE4E5B9);
  LValue := (LValue xor (LValue shr 27)) * UInt64($94D049BB133111EB);

  Result := LValue xor (LValue shr 31);
end;

class function TTestFileHelpers.ExpectedByte(const AOffset: UInt64): Byte;
begin
  Result := Byte(PatternWord(AOffset shr 3) shr ((AOffset and 7) * 8));
end;

class procedure TTestFileHelpers.FillPattern(const AOffset: UInt64; var ABuffer; const ACount: NativeInt);
var
  LTarget: PByte;
  LOffset: UInt64;
  LRemaining: NativeInt;
  LWord: UInt64;
begin
  LTarget := @ABuffer;
  LOffset := AOffset;
  LRemaining := ACount;

  // Leading bytes until the file offset is 8-byte aligned
  while (LRemaining > 0) and ((LOffset and 7) <> 0) do
  begin
    LTarget^ := ExpectedByte(LOffset);
    Inc(LTarget);
    Inc(LOffset);
    Dec(LRemaining);
  end;

  // Whole words
  while LRemaining >= 8 do
  begin
    LWord := PatternWord(LOffset shr 3);
    Move(LWord, LTarget^, 8);
    Inc(LTarget, 8);
    Inc(LOffset, 8);
    Dec(LRemaining, 8);
  end;

  // Trailing bytes
  while LRemaining > 0 do
  begin
    LTarget^ := ExpectedByte(LOffset);
    Inc(LTarget);
    Inc(LOffset);
    Dec(LRemaining);
  end;
end;

class function TTestFileHelpers.CheckPattern(const AOffset: UInt64; const ABuffer; const ACount: NativeInt;
  out AFirstBadOffset: UInt64): Boolean;
var
  LSource: PByte;
  LOffset: UInt64;
  LRemaining: NativeInt;
  LWord: UInt64;
  LActual: UInt64;
begin
  LSource := @ABuffer;
  LOffset := AOffset;
  LRemaining := ACount;
  AFirstBadOffset := 0;

  while LRemaining > 0 do
  begin
    if ((LOffset and 7) = 0) and (LRemaining >= 8) then
    begin
      LWord := PatternWord(LOffset shr 3);
      Move(LSource^, LActual, 8);

      if LActual = LWord then
      begin
        Inc(LSource, 8);
        Inc(LOffset, 8);
        Dec(LRemaining, 8);

        Continue;
      end;
    end;

    // Byte-wise: unaligned head/tail, or a word that did not match
    if LSource^ <> ExpectedByte(LOffset) then
    begin
      AFirstBadOffset := LOffset;

      Exit(False);
    end;

    Inc(LSource);
    Inc(LOffset);
    Dec(LRemaining);
  end;

  Result := True;
end;

class function TTestFileHelpers.TestFolder: string;
begin
{$IFDEF FPC}
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'Pascal.IOUring.Tests' + PathDelim;
{$ELSE}
  Result := IncludeTrailingPathDelimiter(TPath.GetTempPath) + 'Pascal.IOUring.Tests' + PathDelim;
{$ENDIF}
  ForceDirectories(Result);
end;

class function TTestFileHelpers.NewTestFileName(const APrefix: string): string;
var
  LGuid: TGUID;
begin
  CreateGUID(LGuid);

  Result := TestFolder + APrefix + '-' + GUIDToString(LGuid) + '.bin';
end;

class function TTestFileHelpers.CreatePatternFile(const ASize: Int64; const APrefix: string): string;
var
  LStream: TFileStream;
  LBuffer: TBytes;
  LOffset: Int64;
  LChunk: Integer;
begin
  Result := NewTestFileName(APrefix);

  SetLength(LBuffer, CREATE_CHUNK_SIZE);

  LStream := TFileStream.Create(Result, fmCreate);
  try
    LOffset := 0;

    while LOffset < ASize do
    begin
      LChunk := CREATE_CHUNK_SIZE;

      if ASize - LOffset < LChunk then
        LChunk := Integer(ASize - LOffset);

      FillPattern(UInt64(LOffset), LBuffer[0], LChunk);
      LStream.WriteBuffer(LBuffer[0], LChunk);
      Inc(LOffset, LChunk);
    end;
  finally
    LStream.Free;
  end;
end;

class procedure TTestFileHelpers.DeleteTestFile(const AFileName: string);
begin
  if (AFileName <> '') and FileExists(AFileName) then
    DeleteFile(AFileName);
end;

end.
