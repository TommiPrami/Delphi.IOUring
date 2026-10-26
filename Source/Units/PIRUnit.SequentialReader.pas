unit PIRUnit.SequentialReader;

{
  Reads a file front to back with read-ahead (Docs/Design.md §7).

  BufferCount buffers of BufferSize bytes form a circular queue. Reads for the next buffers are in flight while the
  caller works on the current one, so in the best case Read only copies data that is already there.

     var
       LReader: TIORingSequentialReader;
     begin
       LReader.Open('big.dat');                       // closed at the end of scope
       while LReader.TryAcquireChunk(LData, LLength) do
       begin
         Process(LData, LLength);                     // zero-copy
         LReader.ReleaseChunk;
       end;
     end;

  The size is taken when the file is opened: data appended later is not read. If the file turns out shorter, the
  reader stops there (end of file). One thread at a time.

  Big Read calls (Docs/Design.md §12.8): the part of a call that the buffers have not asked for yet is read straight
  into the caller's memory - one copy less. The buffers read ahead after the end of the call once all of those
  reads have started. Unbuffered, only when the caller's memory and the part's length are whole sectors.

  Several chunks at once (Docs/Design.md §12.11): TryAcquireChunk(out AChunk) and ReleaseChunk(const AChunk) can be
  called from several threads. The chunks come in file order, each with its file offset, and go back in any order;
  a released buffer is read into again at once. For workers that each take the next piece of the file:

     // on each worker thread
     while LReader.TryAcquireChunk(LChunk) do
     begin
       Process(LChunk.Data, LChunk.Length, LChunk.FileOffset);
       LReader.ReleaseChunk(LChunk);
     end;

  The free buffers are kept in a list, and the reads started are queued in file order, so a buffer can be released
  while the ones before it are still out.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing;

const
  IORING_READER_DEFAULT_BUFFER_SIZE = 1024 * 1024;
  IORING_READER_DEFAULT_BUFFER_COUNT = 8;
  { BufferSize must be a multiple of this (page size; also covers the sector size needed for
    unbuffered reads on usual disks) }
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

  TIORingSequentialReaderStats = record
    ReadsIssued: UInt64;          // reads into the buffers
    BytesFromDisk: UInt64;        // bytes the completed reads returned (both kinds)
    Stalls: UInt64;               // times Read / TryAcquireChunk had to wait for data
    StallMicroseconds: UInt64;    // total time spent waiting in those stalls
    MaxReadAhead: Cardinal;       // largest number of buffers allowed in flight
    DirectReads: UInt64;          // reads straight into the caller's memory (big Read calls)
    DirectBytes: UInt64;          // bytes those reads returned
  end;

  { A chunk of TIORingSequentialReader.TryAcquireChunk(out AChunk): the reader's own buffer, valid until
    ReleaseChunk(AChunk) }
  TIORingReaderChunk = record
  private
    FSlot: Cardinal;
  public
    Data: PByte;
    Length: NativeInt;
    // Where Data starts in the file
    FileOffset: Int64;
  end;

  { Custom managed record: owns the file handle (if asked), the ring and the buffer memory, and releases them at the
    end of scope. Not copyable. }
  TIORingSequentialReader = record
  private
    type
      // One buffer. rssTaken: out as a chunk of TryAcquireChunk(out AChunk).
      TSlotState = (rssFree, rssInFlight, rssReady, rssTaken);
      PSlot = ^TSlot;

      TSlot = record
        State: TSlotState;
        Data: PByte;
        FileOffset: Int64;
        Expected: Cardinal;       // bytes this buffer should get (up to the size at open)
        BytesRead: Cardinal;
        NativeResult: Integer;    // < 0: the read failed
      end;

      // One read straight into the caller's memory
      PDirectRead = ^TDirectRead;

      TDirectRead = record
        InFlight: Boolean;
        FileOffset: Int64;
        Length: Cardinal;
      end;

  private
    FRing: TIORing;
    FFile: THandle;
    FHasFile: Boolean;
    FOwnsFile: Boolean;
    FMemory: PByte;
    FMemorySize: NativeUInt;      // for FreePages
    FSlots: array of TSlot;
    FBufferSize: Cardinal;
    FBufferCount: Cardinal;
    FRegistered: Boolean;
    FAdaptive: Boolean;
    FSize: Int64;
    FEnd: Int64;              // FSize, or less if the file turned out shorter
    FPosition: Int64;
    FNextReadOffset: Int64;
    // The slots in flight or ready, not yet delivered, in file order (a ring). The first holds the data at FPosition.
    FOrder: array of Cardinal;
    FOrderFirst: Cardinal;
    FOrderCount: Cardinal;
    // The free slots (a stack: the one freed last is read into first, its memory is warm)
    FFree: array of Cardinal;
    FFreeCount: Cardinal;
    FHeadOffset: Cardinal;    // bytes of the first slot in FOrder already delivered
    FReadAhead: Cardinal;     // how many slots may be in FOrder
    FChunkAcquired: Boolean;
    // Several chunks at once: how many are out; the lock (0 free, 1 taken, 2 taken and maybe waited for); counts the
    // releases, so a thread that waits for a free buffer can sleep on it
    FTakenCount: Cardinal;
    FLockState: Integer;
    FReleaseCount: Integer;
    FReleaseWaiters: Integer;
    FStats: TIORingSequentialReaderStats;
    // Big Read calls: the reads straight into the caller's memory
    FAlignment: Cardinal;         // unbuffered: the sector size; buffered: 1
    FDirectReads: array of TDirectRead;
    FDirectTarget: PByte;         // the caller's memory for FDirectStart
    FDirectStart: Int64;          // the part of the file they read
    FDirectEnd: Int64;            // shrinks to the end of the data when a read comes back short
    FDirectNext: Int64;           // next offset to read
    FDirectInFlight: Cardinal;
    FDirectError: Integer;        // < 0: one of them failed (the first error)
    FDirectErrorOffset: Int64;
    FDirectFailed: Boolean;       // a big Read failed: every later call fails (the data would have a gap)

    procedure CheckOpen;
    procedure IssueReads;
    procedure ProcessCompletions;
    procedure Stall;
    function PrepareHead(const AWait: Boolean): Boolean;
    function PopHead: Cardinal;
    procedure ReleaseHead;
    procedure Lock;
    procedure Unlock;
    function CopyFromBuffers(var ATarget: PByte; const AMaxCount: NativeInt): NativeInt;
    function PlanDirectRead(const ATarget: PByte; const ACount: NativeInt; var AStart, AEnd: Int64): Boolean;
    procedure IssueDirectReads;
    procedure DirectReadDone(const ACompletion: TIORingCompletion);
    procedure WaitForDirectReads;
    procedure AbandonDirectReads;
    procedure RaiseDirectFailure; {$IFNDEF FPC} noreturn; {$ENDIF}
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

    { Opens the file and starts reading ahead. ABufferSize: multiple of IORING_READER_BUFFER_SIZE_UNIT. ABufferCount:
      1..IORING_READER_MAX_BUFFER_COUNT. }
    procedure Open(const AFileName: string; const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = IORING_READER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_READER_DEFAULT_BUFFER_COUNT); overload;
    { Reads from a handle opened by the caller (read access; for sroUnbuffered it must have been opened unbuffered).
      With AOwnsHandle the reader closes it, also when Open fails. sroNoSequentialScanHint has no effect here. }
    procedure Open(const AHandle: THandle; const AOwnsHandle: Boolean;
      const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = IORING_READER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_READER_DEFAULT_BUFFER_COUNT); overload;
    // Waits for the reads in flight, then releases everything. Does nothing if not open.
    procedure Close;
    function IsOpen: Boolean;

    // Copies up to ACount bytes; returns fewer only at the end of the file
    function Read(var ABuffer; const ACount: NativeInt): NativeInt;

    { Zero-copy: the rest of the current buffer, valid until ReleaseChunk. False at the end of the file, or (AWait =
      False) when the data is not there yet - check Eof to tell them apart. }
    function TryAcquireChunk(out AData: PByte; out ALength: NativeInt; const AWait: Boolean = True): Boolean; overload;
    procedure ReleaseChunk; overload;

    {
      Several chunks at once, from several threads: the next chunk in file order, a buffer of its own, valid until
      ReleaseChunk(AChunk). Release them in any order; the buffer is read into again at once. When every buffer is out
      as a chunk, waits for a release (AWait = False: returns False). False at the end of the file - check Eof. Do not
      mix with Read or the chunks above while chunks of these are out; Close only after all are released.
    }
    function TryAcquireChunk(out AChunk: TIORingReaderChunk; const AWait: Boolean = True): Boolean; overload;
    procedure ReleaseChunk(const AChunk: TIORingReaderChunk); overload;

    // True if the next Read returns at once (data is there, or end of file)
    function DataReady: Boolean;
    function Eof: Boolean;

    property Position: Int64 read FPosition;    // bytes delivered so far
    property Size: Int64 read FSize;            // file size when opened
    property BufferSize: Cardinal read FBufferSize;
    property BufferCount: Cardinal read FBufferCount;
    property Stats: TIORingSequentialReaderStats read FStats;
  end;

implementation

uses
  PIRUnit.Types, PIRUnit.Atomics;

const
  // UserData of the registration entries; slot indexes are below IORING_READER_MAX_BUFFER_COUNT
  REGISTRATION_USER_DATA = TIORingUserData(High(TIORingUserData));
  // UserData of a read straight into the caller's memory: this + its index
  DIRECT_USER_DATA = TIORingUserData(IORING_READER_MAX_BUFFER_COUNT);
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
  ADest.FOrderFirst := 0;
  ADest.FOrderCount := 0;
  ADest.FFreeCount := 0;
  ADest.FHeadOffset := 0;
  ADest.FReadAhead := 0;
  ADest.FChunkAcquired := False;
  ADest.FTakenCount := 0;
  ADest.FLockState := 0;
  ADest.FReleaseCount := 0;
  ADest.FReleaseWaiters := 0;
  FillChar(ADest.FStats, SizeOf(ADest.FStats), 0);
  ADest.FAlignment := 1;
  ADest.FDirectTarget := nil;
  ADest.FDirectStart := 0;
  ADest.FDirectEnd := 0;
  ADest.FDirectNext := 0;
  ADest.FDirectInFlight := 0;
  ADest.FDirectError := 0;
  ADest.FDirectErrorOffset := 0;
  ADest.FDirectFailed := False;
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

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A sequential reader cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure RaiseReaderAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseIORingError('The reader is already open');
end;

procedure TIORingSequentialReader.Open(const AFileName: string; const AOptions: TIORingSequentialReaderOptions;
  const ABufferSize, ABufferCount: Cardinal);
var
  LHandle: THandle;
begin
  if IsOpen then
    RaiseReaderAlreadyOpen;

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
  LRegistration: TIORingCompletion;
begin
  if IsOpen then
    RaiseReaderAlreadyOpen;

  FFile := AHandle;
  FHasFile := True;
  FOwnsFile := AOwnsHandle;

  try
    LTotalSize := IORingCheckBufferArguments(ABufferSize, ABufferCount, IORING_READER_BUFFER_SIZE_UNIT,
      IORING_READER_MAX_BUFFER_COUNT);
    FAlignment := 1;

    if sroUnbuffered in AOptions then
    begin
      LSectorSize := TIORingPlatform.GetSectorSize(AHandle);
      IORingCheckSectorMultiple(ABufferSize, LSectorSize);
      FAlignment := LSectorSize;
    end;

    FSize := TIORingPlatform.GetFileSize(AHandle);
    FBufferSize := ABufferSize;
    FBufferCount := ABufferCount;
    FMemorySize := NativeUInt(LTotalSize);
    FMemory := TIORingPlatform.AllocPages(FMemorySize);

    SetLength(FSlots, ABufferCount);
    SetLength(FOrder, ABufferCount);
    SetLength(FFree, ABufferCount);

    for LIndex := 0 to ABufferCount - 1 do
    begin
      FSlots[LIndex].State := rssFree;
      FSlots[LIndex].Data := FMemory + NativeUInt(LIndex) * ABufferSize;
      // Slot 0 on top: the first reads go to the slots in order
      FFree[LIndex] := ABufferCount - 1 - LIndex;
    end;

    FFreeCount := ABufferCount;

    // As many reads straight into a caller's memory as there are buffers
    SetLength(FDirectReads, ABufferCount);
    FillChar(FDirectReads[0], ABufferCount * SizeOf(TDirectRead), 0);
    FDirectInFlight := 0;

    // One entry per buffer and per direct read, plus the two registrations
    FRing.Open(2 * ABufferCount + 2);

    // A registered buffer's offset is 32 bits, so register only below 4 GiB
    FRegistered := not (sroNoRegistration in AOptions) and (LTotalSize <= High(Cardinal));

    if FRegistered then
    begin
      LBufferInfo.Address := FMemory;
      LBufferInfo.Length := Cardinal(LTotalSize);
      FRing.PrepareRegisterFiles([AHandle], REGISTRATION_USER_DATA);
      FRing.PrepareRegisterBuffers([LBufferInfo], REGISTRATION_USER_DATA);

      { Windows: submitted together with the first reads; registration is a barrier for them. Linux: registration is a
        system call, its results are there already - if it failed (for example RLIMIT_MEMLOCK), read without it. }
      while FRing.TryPopCompletion(LRegistration) do
        if not LRegistration.Succeeded then
          FRegistered := False;
    end;

    FAdaptive := not (sroFixedReadAhead in AOptions);

    if FAdaptive and (ABufferCount > INITIAL_ADAPTIVE_READ_AHEAD) then
      FReadAhead := INITIAL_ADAPTIVE_READ_AHEAD
    else
      FReadAhead := ABufferCount;

    FEnd := FSize;
    FPosition := 0;
    FNextReadOffset := 0;
    FOrderFirst := 0;
    FOrderCount := 0;
    FHeadOffset := 0;
    FChunkAcquired := False;
    FTakenCount := 0;
    FillChar(FStats, SizeOf(FStats), 0);
    FStats.MaxReadAhead := FReadAhead;
    FDirectNext := 0;
    FDirectEnd := 0;
    FDirectError := 0;
    FDirectErrorOffset := 0;
    FDirectFailed := False;

    // Submits the registrations too (also for an empty file, which gets no reads)
    IssueReads;
  except
    Close;
    raise;
  end;
end;

procedure TIORingSequentialReader.Close;
begin
  // The ring first: it waits for the reads still in flight, so the kernel is done with the buffers before they are freed
  FRing.Close;

  FSlots := nil;
  FOrder := nil;
  FFree := nil;
  FDirectReads := nil;
  FDirectInFlight := 0;
  TIORingPlatform.FreePages(FMemory, FMemorySize);
  FMemory := nil;

  if FHasFile and FOwnsFile then
    TIORingPlatform.CloseFile(FFile);

  FFile := 0;
  FHasFile := False;
  FOwnsFile := False;

  FBufferSize := 0;
  FBufferCount := 0;
  FOrderFirst := 0;
  FOrderCount := 0;
  FFreeCount := 0;
  FChunkAcquired := False;
  FTakenCount := 0;
end;

function TIORingSequentialReader.IsOpen: Boolean;
begin
  Result := FHasFile;
end;

procedure TIORingSequentialReader.CheckOpen;

  procedure RaiseNotOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The reader is not open');
  end;

begin
  if not FHasFile then
    RaiseNotOpen;

end;

{ TIORingSequentialReader - read-ahead engine }

procedure TIORingSequentialReader.IssueReads;
var
  LIndex: Cardinal;
  LSlot: PSlot;
  LPrepared: Boolean;
begin
  { A big Read: no reading ahead after the call until all of its reads straight into the caller's memory have started,
    so the file is read in order (the OS reads ahead too when it sees that) }
  if FDirectNext < FDirectEnd then
    Exit;

  while (FOrderCount < FReadAhead) and (FFreeCount > 0) and (FNextReadOffset < FEnd) do
  begin
    LIndex := FFree[FFreeCount - 1];
    LSlot := @FSlots[LIndex];

    { Always the whole buffer: unbuffered reads need sector multiples, and the read at the end of the file
      simply returns fewer bytes }
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

    Dec(FFreeCount);
    FOrder[(FOrderFirst + FOrderCount) mod FBufferCount] := LIndex;
    Inc(FOrderCount);
    Inc(FNextReadOffset, FBufferSize);
    Inc(FStats.ReadsIssued);
  end;

  if FRing.PreparedCount > 0 then
    FRing.Submit;
end;

procedure TIORingSequentialReader.ProcessCompletions;
var
  LCompletion: TIORingCompletion;
  LSlot: PSlot;
begin
  while FRing.TryPopCompletion(LCompletion) do
  begin
    if LCompletion.UserData = REGISTRATION_USER_DATA then
    begin
      // Registration. If it failed, the reads after it fail as well.
      LCompletion.RaiseIfFailed('Register file and buffers');

      Continue;
    end;

    if LCompletion.UserData >= DIRECT_USER_DATA then
    begin
      DirectReadDone(LCompletion);

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

  // All completions were popped, so this waits for a new one. FOrder is not empty here.
  while FSlots[FOrder[FOrderFirst]].State = rssInFlight do
  begin
    FRing.WaitForCompletions(1);
    ProcessCompletions;
  end;

  Inc(FStats.StallMicroseconds, TIORingPlatform.TimestampMicroseconds - LStart);
end;

function TIORingSequentialReader.PrepareHead(const AWait: Boolean): Boolean;

  procedure RaiseReadFailed(const AResult: Integer; const AOffset: Int64); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(AResult, 'Read at offset %d', [AOffset]);
  end;

var
  LSlot: PSlot;

begin
  if FDirectFailed then
    RaiseDirectFailure;

  if FPosition >= FEnd then
    Exit(False);

  if FOrderCount = 0 then
  begin
    IssueReads;

    // Every buffer is out as a chunk (several chunks at once): the caller waits for a release
    if FOrderCount = 0 then
      Exit(False);
  end;

  LSlot := @FSlots[FOrder[FOrderFirst]];

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
    RaiseReadFailed(LSlot.NativeResult, LSlot.FileOffset);

  // Shorter than expected: the file got shorter after Open; this is its end now
  if LSlot.BytesRead < LSlot.Expected then
    FEnd := LSlot.FileOffset + LSlot.BytesRead;

  Result := FHeadOffset < LSlot.BytesRead;
end;

// Takes the first slot out of FOrder (its data is delivered) and returns it
function TIORingSequentialReader.PopHead: Cardinal;
begin
  Result := FOrder[FOrderFirst];
  FOrderFirst := (FOrderFirst + 1) mod FBufferCount;
  Dec(FOrderCount);
  FHeadOffset := 0;
end;

procedure TIORingSequentialReader.ReleaseHead;
var
  LIndex: Cardinal;
begin
  LIndex := PopHead;
  FSlots[LIndex].State := rssFree;
  FFree[FFreeCount] := LIndex;
  Inc(FFreeCount);
  IssueReads;
end;

{ The lock of the chunks from several threads: 0 free, 1 taken, 2 taken and maybe waited for (Ulrich Drepper,
  "Futexes Are Tricky"). It is held while a thread waits for a read in flight - that read completes without any other
  thread - but never while waiting for a release. }
procedure TIORingSequentialReader.Lock;
begin
  if TAtomic.CompareExchange(FLockState, 1, 0) = 0 then
    Exit;

  while TAtomic.Exchange(FLockState, 2) <> 0 do
    TAtomic.WaitWhileEqual(FLockState, 2);
end;

procedure TIORingSequentialReader.Unlock;
begin
  if TAtomic.Exchange(FLockState, 0) = 2 then
    TAtomic.WakeOne(FLockState);
end;

{ TIORingSequentialReader - reading }

// Copies up to AMaxCount bytes from the buffers (waiting for them if needed)
function TIORingSequentialReader.CopyFromBuffers(var ATarget: PByte; const AMaxCount: NativeInt): NativeInt;
var
  LRemaining: NativeInt;
  LChunk: NativeInt;
  LSlot: PSlot;
begin
  Result := 0;
  LRemaining := AMaxCount;

  while (LRemaining > 0) and PrepareHead(True) do
  begin
    LSlot := @FSlots[FOrder[FOrderFirst]];
    LChunk := LSlot.BytesRead - FHeadOffset;

    if LChunk > LRemaining then
      LChunk := LRemaining;

    Move((LSlot.Data + FHeadOffset)^, ATarget^, LChunk);
    Inc(ATarget, LChunk);
    Dec(LRemaining, LChunk);
    Inc(Result, LChunk);
    Inc(FHeadOffset, LChunk);
    Inc(FPosition, LChunk);

    if FHeadOffset >= LSlot.BytesRead then
      ReleaseHead;
  end;
end;

{ The part of a call the buffers have not asked for yet: from FNextReadOffset to the end of the call. Worth it from one
  buffer size on; unbuffered only in whole sectors, into memory that starts on a sector boundary. }
function TIORingSequentialReader.PlanDirectRead(const ATarget: PByte; const ACount: NativeInt;
  var AStart, AEnd: Int64): Boolean;
begin
  AStart := FNextReadOffset;

  if AStart < FPosition then
    AStart := FPosition;

  AEnd := FPosition + ACount;

  if AEnd > FEnd then
    AEnd := FEnd;

  if AEnd - AStart < FBufferSize then
    Exit(False);

  if FAlignment > 1 then
  begin
    // FNextReadOffset is always on a sector boundary here (buffer sizes and earlier direct parts are whole sectors)
    AEnd := AStart + ((AEnd - AStart) div FAlignment) * FAlignment;

    if NativeUInt(ATarget + NativeInt(AStart - FPosition)) mod FAlignment <> 0 then
      Exit(False);
  end;

  Result := AEnd - AStart >= FBufferSize;
end;

{ Starts reads straight into the caller's memory, in pieces of the buffer size, up to as many in
  flight as there are buffers }
procedure TIORingSequentialReader.IssueDirectReads;
var
  LIndex: Cardinal;
  LLength: Int64;
  LTarget: PByte;
  LPrepared: Boolean;
begin
  LIndex := 0;

  while (FDirectNext < FDirectEnd) and (FDirectInFlight < FBufferCount) do
  begin
    // A free entry: there is one, fewer than FBufferCount are in flight
    while FDirectReads[LIndex].InFlight do
      Inc(LIndex);

    LLength := FDirectEnd - FDirectNext;

    if LLength > FBufferSize then
      LLength := FBufferSize;

    LTarget := FDirectTarget + NativeInt(FDirectNext - FDirectStart);

    if FRegistered then
      LPrepared := FRing.PrepareRead(TIORingFileRef.FromIndex(0), TIORingBufferRef.FromPointer(LTarget),
        Cardinal(LLength), UInt64(FDirectNext), DIRECT_USER_DATA + LIndex)
    else
      LPrepared := FRing.PrepareRead(TIORingFileRef.FromHandle(FFile), TIORingBufferRef.FromPointer(LTarget),
        Cardinal(LLength), UInt64(FDirectNext), DIRECT_USER_DATA + LIndex);

    if not LPrepared then
      Break;

    FDirectReads[LIndex].InFlight := True;
    FDirectReads[LIndex].FileOffset := FDirectNext;
    FDirectReads[LIndex].Length := Cardinal(LLength);
    Inc(FDirectNext, LLength);
    Inc(FDirectInFlight);
    Inc(FStats.DirectReads);
  end;

  // All started: the buffers read ahead after the call (submits all)
  if FDirectNext >= FDirectEnd then
    IssueReads
  else if FRing.PreparedCount > 0 then
    FRing.Submit;
end;

procedure TIORingSequentialReader.DirectReadDone(const ACompletion: TIORingCompletion);
var
  LRead: PDirectRead;
  LBytes: Cardinal;
  LEnd: Int64;
begin
  LRead := @FDirectReads[ACompletion.UserData - DIRECT_USER_DATA];
  LBytes := 0;

  if ACompletion.Succeeded then
  begin
    if ACompletion.BytesTransferred < LRead.Length then
      LBytes := Cardinal(ACompletion.BytesTransferred)
    else
      LBytes := LRead.Length;
  end
  else if not ACompletion.IsEndOfFile then
  begin
    // Raised by Read once all of them are back (the first error)
    if FDirectError = 0 then
    begin
      FDirectError := ACompletion.NativeResult;
      FDirectErrorOffset := LRead.FileOffset;
    end;

    FDirectFailed := True;
  end;

  // Short: the file ends there (it got shorter after Open); the data stops there, and no more pieces are started
  if LBytes < LRead.Length then
  begin
    LEnd := LRead.FileOffset + LBytes;

    if LEnd < FDirectEnd then
      FDirectEnd := LEnd;
  end;

  Inc(FStats.DirectBytes, LBytes);
  Inc(FStats.BytesFromDisk, LBytes);
  LRead.InFlight := False;
  Dec(FDirectInFlight);
end;

// Until every piece has been read; counts as a stall if it has to wait
procedure TIORingSequentialReader.WaitForDirectReads;

  procedure RaiseCouldNotStart; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('Reads straight into the caller''s memory could not be started');
  end;

var
  LStart: UInt64;

  LStalled: Boolean;
begin
  LStalled := False;
  LStart := 0;

  repeat
    ProcessCompletions;
    IssueDirectReads;

    if FDirectInFlight = 0 then
    begin
      if FDirectNext >= FDirectEnd then
        Break;

      { Nothing in flight and nothing could be started: should not happen (the ring has room for every buffer and
        every piece) }
      RaiseCouldNotStart;
    end;

    if not LStalled then
    begin
      LStalled := True;
      Inc(FStats.Stalls);
      LStart := TIORingPlatform.TimestampMicroseconds;
    end;

    FRing.WaitForCompletions(1);
  until False;

  if LStalled then
    Inc(FStats.StallMicroseconds, TIORingPlatform.TimestampMicroseconds - LStart);
end;

{ After an exception: no more pieces, and wait for those in flight - they write into the caller's memory, which may be
  gone once Read has returned }
procedure TIORingSequentialReader.AbandonDirectReads;
begin
  FDirectEnd := FDirectNext;

  while FDirectInFlight > 0 do
  begin
    FRing.WaitForCompletions(1);
    ProcessCompletions;
  end;
end;

procedure TIORingSequentialReader.RaiseDirectFailure;
begin
  if FDirectError < 0 then
    RaiseIORingErrorNativeFmt(FDirectError, 'Read at offset %d', [FDirectErrorOffset]);

  RaiseIORingError('An earlier big Read failed; the reader cannot continue');
end;

procedure RaiseChunksOut; { FPC} noreturn; {}
begin
  RaiseError(EInvalidOpException, 'Release the chunks of TryAcquireChunk(AChunk) first');
end;

function TIORingSequentialReader.Read(var ABuffer; const ACount: NativeInt): NativeInt;

  procedure RaiseChunkAcquired; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'Call ReleaseChunk before Read');
  end;

