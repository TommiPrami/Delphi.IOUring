unit PIRUnit.Benchmark.Readers;

{
  Ways of reading a whole file in order and handing the data to a
  TBenchConsumer. Plain procedures that compile with Delphi and Free Pascal,
  so the Delphi benchmark (PIRUnit.Benchmark.Contenders) and the FPC benchmark use the
  same code.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF MSWINDOWS}
  {$IFDEF FPC}
  Windows,
  {$ELSE}
  Winapi.Windows,
  {$ENDIF}
{$ENDIF}
  PIRUnit.SequentialReader, PIRUnit.Benchmark.Common;

const
  STREAM_READ_SIZE = 64 * 1024;

  // TFileStream.Read with AReadSize blocks
  procedure ReadWithFileStream(const AFileName: string; const AReadSize: Integer; var AConsumer: TBenchConsumer);

  { Plain synchronous ReadFile (Linux: read). ASequentialScanHint: FILE_FLAG_SEQUENTIAL_SCAN
    (Linux: POSIX_FADV_SEQUENTIAL). }
  procedure ReadWithReadFile(const AFileName: string; const AReadSize: Cardinal; const ASequentialScanHint: Boolean;
    var AConsumer: TBenchConsumer);

{$IFDEF MSWINDOWS}
  { Classic asynchronous I/O without IoRing: ABufferCount overlapped ReadFile calls in flight, consumed in order. The fair
    "is IoRing better than what Windows always had?" baseline. }
  procedure ReadWithOverlapped(const AFileName: string; const AUnbuffered: Boolean;
    const ABufferSize, ABufferCount: Cardinal; var AConsumer: TBenchConsumer);
{$ENDIF}

  // TSequentialReadOnlyFileStream with STREAM_READ_SIZE reads; returns the stalls
  function ReadWithIORingStream(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
    var AConsumer: TBenchConsumer): UInt64;

  // TIORingSequentialReader with TryAcquireChunk / ReleaseChunk; returns the stalls
  function ReadWithIORingZeroCopy(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
    const ABufferSize, ABufferCount: Cardinal; var AConsumer: TBenchConsumer): UInt64;

  {
    The first unbuffered read after a buffered read of the same file is slower (about 0.13 s here), probably because
    Windows keeps the file's cache structures for a while after the buffered reader closes it. Doing this untimed
    unbuffered read first lets the unbuffered contenders be measured fairly.
  }
  procedure ReadUnbufferedUntimed(const AFileName: string);

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Streams;

procedure ReadWithFileStream(const AFileName: string; const AReadSize: Integer; var AConsumer: TBenchConsumer);
var
  LStream: TFileStream;
  LBuffer: TBytes;
  LRead: Integer;
begin
  SetLength(LBuffer, AReadSize);
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    repeat
      LRead := LStream.Read(LBuffer[0], AReadSize);

      if LRead > 0 then
        AConsumer.Consume(@LBuffer[0], LRead);
    until LRead = 0;
  finally
    LStream.Free;
  end;
end;

procedure ReadWithReadFile(const AFileName: string; const AReadSize: Cardinal; const ASequentialScanHint: Boolean;
  var AConsumer: TBenchConsumer);
var
  LHandle: THandle;
  LBuffer: Pointer;
  LRead: Cardinal;
begin
  LBuffer := TIORingPlatform.AllocPages(AReadSize);
  try
    LHandle := BenchOpenForReading(AFileName, False, False, ASequentialScanHint);
    try
      repeat
        LRead := BenchRead(LHandle, LBuffer^, AReadSize);

        if LRead > 0 then
          AConsumer.Consume(LBuffer, LRead);
      until LRead = 0;
    finally
      BenchCloseFile(LHandle);
    end;
  finally
    TIORingPlatform.FreePages(LBuffer, AReadSize);
  end;
end;

{$IFDEF MSWINDOWS}
procedure ReadWithOverlapped(const AFileName: string; const AUnbuffered: Boolean;
  const ABufferSize, ABufferCount: Cardinal; var AConsumer: TBenchConsumer);
