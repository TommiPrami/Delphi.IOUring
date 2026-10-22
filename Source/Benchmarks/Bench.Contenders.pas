unit Bench.Contenders;

{
  The ways of reading a file that the benchmark compares. Every contender
  reads the whole file and gives the data, in file order, to a TBenchConsumer
  (except the multi-threaded one, whose threads each read a part).
}

interface

uses
  Bench.Common;

type
  // AStalls: how often an IoRing reader had to wait for data (0 for the others)
  TContenderProc = reference to procedure(const AFileName: string; var AConsumer: TBenchConsumer;
    var AStalls: UInt64);

  TContender = record
    Name: string;
    Unbuffered: Boolean;   // bypasses the file cache: only cold runs make sense
    InOrder: Boolean;      // False: parallel threads, no in-order consumer (no work scenario)
    Run: TContenderProc;
  end;

// The comparison set (Docs/Plan.md, Phase 5)
function MainContenders(const AThreadCount: Integer): TArray<TContender>;

// IoRing reader variants for choosing the defaults
function TuningContenders: TArray<TContender>;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  Delphi.IOUring.SequentialReader,
  Delphi.IOUring.Streams;

const
  STREAM_READ_SIZE = 64 * 1024;

{ Classic RTL streams }

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

procedure ReadWithBufferedFileStream(const AFileName: string; const ABufferSize, AReadSize: Integer;
  var AConsumer: TBenchConsumer);
var
  LStream: TBufferedFileStream;
  LBuffer: TBytes;
  LRead: Integer;
begin
  SetLength(LBuffer, AReadSize);
  LStream := TBufferedFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite, ABufferSize);
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

{ Plain Windows API }

procedure ReadWithReadFile(const AFileName: string; const AReadSize: DWORD; const ASequentialScanHint: Boolean;
  var AConsumer: TBenchConsumer);
var
  LHandle: THandle;
  LBuffer: Pointer;
  LRead: DWORD;
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL;
  if ASequentialScanHint then
    LFlags := LFlags or FILE_FLAG_SEQUENTIAL_SCAN;

  LBuffer := VirtualAlloc(nil, AReadSize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
  try
    LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING, LFlags, 0);
    if LHandle = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
    try
      repeat
        if not ReadFile(LHandle, LBuffer^, AReadSize, LRead, nil) then
          RaiseLastOSError;
        if LRead > 0 then
          AConsumer.Consume(LBuffer, LRead);
      until LRead = 0;
    finally
      CloseHandle(LHandle);
    end;
  finally
    VirtualFree(LBuffer, 0, MEM_RELEASE);
  end;
end;

// Classic asynchronous I/O without IoRing: ABufferCount overlapped ReadFile
// calls in flight, consumed in order. The fair "is IoRing better than what
// Windows always had?" baseline.
procedure ReadWithOverlapped(const AFileName: string; const AUnbuffered: Boolean;
  const ABufferSize, ABufferCount: Cardinal; var AConsumer: TBenchConsumer);
type
  TSlot = record
    Overlapped: TOverlapped;
    Data: PByte;
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
  LDummy: DWORD;

  procedure Issue(const ASlot: Cardinal);
  var
    LEvent: THandle;
  begin
    LEvent := LSlots[ASlot].Overlapped.hEvent;
    FillChar(LSlots[ASlot].Overlapped, SizeOf(TOverlapped), 0);
    LSlots[ASlot].Overlapped.hEvent := LEvent;
    LSlots[ASlot].Overlapped.Offset := DWORD(LNextOffset);
    LSlots[ASlot].Overlapped.OffsetHigh := DWORD(LNextOffset shr 32);
    if not ReadFile(LHandle, LSlots[ASlot].Data^, ABufferSize, LDummy, @LSlots[ASlot].Overlapped) then
      if GetLastError <> ERROR_IO_PENDING then
        RaiseLastOSError;
    Inc(LNextOffset, ABufferSize);
    Inc(LOutstanding);
  end;

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
        Issue(LIndex);

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
        Issue(LHead);
      LHead := (LHead + 1) mod ABufferCount;
    end;
  finally
    // Nothing is in flight here (the loop waited for everything), except
    // after an error: CloseHandle cancels the rest
    CloseHandle(LHandle);
    for LIndex := 0 to ABufferCount - 1 do
      CloseHandle(LSlots[LIndex].Overlapped.hEvent);
    VirtualFree(LMemory, 0, MEM_RELEASE);
  end;
