unit Bench.Blocks;

{
  Benchmark of reading blocks that are known in advance (Plan, Phase 14):
  many small reads at given offsets, as a program does that reads records
  found in an index.

  Block lists (the same for every contender):
    random 4 KiB   4 KiB blocks at random 4 KiB-aligned offsets, random order
    sorted, gaps   4 KiB blocks in increasing order, 0..28 KiB apart
  Contenders:
    TFileStream            Seek + ReadBuffer per block
    ReadFile at offset     positioned ReadFile per block (no seek call)
    ReadFile, 8 threads    the same on 8 threads, each a share of the blocks
    Block reader, N        TIORingBlockReader through one TIORingEngine with
                           N reads in flight (and with MaxGap for the sorted
                           list: neighbours up to 32 KiB apart become one read),
                           on an overlapped handle; once more on a synchronous
                           handle, to show that Windows then reads one at a time;
                           read-ahead 128 also with an engine of 2 and of 4 I/O
                           threads (Phase 15), and with the overlap rule
                           orKeepOrder on 1 and 4 I/O threads (Phase 16: its
                           cost; one file then uses one I/O thread)
  Cache: cold (the file is purged from the cache before every run), warm, and
  unbuffered (FILE_FLAG_NO_BUFFERING: every read goes to the disk; not for
  TFileStream, whose buffers are not aligned).
  Reported: thousand blocks per second, MiB/s of block data, CPU time of all
  threads; median of the runs. All contenders must get the same checksum.

  Shared by Delphi (Delphi.IOUring.Benchmarks.Blocks.dpr) and Free Pascal
  (FPC\Delphi.IOUring.Benchmarks.Blocks.FPC.lpr).

  Options:
    --dir <folder>     where the test file is created (default %TEMP%\Delphi.IOUring.Bench)
    --size-gib <n>     size of the test file (default 4)
    --blocks <n>       blocks per list (default 20000)
    --runs <n>         runs per contender and case; the median is reported (default 3)
    --csv <file>       append every single run to this CSV file
    --keep             keep the test file
}

{$I Delphi.IOUring.inc}

interface

procedure RunBlockBenchmarks;

implementation

uses
{$IFDEF FPC}
  Windows,
  SysUtils,
  Classes,
{$ELSE}
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
{$ENDIF}
  Delphi.IOUring,
  Delphi.IOUring.Atomics,
  Delphi.IOUring.Engine,
  Delphi.IOUring.BlockReader,
  Bench.Common;

{$IFDEF FPC}
const
  COMPILER_NAME = 'FPC';
{$ELSE}
const
  COMPILER_NAME = 'Delphi';
{$ENDIF}

const
  BLOCK_SIZE = 4096;
  MAX_GAP = 32 * 1024;
  THREAD_COUNT = 8;

type
  TBlockList = array of TIORingBlock;

  TListKind = (lkRandom, lkSortedGaps);
  TCacheState = (csCold, csWarm, csUnbuffered);
  TContender = (cnFileStream, cnReadFile, cnReadFileThreads, cnReader1, cnReader8, cnReader32, cnReader128,
    cnReader128IO2, cnReader128IO4, cnReader128Keep, cnReader128IO4Keep, cnReader32Gap, cnReader32Sync);

const
  LIST_NAMES: array[TListKind] of string = ('random 4 KiB', 'sorted, gaps');
  CACHE_NAMES: array[TCacheState] of string = ('cold', 'warm', 'unbuffered');
  CONTENDER_NAMES: array[TContender] of string = (
    'TFileStream, Seek + Read',
    'ReadFile at offset',
    'ReadFile at offset, 8 threads',
    'Block reader, read-ahead 1',
    'Block reader, read-ahead 8',
    'Block reader, read-ahead 32',
    'Block reader, read-ahead 128',
    'Block reader, read-ahead 128, 2 I/O threads',
    'Block reader, read-ahead 128, 4 I/O threads',
    'Block reader, read-ahead 128, overlap rule',
    'Block reader, read-ahead 128, 4 I/O thr., overlap rule',
    'Block reader, read-ahead 32, MaxGap 32 KiB',
    'Block reader, read-ahead 32, synchronous handle');
  READ_AHEAD: array[TContender] of Cardinal = (0, 0, 0, 1, 8, 32, 128, 128, 128, 128, 128, 32, 32);
  // The engine a block reader uses: its I/O threads, and whether it keeps the
  // order of overlapping requests (orKeepOrder; one file then uses one I/O thread)
  IO_THREADS: array[TContender] of Integer = (0, 0, 0, 1, 1, 1, 1, 2, 4, 1, 4, 1, 1);
  KEEP_ORDER: array[TContender] of Boolean = (False, False, False, False, False, False, False, False, False,
    True, True, False, False);

