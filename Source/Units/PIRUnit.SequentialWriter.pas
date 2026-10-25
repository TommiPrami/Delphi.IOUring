unit PIRUnit.SequentialWriter;

{
  Writes a file front to back in the background (Docs/Design.md §8.2).

  BufferCount buffers of BufferSize bytes are used in turn. Write copies into the current buffer; a full buffer goes to
  an engine (TIORingEngine), whose I/O thread writes it while the caller fills the next one. The writes go through the
  engine and not through a ring of the caller's thread because Windows does buffered writes - and unbuffered writes that
  extend a file - inside the submit call (Design §2.1): the caller would do all the work itself.

    var
      LWriter: TIORingSequentialWriter;
    begin
      LWriter.Open('big.dat');
      LWriter.Write(LData, LLength);         // as often as needed
      LWriter.Close;                         // waits for the writes; raises if one failed
    end;

  A write fails after Write has returned, so its error comes later: the next
  Write, CommitBuffer or Flush that runs into it, and Close, raise EIORingError
  - and every later call again (the file's content is then unknown). At the
  end of scope without Close the rest is still written, but errors are lost.

  By default the writer has its own engine (one I/O thread). A shared engine (Open's AEngine) must allow at least
  BufferCount requests and live longer than the writer. One thread at a time.
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
  IORING_WRITER_DEFAULT_BUFFER_SIZE = 1024 * 1024;
  IORING_WRITER_DEFAULT_BUFFER_COUNT = 8;
  { BufferSize must be a multiple of this (page size; also covers the sector size needed for
    unbuffered writes on usual disks) }
  IORING_WRITER_BUFFER_SIZE_UNIT = 4096;
  IORING_WRITER_MAX_BUFFER_COUNT = 1024;

type
  TIORingSequentialWriterOption = (
    swoUnbuffered     // past the OS file cache (FILE_FLAG_NO_BUFFERING)
  );

  TIORingSequentialWriterOptions = set of TIORingSequentialWriterOption;

  TIORingSequentialWriterStats = record
    WritesIssued: UInt64;
    BytesWritten: UInt64;         // bytes the completed writes wrote (also again after a Flush)
    Waits: UInt64;                // times the caller had to wait for a free buffer
    WaitMicroseconds: UInt64;     // total time spent in those waits
  end;

  { Custom managed record: owns the file handle (if asked), its engine (if it made one) and the buffer memory, and
    releases them at the end of scope. Not copyable. }
  TIORingSequentialWriter = record
  private
    type
      // One buffer
      PSlot = ^TSlot;

      TSlot = record
        Data: PByte;
        FileOffset: Int64;
        Length: Cardinal;         // bytes of its write in flight
        Request: TIORingRequestHandle;
      end;

  private
    FEngine: TIORingEngine;
    FOwnsEngine: Boolean;
    FFile: THandle;
    FHasFile: Boolean;
    FOwnsFile: Boolean;
    FUnbuffered: Boolean;
    FSectorSize: Cardinal;
    FMemory: PByte;
    FMemorySize: NativeUInt;      // for FreePages
    FSlots: array of TSlot;
    FBufferSize: Cardinal;
    FBufferCount: Cardinal;
    { The slots in flight are the oldest FInFlight ones from FInFlightHead; the slot after them is being
      filled (FFill bytes so far) }
    FInFlightHead: Cardinal;
    FInFlight: Cardinal;
    FFill: Cardinal;
    FCurrentOffset: Int64;        // file offset of the buffer being filled
    FPosition: Int64;             // bytes accepted
    FBufferAcquired: Boolean;
    // The first failed write
    FFailed: Boolean;
    FFailCode: Integer;           // native code; 0: a short write
    FFailContext: string;
    FErrorReported: Boolean;
    FStats: TIORingSequentialWriterStats;

    procedure CheckOpen;
    procedure CheckUsable;
    procedure RaiseFailure; {$IFNDEF FPC} noreturn; {$ENDIF}
    function CurrentSlot: PSlot;
    function WaitedFor(const ASlot: PSlot; const AWait: Boolean): Boolean;
    procedure CollectFinished;
    procedure WaitForOldest;
    procedure MakeCurrentFree;
    procedure SubmitCurrent;
    procedure WaitForAll;
    procedure WritePartOfCurrent;
  public
{$IFDEF FPC}
    class operator Initialize(var ADest: TIORingSequentialWriter);
    class operator Finalize(var ADest: TIORingSequentialWriter);
    class operator Copy(constref ASource: TIORingSequentialWriter; var ADest: TIORingSequentialWriter);
{$ELSE}
    class operator Initialize(out ADest: TIORingSequentialWriter);
    class operator Finalize(var ADest: TIORingSequentialWriter);
    class operator Assign(var ADest: TIORingSequentialWriter; const [ref] ASource: TIORingSequentialWriter);
{$ENDIF}

    {
      Creates the file, or empties it if it exists. ABufferSize: multiple of IORING_WRITER_BUFFER_SIZE_UNIT (with
      swoUnbuffered also of the sector size). ABufferCount: 1..IORING_WRITER_MAX_BUFFER_COUNT. AEngine = nil: the
      writer makes its own engine.
    }
    procedure Open(const AFileName: string; const AOptions: TIORingSequentialWriterOptions = [];
      const ABufferSize: Cardinal = IORING_WRITER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_WRITER_DEFAULT_BUFFER_COUNT;
      const AEngine: TIORingEngine = nil); overload;
    { Writes to a handle opened by the caller (write access, overlapped; for swoUnbuffered opened unbuffered), from
      offset 0 on. With AOwnsHandle the writer closes it, also when Open fails. }
    procedure Open(const AHandle: THandle; const AOwnsHandle: Boolean;
      const AOptions: TIORingSequentialWriterOptions = [];
      const ABufferSize: Cardinal = IORING_WRITER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_WRITER_DEFAULT_BUFFER_COUNT;
      const AEngine: TIORingEngine = nil); overload;
    { Writes the rest, waits for all writes, cuts the file to its size (unbuffered) and releases everything. With
      ARaiseError a failed write raises EIORingError - after everything is released. Does nothing if not open. }
    procedure Close(const ARaiseError: Boolean = True);
    function IsOpen: Boolean;

    // Copies ACount bytes; full buffers are written at once
    procedure Write(const ABuffer; const ACount: NativeInt);

    { Zero-copy: the free part of the current buffer (ACapacity > 0). Fill some of it, then CommitBuffer with
      the number of bytes filled. }
    procedure AcquireBuffer(out AData: PByte; out ACapacity: NativeInt);
    procedure CommitBuffer(const ALength: NativeInt);

    { Writes what has been written so far, also a partly filled buffer, and waits until it is in the file. AToDisk:
      also FlushFileBuffers (slow). }
    procedure Flush(const AToDisk: Boolean = False);

    // A write has failed (and raises at the next call)
    property Failed: Boolean read FFailed;
    // That failure has been raised to the caller already
    property ErrorReported: Boolean read FErrorReported;
    property Position: Int64 read FPosition;    // bytes accepted so far
    property BufferSize: Cardinal read FBufferSize;
    property BufferCount: Cardinal read FBufferCount;
    property Stats: TIORingSequentialWriterStats read FStats;
  end;

implementation

uses
  PIRUnit.Types;

{ TIORingSequentialWriter - life cycle }

{$IFDEF FPC}
class operator TIORingSequentialWriter.Initialize(var ADest: TIORingSequentialWriter);
{$ELSE}
class operator TIORingSequentialWriter.Initialize(out ADest: TIORingSequentialWriter);
{$ENDIF}
begin
  ADest.FEngine := nil;
  ADest.FOwnsEngine := False;
  ADest.FFile := 0;
  ADest.FHasFile := False;
  ADest.FOwnsFile := False;
  ADest.FUnbuffered := False;
  ADest.FSectorSize := 0;
  ADest.FMemory := nil;
  ADest.FMemorySize := 0;
  ADest.FBufferSize := 0;
  ADest.FBufferCount := 0;
  ADest.FInFlightHead := 0;
  ADest.FInFlight := 0;
  ADest.FFill := 0;
  ADest.FCurrentOffset := 0;
  ADest.FPosition := 0;
  ADest.FBufferAcquired := False;
  ADest.FFailed := False;
  ADest.FFailCode := 0;
  ADest.FErrorReported := False;
  FillChar(ADest.FStats, SizeOf(ADest.FStats), 0);
end;

class operator TIORingSequentialWriter.Finalize(var ADest: TIORingSequentialWriter);
begin
  // Still writes the rest; an error cannot be raised here
  ADest.Close(False);
end;

{$IFDEF FPC}
class operator TIORingSequentialWriter.Copy(constref ASource: TIORingSequentialWriter;
  var ADest: TIORingSequentialWriter);
{$ELSE}
class operator TIORingSequentialWriter.Assign(var ADest: TIORingSequentialWriter;
  const [ref] ASource: TIORingSequentialWriter);
{$ENDIF}

  procedure RaiseCannotCopy; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'A sequential writer cannot be copied. Pass it as var or const [ref].');
  end;

begin
  RaiseCannotCopy;
end;

procedure RaiseWriterAlreadyOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseIORingError('The writer is already open');
end;

procedure TIORingSequentialWriter.Open(const AFileName: string; const AOptions: TIORingSequentialWriterOptions;
  const ABufferSize, ABufferCount: Cardinal; const AEngine: TIORingEngine);
var
  LHandle: THandle;
begin
  if IsOpen then
    RaiseWriterAlreadyOpen;

  LHandle := TIORingPlatform.CreateFileForWrite(AFileName, swoUnbuffered in AOptions);
  Open(LHandle, True, AOptions, ABufferSize, ABufferCount, AEngine);
end;

procedure TIORingSequentialWriter.Open(const AHandle: THandle; const AOwnsHandle: Boolean;
  const AOptions: TIORingSequentialWriterOptions; const ABufferSize, ABufferCount: Cardinal;
  const AEngine: TIORingEngine);

  procedure RaiseEngineTooSmall(const ACount: Cardinal; const AMaxRequests: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('%d buffers need an engine of at least %d requests, not %d', [ACount, ACount, AMaxRequests]);
  end;

var
  LTotalSize: UInt64;
  LIndex: Cardinal;
begin
  if IsOpen then
    RaiseWriterAlreadyOpen;

  FFile := AHandle;
  FHasFile := True;
  FOwnsFile := AOwnsHandle;

  try
    LTotalSize := IORingCheckBufferArguments(ABufferSize, ABufferCount, IORING_WRITER_BUFFER_SIZE_UNIT,
      IORING_WRITER_MAX_BUFFER_COUNT);

    if (AEngine <> nil) and (AEngine.MaxRequests < ABufferCount) then
      RaiseEngineTooSmall(ABufferCount, AEngine.MaxRequests);

    FUnbuffered := swoUnbuffered in AOptions;

    if FUnbuffered then
    begin
      FSectorSize := TIORingPlatform.GetSectorSize(AHandle);
      IORingCheckSectorMultiple(ABufferSize, FSectorSize);
    end;

    FBufferSize := ABufferSize;
    FBufferCount := ABufferCount;
    FMemorySize := NativeUInt(LTotalSize);
    FMemory := TIORingPlatform.AllocPages(FMemorySize);
    SetLength(FSlots, ABufferCount);

    for LIndex := 0 to ABufferCount - 1 do
    begin
      FSlots[LIndex].Data := FMemory + NativeUInt(LIndex) * ABufferSize;
      FSlots[LIndex].Request.Value := 0;
    end;

    if AEngine <> nil then
    begin
      FEngine := AEngine;
      FOwnsEngine := False;
    end
    else
    begin
      // Enough requests for all buffers, so that starting a write never waits
      FEngine := TIORingEngine.Create(ABufferCount + 2, ABufferCount + 2);
      FOwnsEngine := True;
    end;

    FInFlightHead := 0;
    FInFlight := 0;
    FFill := 0;
    FCurrentOffset := 0;
    FPosition := 0;
    FBufferAcquired := False;
    FFailed := False;
    FFailCode := 0;
    FFailContext := '';
    FErrorReported := False;
    FillChar(FStats, SizeOf(FStats), 0);
  except
    Close(False);
    raise;
  end;
end;

procedure TIORingSequentialWriter.Close(const ARaiseError: Boolean);
begin
  if not FHasFile then
    Exit;

  try
    // A write in flight still uses its buffer
    if FEngine <> nil then
      WaitForAll;

    // The rest (not after a failure: the file is not right anyway). A buffer acquired but not committed is not written.
    if not FFailed and (FEngine <> nil) and (FFill > 0) then

    try
      WritePartOfCurrent;
    except
      on E: EIORingError do
      begin
        FFailed := True;
        FFailCode := E.NativeCode;
        FFailContext := 'Write the last part';
      end;
    end;

    if FUnbuffered and not FFailed and (FMemory <> nil) then

    try
      TIORingPlatform.SetFileSize(FFile, FPosition);
    except
      on E: EIORingError do
      begin
        FFailed := True;
        FFailCode := E.NativeCode;
        FFailContext := 'Cut the file to its size';
      end;
    end;
  finally
    if FOwnsEngine then
      FEngine.Free;

    FEngine := nil;
    FOwnsEngine := False;
    FSlots := nil;
    TIORingPlatform.FreePages(FMemory, FMemorySize);
    FMemory := nil;

    if FOwnsFile then
      TIORingPlatform.CloseFile(FFile);

    FFile := 0;
    FHasFile := False;
    FOwnsFile := False;
    FBufferSize := 0;
    FBufferCount := 0;
    FInFlight := 0;
    FFill := 0;
    FBufferAcquired := False;
  end;

  if FFailed and ARaiseError then
    RaiseFailure;
end;

function TIORingSequentialWriter.IsOpen: Boolean;
begin
  Result := FHasFile;
end;

procedure TIORingSequentialWriter.CheckOpen;

  procedure RaiseNotOpen; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('The writer is not open');
  end;

begin
  if not FHasFile then
    RaiseNotOpen;

end;

procedure TIORingSequentialWriter.CheckUsable;
begin
  CheckOpen;

  if FFailed then
    RaiseFailure;
end;

procedure TIORingSequentialWriter.RaiseFailure;
begin
  FErrorReported := True;

  if FFailCode <> 0 then
    RaiseIORingErrorNative(FFailCode, FFailContext)
  else
    RaiseIORingError(FFailContext);
end;

{ TIORingSequentialWriter - the buffers }

function TIORingSequentialWriter.CurrentSlot: TIORingSequentialWriter.PSlot;
begin
  Result := @FSlots[(FInFlightHead + FInFlight) mod FBufferCount];
end;

function TIORingSequentialWriter.WaitedFor(const ASlot: TIORingSequentialWriter.PSlot; const AWait: Boolean): Boolean;
var
  LCompletion: TIORingCompletion;
begin
  // The write is finished either way afterwards; its failure is kept
  if AWait then
    Result := FEngine.Wait(ASlot^.Request, LCompletion)
  else
    Result := FEngine.TryGetResult(ASlot^.Request, LCompletion);

  if not Result then
    Exit;

  ASlot^.Request.Value := 0;

  if LCompletion.Succeeded then
    Inc(FStats.BytesWritten, LCompletion.BytesTransferred);

  if FFailed then
    Exit;

  if not LCompletion.Succeeded then
  begin
    FFailed := True;
    FFailCode := LCompletion.NativeResult;
    FFailContext := Format('Write at offset %d', [ASlot^.FileOffset]);
  end
  else if LCompletion.BytesTransferred <> ASlot^.Length then
  begin
    FFailed := True;
    FFailCode := 0;
    FFailContext := Format('Write at offset %d: only %d of %d bytes written', [ASlot^.FileOffset,
      LCompletion.BytesTransferred, ASlot^.Length]);
  end;
end;

procedure TIORingSequentialWriter.CollectFinished;
begin
  // Oldest first; stops at the first one still in flight
  while (FInFlight > 0) and WaitedFor(@FSlots[FInFlightHead], False) do
  begin
    FInFlightHead := (FInFlightHead + 1) mod FBufferCount;
    Dec(FInFlight);
  end;
end;

procedure TIORingSequentialWriter.WaitForOldest;
begin
  WaitedFor(@FSlots[FInFlightHead], True);
  FInFlightHead := (FInFlightHead + 1) mod FBufferCount;
  Dec(FInFlight);
end;

procedure TIORingSequentialWriter.MakeCurrentFree;
var
  LStart: UInt64;
begin
  // All buffers in flight: the one to fill next is the oldest of them
  if FInFlight = FBufferCount then
  begin
    Inc(FStats.Waits);
    LStart := TIORingPlatform.TimestampMicroseconds;
    WaitForOldest;
    Inc(FStats.WaitMicroseconds, TIORingPlatform.TimestampMicroseconds - LStart);
  end;
end;

procedure TIORingSequentialWriter.SubmitCurrent;
var
  LSlot: PSlot;
begin
  // A full buffer: written in the background; the next one is filled meanwhile
  LSlot := CurrentSlot;
  LSlot^.FileOffset := FCurrentOffset;
  LSlot^.Length := FFill;
  LSlot^.Request := FEngine.WriteAsync(FFile, LSlot^.Data^, FFill, UInt64(FCurrentOffset));
  Inc(FInFlight);
  Inc(FStats.WritesIssued);
  Inc(FCurrentOffset, FFill);
  FFill := 0;
  CollectFinished;
end;

procedure TIORingSequentialWriter.WaitForAll;
begin
  while FInFlight > 0 do
    WaitForOldest;
end;

procedure TIORingSequentialWriter.WritePartOfCurrent;
var
  LSlot: PSlot;
  LLength: Cardinal;
begin
  { The buffer stays the current one: when it is full, it is written again, whole, at the same offset - so every write
    starts where a buffer starts (sector-aligned for unbuffered writes) }
  LSlot := CurrentSlot;
  LLength := FFill;

  if FUnbuffered and (LLength mod FSectorSize <> 0) then
  begin
    // Whole sectors only; the file is cut to its size afterwards
    LLength := (LLength div FSectorSize + 1) * FSectorSize;
    FillChar((LSlot^.Data + FFill)^, LLength - FFill, 0);
  end;

  LSlot^.FileOffset := FCurrentOffset;
  LSlot^.Length := LLength;
  LSlot^.Request := FEngine.WriteAsync(FFile, LSlot^.Data^, LLength, UInt64(FCurrentOffset));
  Inc(FStats.WritesIssued);
  WaitedFor(LSlot, True);
end;

{ TIORingSequentialWriter - writing }

procedure TIORingSequentialWriter.Write(const ABuffer; const ACount: NativeInt);

  procedure RaiseBufferAcquired; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'Call CommitBuffer before Write');
  end;

var
  LSource: PByte;

  LRemaining: NativeInt;
  LChunk: NativeInt;
begin
  CheckUsable;

  if FBufferAcquired then
    RaiseBufferAcquired;

  if ACount <= 0 then
    Exit;

  LSource := @ABuffer;
  LRemaining := ACount;

  while LRemaining > 0 do
  begin
    MakeCurrentFree;

    if FFailed then
      RaiseFailure;

    LChunk := FBufferSize - FFill;

    if LChunk > LRemaining then
      LChunk := LRemaining;

    Move(LSource^, (CurrentSlot^.Data + FFill)^, LChunk);
    Inc(LSource, LChunk);
    Dec(LRemaining, LChunk);
    Inc(FFill, LChunk);
    Inc(FPosition, LChunk);

    if FFill = FBufferSize then
      SubmitCurrent;
  end;

  if FFailed then
    RaiseFailure;
end;

procedure TIORingSequentialWriter.AcquireBuffer(out AData: PByte; out ACapacity: NativeInt);

  procedure RaiseBufferAcquired; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'Call CommitBuffer before acquiring the next buffer');
  end;

begin
  AData := nil;

  ACapacity := 0;
  CheckUsable;

  if FBufferAcquired then
    RaiseBufferAcquired;

  MakeCurrentFree;

  if FFailed then
    RaiseFailure;

  AData := CurrentSlot^.Data + FFill;
  ACapacity := FBufferSize - FFill;
  FBufferAcquired := True;
end;

procedure TIORingSequentialWriter.CommitBuffer(const ALength: NativeInt);

  procedure RaiseLengthTooBig(const ACount: NativeInt; const AFree: Cardinal); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingErrorFmt('CommitBuffer: %d bytes do not fit (0..%d)', [ACount, AFree]);
  end;

  procedure RaiseNoBuffer; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'No buffer is acquired');
  end;

