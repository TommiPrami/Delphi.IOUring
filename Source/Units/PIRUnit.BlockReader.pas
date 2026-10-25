unit PIRUnit.BlockReader;

{
  Reads blocks that are known in advance - (offset, length) pairs that a provider gives - through a shared engine
  (Docs/Design.md §10.4, Phase 14).

    var
      LReader: TIORingBlockReader;               // closed at the end of scope
    begin
      LReader.Open(LEngine, LFile, NextBlock);   // or a list of blocks
      while LReader.TryGetBlock(LBlock, LData, LLength) do
      begin
        Process(LBlock, LData, LLength);         // zero-copy
        LReader.ReleaseBlock;
      end;
    end;

  Up to ReadAhead reads are in flight while the caller works on the current block. Neighbouring blocks (touching, or
  with at most MaxGap bytes between them) are read with one read, if it fits into one buffer. The blocks come out in the
  provider's order, whatever order the reads complete in.

  One thread at a time. The engine and the file handle belong to the caller: close the reader before destroying the
  engine or closing the file. Open the file with FILE_FLAG_OVERLAPPED (TIORingPlatform.OpenFileForRead does): on a
  handle opened without it, Windows reads one block at a time, whatever the read-ahead.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine;

const
  IORING_BLOCK_READER_DEFAULT_READ_AHEAD = 32;
  IORING_BLOCK_READER_DEFAULT_BUFFER_SIZE = 256 * 1024;
  IORING_BLOCK_READER_MAX_READ_AHEAD = 1024;

type
  TIORingBlock = record
    Offset: UInt64;
    Length: Cardinal;
    class function Create(const AOffset: UInt64; const ALength: Cardinal): TIORingBlock; static;
  end;

  { Gives the next block the reader will need. False: no more blocks. Called on the reader's thread, at most one block
    ahead of the reads already started. }
  TIORingBlockProvider = function(out ABlock: TIORingBlock): Boolean of object;

  TIORingBlockReaderStats = record
    Blocks: UInt64;               // blocks delivered by TryGetBlock
    Reads: UInt64;                // reads started (merged blocks count once)
    BytesRead: UInt64;            // bytes the completed reads returned
    Stalls: UInt64;               // times TryGetBlock had to wait for data
    StallMicroseconds: UInt64;    // total time spent waiting in those stalls
  end;

  // Custom managed record: owns the buffer memory and waits for its reads at the end of scope. Not copyable.
  TIORingBlockReader = record
  private
    type
      // One buffer and its read
      TSlotState = (bssFree, bssInFlight, bssReady);
      PSlot = ^TSlot;

      TSlot = record
        State: TSlotState;
        Data: PByte;
        Offset: UInt64;               // file offset of the read
        Length: Cardinal;             // bytes asked for
        BytesRead: Cardinal;          // bytes the read returned
        NativeResult: Integer;        // < 0 (and not end of file): the read failed
        Request: TIORingRequestHandle;
        Blocks: array of TIORingBlock;    // the blocks of this read, in order
        BlockCount: Integer;
      end;

  private
    FEngine: TIORingEngine;
    FFile: THandle;
    FProvider: TIORingBlockProvider;
    FList: array of TIORingBlock;     // the blocks of the list version of Open
    FListIndex: Integer;
    FUseList: Boolean;
    FMemory: PByte;
    FMemorySize: NativeUInt;      // for FreePages
    FSlots: array of TSlot;
    FBufferSize: Cardinal;
    FMaxGap: Cardinal;
    FHead: Integer;                   // the slot of the next block to deliver
    FHeadBlock: Integer;              // that block's index in the slot
    FOutstanding: Integer;            // slots in flight or ready, not yet delivered
    FNext: TIORingBlock;              // taken from the provider, not in a read yet
    FHaveNext: Boolean;
    FBlockAcquired: Boolean;
    FStats: TIORingBlockReaderStats;

    procedure OpenCommon(const AEngine: TIORingEngine; const AFile: THandle; const AReadAhead, ABufferSize,
      AMaxGap: Cardinal);
    function FetchBlock(var ABlock: TIORingBlock): Boolean;
    function CanJoin(const ASlot: PSlot; const ABlock: TIORingBlock): Boolean;
    procedure StartReads;
    function CompleteHead(const AWait: Boolean): Boolean;
    function GetReadAhead: Integer;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingBlockReader);
    class operator Finalize(var ADest: TIORingBlockReader);
    class operator Copy(constref ASource: TIORingBlockReader; var ADest: TIORingBlockReader);
{$ELSE}
    class operator Initialize(out ADest: TIORingBlockReader);
    class operator Finalize(var ADest: TIORingBlockReader);
    class operator Assign(var ADest: TIORingBlockReader; const [ref] ASource: TIORingBlockReader);
{$ENDIF}

    {
      Starts reading the blocks AProvider gives, from AFile (opened with read access) through AEngine. AReadAhead
      buffers of ABufferSize bytes: a block may be at most ABufferSize long. The engine must allow at least AReadAhead
      requests (TIORingEngine.MaxRequests). Raises EIORingError for bad arguments or if already open.
    }
    procedure Open(const AEngine: TIORingEngine; const AFile: THandle; const AProvider: TIORingBlockProvider;
      const AReadAhead: Cardinal = IORING_BLOCK_READER_DEFAULT_READ_AHEAD;
      const ABufferSize: Cardinal = IORING_BLOCK_READER_DEFAULT_BUFFER_SIZE;
      const AMaxGap: Cardinal = 0); overload;
    // The same with a list of blocks (copied)
    procedure Open(const AEngine: TIORingEngine; const AFile: THandle; const ABlocks: array of TIORingBlock;
      const AReadAhead: Cardinal = IORING_BLOCK_READER_DEFAULT_READ_AHEAD;
      const ABufferSize: Cardinal = IORING_BLOCK_READER_DEFAULT_BUFFER_SIZE;
      const AMaxGap: Cardinal = 0); overload;
    // Waits for the reads in flight, then releases everything. Does nothing if not open.
    procedure Close;
    function IsOpen: Boolean;

    {
      The next block, in the provider's order. AData: ALength bytes of it, valid until ReleaseBlock; ALength is shorter
      than ABlock.Length only at the end of the file (0 for a block that starts at or after it). False: no more blocks
      (Finished), or - with AWait = False - the data is not there yet. A failed read raises EIORingError.
    }
    function TryGetBlock(out ABlock: TIORingBlock; out AData: PByte; out ALength: Cardinal;
      const AWait: Boolean = True): Boolean;
    procedure ReleaseBlock;
    // True when every block has been delivered
    function Finished: Boolean;

    property ReadAhead: Integer read GetReadAhead;
    property BufferSize: Cardinal read FBufferSize;
    property MaxGap: Cardinal read FMaxGap;
    property Stats: TIORingBlockReaderStats read FStats;
  end;