type
  TRunResult = record
    Seconds: Double;
    CpuMilliseconds: Double;
    Checksum: UInt64;
    Bytes: Int64;
  end;

  // One thread of the "8 threads" contender: every THREAD_COUNT-th block,
  // with a synchronous handle of its own (one shared synchronous handle
  // would let only one thread read at a time)
  TReadFileThread = class(TThread)
  private
    FFileName: string;
    FUnbuffered: Boolean;
    FBlocks: TBlockList;
    FFirst: Integer;
    FReady: PInteger;
  protected
    procedure Execute; override;
  public
    Consumer: TBenchConsumer;
    constructor Create(const AFileName: string; const AUnbuffered: Boolean; const ABlocks: TBlockList;
      const AFirst: Integer; const AReady: PInteger);
  end;

var
  GInvariant: TFormatSettings;
  GFolder: string;
  GSizeGiB: Integer = 4;
  GBlockCount: Integer = 20000;
  GRuns: Integer = 3;
  GCsvFile: string;
  GKeep: Boolean;
  // Engines with 1, 2 and 4 I/O threads
  GEngine: TIORingEngine;
  GEngine2: TIORingEngine;
  GEngine4: TIORingEngine;
  // With the overlap rule, 1 and 4 I/O threads
  GEngineKeep: TIORingEngine;
  GEngine4Keep: TIORingEngine;

// Small random numbers (fixed seed: the same lists every time)
function NextRandom(var AState: Cardinal): Cardinal;
begin
  AState := AState xor (AState shl 13);
  AState := AState xor (AState shr 17);
  AState := AState xor (AState shl 5);
  Result := AState;
end;

function MakeList(const AKind: TListKind; const AFileSize: Int64): TBlockList;
var
  LIndex: Integer;
  LRandom: Cardinal;
  LBlocksInFile: Cardinal;
  LOffset: UInt64;
begin
  LRandom := 20261023;
  Result := nil;
  SetLength(Result, GBlockCount);
  LBlocksInFile := Cardinal(AFileSize div BLOCK_SIZE);
  LOffset := 0;
  for LIndex := 0 to GBlockCount - 1 do
  begin
    Result[LIndex].Length := BLOCK_SIZE;
    if AKind = lkRandom then
      Result[LIndex].Offset := UInt64(NextRandom(LRandom) mod LBlocksInFile) * BLOCK_SIZE
    else
    begin
      Result[LIndex].Offset := LOffset;
      // Next one 0..28 KiB after this one's end, 4 KiB steps
      Inc(LOffset, BLOCK_SIZE + UInt64(NextRandom(LRandom) mod 8) * BLOCK_SIZE);
    end;
  end;
end;

// AOverlapped = False: a synchronous handle - positioned ReadFile waits for
// the data. Windows runs the I/O of such a handle one at a time, also from
// several threads and also through IoRing; the block reader needs
// AOverlapped = True to have many reads in flight. AUnbuffered: past the
// file cache; buffers, offsets and lengths must then be sector-aligned.
function OpenForReading(const AFileName: string; const AOverlapped, AUnbuffered: Boolean): THandle;
var
  LFlags: DWORD;
