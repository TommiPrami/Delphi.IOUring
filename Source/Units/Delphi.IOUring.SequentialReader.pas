unit Delphi.IOUring.SequentialReader;

// Reads a file front to back with read-ahead (Docs/Design.md §7).
//
// BufferCount buffers of BufferSize bytes form a circular queue. Reads for the
// next buffers are in flight while the caller works on the current one, so in
// the best case Read only copies data that is already there.
//
//   var
//     LReader: TIORingSequentialReader;
//   begin
//     LReader.Open('big.dat');                       // closed at the end of scope
//     while LReader.TryAcquireChunk(LData, LLength) do
//     begin
//       Process(LData, LLength);                     // zero-copy
//       LReader.ReleaseChunk;
//     end;
//   end;
//
// The size is taken when the file is opened: data appended later is not read.
// If the file turns out shorter, the reader stops there (end of file).
// One thread at a time.

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  Delphi.IOUring;

const
  IORING_READER_DEFAULT_BUFFER_SIZE = 1024 * 1024;
  IORING_READER_DEFAULT_BUFFER_COUNT = 8;
  // BufferSize must be a multiple of this (page size; also covers the sector
  // size needed for unbuffered reads on usual disks)
  IORING_READER_BUFFER_SIZE_UNIT = 4096;
  IORING_READER_MAX_BUFFER_COUNT = 1024;

type
  TIORingSequentialReaderOption = (
    sroUnbuffered,            // bypass the OS file cache (FILE_FLAG_NO_BUFFERING)
    sroNoSequentialScanHint,  // do not tell the OS that the file is read sequentially
    sroFixedReadAhead,        // all buffers in flight from the start (no adaptive ramp-up)
    sroNoRegistration         // do not register the file and buffers with the ring (benchmarks)
  );
  TIORingSequentialReaderOptions = set of TIORingSequentialReaderOption;

  TIORingReaderStats = record
    ReadsIssued: UInt64;
    BytesFromDisk: UInt64;        // bytes the completed reads returned
    Stalls: UInt64;               // times Read / TryAcquireChunk had to wait for data
    StallMicroseconds: UInt64;    // total time spent waiting in those stalls
    MaxReadAhead: Cardinal;       // largest number of buffers allowed in flight
  end;

  // One buffer of the circular queue (internal)
  TIORingReaderSlotState = (rssFree, rssInFlight, rssReady);
  PIORingReaderSlot = ^TIORingReaderSlot;
  TIORingReaderSlot = record
    State: TIORingReaderSlotState;
    Data: PByte;
    FileOffset: Int64;
    Expected: Cardinal;       // bytes this buffer should get (up to the size at open)
    BytesRead: Cardinal;
    NativeResult: Integer;    // < 0: the read failed
  end;

  // Custom managed record: owns the file handle (if asked), the ring and the
  // buffer memory, and releases them at the end of scope. Not copyable.
  TIORingSequentialReader = record
  private
    FRing: TIORing;
    FFile: THandle;
    FHasFile: Boolean;
    FOwnsFile: Boolean;
    FMemory: PByte;
    FMemorySize: NativeUInt;      // for FreePages
    FSlots: array of TIORingReaderSlot;
    FBufferSize: Cardinal;
    FBufferCount: Cardinal;
    FRegistered: Boolean;
    FAdaptive: Boolean;
    FSize: Int64;
    FEnd: Int64;              // FSize, or less if the file turned out shorter
    FPosition: Int64;
    FNextReadOffset: Int64;
    FHead: Cardinal;          // slot holding the data at FPosition
    FHeadOffset: Cardinal;    // bytes of the head slot already delivered
    FOutstanding: Cardinal;   // slots in flight or ready, not yet consumed
    FReadAhead: Cardinal;     // how many slots may be outstanding
    FChunkAcquired: Boolean;
    FStats: TIORingReaderStats;

    procedure CheckOpen;
    procedure IssueReads;
    procedure ProcessCompletions;
    procedure Stall;
    function PrepareHead(const AWait: Boolean): Boolean;
    procedure ReleaseHead;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingSequentialReader);
    class operator Finalize(var ADest: TIORingSequentialReader);
    class operator Copy(constref ASource: TIORingSequentialReader; var ADest: TIORingSequentialReader);
{$ELSE}
    class operator Initialize(out ADest: TIORingSequentialReader);
    class operator Finalize(var ADest: TIORingSequentialReader);
    class operator Assign(var ADest: TIORingSequentialReader; const [ref] ASource: TIORingSequentialReader);
{$ENDIF}

    // Opens the file and starts reading ahead. ABufferSize: multiple of
    // IORING_READER_BUFFER_SIZE_UNIT. ABufferCount: 1..IORING_READER_MAX_BUFFER_COUNT.
    procedure Open(const AFileName: string; const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = IORING_READER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_READER_DEFAULT_BUFFER_COUNT); overload;
    // Reads from a handle opened by the caller (read access; for sroUnbuffered
    // it must have been opened unbuffered). With AOwnsHandle the reader closes
    // it, also when Open fails. sroNoSequentialScanHint has no effect here.
    procedure Open(const AHandle: THandle; const AOwnsHandle: Boolean;
      const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = IORING_READER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_READER_DEFAULT_BUFFER_COUNT); overload;
    // Waits for the reads in flight, then releases everything. Does nothing if not open.
    procedure Close;
    function IsOpen: Boolean;

    // Copies up to ACount bytes; returns fewer only at the end of the file
    function Read(var ABuffer; const ACount: NativeInt): NativeInt;

    // Zero-copy: the rest of the current buffer, valid until ReleaseChunk.
    // False at the end of the file, or (AWait = False) when the data is not
    // there yet - check Eof to tell them apart.
    function TryAcquireChunk(out AData: PByte; out ALength: NativeInt; const AWait: Boolean = True): Boolean;
    procedure ReleaseChunk;

    // True if the next Read returns at once (data is there, or end of file)
    function DataReady: Boolean;
    function Eof: Boolean;

    property Position: Int64 read FPosition;    // bytes delivered so far
    property Size: Int64 read FSize;            // file size when opened
    property BufferSize: Cardinal read FBufferSize;
    property BufferCount: Cardinal read FBufferCount;
    property Stats: TIORingReaderStats read FStats;
  end;