end;

// Starts a thread that reads [AFrom, ATo) of the file into AResult
function StartPartReader(const AFileName: string; const AReadSize: DWORD; const AFrom, ATo: Int64;
  const AResult: PBenchConsumer): TThread;
begin
  Result := TThread.CreateAnonymousThread(
    procedure
    var
      LHandle: THandle;
      LBuffer: Pointer;
      LOffset: Int64;
      LWanted: DWORD;
      LRead: DWORD;
    begin
      AResult^.Init(0);
      LBuffer := VirtualAlloc(nil, AReadSize, MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE);
      LHandle := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL or FILE_FLAG_SEQUENTIAL_SCAN, 0);
      try
        SetFilePointerEx(LHandle, AFrom, nil, FILE_BEGIN);
        LOffset := AFrom;
        while LOffset < ATo do
        begin
          LWanted := AReadSize;
          if ATo - LOffset < LWanted then
            LWanted := DWORD(ATo - LOffset);
          if not ReadFile(LHandle, LBuffer^, LWanted, LRead, nil) or (LRead = 0) then
            Break;
          AResult^.Consume(LBuffer, LRead);
          Inc(LOffset, LRead);
        end;
      finally
        CloseHandle(LHandle);
        VirtualFree(LBuffer, 0, MEM_RELEASE);
      end;
    end);
  Result.FreeOnTerminate := False;
  Result.Start;
end;

// Several threads, each reading its own part of the file synchronously
// (PostgreSQL's "more workers" alternative to asynchronous I/O)
procedure ReadWithThreads(const AFileName: string; const AThreadCount: Integer; const AReadSize: DWORD;
  var AConsumer: TBenchConsumer);
var
  LSize: Int64;
  LPart: Int64;
  LThreads: array of TThread;
  LResults: array of TBenchConsumer;
  LIndex: Integer;
  LTo: Int64;
begin
  LSize := FileSizeOf(AFileName);
  // Parts start on MiB boundaries, so the 64-bit checksum words line up
  LPart := ((LSize div AThreadCount) + MiB - 1) div MiB * MiB;

  SetLength(LThreads, AThreadCount);
  SetLength(LResults, AThreadCount);
  for LIndex := 0 to AThreadCount - 1 do
  begin
    LTo := (LIndex + 1) * LPart;
    if (LIndex = AThreadCount - 1) or (LTo > LSize) then
      LTo := LSize;
    LThreads[LIndex] := StartPartReader(AFileName, AReadSize, LIndex * LPart, LTo, @LResults[LIndex]);
  end;

  for LIndex := 0 to AThreadCount - 1 do
  begin
    LThreads[LIndex].WaitFor;
    LThreads[LIndex].Free;
    AConsumer.Merge(LResults[LIndex]);
  end;
end;

{ IoRing }

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

{ Contender lists }

function Contender(const AName: string; const AUnbuffered, AInOrder: Boolean;
  const ARun: TContenderProc): TContender;
begin
  Result.Name := AName;
  Result.Unbuffered := AUnbuffered;
  Result.InOrder := AInOrder;
  Result.Run := ARun;
end;

function IORingZeroCopyContender(const AName: string; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal): TContender;
begin
  Result := Contender(AName, sroUnbuffered in AOptions, True,
    procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
    begin
      AStalls := ReadWithIORingZeroCopy(AFileName, AOptions, ABufferSize, ABufferCount, AConsumer);
    end);