var
  LTarget: PByte;

  LDirectStart: Int64;
  LDirectEnd: Int64;
begin
  CheckOpen;

  if FChunkAcquired then
    RaiseChunkAcquired;

  if FTakenCount > 0 then
    RaiseChunksOut;

  if FDirectFailed then
    RaiseDirectFailure;

  if ACount <= 0 then
    Exit(0);

  LTarget := @ABuffer;

  if not PlanDirectRead(LTarget, ACount, LDirectStart, LDirectEnd) then
    Exit(CopyFromBuffers(LTarget, ACount));

  { A big call: [LDirectStart, LDirectEnd) is read straight into the caller's memory; the buffers read ahead after
    LDirectEnd as soon as all of those reads have started }
  FDirectTarget := LTarget + NativeInt(LDirectStart - FPosition);
  FDirectStart := LDirectStart;
  FDirectEnd := LDirectEnd;
  FDirectNext := LDirectStart;
  FNextReadOffset := LDirectEnd;

  try
    IssueDirectReads;
    // What the buffers hold before the direct part
    Result := CopyFromBuffers(LTarget, NativeInt(LDirectStart - FPosition));
    WaitForDirectReads;
  except
    // The buffers already read after the call: going on would leave a gap
    FDirectFailed := True;
    AbandonDirectReads;
    raise;
  end;

  if FDirectFailed then
    RaiseDirectFailure;

  // The buffers ended before the direct part: the file got shorter
  if FPosition < LDirectStart then
    Exit;

  Inc(Result, NativeInt(FDirectEnd - LDirectStart));
  LTarget := FDirectTarget + NativeInt(FDirectEnd - LDirectStart);
  FPosition := FDirectEnd;

  if FDirectEnd < LDirectEnd then
  begin
    // A piece came back short: the file ends there now
    FEnd := FDirectEnd;

    Exit;
  end;

  // The rest of the call from the buffers (unbuffered: less than a sector)
  Inc(Result, CopyFromBuffers(LTarget, ACount - Result));