begin
  LFlags := FILE_ATTRIBUTE_NORMAL;
  if AOverlapped then
    LFlags := LFlags or FILE_FLAG_OVERLAPPED;
  if AUnbuffered then
    LFlags := LFlags or FILE_FLAG_NO_BUFFERING;
  Result := CreateFile(PChar(AFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING,
    LFlags, 0);
  if Result = INVALID_HANDLE_VALUE then
    RaiseLastOSError;
end;

procedure ReadAt(const AFile: THandle; var ABuffer; const ACount: Cardinal; const AOffset: UInt64);
var
  LOverlapped: TOverlapped;
  LRead: DWORD;
begin
  FillChar(LOverlapped, SizeOf(LOverlapped), 0);
  LOverlapped.Offset := DWORD(AOffset and $FFFFFFFF);
  LOverlapped.OffsetHigh := DWORD(AOffset shr 32);
  LRead := 0;
  if not ReadFile(AFile, ABuffer, ACount, LRead, @LOverlapped) then
    RaiseLastOSError;
  if LRead <> ACount then
    raise Exception.CreateFmt('Short read at %d', [AOffset]);
end;

{ TReadFileThread }

constructor TReadFileThread.Create(const AFileName: string; const AUnbuffered: Boolean; const ABlocks: TBlockList;
  const AFirst: Integer; const AReady: PInteger);
begin
  FFileName := AFileName;
  FUnbuffered := AUnbuffered;
  FBlocks := ABlocks;
  FFirst := AFirst;
  FReady := AReady;
  Consumer.Init(0);
  inherited Create(True);
end;

procedure TReadFileThread.Execute;
var
  LFile: THandle;
  LBuffer: PByte;
  LIndex: Integer;
begin
  // Page-aligned, as unbuffered reads need
  LBuffer := TIORingPlatform.AllocPages(BLOCK_SIZE);
  LFile := OpenForReading(FFileName, False, FUnbuffered);
  try
    TAtomic.Increment(FReady^);
    while TAtomic.LoadAcquire(FReady^) < THREAD_COUNT do
      TThread.Yield;
    LIndex := FFirst;
    while LIndex <= High(FBlocks) do
    begin
      ReadAt(LFile, LBuffer^, FBlocks[LIndex].Length, FBlocks[LIndex].Offset);
      Consumer.Consume(LBuffer, FBlocks[LIndex].Length);
      Inc(LIndex, THREAD_COUNT);
    end;
  finally
    CloseHandle(LFile);
    TIORingPlatform.FreePages(LBuffer);
  end;
end;

{ Contenders }

procedure ReadWithFileStream(const AFileName: string; const ABlocks: TBlockList; var AConsumer: TBenchConsumer);
var
  LStream: TFileStream;
  LBuffer: array[0..BLOCK_SIZE - 1] of Byte;
  LIndex: Integer;
begin
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    for LIndex := 0 to High(ABlocks) do
    begin
      LStream.Seek(Int64(ABlocks[LIndex].Offset), soBeginning);
      LStream.ReadBuffer(LBuffer, ABlocks[LIndex].Length);
      AConsumer.Consume(@LBuffer[0], ABlocks[LIndex].Length);
    end;
  finally
    LStream.Free;
  end;
end;

procedure ReadWithReadFile(const AFile: THandle; const ABlocks: TBlockList; var AConsumer: TBenchConsumer);
var
  LBuffer: PByte;
  LIndex: Integer;
begin
  // Page-aligned, as unbuffered reads need
  LBuffer := TIORingPlatform.AllocPages(BLOCK_SIZE);
  try
    for LIndex := 0 to High(ABlocks) do
    begin
      ReadAt(AFile, LBuffer^, ABlocks[LIndex].Length, ABlocks[LIndex].Offset);
      AConsumer.Consume(LBuffer, ABlocks[LIndex].Length);
    end;
  finally
    TIORingPlatform.FreePages(LBuffer);
  end;
end;

procedure ReadWithThreads(const AFileName: string; const AUnbuffered: Boolean; const ABlocks: TBlockList;
  var AConsumer: TBenchConsumer);
var
  LThreads: array[0..THREAD_COUNT - 1] of TReadFileThread;
  LReady: Integer;
  LIndex: Integer;
begin
  LReady := 0;
  for LIndex := 0 to THREAD_COUNT - 1 do
    LThreads[LIndex] := TReadFileThread.Create(AFileName, AUnbuffered, ABlocks, LIndex, @LReady);
  try
    for LIndex := 0 to THREAD_COUNT - 1 do
      LThreads[LIndex].Start;
    for LIndex := 0 to THREAD_COUNT - 1 do
    begin
      LThreads[LIndex].WaitFor;
      if LThreads[LIndex].FatalException <> nil then
        raise Exception.Create('Read thread failed: ' + Exception(LThreads[LIndex].FatalException).Message);
      AConsumer.Merge(LThreads[LIndex].Consumer);
    end;
  finally
    for LIndex := 0 to THREAD_COUNT - 1 do
      LThreads[LIndex].Free;
  end;
end;

procedure ReadWithBlockReader(const AEngine: TIORingEngine; const AFile: THandle; const ABlocks: TBlockList;
  const AReadAhead, AMaxGap: Cardinal; var AConsumer: TBenchConsumer);
var
  LReader: TIORingBlockReader;
  LBlock: TIORingBlock;
  LData: PByte;
  LLength: Cardinal;
begin
  LReader.Open(AEngine, AFile, ABlocks, AReadAhead, IORING_BLOCK_READER_DEFAULT_BUFFER_SIZE, AMaxGap);
  while LReader.TryGetBlock(LBlock, LData, LLength) do
  begin
    AConsumer.Consume(LData, LLength);
    LReader.ReleaseBlock;
  end;
end;

// Does this contender run in this case?
function Runs(const AContender: TContender; const AKind: TListKind; const ACache: TCacheState): Boolean;
begin
  if (AContender = cnReader32Gap) and (AKind = lkRandom) then
    Result := False    // random blocks have no neighbours to merge
  else if (AContender = cnFileStream) and (ACache = csUnbuffered) then
    Result := False    // its buffers are not aligned
  else
    Result := True;
end;

function EngineFor(const AContender: TContender): TIORingEngine;
begin
  if KEEP_ORDER[AContender] then
  begin
    if IO_THREADS[AContender] = 4 then
      Result := GEngine4Keep
    else
      Result := GEngineKeep;
  end
  else
    case IO_THREADS[AContender] of
      2: Result := GEngine2;
      4: Result := GEngine4;
    else
      Result := GEngine;
    end;
end;

function RunContender(const AContender: TContender; const AFileName: string; const ABlocks: TBlockList;
  const ACache: TCacheState): TRunResult;
var
  LConsumer: TBenchConsumer;
  LMeasurement: TBenchMeasurement;
  LFile: THandle;
  LUnbuffered: Boolean;
begin
  if ACache = csCold then
    PurgeFileCache(AFileName);
  LUnbuffered := ACache = csUnbuffered;
  LConsumer.Init(0);
  // The block readers need an overlapped handle (see OpenForReading)
  LFile := OpenForReading(AFileName, (READ_AHEAD[AContender] > 0) and (AContender <> cnReader32Sync), LUnbuffered);
  try
    LMeasurement.Start;
    case AContender of
      cnFileStream:
        ReadWithFileStream(AFileName, ABlocks, LConsumer);
      cnReadFile:
        ReadWithReadFile(LFile, ABlocks, LConsumer);
      cnReadFileThreads:
        ReadWithThreads(AFileName, LUnbuffered, ABlocks, LConsumer);
      cnReader32Gap:
        ReadWithBlockReader(EngineFor(AContender), LFile, ABlocks, READ_AHEAD[AContender], MAX_GAP, LConsumer);
    else
      ReadWithBlockReader(EngineFor(AContender), LFile, ABlocks, READ_AHEAD[AContender], 0, LConsumer);
    end;
    LMeasurement.Stop;
  finally
    CloseHandle(LFile);
  end;
  Result.Seconds := LMeasurement.Seconds;
  Result.CpuMilliseconds := LMeasurement.UserMilliseconds + LMeasurement.KernelMilliseconds;
  Result.Checksum := LConsumer.Checksum;
  Result.Bytes := LConsumer.Bytes;
end;

{ Reporting }

function Median(const AValues: array of Double): Double;
var
  LSorted: array of Double;
  LIndex: Integer;
  LOther: Integer;
  LValue: Double;
begin
  SetLength(LSorted, Length(AValues));
  for LIndex := 0 to High(AValues) do
    LSorted[LIndex] := AValues[LIndex];
  for LIndex := 1 to High(LSorted) do
  begin
    LValue := LSorted[LIndex];
    LOther := LIndex - 1;
    while (LOther >= 0) and (LSorted[LOther] > LValue) do
    begin
      LSorted[LOther + 1] := LSorted[LOther];
      Dec(LOther);
    end;
    LSorted[LOther + 1] := LValue;
  end;
  Result := LSorted[High(LSorted) div 2];
end;

function PlatformName: string;
begin
{$IF SizeOf(Pointer) = 8}
  Result := 'Win64';
{$ELSE}
  Result := 'Win32';
{$ENDIF}
end;

procedure AppendCsv(const AKind: TListKind; const ACache: TCacheState; const AContender: TContender;
  const ARun: Integer; const AResult: TRunResult; const AChecksumOK: Boolean);
var
  LFile: TextFile;
  LNew: Boolean;
begin
  if GCsvFile = '' then
    Exit;
  LNew := not FileExists(GCsvFile);
  AssignFile(LFile, GCsvFile);
  if LNew then
    Rewrite(LFile)
  else
    Append(LFile);
  try
    if LNew then
      Writeln(LFile, 'timestamp,compiler,platform,blocks,scenario,cache,contender,run,seconds,blocks_per_s,mib_per_s,cpu_ms,checksum_ok');
    Writeln(LFile, Format('%s,%s,%s,%d,%s,%s,"%s",%d,%.4f,%.0f,%.1f,%.1f,%s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now, GInvariant), COMPILER_NAME, PlatformName, GBlockCount,
       LIST_NAMES[AKind], CACHE_NAMES[ACache], CONTENDER_NAMES[AContender], ARun, AResult.Seconds,
       GBlockCount / AResult.Seconds, AResult.Bytes / AResult.Seconds / MiB, AResult.CpuMilliseconds,
       BoolToStr(AChecksumOK, True)], GInvariant));
  finally
    CloseFile(LFile);
  end;
