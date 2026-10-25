unit PIRUnit.Benchmark.Structures;

{
  Benchmarks of the engine's lock-free structures against the same structure
  behind a lock. Design §10.5: each lock-free structure gets such a benchmark
  before it is accepted; if the lock wins or ties, the lock stays.

  Free list (Phase 11): the free slots of the request pool.
    lock-free   TIORingFreeList (Treiber stack, one 64-bit compare-exchange)
    SRW lock    the same stack (an array) behind a Windows SRW lock (Linux: a
                pthread mutex)
  Each thread repeats: take one index, work, give it back.

  Request queue (Phase 12): producers -> one consumer (the I/O thread).
    lock-free   TIORingRequestQueue (Vyukov's bounded queue)
    SRW lock    a ring buffer behind a Windows SRW lock (Linux: a pthread mutex)
  N producers put values in, one consumer takes them all out.

  Scenarios:
    tight       no work in between: the worst case for contention
    work 1 us   ~1 µs of work per operation (free list: while holding the
                index; queue: before each value, like preparing a request)
  Reported: million operations per second, all threads together (median of
  the runs), and the CPU time of all threads. Free list: one operation = take
  + give; queue: one value through the queue.

  Shared by Delphi (Pascal.IOUring.Benchmarks.Structures.dpr) and Free Pascal
  (FPC\Pascal.IOUring.Benchmarks.Structures.FPC.lpr).

  Options:
    --only <name>      freelist or queue (default: both)
    --runs <n>         runs per case; the median is reported (default 3)
    --threads <list>   thread counts, comma separated (default 1,2,4,8,16 and
                       the number of logical processors; for the queue these
                       are producers, at most one less than the processors)
    --csv <file>       append every single run to this CSV file
}

{$I PIRInclude.Compiler.inc}

interface

  procedure RunStructureBenchmarks;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Atomics, PIRUnit.Types, PIRUnit.RequestPool,
  PIRUnit.RequestQueue, PIRUnit.Benchmark.Common;

{$IFDEF FPC}
const
  COMPILER_NAME = 'FPC';
{$ELSE}
const
  COMPILER_NAME = 'Delphi';
{$ENDIF}

const
  FREE_LIST_CAPACITY = 1024;
  QUEUE_CAPACITY = 1024;
  WORK_MICROSECONDS = 1;
  // Operations per case, split between the threads (queue: the producers)
  TIGHT_OPERATIONS = 4000000;
  WORK_OPERATIONS = 400000;

type
  TStructure = (stFreeList, stQueue);
  TContender = (cnLockFree, cnLock);
  TScenario = (scTight, scWork);

const
{$IFDEF MSWINDOWS}
  LOCK_NAME = 'SRW lock';
  LOCK_SHORT_NAME = 'SRW';
  // Bytes the lock takes at the start of its cache line
  LOCK_SIZE = 8;
{$ELSE}
  LOCK_NAME = 'mutex';
  LOCK_SHORT_NAME = 'mutex';
  // pthread_mutex_t: 40 bytes on x86-64, 48 on AArch64
  LOCK_SIZE = 48;
{$ENDIF}
  STRUCTURE_NAMES: array[TStructure] of string = ('free list', 'queue');
  STRUCTURE_OPTIONS: array[TStructure] of string = ('freelist', 'queue');
  CONTENDER_NAMES: array[TContender] of string = ('lock-free', LOCK_NAME);
  SCENARIO_NAMES: array[TScenario] of string = ('tight', 'work 1 us');

{ The lock: Windows SRW lock (Vista and newer), Linux pthread mutex. Both start unlocked when their memory is zero. Own
  names, so the Windows units' declarations do not matter. }
{$IFDEF MSWINDOWS}
procedure BenchAcquireSRWLockExclusive(var ALock: Pointer); stdcall;
  external 'kernel32.dll' name 'AcquireSRWLockExclusive';
procedure BenchReleaseSRWLockExclusive(var ALock: Pointer); stdcall;
  external 'kernel32.dll' name 'ReleaseSRWLockExclusive';
{$ELSE}
function BenchMutexLock(const AMutex: Pointer): Integer; cdecl; external 'c' name 'pthread_mutex_lock';
function BenchMutexUnlock(const AMutex: Pointer): Integer; cdecl; external 'c' name 'pthread_mutex_unlock';
{$ENDIF}

procedure LockAcquire(const ALock: Pointer); inline;
begin
{$IFDEF MSWINDOWS}
  BenchAcquireSRWLockExclusive(PPointer(ALock)^);
{$ELSE}
  BenchMutexLock(ALock);
{$ENDIF}
end;

procedure LockRelease(const ALock: Pointer); inline;
begin
{$IFDEF MSWINDOWS}
  BenchReleaseSRWLockExclusive(PPointer(ALock)^);
{$ELSE}
  BenchMutexUnlock(ALock);
{$ENDIF}
end;

type
  TNativeUIntArray = array[0..MaxInt div SizeOf(NativeUInt) - 1] of NativeUInt;
  PNativeUIntArray = ^TNativeUIntArray;
  TCardinalArray = array[0..MaxInt div SizeOf(Cardinal) - 1] of Cardinal;
  PCardinalArray = ^TCardinalArray;

  { The same stack as TIORingFreeList, behind the lock. The lock and the count share one cache line of their own
    (like the lock-free head). }
  TLockedFreeList = record
  private
    FMemory: Pointer;
    FLock: Pointer;
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

  // A ring buffer behind the lock. The lock, the head and the count share one cache line of their own.
  TLockedQueue = record
  private
    FMemory: Pointer;
    FLock: Pointer;
    FHead: PCardinal;     // the next value to take
    FCount: PCardinal;
    FItems: PNativeUIntArray;
    FMask: Cardinal;
  public
    // ACapacity: a power of two
    procedure Open(const ACapacity: Cardinal);
    procedure Close;
    function TryEnqueue(const AValue: NativeUInt): Boolean;
    function TryDequeue(out AValue: NativeUInt): Boolean;
  end;
  PLockedQueue = ^TLockedQueue;
  PIORingRequestQueue = ^TIORingRequestQueue;

  // A benchmark thread: waits until all threads of the run have started, then runs Work between StartTime and EndTime
  TBenchWorker = class(TThread)
  private
    FReady: PInteger;
    FThreads: Integer;
  protected
    FContender: TContender;
    FOperations: Integer;
    FWorkMicroseconds: Cardinal;
    procedure Execute; override;
    procedure Work; virtual; abstract;
  public
    StartTime: UInt64;    // microseconds
    EndTime: UInt64;
    constructor Create(const AContender: TContender; const AOperations: Integer;
      const AWorkMicroseconds: Cardinal; const AReady: PInteger; const AThreads: Integer);
  end;

  TFreeListWorker = class(TBenchWorker)
  protected
    procedure Work; override;
  public
    LockFree: PIORingFreeList;
    Locked: PLockedFreeList;
    Misses: Integer;      // takes that found the stack empty (should stay 0)
  end;

  { A producer puts the values 1..Operations in; the consumer takes Operations values out and adds them up (to
    check that none was lost) }
  TQueueWorker = class(TBenchWorker)
  protected
    procedure Work; override;
  public
    LockFree: PIORingRequestQueue;
    Locked: PLockedQueue;
    Consumer: Boolean;
    Sum: UInt64;
  end;

  TRunResult = record
    OperationsPerSecond: Double;
    CpuMilliseconds: Double;
  end;

var
  GInvariant: TFormatSettings;
  GRuns: Integer = 3;
  GThreadCounts: array of Integer;
  GCsvFile: string;
  GStructures: set of TStructure = [stFreeList, stQueue];

{ TLockedFreeList }

procedure TLockedFreeList.Open(const ACapacity: Cardinal);
var
  LBlock: PByte;
  LIndex: Cardinal;
begin
  LBlock := IORingAllocCacheAligned(IORING_CACHE_LINE_SIZE + ACapacity * SizeOf(Cardinal), FMemory);
  FLock := Pointer(LBlock);
  FCount := Pointer(LBlock + LOCK_SIZE);
  FItems := Pointer(LBlock + IORING_CACHE_LINE_SIZE);

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
  LockAcquire(FLock);
  Result := FCount^ > 0;

  if Result then
  begin
    Dec(FCount^);
    AIndex := FItems^[FCount^];
  end
  else
    AIndex := 0;

  LockRelease(FLock);
end;

procedure TLockedFreeList.Push(const AIndex: Cardinal);
begin
  LockAcquire(FLock);
  FItems^[FCount^] := AIndex;
  Inc(FCount^);
  LockRelease(FLock);
end;

{ TLockedQueue }

procedure TLockedQueue.Open(const ACapacity: Cardinal);
var
  LBlock: PByte;
begin
  LBlock := IORingAllocCacheAligned(IORING_CACHE_LINE_SIZE + ACapacity * SizeOf(NativeUInt), FMemory);
  FLock := Pointer(LBlock);
  FHead := Pointer(LBlock + LOCK_SIZE);
  FCount := Pointer(LBlock + LOCK_SIZE + 4);
  FItems := Pointer(LBlock + IORING_CACHE_LINE_SIZE);
  FMask := ACapacity - 1;
end;

procedure TLockedQueue.Close;
begin
  FreeMem(FMemory);
  FMemory := nil;
end;

{ Both first look at the count without the lock: a full (or empty) queue is then answered without taking the lock - what
  a careful lock-based queue does, and what the lock-free queue does by itself }
function TLockedQueue.TryEnqueue(const AValue: NativeUInt): Boolean;
begin
  if TAtomic.LoadAcquire(FCount^) > FMask then
    Exit(False);

  LockAcquire(FLock);
  Result := FCount^ <= FMask;

  if Result then
  begin
    FItems^[(FHead^ + FCount^) and FMask] := AValue;
    Inc(FCount^);
  end;

  LockRelease(FLock);
end;

function TLockedQueue.TryDequeue(out AValue: NativeUInt): Boolean;
begin
  AValue := 0;

  if TAtomic.LoadAcquire(FCount^) = 0 then
    Exit(False);

  LockAcquire(FLock);
  Result := FCount^ > 0;

  if Result then
  begin
    AValue := FItems^[FHead^];
    FHead^ := (FHead^ + 1) and FMask;
    Dec(FCount^);
  end
  else
    AValue := 0;

  LockRelease(FLock);
end;

{ TBenchWorker }

constructor TBenchWorker.Create(const AContender: TContender; const AOperations: Integer;
  const AWorkMicroseconds: Cardinal; const AReady: PInteger; const AThreads: Integer);
begin
  FContender := AContender;
  FOperations := AOperations;
  FWorkMicroseconds := AWorkMicroseconds;
  FReady := AReady;
  FThreads := AThreads;

  inherited Create(True);
end;

procedure TBenchWorker.Execute;
begin
  // Start together
  TAtomic.Increment(FReady^);

  while TAtomic.LoadAcquire(FReady^) < FThreads do
    TThread.Yield;

  StartTime := TIORingPlatform.TimestampMicroseconds;
  Work;
  EndTime := TIORingPlatform.TimestampMicroseconds;
end;

{ TFreeListWorker }

procedure TFreeListWorker.Work;
var
  LPair: Integer;
  LIndex: Cardinal;
begin
  case FContender of
    cnLockFree:
      for LPair := 1 to FOperations do
        if LockFree^.TryPop(LIndex) then
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);

          LockFree^.Push(LIndex);
        end
        else
          Inc(Misses);
    cnLock:
      for LPair := 1 to FOperations do
        if Locked^.TryPop(LIndex) then
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);

          Locked^.Push(LIndex);
        end
        else
          Inc(Misses);
  end;
