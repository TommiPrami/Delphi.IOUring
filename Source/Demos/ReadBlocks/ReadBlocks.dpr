program ReadBlocks;

{
  Reads blocks of a file that are known in advance - as a program reads the
  records it found in an index - with the block reader: up to 32 reads are in
  flight, and the blocks come back in the order of the list.

    ReadBlocks [<file>]

  The list: every 37th block of 4 KiB. Without a file name it uses a
  temporary file of 64 MiB and deletes it afterwards. For comparison the same
  blocks are read once more with TFileStream: Seek, then Read.
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
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.BlockReader, PIRUnit.Demo.Common in '..\Common\PIRUnit.Demo.Common.pas';

const
  BLOCK_SIZE = 4096;
  EVERY_NTH = 37;

type
  TBlockList = array of TIORingBlock;

// A simple sum of the bytes of all blocks, to compare the two ways
procedure AddToSum(var ASum: UInt64; AData: PByte; const ALength: Cardinal);
var
  LIndex: Cardinal;
begin
  for LIndex := 1 to ALength do
  begin
    Inc(ASum, AData^);
    Inc(AData);
  end;
end;

function MakeBlockList(const AFileSize: Int64): TBlockList;
var
  LCount: Integer;
  LIndex: Integer;
begin
  LCount := AFileSize div (BLOCK_SIZE * EVERY_NTH);
  Result := nil;
  SetLength(Result, LCount);

  for LIndex := 0 to LCount - 1 do
    Result[LIndex] := TIORingBlock.Create(UInt64(LIndex) * EVERY_NTH * BLOCK_SIZE, BLOCK_SIZE);
end;

{ The library's way: one engine (I/O thread) for the program; the reader hands out its own buffers (no copy); give each
  one back with ReleaseBlock }
function SumWithBlockReader(const AFileName: string; const ABlocks: array of TIORingBlock; out AStalls: UInt64): UInt64;
var
  LEngine: TIORingEngine;
  LFile: THandle;
  LReader: TIORingBlockReader;         // a record: closed at the end of the scope
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  Result := 0;
  LEngine := TIORingEngine.Create;
  try
    // On Windows the handle must allow overlapped I/O (it does), or Windows reads one block at a time
    LFile := TIORingPlatform.OpenFileForRead(AFileName, False, False);
    try
      LReader.Open(LEngine, LFile, ABlocks);   // read-ahead 32 by default

      try
        while LReader.TryGetBlock(LBlock, LData, LLength) do
        begin
          AddToSum(Result, LData, LLength);
          LReader.ReleaseBlock;
        end;

        AStalls := LReader.Stats.Stalls;
      finally
        LReader.Close;                 // before the file and the engine go away
      end;
    finally
      TIORingPlatform.CloseFile(LFile);
    end;
  finally
    LEngine.Free;
  end;
end;

// The usual way, for comparison
function SumWithFileStream(const AFileName: string; const ABlocks: array of TIORingBlock): UInt64;
var
  LStream: TFileStream;
  LBuffer: array[0..BLOCK_SIZE - 1] of Byte;
  LIndex: Integer;
begin
  Result := 0;
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    for LIndex := 0 to High(ABlocks) do
    begin
      LStream.Seek(Int64(ABlocks[LIndex].Offset), soBeginning);
      LStream.ReadBuffer(LBuffer, ABlocks[LIndex].Length);
      AddToSum(Result, @LBuffer[0], ABlocks[LIndex].Length);
    end;
  finally
    LStream.Free;
  end;
end;

var
  LFileName: string;
  LTemporary: Boolean;
  LBlocks: TBlockList;
  LStart: UInt64;
  LMilliseconds: UInt64;
  LStalls: UInt64;
  LReaderSum: UInt64;
  LStreamSum: UInt64;
begin
  try
    LTemporary := ParamCount = 0;

    if LTemporary then
    begin
      LFileName := DemoFileName('ReadBlocks.dat');
      CreateDemoFile(LFileName, 64 * 1024 * 1024);
    end
    else
      LFileName := ParamStr(1);

    try
      LBlocks := MakeBlockList(DemoFileSize(LFileName));
      Writeln(Format('%d blocks of %d bytes (every %dth) of %s', [Length(LBlocks), BLOCK_SIZE, EVERY_NTH, LFileName]));

      LStart := DemoMilliseconds;
      LReaderSum := SumWithBlockReader(LFileName, LBlocks, LStalls);
      LMilliseconds := DemoMilliseconds - LStart;
      Writeln(Format('Block reader:             sum %d in %d ms, waited for data %d times',
        [LReaderSum, LMilliseconds, LStalls]));

      LStart := DemoMilliseconds;
      LStreamSum := SumWithFileStream(LFileName, LBlocks);
      LMilliseconds := DemoMilliseconds - LStart;
      Writeln(Format('TFileStream, Seek + Read: sum %d in %d ms', [LStreamSum, LMilliseconds]));

      if LStreamSum <> LReaderSum then
      begin
        Writeln('The sums differ!');
        ExitCode := 1;
      end;

      Writeln('(Both read from the file cache here. With data that is not in the cache yet,');
      Writeln(' the block reader is many times faster: Docs/Benchmarks.md.)');
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