end;

procedure ParseOptions;
var
  LIndex: Integer;
  LName: string;
begin
  GFolder := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'Delphi.IOUring.Bench';
  LIndex := 1;
  while LIndex <= ParamCount do
  begin
    LName := LowerCase(ParamStr(LIndex));
    if (LName = '--dir') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GFolder := ParamStr(LIndex);
    end
    else if (LName = '--size-gib') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GSizeGiB := StrToInt(ParamStr(LIndex));
    end
    else if (LName = '--blocks') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GBlockCount := StrToInt(ParamStr(LIndex));
    end
    else if (LName = '--runs') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GRuns := StrToInt(ParamStr(LIndex));
    end
    else if (LName = '--csv') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GCsvFile := ParamStr(LIndex);
    end
    else if LName = '--keep' then
      GKeep := True
    else
      raise Exception.CreateFmt('Unknown option: %s', [ParamStr(LIndex)]);
    Inc(LIndex);
  end;
  if (GRuns < 1) or (GBlockCount < 1) or (GSizeGiB < 1) then
    raise Exception.Create('--runs, --blocks and --size-gib must be at least 1');
end;

procedure RunBlockBenchmarks;
var
  LFileName: string;
  LSize: Int64;
  LKind: TListKind;
  LCache: TCacheState;
  LContender: TContender;
  LBlocks: TBlockList;
  LRun: Integer;
  LResult: TRunResult;
  LSeconds: array[TContender] of array of Double;
  LCpu: array[TContender] of array of Double;
  LExpected: UInt64;
  LHaveExpected: Boolean;
  LChecksumOK: Boolean;
  LAllOK: array[TContender] of Boolean;
  LMedian: Double;
  LMark: string;