end;

{ TQueueWorker }

procedure TQueueWorker.Work;
var
  LItem: Integer;
  LValue: NativeUInt;
begin
  if Consumer then
  begin
    LItem := 0;

    case FContender of
      cnLockFree:
        while LItem < FOperations do
          if LockFree^.TryDequeue(LValue) then
          begin
            Inc(LItem);
            Inc(Sum, LValue);
          end
          else
            TAtomic.CpuPause;
      cnLock:
        while LItem < FOperations do
          if Locked^.TryDequeue(LValue) then
          begin
            Inc(LItem);
            Inc(Sum, LValue);
          end
          else
            TAtomic.CpuPause;
    end;
  end
  else
    case FContender of
      cnLockFree:
        for LItem := 1 to FOperations do
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);

          while not LockFree^.TryEnqueue(NativeUInt(LItem)) do
            TAtomic.CpuPause;
        end;
      cnLock:
        for LItem := 1 to FOperations do
        begin
          if FWorkMicroseconds > 0 then
            SpinMicroseconds(FWorkMicroseconds);

          while not Locked^.TryEnqueue(NativeUInt(LItem)) do
            TAtomic.CpuPause;
        end;
    end;
end;

{ Running }

// Starts AWorkers together and measures them: operations per second from the first start to the last end
function RunWorkers(const AWorkers: array of TBenchWorker; const AOperations: Int64): TRunResult;

  procedure RaiseWorkerFailed(const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'A benchmark thread failed: %s', [AMessage]);
  end;