begin
  CheckOpen;

  if not FBufferAcquired then
    RaiseNoBuffer;

  if (ALength < 0) or (ALength > NativeInt(FBufferSize - FFill)) then
    RaiseLengthTooBig(ALength, FBufferSize - FFill);

  FBufferAcquired := False;
  Inc(FFill, ALength);
  Inc(FPosition, ALength);

  if FFill = FBufferSize then
    SubmitCurrent;

  if FFailed then
    RaiseFailure;
end;

procedure TIORingSequentialWriter.Flush(const AToDisk: Boolean);

  procedure RaiseBufferAcquired; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(EInvalidOpException, 'Call CommitBuffer before Flush');
  end;

var
  LCompletion: TIORingCompletion;

begin
  CheckUsable;

  if FBufferAcquired then
    RaiseBufferAcquired;

  WaitForAll;

  if not FFailed and (FFill > 0) then
    WritePartOfCurrent;

  // A part written in whole sectors made the file longer
  if not FFailed and FUnbuffered and (FFill mod FSectorSize <> 0) then
    try
      TIORingPlatform.SetFileSize(FFile, FPosition);
    except
      on E: EIORingError do
      begin
        FFailed := True;
        FFailCode := E.NativeCode;
        FFailContext := 'Set the file size';
      end;
    end;

  if not FFailed and AToDisk then
  begin
    FEngine.Wait(FEngine.FlushAsync(FFile), LCompletion);

    if not LCompletion.Succeeded then
    begin
      FFailed := True;
      FFailCode := LCompletion.NativeResult;
      FFailContext := 'Flush to the disk';
    end;
  end;

  if FFailed then
    RaiseFailure;
end;

end.