implementation

uses
  PIRUnit.Types;

{ TIORingBlock }

class function TIORingBlock.Create(const AOffset: UInt64; const ALength: Cardinal): TIORingBlock;
begin
  Result.Offset := AOffset;
  Result.Length := ALength;
end;

{ TIORingBlockReader - life cycle }

{$IFDEF FPC}
class operator TIORingBlockReader.Initialize(var ADest: TIORingBlockReader);
{$ELSE}
class operator TIORingBlockReader.Initialize(out ADest: TIORingBlockReader);
{$ENDIF}
begin
  ADest.FEngine := nil;
  ADest.FFile := 0;
  ADest.FProvider := nil;
  ADest.FListIndex := 0;
  ADest.FUseList := False;
  ADest.FMemory := nil;
  ADest.FMemorySize := 0;
  ADest.FBufferSize := 0;
  ADest.FMaxGap := 0;
  ADest.FHead := 0;
  ADest.FHeadBlock := 0;
  ADest.FOutstanding := 0;
  ADest.FHaveNext := False;
  ADest.FBlockAcquired := False;
  FillChar(ADest.FStats, SizeOf(ADest.FStats), 0);
end;

class operator TIORingBlockReader.Finalize(var ADest: TIORingBlockReader);
begin
  ADest.Close;