var
  LMeasurement: TBenchMeasurement;
  LIndex: Integer;
  LStart: UInt64;
  LEnd: UInt64;
begin
  LMeasurement.Start;

  for LIndex := 0 to High(AWorkers) do
    AWorkers[LIndex].Start;

  for LIndex := 0 to High(AWorkers) do
    AWorkers[LIndex].WaitFor;

  LMeasurement.Stop;

  LStart := High(UInt64);
  LEnd := 0;

  for LIndex := 0 to High(AWorkers) do
  begin
    if AWorkers[LIndex].FatalException <> nil then
      RaiseWorkerFailed(Exception(AWorkers[LIndex].FatalException).Message);

    if AWorkers[LIndex].StartTime < LStart then
      LStart := AWorkers[LIndex].StartTime;

    if AWorkers[LIndex].EndTime > LEnd then
      LEnd := AWorkers[LIndex].EndTime;
  end;

  Result.OperationsPerSecond := AOperations / ((LEnd - LStart) / 1000000);
  Result.CpuMilliseconds := LMeasurement.UserMilliseconds + LMeasurement.KernelMilliseconds;
end;

procedure ScenarioSettings(const AScenario: TScenario; out AOperations: Integer; out AWork: Cardinal);
begin
  if AScenario = scTight then
  begin
    AOperations := TIGHT_OPERATIONS;
    AWork := 0;
  end
  else
  begin
    AOperations := WORK_OPERATIONS;
    AWork := WORK_MICROSECONDS;
  end;