implementation

const
  // UserData of the registration entries; slot indexes are below IORING_READER_MAX_BUFFER_COUNT
  REGISTRATION_USER_DATA = TIORingUserData(High(TIORingUserData));
  INITIAL_ADAPTIVE_READ_AHEAD = 2;

{ TIORingSequentialReader - life cycle }

{$IFDEF FPC}
class operator TIORingSequentialReader.Initialize(var ADest: TIORingSequentialReader);
{$ELSE}
class operator TIORingSequentialReader.Initialize(out ADest: TIORingSequentialReader);
{$ENDIF}
begin
  ADest.FFile := 0;
  ADest.FHasFile := False;
  ADest.FOwnsFile := False;
  ADest.FMemory := nil;
  ADest.FMemorySize := 0;
  ADest.FBufferSize := 0;
  ADest.FBufferCount := 0;
  ADest.FRegistered := False;
  ADest.FAdaptive := False;
  ADest.FSize := 0;
  ADest.FEnd := 0;
  ADest.FPosition := 0;
  ADest.FNextReadOffset := 0;
  ADest.FHead := 0;
  ADest.FHeadOffset := 0;
  ADest.FOutstanding := 0;
  ADest.FReadAhead := 0;
  ADest.FChunkAcquired := False;
  FillChar(ADest.FStats, SizeOf(ADest.FStats), 0);
end;

class operator TIORingSequentialReader.Finalize(var ADest: TIORingSequentialReader);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TIORingSequentialReader.Copy(constref ASource: TIORingSequentialReader;
  var ADest: TIORingSequentialReader);
{$ELSE}
class operator TIORingSequentialReader.Assign(var ADest: TIORingSequentialReader;
  const [ref] ASource: TIORingSequentialReader);
{$ENDIF}
begin
  raise EInvalidOpException.Create('A sequential reader cannot be copied. Pass it as var or const [ref].');
end;

procedure TIORingSequentialReader.Open(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal);
var
  LHandle: THandle;