end;

{$IFDEF FPC}
class operator TIORingBlockReader.Copy(constref ASource: TIORingBlockReader; var ADest: TIORingBlockReader);
{$ELSE}
class operator TIORingBlockReader.Assign(var ADest: TIORingBlockReader; const [ref] ASource: TIORingBlockReader);
{$ENDIF}

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A block reader cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure RaiseAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseIORingError('The block reader is already open');
end;

procedure TIORingBlockReader.Open(const AEngine: TIORingEngine; const AFile: THandle;
  const AProvider: TIORingBlockProvider; const AReadAhead, ABufferSize, AMaxGap: Cardinal);

  procedure RaiseNoProvider; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('Block reader: no block provider');
  end;

begin
  if IsOpen then
    RaiseAlreadyOpen;

  if not Assigned(AProvider) then
    RaiseNoProvider;

  FProvider := AProvider;
  FUseList := False;
  OpenCommon(AEngine, AFile, AReadAhead, ABufferSize, AMaxGap);
end;

procedure TIORingBlockReader.Open(const AEngine: TIORingEngine; const AFile: THandle;
  const ABlocks: array of TIORingBlock; const AReadAhead, ABufferSize, AMaxGap: Cardinal);
var
  LIndex: Integer;
begin
  if IsOpen then
    RaiseAlreadyOpen;

  SetLength(FList, Length(ABlocks));

  for LIndex := 0 to High(ABlocks) do
    FList[LIndex] := ABlocks[LIndex];

  FListIndex := 0;
  FUseList := True;
  OpenCommon(AEngine, AFile, AReadAhead, ABufferSize, AMaxGap);
end;