end;

function RunFreeList(const AContender: TContender; const AScenario: TScenario; const AThreads: Integer): TRunResult;

  procedure RaiseFreeListEmpty; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'The free list ran empty - the benchmark is wrong');
  end;

var
  LLockFree: TIORingFreeList;
  LLocked: TLockedFreeList;
  LWorkers: array of TBenchWorker;
  LWorker: TFreeListWorker;
  LReady: Integer;
  LIndex: Integer;
  LPairs: Integer;
  LWork: Cardinal;
begin
  ScenarioSettings(AScenario, LPairs, LWork);
  LPairs := LPairs div AThreads;
  LLockFree.Open(FREE_LIST_CAPACITY);
  LLocked.Open(FREE_LIST_CAPACITY);

  try
    LReady := 0;
    SetLength(LWorkers, AThreads);

    for LIndex := 0 to AThreads - 1 do
    begin
      LWorker := TFreeListWorker.Create(AContender, LPairs, LWork, @LReady, AThreads);
      LWorker.LockFree := @LLockFree;
      LWorker.Locked := @LLocked;
      LWorkers[LIndex] := LWorker;
    end;

    try
      Result := RunWorkers(LWorkers, Int64(LPairs) * AThreads);

      for LIndex := 0 to AThreads - 1 do
        if TFreeListWorker(LWorkers[LIndex]).Misses > 0 then
          RaiseFreeListEmpty;
    finally
      for LIndex := 0 to AThreads - 1 do
        LWorkers[LIndex].Free;
    end;
  finally
    LLocked.Close;
    LLockFree.Close;
  end;