begin
  if IsOpen then
    raise EIORingError.Create('The reader is already open');

  LHandle := TIORingPlatform.OpenFileForRead(AFileName, sroUnbuffered in AOptions,
    not (sroNoSequentialScanHint in AOptions));
  Open(LHandle, True, AOptions, ABufferSize, ABufferCount);
end;

procedure TIORingSequentialReader.Open(const AHandle: THandle; const AOwnsHandle: Boolean;
  const AOptions: TIORingSequentialReaderOptions; const ABufferSize, ABufferCount: Cardinal);
var
  LTotalSize: UInt64;
  LSectorSize: Cardinal;
  LIndex: Cardinal;
  LBufferInfo: TIORingBufferInfo;
begin
  if IsOpen then
    raise EIORingError.Create('The reader is already open');

  FFile := AHandle;
  FHasFile := True;
  FOwnsFile := AOwnsHandle;
  try
    if (ABufferSize = 0) or (ABufferSize mod IORING_READER_BUFFER_SIZE_UNIT <> 0) then
      raise EIORingError.CreateFmt('Buffer size %d is not a multiple of %d', [ABufferSize, IORING_READER_BUFFER_SIZE_UNIT]);
    if (ABufferCount = 0) or (ABufferCount > IORING_READER_MAX_BUFFER_COUNT) then
      raise EIORingError.CreateFmt('Buffer count %d is not between 1 and %d', [ABufferCount, IORING_READER_MAX_BUFFER_COUNT]);

    LTotalSize := UInt64(ABufferSize) * ABufferCount;
    if LTotalSize > UInt64(High(NativeInt) div 2) then
      raise EIORingError.CreateFmt('%d buffers of %d bytes do not fit in memory', [ABufferCount, ABufferSize]);

    if sroUnbuffered in AOptions then
    begin
      LSectorSize := TIORingPlatform.GetSectorSize(AHandle);
      if ABufferSize mod LSectorSize <> 0 then
        raise EIORingError.CreateFmt('Unbuffered reading needs a buffer size that is a multiple of the sector size %d',
          [LSectorSize]);
    end;

    FSize := TIORingPlatform.GetFileSize(AHandle);
    FBufferSize := ABufferSize;
    FBufferCount := ABufferCount;
    FMemorySize := NativeUInt(LTotalSize);
    FMemory := TIORingPlatform.AllocPages(FMemorySize);

    SetLength(FSlots, ABufferCount);
    for LIndex := 0 to ABufferCount - 1 do
    begin
      FSlots[LIndex].State := rssFree;
      FSlots[LIndex].Data := FMemory + NativeUInt(LIndex) * ABufferSize;
    end;

    // One entry per buffer, plus the two registrations
    FRing.Open(ABufferCount + 2);

    // A registered buffer's offset is 32 bits, so register only below 4 GiB
    FRegistered := not (sroNoRegistration in AOptions) and (LTotalSize <= High(Cardinal));
    if FRegistered then
    begin
      LBufferInfo.Address := FMemory;
      LBufferInfo.Length := Cardinal(LTotalSize);
      FRing.PrepareRegisterFiles([AHandle], REGISTRATION_USER_DATA);
      FRing.PrepareRegisterBuffers([LBufferInfo], REGISTRATION_USER_DATA);
      // Submitted together with the first reads; registration is a barrier for them
    end;

    FAdaptive := not (sroFixedReadAhead in AOptions);
    if FAdaptive and (ABufferCount > INITIAL_ADAPTIVE_READ_AHEAD) then
      FReadAhead := INITIAL_ADAPTIVE_READ_AHEAD
    else
      FReadAhead := ABufferCount;

    FEnd := FSize;
    FPosition := 0;
    FNextReadOffset := 0;
    FHead := 0;
    FHeadOffset := 0;
    FOutstanding := 0;
    FChunkAcquired := False;
    FillChar(FStats, SizeOf(FStats), 0);
    FStats.MaxReadAhead := FReadAhead;

    // Submits the registrations too (also for an empty file, which gets no reads)
    IssueReads;
  except
    Close;
    raise;
  end;
end;