end;

function TIORingSequentialReader.TryAcquireChunk(out AData: PByte; out ALength: NativeInt;
  const AWait: Boolean): Boolean;

  procedure RaiseChunkAcquired; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'Call ReleaseChunk before acquiring the next chunk');
  end;

var
  LSlot: PSlot;
begin
  CheckOpen;

  if FChunkAcquired then
    RaiseChunkAcquired;

  if FTakenCount > 0 then
    RaiseChunksOut;

  AData := nil;
  ALength := 0;

  if not PrepareHead(AWait) then
    Exit(False);

  LSlot := @FSlots[FOrder[FOrderFirst]];
  AData := LSlot.Data + FHeadOffset;
  ALength := LSlot.BytesRead - FHeadOffset;
  FChunkAcquired := True;

  Result := True;
end;

procedure TIORingSequentialReader.ReleaseChunk;

  procedure RaiseNoChunk; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'No chunk is acquired');
  end;

begin
  if not FChunkAcquired then
    RaiseNoChunk;

  FChunkAcquired := False;
  Inc(FPosition, FSlots[FOrder[FOrderFirst]].BytesRead - FHeadOffset);
  ReleaseHead;
end;

function TIORingSequentialReader.DataReady: Boolean;
begin
  CheckOpen;

  if FPosition >= FEnd then
    Exit(True);

  ProcessCompletions;

  Result := (FOrderCount > 0) and (FSlots[FOrder[FOrderFirst]].State = rssReady);