end;

function RunQueue(const AContender: TContender; const AScenario: TScenario; const AProducers: Integer): TRunResult;

  procedure RaiseQueueWrong; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'The queue lost or changed values - the benchmark or the queue is wrong');
  end;

var
  LLockFree: TIORingRequestQueue;
  LLocked: TLockedQueue;
  LWorkers: array of TBenchWorker;
  LWorker: TQueueWorker;
  LReady: Integer;
  LIndex: Integer;
  LPerProducer: Integer;
  LWork: Cardinal;
begin
  ScenarioSettings(AScenario, LPerProducer, LWork);
  LPerProducer := LPerProducer div AProducers;
  LLockFree.Open(QUEUE_CAPACITY);
  LLocked.Open(QUEUE_CAPACITY);

  try
    LReady := 0;
    // Worker 0 is the consumer
    SetLength(LWorkers, AProducers + 1);

    for LIndex := 0 to AProducers do
    begin
      if LIndex = 0 then
        LWorker := TQueueWorker.Create(AContender, LPerProducer * AProducers, 0, @LReady, AProducers + 1)
      else
        LWorker := TQueueWorker.Create(AContender, LPerProducer, LWork, @LReady, AProducers + 1);

      LWorker.LockFree := @LLockFree;
      LWorker.Locked := @LLocked;
      LWorker.Consumer := LIndex = 0;
      LWorkers[LIndex] := LWorker;
    end;

    try
      Result := RunWorkers(LWorkers, Int64(LPerProducer) * AProducers);

      // Every producer put 1..LPerProducer in
      if TQueueWorker(LWorkers[0]).Sum <> UInt64(AProducers) * (UInt64(LPerProducer) * UInt64(LPerProducer + 1) div 2) then
        RaiseQueueWrong;
    finally
      for LIndex := 0 to AProducers do
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

function LogicalProcessorCount: Integer;
begin
  Result := BenchProcessorCount;
end;

procedure AppendCsv(const AStructure: TStructure; const AContender: TContender; const AScenario: TScenario;
  const AThreads, ARun: Integer; const AResult: TRunResult);
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
    // ops_per_s: free list = take+give pairs, queue = values; threads: queue = producers
    if LNew then
      Writeln(LFile, 'timestamp,compiler,platform,structure,variant,scenario,threads,run,ops_per_s,cpu_ms');

    Writeln(LFile, Format('%s,%s,%s,%s,%s,%s,%d,%d,%.0f,%.1f',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now, GInvariant), COMPILER_NAME, BenchPlatformName,
       STRUCTURE_NAMES[AStructure], CONTENDER_NAMES[AContender], SCENARIO_NAMES[AScenario], AThreads, ARun,
       AResult.OperationsPerSecond, AResult.CpuMilliseconds], GInvariant));
  finally
    CloseFile(LFile);
  end;
end;