procedure TIORingSequentialReader.Close;
begin
  // The ring first: it waits for the reads still in flight, so the kernel is
  // done with the buffers before they are freed
  FRing.Close;

  FSlots := nil;
  TIORingPlatform.FreePages(FMemory, FMemorySize);
  FMemory := nil;

  if FHasFile and FOwnsFile then
    TIORingPlatform.CloseFile(FFile);
  FFile := 0;
  FHasFile := False;
  FOwnsFile := False;

  FBufferSize := 0;
  FBufferCount := 0;
  FOutstanding := 0;
  FChunkAcquired := False;
end;

function TIORingSequentialReader.IsOpen: Boolean;
begin
  Result := FHasFile;
end;

procedure TIORingSequentialReader.CheckOpen;
begin
  if not FHasFile then
    raise EIORingError.Create('The reader is not open');
end;

{ TIORingSequentialReader - read-ahead engine }

procedure TIORingSequentialReader.IssueReads;
var
  LIndex: Cardinal;
  LSlot: PIORingReaderSlot;
  LPrepared: Boolean;
begin
  while (FOutstanding < FReadAhead) and (FNextReadOffset < FEnd) do
  begin
    LIndex := (FHead + FOutstanding) mod FBufferCount;
    LSlot := @FSlots[LIndex];

    // Always the whole buffer: unbuffered reads need sector multiples, and the
    // read at the end of the file simply returns fewer bytes
    if FRegistered then
      LPrepared := FRing.PrepareRead(TIORingFileRef.FromIndex(0),
        TIORingBufferRef.FromRegistered(0, LIndex * FBufferSize), FBufferSize, UInt64(FNextReadOffset), LIndex)
    else
      LPrepared := FRing.PrepareRead(TIORingFileRef.FromHandle(FFile),
        TIORingBufferRef.FromPointer(LSlot.Data), FBufferSize, UInt64(FNextReadOffset), LIndex);
    if not LPrepared then
      Break;

    LSlot.State := rssInFlight;
    LSlot.FileOffset := FNextReadOffset;
    if FEnd - FNextReadOffset < FBufferSize then
      LSlot.Expected := Cardinal(FEnd - FNextReadOffset)
    else
      LSlot.Expected := FBufferSize;
    LSlot.BytesRead := 0;
    LSlot.NativeResult := 0;

    Inc(FNextReadOffset, FBufferSize);
    Inc(FOutstanding);
    Inc(FStats.ReadsIssued);
  end;

  if FRing.PreparedCount > 0 then
    FRing.Submit;
end;

procedure TIORingSequentialReader.ProcessCompletions;
var
  LCompletion: TIORingCompletion;
  LSlot: PIORingReaderSlot;
begin
  while FRing.TryPopCompletion(LCompletion) do
  begin
    if LCompletion.UserData >= FBufferCount then
    begin
      // Registration. If it failed, the reads after it fail as well.
      LCompletion.RaiseIfFailed('Register file and buffers');
      Continue;
    end;

    LSlot := @FSlots[LCompletion.UserData];
    if LCompletion.Succeeded then
    begin
      LSlot.NativeResult := 0;
      // Data appended after Open is not delivered
      if LCompletion.BytesTransferred < LSlot.Expected then
        LSlot.BytesRead := Cardinal(LCompletion.BytesTransferred)
      else
        LSlot.BytesRead := LSlot.Expected;
    end
    else if LCompletion.IsEndOfFile then
    begin
      LSlot.NativeResult := 0;    // the file got shorter
      LSlot.BytesRead := 0;
    end
    else
    begin
      LSlot.NativeResult := LCompletion.NativeResult;
      LSlot.BytesRead := 0;
    end;

    Inc(FStats.BytesFromDisk, LSlot.BytesRead);
    LSlot.State := rssReady;
  end;
end;

procedure TIORingSequentialReader.Stall;
var
  LStart: UInt64;