begin
  ParseOptions;
  ForceDirectories(GFolder);
  LSize := Int64(GSizeGiB) * 1024 * MiB;
  LFileName := IncludeTrailingPathDelimiter(GFolder) + Format('blocks-%dGiB.dat', [GSizeGiB]);
  Writeln(Format('Blocks known in advance: %s %s, %s', [COMPILER_NAME, PlatformName,
    FormatDateTime('yyyy-mm-dd hh:nn', Now, GInvariant)], GInvariant));
  if FileSizeOf(LFileName) <> LSize then
  begin
    Write(Format('Creating %s (%d GiB) ... ', [LFileName, GSizeGiB]));
    CreateBenchFile(LFileName, LSize);
    Writeln('done');
  end;
  Writeln(Format('%d blocks of %d bytes per list; median of %d runs', [GBlockCount, BLOCK_SIZE, GRuns], GInvariant));

  GEngine := TIORingEngine.Create;
  GEngine2 := TIORingEngine.Create(IORING_ENGINE_DEFAULT_MAX_REQUESTS, IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE, 2);
  GEngine4 := TIORingEngine.Create(IORING_ENGINE_DEFAULT_MAX_REQUESTS, IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE, 4);
  GEngineKeep := TIORingEngine.Create(IORING_ENGINE_DEFAULT_MAX_REQUESTS, IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE,
    1, orKeepOrder);
  GEngine4Keep := TIORingEngine.Create(IORING_ENGINE_DEFAULT_MAX_REQUESTS, IORING_ENGINE_DEFAULT_SUBMISSION_QUEUE_SIZE,
    4, orKeepOrder);
  try
    for LKind := Low(TListKind) to High(TListKind) do
    begin
      LBlocks := MakeList(LKind, LSize);
      for LCache := Low(TCacheState) to High(TCacheState) do
      begin
        Writeln;
        Writeln(Format('%s, %s cache', [LIST_NAMES[LKind], CACHE_NAMES[LCache]]));
        Writeln(Format('  %-54s %11s %9s %9s', ['Contender', 'K blocks/s', 'MiB/s', 'CPU ms'], GInvariant));
        if LCache = csWarm then
          RunContender(cnReadFile, LFileName, LBlocks, csWarm);    // bring the blocks into the cache
        LHaveExpected := False;
        LExpected := 0;
        for LContender := Low(TContender) to High(TContender) do
        begin
          SetLength(LSeconds[LContender], GRuns);
          SetLength(LCpu[LContender], GRuns);
          LAllOK[LContender] := True;
        end;
        // The contenders take turns, so that a slow moment of the machine hits all of them
        for LRun := 1 to GRuns do
          for LContender := Low(TContender) to High(TContender) do
          begin
            if not Runs(LContender, LKind, LCache) then
              Continue;
            LResult := RunContender(LContender, LFileName, LBlocks, LCache);
            if not LHaveExpected then
            begin
              LExpected := LResult.Checksum;
              LHaveExpected := True;
            end;
            LChecksumOK := LResult.Checksum = LExpected;
            if not LChecksumOK then
              LAllOK[LContender] := False;
            LSeconds[LContender][LRun - 1] := LResult.Seconds;
            LCpu[LContender][LRun - 1] := LResult.CpuMilliseconds;
            AppendCsv(LKind, LCache, LContender, LRun, LResult, LChecksumOK);
          end;
        for LContender := Low(TContender) to High(TContender) do
        begin
          if not Runs(LContender, LKind, LCache) then
            Continue;
          LMedian := Median(LSeconds[LContender]);
          if LAllOK[LContender] then
            LMark := ''
          else
            LMark := '  CHECKSUM!';
          Writeln(Format('  %-54s %11.1f %9.1f %9.0f%s', [CONTENDER_NAMES[LContender], GBlockCount / LMedian / 1000,
            GBlockCount * BLOCK_SIZE / LMedian / MiB, Median(LCpu[LContender]), LMark], GInvariant));
        end;
      end;
    end;
  finally
    GEngine4Keep.Free;
    GEngineKeep.Free;
    GEngine4.Free;
    GEngine2.Free;
    GEngine.Free;
  end;
  if not GKeep then
    DeleteFile(LFileName);
end;

initialization
{$IFDEF FPC}
  GInvariant := DefaultFormatSettings;
{$ELSE}
  GInvariant := TFormatSettings.Create('en-US');
{$ENDIF}
  GInvariant.DecimalSeparator := '.';
  GInvariant.ThousandSeparator := ',';

end.
