unit Bench.Structures;

{
  Benchmarks of the engine's lock-free structures against the same structure
  behind a lock. Design §10.5: each lock-free structure gets such a benchmark
  before it is accepted; if the lock wins or ties, the lock stays.

  Free list (Phase 11): the free slots of the request pool.
    lock-free   TIORingFreeList (Treiber stack, one 64-bit compare-exchange)
    SRW lock    the same stack (an array) behind a Windows SRW lock
  Each thread repeats: take one index, work, give it back.
    tight       no work in between: the worst case for contention
    work 1 us   ~1 µs of work while holding the index (a request being used)
  Reported: million take+give pairs per second, all threads together (median
  of the runs), and the CPU time of all threads.

  Shared by Delphi (Delphi.IOUring.Benchmarks.Structures.dpr) and Free Pascal
  (FPC\Delphi.IOUring.Benchmarks.Structures.FPC.lpr).

  Options:
    --runs <n>         runs per case; the median is reported (default 3)
    --threads <list>   thread counts, comma separated (default 1,2,4,8,16 and
                       the number of logical processors)
    --csv <file>       append every single run to this CSV file
}

{$I Delphi.IOUring.inc}

interface

procedure RunStructureBenchmarks;

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
  Delphi.IOUring.RequestPool,
  Bench.Common;

{$IFDEF FPC}
const
  COMPILER_NAME = 'FPC';
{$ELSE}
const
  COMPILER_NAME = 'Delphi';
{$ENDIF}

const
  FREE_LIST_CAPACITY = 1024;
  WORK_MICROSECONDS = 1;
  // Take+give pairs per case, split between the threads
  TIGHT_PAIRS = 4000000;
  WORK_PAIRS = 400000;

type
  TFreeListVariant = (fvLockFree, fvSrwLock);
  TScenario = (scTight, scWork);

const
  VARIANT_NAMES: array[TFreeListVariant] of string = ('lock-free', 'SRW lock');
  SCENARIO_NAMES: array[TScenario] of string = ('tight', 'work 1 us');

// Windows SRW lock (Vista and newer); own names, so the Windows units'
// declarations do not matter
procedure BenchAcquireSRWLockExclusive(var ALock: Pointer); stdcall;
  external 'kernel32.dll' name 'AcquireSRWLockExclusive';
procedure BenchReleaseSRWLockExclusive(var ALock: Pointer); stdcall;
  external 'kernel32.dll' name 'ReleaseSRWLockExclusive';

type
  // The same stack as TIORingFreeList, behind an SRW lock. The lock and the
  // count share one cache line of their own (like the lock-free head).
  TLockedFreeList = record
  private
    FMemory: Pointer;
    FLock: ^Pointer;
    FCount: PCardinal;
    FItems: PCardinalArray;
  public
    procedure Open(const ACapacity: Cardinal);
    procedure Close;
    function TryPop(out AIndex: Cardinal): Boolean;
    procedure Push(const AIndex: Cardinal);
  end;
  PLockedFreeList = ^TLockedFreeList;
  PIORingFreeList = ^TIORingFreeList;

  TFreeListWorker = class(TThread)
  private
    FVariant: TFreeListVariant;
    FLockFree: PIORingFreeList;
    FLocked: PLockedFreeList;
    FPairs: Integer;
    FWorkMicroseconds: Cardinal;
    FReady: PInteger;
    FThreads: Integer;
  protected
    procedure Execute; override;
  public
    StartTime: UInt64;    // microseconds
    EndTime: UInt64;
    Misses: Integer;      // takes that found the stack empty (should stay 0)
    constructor Create(const AVariant: TFreeListVariant; const ALockFree: PIORingFreeList;
      const ALocked: PLockedFreeList; const APairs: Integer; const AWorkMicroseconds: Cardinal;
      const AReady: PInteger; const AThreads: Integer);
  end;

  TRunResult = record
    PairsPerSecond: Double;
    CpuMilliseconds: Double;
  end;

var
  GInvariant: TFormatSettings;
  GRuns: Integer = 3;
  GThreadCounts: array of Integer;
  GCsvFile: string;

{ TLockedFreeList }

procedure TLockedFreeList.Open(const ACapacity: Cardinal);
var
  LAddress: NativeUInt;
  LIndex: Cardinal;
begin
  GetMem(FMemory, IORING_CACHE_LINE_SIZE + ACapacity * SizeOf(Cardinal) + IORING_CACHE_LINE_SIZE);
  LAddress := NativeUInt(FMemory) + NativeUInt(IORING_CACHE_LINE_SIZE - 1);
  LAddress := LAddress and not NativeUInt(IORING_CACHE_LINE_SIZE - 1);
  FLock := Pointer(LAddress);
  FCount := Pointer(LAddress + SizeOf(Pointer));
  FItems := Pointer(LAddress + IORING_CACHE_LINE_SIZE);
  FLock^ := nil;
  // Same order as TIORingFreeList: 0 on top
  for LIndex := 0 to ACapacity - 1 do
    FItems^[LIndex] := ACapacity - 1 - LIndex;
  FCount^ := ACapacity;