begin
  Inc(FStats.Stalls);
  LStart := TIORingPlatform.TimestampMicroseconds;

  // The caller is faster than the disk: allow more reads in flight
  if FAdaptive and (FReadAhead < FBufferCount) then
  begin
    FReadAhead := FReadAhead * 2;
    if FReadAhead > FBufferCount then
      FReadAhead := FBufferCount;
    if FReadAhead > FStats.MaxReadAhead then
      FStats.MaxReadAhead := FReadAhead;
    IssueReads;
  end;

  // All completions were popped, so this waits for a new one
  while FSlots[FHead].State = rssInFlight do
  begin
    FRing.WaitForCompletions(1);
    ProcessCompletions;
  end;

  Inc(FStats.StallMicroseconds, TIORingPlatform.TimestampMicroseconds - LStart);
end;

function TIORingSequentialReader.PrepareHead(const AWait: Boolean): Boolean;
var
  LSlot: PIORingReaderSlot;
begin
  if FPosition >= FEnd then
    Exit(False);

  LSlot := @FSlots[FHead];
  if LSlot.State = rssFree then
    IssueReads;

  if LSlot.State = rssInFlight then
  begin
    ProcessCompletions;
    if LSlot.State = rssInFlight then
    begin
      if not AWait then
        Exit(False);
      Stall;
    end;
  end;

  if LSlot.NativeResult < 0 then
    raise EIORingError.CreateNative(LSlot.NativeResult,
      Format('Read at offset %d', [LSlot.FileOffset]));

  // Shorter than expected: the file got shorter after Open; this is its end now
  if LSlot.BytesRead < LSlot.Expected then
    FEnd := LSlot.FileOffset + LSlot.BytesRead;

  Result := FHeadOffset < LSlot.BytesRead;
end;

procedure TIORingSequentialReader.ReleaseHead;
begin
  FSlots[FHead].State := rssFree;
  FHead := (FHead + 1) mod FBufferCount;
  FHeadOffset := 0;
  Dec(FOutstanding);
  IssueReads;
end;

{ TIORingSequentialReader - reading }

function TIORingSequentialReader.Read(var ABuffer; const ACount: NativeInt): NativeInt;
var
  LTarget: PByte;
  LRemaining: NativeInt;
  LChunk: NativeInt;
  LSlot: PIORingReaderSlot;
begin
  CheckOpen;
  if FChunkAcquired then
    raise EInvalidOpException.Create('Call ReleaseChunk before Read');

  Result := 0;
  LTarget := @ABuffer;
  LRemaining := ACount;

  while (LRemaining > 0) and PrepareHead(True) do
  begin
    LSlot := @FSlots[FHead];
    LChunk := LSlot.BytesRead - FHeadOffset;
    if LChunk > LRemaining then
      LChunk := LRemaining;

    Move((LSlot.Data + FHeadOffset)^, LTarget^, LChunk);
    Inc(LTarget, LChunk);
    Dec(LRemaining, LChunk);
    Inc(Result, LChunk);
    Inc(FHeadOffset, LChunk);
    Inc(FPosition, LChunk);

    if FHeadOffset >= LSlot.BytesRead then
      ReleaseHead;
  end;
end;

function TIORingSequentialReader.TryAcquireChunk(out AData: PByte; out ALength: NativeInt;
  const AWait: Boolean): Boolean;
var
  LSlot: PIORingReaderSlot;
begin
  CheckOpen;
  if FChunkAcquired then
    raise EInvalidOpException.Create('Call ReleaseChunk before acquiring the next chunk');

  AData := nil;
  ALength := 0;
  if not PrepareHead(AWait) then
    Exit(False);

  LSlot := @FSlots[FHead];
  AData := LSlot.Data + FHeadOffset;
  ALength := LSlot.BytesRead - FHeadOffset;
  FChunkAcquired := True;
  Result := True;
end;

procedure TIORingSequentialReader.ReleaseChunk;
begin
  if not FChunkAcquired then
    raise EInvalidOpException.Create('No chunk is acquired');

  FChunkAcquired := False;
  Inc(FPosition, FSlots[FHead].BytesRead - FHeadOffset);
  ReleaseHead;
end;

function TIORingSequentialReader.DataReady: Boolean;
begin
  CheckOpen;
  if FPosition >= FEnd then
    Exit(True);

  ProcessCompletions;
  Result := FSlots[FHead].State = rssReady;
end;

function TIORingSequentialReader.Eof: Boolean;
begin
  Result := FPosition >= FEnd;
end;

end.