procedure ParseOptions;

  procedure RaiseUnknownStructure(const AIndex: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Unknown structure: %s (freelist or queue)', [ParamStr(AIndex)]);
  end;

  procedure RaiseUnknownOption(const AIndex: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Unknown option: %s', [ParamStr(AIndex)]);
  end;

  procedure RaiseBadRuns; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, '--runs must be at least 1');
  end;

var
  LIndex: Integer;
  LName: string;
  LList: TStringList;
  LItem: Integer;
  LCpus: Integer;
  LStructure: TStructure;
  LFound: Boolean;
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
    else if (LName = '--only') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      LFound := False;

      for LStructure := Low(TStructure) to High(TStructure) do
        if LowerCase(ParamStr(LIndex)) = STRUCTURE_OPTIONS[LStructure] then
        begin
          GStructures := [LStructure];
          LFound := True;
        end;

      if not LFound then
        RaiseUnknownStructure(LIndex);
    end
    else if (LName = '--csv') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GCsvFile := ParamStr(LIndex);
    end
    else
      RaiseUnknownOption(LIndex);

    Inc(LIndex);
  end;

  if GRuns < 1 then
    RaiseBadRuns;

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

procedure RunStructure(const AStructure: TStructure);
var
  LScenario: TScenario;
  LThreadIndex: Integer;
  LThreads: Integer;
  LRun: Integer;
  LContender: TContender;
  LResult: TRunResult;
  LRates: array[TContender] of array of Double;
  LCpu: array[TContender] of array of Double;
  LRate: array[TContender] of Double;
  LDone: array of Integer;
  LIndex: Integer;
  LSkip: Boolean;
begin
  Writeln;

  if AStructure = stFreeList then
  begin
    Writeln('Free list: take one index, (work,) give it back.');
    Writeln('Mops/s = million take+give pairs per second, all threads; median of ', GRuns, ' runs.');
  end
  else
  begin
    Writeln('Request queue: N producers put values in, one consumer takes them out.');
    Writeln('Threads = producers (plus the consumer). Mops/s = million values per second; median of ', GRuns, ' runs.');
  end;

  Writeln('CPU ms = CPU time of all threads for the run (median).');
  Writeln;
  Writeln(Format('%-10s %7s %11s %11s %9s %12s %12s',
    ['Scenario', 'Threads', 'lock-free', LOCK_NAME, 'LF/' + LOCK_SHORT_NAME, 'LF CPU ms', LOCK_SHORT_NAME + ' CPU ms'],
    GInvariant));
  Writeln(Format('%-10s %7s %11s %11s %9s %12s %12s', ['', '', 'Mops/s', 'Mops/s', '', '', ''], GInvariant));

  for LScenario := Low(TScenario) to High(TScenario) do
  begin
    LDone := nil;

    for LThreadIndex := 0 to High(GThreadCounts) do
    begin
      LThreads := GThreadCounts[LThreadIndex];

      // The queue needs a processor for the consumer too
      if (AStructure = stQueue) and (LThreads >= LogicalProcessorCount) then
        LThreads := LogicalProcessorCount - 1;

      LSkip := LThreads < 1;

      for LIndex := 0 to High(LDone) do
        if LDone[LIndex] = LThreads then
          LSkip := True;

      if LSkip then
        Continue;

      SetLength(LDone, Length(LDone) + 1);
      LDone[High(LDone)] := LThreads;

      for LContender := Low(TContender) to High(TContender) do
      begin
        SetLength(LRates[LContender], GRuns);
        SetLength(LCpu[LContender], GRuns);
      end;

      // The contenders take turns, so that a slow moment of the machine hits both
      for LRun := 1 to GRuns do
        for LContender := Low(TContender) to High(TContender) do
        begin
          if AStructure = stFreeList then
            LResult := RunFreeList(LContender, LScenario, LThreads)
          else
            LResult := RunQueue(LContender, LScenario, LThreads);

          LRates[LContender][LRun - 1] := LResult.OperationsPerSecond;
          LCpu[LContender][LRun - 1] := LResult.CpuMilliseconds;
          AppendCsv(AStructure, LContender, LScenario, LThreads, LRun, LResult);
        end;

      for LContender := Low(TContender) to High(TContender) do
        LRate[LContender] := Median(LRates[LContender]);

      Writeln(Format('%-10s %7d %11.2f %11.2f %9.2f %12.0f %12.0f',
        [SCENARIO_NAMES[LScenario], LThreads, LRate[cnLockFree] / 1E6, LRate[cnLock] / 1E6,
         LRate[cnLockFree] / LRate[cnLock], Median(LCpu[cnLockFree]), Median(LCpu[cnLock])], GInvariant));
    end;
  end;
end;

procedure RunStructureBenchmarks;
var
  LStructure: TStructure;
begin
  ParseOptions;
  Writeln(Format('Engine structures: %s %s, %d logical processors, %s',
    [COMPILER_NAME, BenchPlatformName, LogicalProcessorCount, FormatDateTime('yyyy-mm-dd hh:nn', Now, GInvariant)],
    GInvariant));

  for LStructure := Low(TStructure) to High(TStructure) do
    if LStructure in GStructures then
      RunStructure(LStructure);
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