end;

function TIORingSequentialReader.TryAcquireChunk(out AChunk: TIORingReaderChunk; const AWait: Boolean): Boolean;

  procedure RaiseOneChunkAcquired; { FPC} noreturn; {}
  begin
    RaiseError(EInvalidOpException, 'Release the chunk of TryAcquireChunk(AData, ALength) first');
  end;

var
  LIndex: Cardinal;
  LReleases: Integer;
  LSlot: PSlot;
begin
  CheckOpen;

  AChunk.FSlot := 0;
  AChunk.Data := nil;
  AChunk.Length := 0;
  AChunk.FileOffset := 0;

  Lock;
  try
    if FChunkAcquired then
      RaiseOneChunkAcquired;

    // Every buffer is out as a chunk: wait for a release, without the lock (the release needs it)
    while (FPosition < FEnd) and (FOrderCount = 0) and (FFreeCount = 0) do
    begin
      if not AWait then
        Exit(False);

      LReleases := FReleaseCount;
      Inc(FReleaseWaiters);
      Unlock;
      try
        TAtomic.WaitWhileEqual(FReleaseCount, LReleases);
      finally
        Lock;
        Dec(FReleaseWaiters);
      end;
    end;

    if not PrepareHead(AWait) then
      Exit(False);

    LSlot := @FSlots[FOrder[FOrderFirst]];
    AChunk.Data := LSlot.Data + FHeadOffset;
    AChunk.Length := LSlot.BytesRead - FHeadOffset;
    AChunk.FileOffset := LSlot.FileOffset + FHeadOffset;
    Inc(FPosition, AChunk.Length);

    LIndex := PopHead;
    LSlot.State := rssTaken;
    AChunk.FSlot := LIndex;
    Inc(FTakenCount);
    IssueReads;

    Result := True;
  finally
    Unlock;
  end;
end;

procedure TIORingSequentialReader.ReleaseChunk(const AChunk: TIORingReaderChunk);

  procedure RaiseNotAcquired; { FPC} noreturn; {}
  begin
    RaiseError(EInvalidOpException, 'The chunk is not acquired');
  end;

var
  LWake: Boolean;
begin
  CheckOpen;

  Lock;
  try
    if (AChunk.FSlot >= FBufferCount) or (FSlots[AChunk.FSlot].State <> rssTaken) then
      RaiseNotAcquired;

    FSlots[AChunk.FSlot].State := rssFree;
    FFree[FFreeCount] := AChunk.FSlot;
    Inc(FFreeCount);
    Dec(FTakenCount);
    TAtomic.Increment(FReleaseCount);
    LWake := FReleaseWaiters > 0;
    IssueReads;
  finally
    Unlock;
  end;

  if LWake then
    TAtomic.WakeAll(FReleaseCount);
end;

function TIORingSequentialReader.Eof: Boolean;
begin
  Result := FPosition >= FEnd;
end;

end.