type
  TSlot = record
    Overlapped: TOverlapped;
    Data: PByte;
  end;

  // Starts an overlapped read of ASize bytes at AOffset into the slot
  procedure Issue(const AHandle: THandle; var ASlot: TSlot; const AOffset: Int64; const ASize: Cardinal);
  var
    LEvent: THandle;
    LDummy: DWORD;
  begin
    LEvent := ASlot.Overlapped.hEvent;
    FillChar(ASlot.Overlapped, SizeOf(TOverlapped), 0);
    ASlot.Overlapped.hEvent := LEvent;
    ASlot.Overlapped.Offset := DWORD(AOffset);
    ASlot.Overlapped.OffsetHigh := DWORD(AOffset shr 32);

    if not ReadFile(AHandle, ASlot.Data^, ASize, LDummy, @ASlot.Overlapped) then
      if GetLastError <> ERROR_IO_PENDING then
        RaiseLastOSError;
  end;

var
  LFlags: DWORD;
  LHandle: THandle;
  LSize: Int64;
  LMemory: PByte;
  LSlots: array of TSlot;
  LNextOffset: Int64;
  LOutstanding: Cardinal;
  LHead: Cardinal;
  LIndex: Cardinal;
  LBytes: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL or FILE_FLAG_OVERLAPPED or FILE_FLAG_SEQUENTIAL_SCAN;

  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;

  LSize := FileSizeOf(AFileName);
  LMemory := VirtualAlloc(nil, NativeUInt(ABufferSize) * ABufferCount, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  SetLength(LSlots, ABufferCount);
  LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, LFlags, 0);

  if LHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  try
    for LIndex := 0 to ABufferCount - 1 do
    begin
      LSlots[LIndex].Data := LMemory + NativeUInt(LIndex) * ABufferSize;
      LSlots[LIndex].Overlapped.hEvent := CreateEvent(nil, True, False, nil);
    end;

    LNextOffset := 0;
    LOutstanding := 0;

    for LIndex := 0 to ABufferCount - 1 do
      if LNextOffset < LSize then
      begin
        Issue(LHandle, LSlots[LIndex], LNextOffset, ABufferSize);
        Inc(LNextOffset, ABufferSize);
        Inc(LOutstanding);
      end;

    LHead := 0;

    while LOutstanding > 0 do
    begin
      if not GetOverlappedResult(LHandle, LSlots[LHead].Overlapped, LBytes, True) then
      begin
        if GetLastError <> ERROR_HANDLE_EOF then
          RaiseLastOSError;

        LBytes := 0;
      end;

      Dec(LOutstanding);

      if LBytes > 0 then
        AConsumer.Consume(LSlots[LHead].Data, LBytes);

      if LNextOffset < LSize then
      begin
        Issue(LHandle, LSlots[LHead], LNextOffset, ABufferSize);
        Inc(LNextOffset, ABufferSize);
        Inc(LOutstanding);
      end;

      LHead := (LHead + 1) mod ABufferCount;
    end;
  finally
    // Nothing is in flight here (the loop waited for everything), except after an error: CloseHandle cancels the rest
    CloseHandle(LHandle);

    for LIndex := 0 to ABufferCount - 1 do
      CloseHandle(LSlots[LIndex].Overlapped.hEvent);

    VirtualFree(LMemory, 0, MEM_RELEASE);
  end;
end;
{$ENDIF}

function ReadWithIORingStream(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
  var AConsumer: TBenchConsumer): UInt64;
var
  LStream: TSequentialReadOnlyFileStream;
  LBuffer: TBytes;
  LRead: Integer;
begin
  SetLength(LBuffer, STREAM_READ_SIZE);
  LStream := TSequentialReadOnlyFileStream.Create(AFileName, AOptions);
  try
    repeat
      LRead := LStream.Read(LBuffer[0], STREAM_READ_SIZE);

      if LRead > 0 then
        AConsumer.Consume(@LBuffer[0], LRead);
    until LRead = 0;

    Result := LStream.Stats.Stalls;
  finally
    LStream.Free;
  end;
end;

function ReadWithIORingZeroCopy(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal; var AConsumer: TBenchConsumer): UInt64;
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
begin
  LReader.Open(AFileName, AOptions, ABufferSize, ABufferCount);

  while LReader.TryAcquireChunk(LData, LLength) do
  begin
    AConsumer.Consume(LData, LLength);
    LReader.ReleaseChunk;
  end;

  Result := LReader.Stats.Stalls;
end;

procedure ReadUnbufferedUntimed(const AFileName: string);
var
  LReader: TIORingSequentialReader;
  LData: PByte;
  LLength: NativeInt;
begin
  LReader.Open(AFileName, [sroUnbuffered]);

  while LReader.TryAcquireChunk(LData, LLength) do
    LReader.ReleaseChunk;
end;

end.