procedure TIORingBlockReader.OpenCommon(const AEngine: TIORingEngine; const AFile: THandle;
  const AReadAhead, ABufferSize, AMaxGap: Cardinal);

  procedure RaiseNoEngine; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('Block reader: no engine');
  end;

  procedure RaiseReadAheadOutOfRange(const ACount: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Read-ahead %d is not between 1 and %d', [ACount, IORING_BLOCK_READER_MAX_READ_AHEAD]);
  end;

  procedure RaiseReadAheadTooBig(const ACount: Cardinal; const AMaxRequests: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Read-ahead %d is more than the engine''s %d requests', [ACount, AMaxRequests]);
  end;

  procedure RaiseBufferSizeZero; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('Block reader: the buffer size must not be 0');
  end;

  procedure RaiseBuffersTooBig(const ACount: Cardinal; const ASize: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('%d buffers of %d bytes do not fit in memory', [ACount, ASize]);
  end;

var
  LTotalSize: UInt64;
  LIndex: Integer;
begin
  try
    if AEngine = nil then
      RaiseNoEngine;

    if (AReadAhead = 0) or (AReadAhead > IORING_BLOCK_READER_MAX_READ_AHEAD) then
      RaiseReadAheadOutOfRange(AReadAhead);

    if AReadAhead > AEngine.MaxRequests then
      RaiseReadAheadTooBig(AReadAhead, AEngine.MaxRequests);

    if ABufferSize = 0 then
      RaiseBufferSizeZero;

    LTotalSize := UInt64(AReadAhead) * ABufferSize;

    if LTotalSize > UInt64(High(NativeInt) div 2) then
      RaiseBuffersTooBig(AReadAhead, ABufferSize);

    FMemorySize := NativeUInt(LTotalSize);
    FMemory := TIORingPlatform.AllocPages(FMemorySize);
    SetLength(FSlots, AReadAhead);

    for LIndex := 0 to High(FSlots) do
    begin
      FSlots[LIndex].State := bssFree;
      FSlots[LIndex].Data := FMemory + NativeUInt(LIndex) * ABufferSize;
      FSlots[LIndex].BlockCount := 0;
    end;

    FEngine := AEngine;
    FFile := AFile;
    FBufferSize := ABufferSize;
    FMaxGap := AMaxGap;
    FHead := 0;
    FHeadBlock := 0;
    FOutstanding := 0;
    FBlockAcquired := False;
    FillChar(FStats, SizeOf(FStats), 0);

    FHaveNext := FetchBlock(FNext);
    StartReads;
  except
    Close;
    raise;
  end;
end;

procedure TIORingBlockReader.Close;
var
  LIndex: Integer;
  LCompletion: TIORingCompletion;
begin
  // A read in flight writes into the buffers: wait for it first
  if FEngine <> nil then
    for LIndex := 0 to High(FSlots) do
      if FSlots[LIndex].State = bssInFlight then

      try
        FEngine.Wait(FSlots[LIndex].Request, LCompletion);
      except
        on EIORingError do
          ;    // not a valid request any more: nothing to wait for
      end;

  TIORingPlatform.FreePages(FMemory, FMemorySize);
  FMemory := nil;
  FSlots := nil;
  FList := nil;
  FListIndex := 0;
  FUseList := False;
  FProvider := nil;
  FEngine := nil;
  FFile := 0;
  FBufferSize := 0;
  FMaxGap := 0;
  FHead := 0;
  FHeadBlock := 0;
  FOutstanding := 0;
  FHaveNext := False;
  FBlockAcquired := False;
end;

function TIORingBlockReader.IsOpen: Boolean;
begin
  Result := FEngine <> nil;
end;

function TIORingBlockReader.GetReadAhead: Integer;
begin
  Result := Length(FSlots);
end;

{ TIORingBlockReader - reading }

function TIORingBlockReader.FetchBlock(var ABlock: TIORingBlock): Boolean;

  procedure RaiseBadBlockLength(const ALength: Cardinal; const AOffset: UInt64; const ABufferSize: Cardinal);
      {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('Block of %d bytes at offset %d: the length must be 1..%d (the buffer size)',
      [ALength, AOffset, ABufferSize]);
  end;

begin
  if FUseList then
  begin
    Result := FListIndex < Length(FList);

    if Result then
    begin
      ABlock := FList[FListIndex];
      Inc(FListIndex);
    end
    else
      ABlock := TIORingBlock.Create(0, 0);
  end
  else
    Result := FProvider(ABlock);

  if Result and ((ABlock.Length = 0) or (ABlock.Length > FBufferSize)) then
    RaiseBadBlockLength(ABlock.Length, ABlock.Offset, FBufferSize);
end;

function TIORingBlockReader.CanJoin(const ASlot: TIORingBlockReader.PSlot; const ABlock: TIORingBlock): Boolean;
var
  LEnd: UInt64;
begin
  // At or after the read's end, at most MaxGap bytes after it, and the read still fits into one buffer
  LEnd := ASlot^.Offset + ASlot^.Length;
  Result := (ABlock.Offset >= LEnd) and (ABlock.Offset - LEnd <= FMaxGap) and
    (ABlock.Offset + ABlock.Length - ASlot^.Offset <= FBufferSize);
end;

procedure TIORingBlockReader.StartReads;
var
  LSlot: PSlot;
begin
  if not FHaveNext or (FOutstanding >= Length(FSlots)) then
    Exit;

  // All reads of this round wake the I/O thread once
  FEngine.BeginBatch;

  try
    while FHaveNext and (FOutstanding < Length(FSlots)) do
    begin
      LSlot := @FSlots[(FHead + FOutstanding) mod Length(FSlots)];
      LSlot^.Offset := FNext.Offset;
      LSlot^.Length := FNext.Length;
      LSlot^.BlockCount := 0;

      repeat
        if LSlot^.BlockCount = Length(LSlot^.Blocks) then
          SetLength(LSlot^.Blocks, 2 * LSlot^.BlockCount + 4);

        LSlot^.Blocks[LSlot^.BlockCount] := FNext;
        Inc(LSlot^.BlockCount);
        LSlot^.Length := Cardinal(FNext.Offset + FNext.Length - LSlot^.Offset);
        FHaveNext := FetchBlock(FNext);
      until not FHaveNext or not CanJoin(LSlot, FNext);

      LSlot^.BytesRead := 0;
      LSlot^.NativeResult := 0;
      LSlot^.Request := FEngine.ReadAsync(FFile, LSlot^.Data^, LSlot^.Length, LSlot^.Offset);
      LSlot^.State := bssInFlight;
      Inc(FOutstanding);
      Inc(FStats.Reads);
    end;
  finally
    FEngine.EndBatch;
  end;
end;

function TIORingBlockReader.CompleteHead(const AWait: Boolean): Boolean;
var
  LSlot: PSlot;
  LCompletion: TIORingCompletion;
  LStart: UInt64;
begin
  LSlot := @FSlots[FHead];

  if not FEngine.TryGetResult(LSlot^.Request, LCompletion) then
  begin
    if not AWait then
      Exit(False);

    Inc(FStats.Stalls);
    LStart := TIORingPlatform.TimestampMicroseconds;
    FEngine.Wait(LSlot^.Request, LCompletion);
    Inc(FStats.StallMicroseconds, TIORingPlatform.TimestampMicroseconds - LStart);
  end;

  { The request is finished either way: the slot no longer waits for it. A failure is kept: every
    block of this read raises it. }
  LSlot^.State := bssReady;

  if LCompletion.IsEndOfFile then
    LSlot^.NativeResult := 0
  else
    LSlot^.NativeResult := LCompletion.NativeResult;

  if LCompletion.Succeeded then
    LSlot^.BytesRead := Cardinal(LCompletion.BytesTransferred);

  Inc(FStats.BytesRead, LSlot^.BytesRead);

  Result := True;
end;

function TIORingBlockReader.TryGetBlock(out ABlock: TIORingBlock; out AData: PByte; out ALength: Cardinal;
  const AWait: Boolean): Boolean;

  procedure RaiseNotOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The block reader is not open');
  end;

  procedure RaiseBlockNotReleased; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('TryGetBlock: call ReleaseBlock first');
  end;

  procedure RaiseReadFailed(const AResult: Integer; const AOffset: UInt64); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorNativeFmt(AResult, 'Block read at offset %d', [AOffset]);
  end;

var
  LSlot: PSlot;
  LStart: UInt64;
begin
  ABlock := TIORingBlock.Create(0, 0);
  AData := nil;
  ALength := 0;

  if not IsOpen then
    RaiseNotOpen;

  if FBlockAcquired then
    RaiseBlockNotReleased;

  StartReads;

  if FOutstanding = 0 then
    Exit(False);    // every block delivered

  LSlot := @FSlots[FHead];

  if (LSlot^.State = bssInFlight) and not CompleteHead(AWait) then
    Exit(False);

  if LSlot^.NativeResult < 0 then
    RaiseReadFailed(LSlot^.NativeResult, LSlot^.Offset);

  ABlock := LSlot^.Blocks[FHeadBlock];
  LStart := ABlock.Offset - LSlot^.Offset;
  AData := LSlot^.Data + NativeUInt(LStart);

  // Shorter only where the read stopped at the end of the file
  if LSlot^.BytesRead <= LStart then
    ALength := 0
  else if LSlot^.BytesRead - LStart < ABlock.Length then
    ALength := Cardinal(LSlot^.BytesRead - LStart)
  else
    ALength := ABlock.Length;

  FBlockAcquired := True;
  Inc(FStats.Blocks);

  Result := True;
end;

procedure TIORingBlockReader.ReleaseBlock;

  procedure RaiseNoBlock; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('ReleaseBlock without a block from TryGetBlock');
  end;

var
  LSlot: PSlot;

begin
  if not FBlockAcquired then
    RaiseNoBlock;

  FBlockAcquired := False;
  LSlot := @FSlots[FHead];
  Inc(FHeadBlock);

  if FHeadBlock >= LSlot^.BlockCount then
  begin
    // The buffer is free: its next read starts at once
    LSlot^.State := bssFree;
    FHeadBlock := 0;
    FHead := (FHead + 1) mod Length(FSlots);
    Dec(FOutstanding);
    StartReads;
  end;
end;

function TIORingBlockReader.Finished: Boolean;
begin
  Result := IsOpen and not FHaveNext and (FOutstanding = 0);
end;

end.