end;

procedure TLockedFreeList.Close;
begin
  FreeMem(FMemory);
  FMemory := nil;
end;

function TLockedFreeList.TryPop(out AIndex: Cardinal): Boolean;
begin
  BenchAcquireSRWLockExclusive(FLock^);
  Result := FCount^ > 0;
  if Result then
  begin
    Dec(FCount^);
    AIndex := FItems^[FCount^];
  end
  else
    AIndex := 0;
  BenchReleaseSRWLockExclusive(FLock^);
end;

procedure TLockedFreeList.Push(const AIndex: Cardinal);
begin
  BenchAcquireSRWLockExclusive(FLock^);
  FItems^[FCount^] := AIndex;
  Inc(FCount^);
  BenchReleaseSRWLockExclusive(FLock^);
end;

{ TFreeListWorker }

constructor TFreeListWorker.Create(const AVariant: TFreeListVariant; const ALockFree: PIORingFreeList;
  const ALocked: PLockedFreeList; const APairs: Integer; const AWorkMicroseconds: Cardinal;
  const AReady: PInteger; const AThreads: Integer);
begin
  FVariant := AVariant;
  FLockFree := ALockFree;
  FLocked := ALocked;
  FPairs := APairs;
  FWorkMicroseconds := AWorkMicroseconds;
  FReady := AReady;
  FThreads := AThreads;
  inherited Create(True);
end;

procedure TFreeListWorker.Execute;
var
  LPair: Integer;
  LIndex: Cardinal;
begin
  // Start together
  TAtomic.Increment(FReady^);
  while TAtomic.LoadAcquire(FReady^) < FThreads do
    TThread.Yield;

  StartTime := TIORingPlatform.TimestampMicroseconds;
  case FVariant of
    fvLockFree:
      for LPair := 1 to FPairs do
        if FLockFree^.TryPop(LIndex) then
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);
          FLockFree^.Push(LIndex);
        end
        else
          Inc(Misses);
    fvSrwLock:
      for LPair := 1 to FPairs do
        if FLocked^.TryPop(LIndex) then
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);
          FLocked^.Push(LIndex);
        end
        else
          Inc(Misses);
  end;
  EndTime := TIORingPlatform.TimestampMicroseconds;
end;

{ Running }

function RunFreeList(const AVariant: TFreeListVariant; const AScenario: TScenario;
  const AThreads: Integer): TRunResult;
var
  LLockFree: TIORingFreeList;
  LLocked: TLockedFreeList;
  LWorkers: array of TFreeListWorker;
  LReady: Integer;
  LIndex: Integer;
  LPairs: Integer;
  LWork: Cardinal;
  LStart: UInt64;
  LEnd: UInt64;
  LMeasurement: TBenchMeasurement;
begin
  if AScenario = scTight then
  begin
    LPairs := TIGHT_PAIRS div AThreads;
    LWork := 0;
  end
  else
  begin
    LPairs := WORK_PAIRS div AThreads;
    LWork := WORK_MICROSECONDS;
  end;

  LLockFree.Open(FREE_LIST_CAPACITY);
  LLocked.Open(FREE_LIST_CAPACITY);
  try
    LReady := 0;
    SetLength(LWorkers, AThreads);
    for LIndex := 0 to AThreads - 1 do
      LWorkers[LIndex] := TFreeListWorker.Create(AVariant, @LLockFree, @LLocked, LPairs, LWork,
        @LReady, AThreads);
    try
      LMeasurement.Start;
      for LIndex := 0 to AThreads - 1 do
        LWorkers[LIndex].Start;
      for LIndex := 0 to AThreads - 1 do
        LWorkers[LIndex].WaitFor;
      LMeasurement.Stop;

      // From the first thread starting to the last one finishing
      LStart := High(UInt64);
      LEnd := 0;
      for LIndex := 0 to AThreads - 1 do
      begin
        if LWorkers[LIndex].Misses > 0 then
          raise Exception.Create('The free list ran empty - the benchmark is wrong');
        if LWorkers[LIndex].StartTime < LStart then
          LStart := LWorkers[LIndex].StartTime;
        if LWorkers[LIndex].EndTime > LEnd then
          LEnd := LWorkers[LIndex].EndTime;
      end;
      Result.PairsPerSecond := Int64(LPairs) * AThreads / ((LEnd - LStart) / 1000000);
      Result.CpuMilliseconds := LMeasurement.UserMilliseconds + LMeasurement.KernelMilliseconds;
    finally
      for LIndex := 0 to AThreads - 1 do
        LWorkers[LIndex].Free;
    end;
  finally
    LLocked.Close;
    LLockFree.Close;
  end;
end;

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

function LogicalProcessorCount: Integer;
var
  LInfo: TSystemInfo;
begin
  GetSystemInfo(LInfo);
  Result := LInfo.dwNumberOfProcessors;
end;