end;

function MainContenders(const AThreadCount: Integer): TArray<TContender>;
begin
  Result := [
    Contender('TFileStream 64 KiB reads', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithFileStream(AFileName, 64 * 1024, AConsumer);
      end),
    Contender('TFileStream 1 MiB reads', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithFileStream(AFileName, MiB, AConsumer);
      end),
    Contender('TBufferedFileStream 1 MiB buffer, 64 KiB reads', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithBufferedFileStream(AFileName, MiB, 64 * 1024, AConsumer);
      end),
    Contender('ReadFile 1 MiB, sequential scan', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithReadFile(AFileName, MiB, True, AConsumer);
      end),
    Contender('ReadFile 1 MiB, no sequential-scan hint', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithReadFile(AFileName, MiB, False, AConsumer);
      end),
    Contender('Overlapped ReadFile 1 MiB x 8', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithOverlapped(AFileName, False, MiB, 8, AConsumer);
      end),
    Contender('Overlapped ReadFile 1 MiB x 8, unbuffered', True, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithOverlapped(AFileName, True, MiB, 8, AConsumer);
      end),
    Contender(Format('%d threads, ReadFile 1 MiB', [AThreadCount]), False, False,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        ReadWithThreads(AFileName, AThreadCount, MiB, AConsumer);
      end),
    Contender('IoRing stream, 64 KiB reads', False, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        AStalls := ReadWithIORingStream(AFileName, [], AConsumer);
      end),
    Contender('IoRing stream, 64 KiB reads, unbuffered', True, True,
      procedure(const AFileName: string; var AConsumer: TBenchConsumer; var AStalls: UInt64)
      begin
        AStalls := ReadWithIORingStream(AFileName, [sroUnbuffered], AConsumer);
      end),
    IORingZeroCopyContender('IoRing reader, zero-copy', [], IORING_READER_DEFAULT_BUFFER_SIZE,
      IORING_READER_DEFAULT_BUFFER_COUNT),
    IORingZeroCopyContender('IoRing reader, zero-copy, no seq.-scan hint', [sroNoSequentialScanHint],
      IORING_READER_DEFAULT_BUFFER_SIZE, IORING_READER_DEFAULT_BUFFER_COUNT),
    IORingZeroCopyContender('IoRing reader, zero-copy, unbuffered', [sroUnbuffered],
      IORING_READER_DEFAULT_BUFFER_SIZE, IORING_READER_DEFAULT_BUFFER_COUNT)
  ];
end;

function TuningContenders: TArray<TContender>;
const
  SIZES: array[0..2] of Cardinal = (256 * 1024, MiB, 4 * MiB);
  COUNTS: array[0..4] of Cardinal = (2, 4, 8, 16, 32);
var
  LUnbuffered: Boolean;
  LSize: Cardinal;
  LCount: Cardinal;
  LOptions: TIORingSequentialReaderOptions;
  LMode: string;
begin
  Result := nil;
  for LUnbuffered in [False, True] do
  begin
    if LUnbuffered then
    begin
      LOptions := [sroUnbuffered];
      LMode := 'unbuffered';
    end
    else
    begin
      LOptions := [];
      LMode := 'buffered';
    end;

    for LSize in SIZES do
      for LCount in COUNTS do
        Result := Result + [IORingZeroCopyContender(Format('%s %d KiB x %d', [LMode, LSize div 1024, LCount]),
          LOptions, LSize, LCount)];

    Result := Result + [
      IORingZeroCopyContender(Format('%s 1024 KiB x 8, fixed read-ahead', [LMode]),
        LOptions + [sroFixedReadAhead], MiB, 8),
      IORingZeroCopyContender(Format('%s 1024 KiB x 8, no registration', [LMode]),
        LOptions + [sroNoRegistration], MiB, 8)];
  end;
end;

end.