procedure AppendCsv(const AVariant: TFreeListVariant; const AScenario: TScenario; const AThreads, ARun: Integer;
  const AResult: TRunResult);
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
      Writeln(LFile, 'timestamp,compiler,platform,structure,variant,scenario,threads,run,pairs_per_s,cpu_ms');
    Writeln(LFile, Format('%s,%s,%s,free list,%s,%s,%d,%d,%.0f,%.1f',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now, GInvariant), COMPILER_NAME, PlatformName,
       VARIANT_NAMES[AVariant], SCENARIO_NAMES[AScenario], AThreads, ARun, AResult.PairsPerSecond,
       AResult.CpuMilliseconds], GInvariant));
  finally
    CloseFile(LFile);
  end;
end;

procedure ParseOptions;
var
  LIndex: Integer;
  LName: string;
  LList: TStringList;
  LItem: Integer;
  LCpus: Integer;
begin
  LIndex := 1;
  while LIndex <= ParamCount do
  begin
    LName := LowerCase(ParamStr(LIndex));
    if (LName = '--runs') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GRuns := StrToInt(ParamStr(LIndex));
    end
    else if (LName = '--threads') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      LList := TStringList.Create;
      try
        LList.CommaText := ParamStr(LIndex);
        SetLength(GThreadCounts, LList.Count);
        for LItem := 0 to LList.Count - 1 do
          GThreadCounts[LItem] := StrToInt(LList[LItem]);
      finally
        LList.Free;
      end;
    end
    else if (LName = '--csv') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GCsvFile := ParamStr(LIndex);
    end
    else
      raise Exception.CreateFmt('Unknown option: %s', [ParamStr(LIndex)]);
    Inc(LIndex);
  end;

  if Length(GThreadCounts) = 0 then
  begin
    LCpus := LogicalProcessorCount;
    LItem := 1;
    while LItem < LCpus do
    begin
      SetLength(GThreadCounts, Length(GThreadCounts) + 1);
      GThreadCounts[High(GThreadCounts)] := LItem;
      LItem := LItem * 2;
    end;
    SetLength(GThreadCounts, Length(GThreadCounts) + 1);
    GThreadCounts[High(GThreadCounts)] := LCpus;
  end;
end;

procedure RunStructureBenchmarks;
var
  LScenario: TScenario;
  LThreadIndex: Integer;
  LThreads: Integer;
  LRun: Integer;
  LVariant: TFreeListVariant;
  LResult: TRunResult;
  LRates: array[TFreeListVariant] of array of Double;
  LCpu: array[TFreeListVariant] of array of Double;
  LRate: array[TFreeListVariant] of Double;
begin
  ParseOptions;
  Writeln(Format('Engine structures: %s %s, %d logical processors, %s',
    [COMPILER_NAME, PlatformName, LogicalProcessorCount, FormatDateTime('yyyy-mm-dd hh:nn', Now, GInvariant)],
    GInvariant));
  Writeln;
  Writeln('Free list: take one index, (work,) give it back.');
  Writeln('Mpairs/s = million take+give pairs per second, all threads; median of ', GRuns, ' runs.');
  Writeln('CPU ms = CPU time of all threads for the run (median).');
  Writeln;
  Writeln(Format('%-10s %7s %11s %11s %9s %12s %12s',
    ['Scenario', 'Threads', 'lock-free', 'SRW lock', 'LF/SRW', 'LF CPU ms', 'SRW CPU ms'], GInvariant));
  Writeln(Format('%-10s %7s %11s %11s %9s %12s %12s', ['', '', 'Mpairs/s', 'Mpairs/s', '', '', ''], GInvariant));

  for LScenario := Low(TScenario) to High(TScenario) do
    for LThreadIndex := 0 to High(GThreadCounts) do
    begin
      LThreads := GThreadCounts[LThreadIndex];
      for LVariant := Low(TFreeListVariant) to High(TFreeListVariant) do
      begin
        SetLength(LRates[LVariant], GRuns);
        SetLength(LCpu[LVariant], GRuns);
      end;
      // Variants take turns, so that a slow moment of the machine hits both
      for LRun := 1 to GRuns do
        for LVariant := Low(TFreeListVariant) to High(TFreeListVariant) do
        begin
          LResult := RunFreeList(LVariant, LScenario, LThreads);
          LRates[LVariant][LRun - 1] := LResult.PairsPerSecond;
          LCpu[LVariant][LRun - 1] := LResult.CpuMilliseconds;
          AppendCsv(LVariant, LScenario, LThreads, LRun, LResult);
        end;
      for LVariant := Low(TFreeListVariant) to High(TFreeListVariant) do
        LRate[LVariant] := Median(LRates[LVariant]);
      Writeln(Format('%-10s %7d %11.2f %11.2f %9.2f %12.0f %12.0f',
        [SCENARIO_NAMES[LScenario], LThreads, LRate[fvLockFree] / 1E6, LRate[fvSrwLock] / 1E6,
         LRate[fvLockFree] / LRate[fvSrwLock], Median(LCpu[fvLockFree]), Median(LCpu[fvSrwLock])], GInvariant));
    end;
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
