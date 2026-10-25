program Pascal.IOUring.Benchmarks;

{
  Sequential file reading benchmark (Docs/Plan.md, Phase 5).

  Compares the IoRing stream and reader with the RTL streams, plain and
  overlapped ReadFile and a multi-threaded reader. Scenarios:
    read-through  read the file, only touching the data (checksum)
    work          the same plus simulated CPU work per MiB (does I/O overlap
                  with the work - "data for free"?)
  Cache states:
    cold          the file is purged from the Windows file cache before each run
    warm          the file is in the cache (buffered contenders only)

  Pascal.IOUring.Benchmarks [options]
    --dir <folder>   where the test files are created (default %TEMP%\Pascal.IOUring.Bench)
    --sizes <list>   file sizes in GiB, comma separated (default 1,10)
    --runs <n>       runs per contender and case; the median is reported (default 3)
    --work-us <n>    CPU work per MiB in the work scenario, microseconds (default 200)
    --threads <n>    threads of the multi-threaded contender (default 4)
    --csv <file>     append every single run to this CSV file
    --tune           only IoRing reader variants: cold read-through of the first size
    --keep           keep the test files (default: delete them at the end)

  The work scenario runs only with the first (smallest) size, to keep the run
  time reasonable.
}

{$APPTYPE CONSOLE}
{$WARN SYMBOL_PLATFORM OFF}

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.StrUtils, System.Generics.Collections,
  System.Generics.Defaults, System.Win.Registry, PIRUnit.IORing, PIRUnit.Types,
  PIRUnit.Benchmark.Common in '..\PIRUnit.Benchmark.Common.pas',
  PIRUnit.Benchmark.Readers in '..\PIRUnit.Benchmark.Readers.pas', PIRUnit.Benchmark.Contenders in '..\PIRUnit.Benchmark.Contenders.pas';

type
  TScenario = (scReadThrough, scWork);
  TCacheState = (csCold, csWarm);

  TRunResult = record
    SizeGiB: Integer;
    Scenario: TScenario;
    Cache: TCacheState;
    Contender: Integer;
    Run: Integer;
    Seconds: Double;
    UserMilliseconds: Double;
    KernelMilliseconds: Double;
    Stalls: UInt64;
    ChecksumOK: Boolean;
  end;

  TOptions = record
    Folder: string;
    Sizes: TArray<Integer>;
    Runs: Integer;
    WorkMicroseconds: Cardinal;
    Threads: Integer;
    CsvFileName: string;
    Tune: Boolean;
    Keep: Boolean;
  end;

const
  SCENARIO_NAMES: array[TScenario] of string = ('read-through', 'work');
  CACHE_NAMES: array[TCacheState] of string = ('cold', 'warm');
{$IFDEF CPUX64}
  PLATFORM_NAME = 'Win64';
{$ELSE}
  PLATFORM_NAME = 'Win32';
{$ENDIF}

var
  GOptions: TOptions;
  GContenders: TArray<TContender>;
  GResults: TList<TRunResult>;
  GInvariant: TFormatSettings;

{ Options }

procedure ParseOptions;

  procedure RaiseMissingValue(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Missing value for %s', [AName]);
  end;

  procedure RaiseUnknownOption(const AIndex: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Unknown option %s', [ParamStr(AIndex)]);
  end;

  // The value after option AName: the next parameter (AIndex moves to it)
  function NextValue(var AIndex: Integer; const AName: string): string;
  begin
    Inc(AIndex);

    if AIndex > ParamCount then
      RaiseMissingValue(AName);

    Result := ParamStr(AIndex);
  end;

var
  LIndex: Integer;
  LName: string;
  LParts: TArray<string>;
  LPart: string;
begin
  GOptions.Folder := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'Pascal.IOUring.Bench';
  GOptions.Sizes := [1, 10];
  GOptions.Runs := 3;
  GOptions.WorkMicroseconds := 200;
  GOptions.Threads := 4;
  GOptions.CsvFileName := '';
  GOptions.Tune := False;
  GOptions.Keep := False;

  LIndex := 1;

  while LIndex <= ParamCount do
  begin
    LName := LowerCase(ParamStr(LIndex));

    if LName = '--dir' then
      GOptions.Folder := NextValue(LIndex, LName)
    else if LName = '--sizes' then
    begin
      GOptions.Sizes := nil;
      LParts := NextValue(LIndex, LName).Split([',']);

      for LPart in LParts do
        GOptions.Sizes := GOptions.Sizes + [StrToInt(Trim(LPart))];
    end
    else if LName = '--runs' then
      GOptions.Runs := StrToInt(NextValue(LIndex, LName))
    else if LName = '--work-us' then
      GOptions.WorkMicroseconds := StrToInt(NextValue(LIndex, LName))
    else if LName = '--threads' then
      GOptions.Threads := StrToInt(NextValue(LIndex, LName))
    else if LName = '--csv' then
      GOptions.CsvFileName := NextValue(LIndex, LName)
    else if LName = '--tune' then
      GOptions.Tune := True
    else if LName = '--keep' then
      GOptions.Keep := True
    else
      RaiseUnknownOption(LIndex);

    Inc(LIndex);
  end;
end;

{ Machine description }

function CpuName: string;
var
  LRegistry: TRegistry;
begin
  Result := '?';
  LRegistry := TRegistry.Create(KEY_READ);
  try
    LRegistry.RootKey := HKEY_LOCAL_MACHINE;

    if LRegistry.OpenKeyReadOnly('HARDWARE\DESCRIPTION\System\CentralProcessor\0') then
      Result := Trim(LRegistry.ReadString('ProcessorNameString'));
  finally
    LRegistry.Free;
  end;
end;

function TotalMemoryGiB: Double;
var
  LStatus: TMemoryStatusEx;
begin
  LStatus.dwLength := SizeOf(LStatus);
  GlobalMemoryStatusEx(LStatus);

  Result := LStatus.ullTotalPhys / (1024.0 * 1024 * 1024);
end;

procedure PrintMachine;
var
  LCapabilities: TIORingCapabilities;
begin
  LCapabilities := TIORing.QueryCapabilities;
  Writeln(Format('Platform:  %s, Delphi compiler %.1f', [PLATFORM_NAME, CompilerVersion], GInvariant));
  Writeln(Format('CPU:       %s, %d logical processors', [CpuName, TThread.ProcessorCount]));
  Writeln(Format('Memory:    %.1f GiB', [TotalMemoryGiB], GInvariant));
  Writeln(Format('Windows:   %d.%d build %d', [TOSVersion.Major, TOSVersion.Minor, TOSVersion.Build]));
  Writeln(Format('IoRing:    version %d, max SQ %d, emulated %s',
    [LCapabilities.NativeVersion, LCapabilities.MaxSubmissionQueueSize, BoolToStr(LCapabilities.Emulated, True)]));
  Writeln(Format('Files in:  %s', [GOptions.Folder]));
  Writeln;
end;

{ Files }

function BenchFileName(const ASizeGiB: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(GOptions.Folder) + Format('Bench-%dGiB.bin', [ASizeGiB]);
end;

procedure PrepareFile(const ASizeGiB: Integer);
var
  LFileName: string;
  LSize: Int64;
  LMeasurement: TBenchMeasurement;
begin
  LFileName := BenchFileName(ASizeGiB);
  LSize := Int64(ASizeGiB) * 1024 * MiB;

  if FileSizeOf(LFileName) = LSize then
    Exit;

  Write(Format('Creating %s ... ', [LFileName]));
  ForceDirectories(GOptions.Folder);
  LMeasurement.Start;
  CreateBenchFile(LFileName, LSize);
  LMeasurement.Stop;
  Writeln(Format('%.1f s', [LMeasurement.Seconds], GInvariant));
end;

{ Reads the file warm, purges it, reads it again: if purging works, the second read is clearly slower. Cold
  results mean nothing otherwise. }
procedure CheckCachePurge(const AFileName: string);
var
  LConsumer: TBenchConsumer;
  LStalls: UInt64;
  LMeasurement: TBenchMeasurement;
  LWarm: Double;
  LCold: Double;
begin
  LStalls := 0;
  LConsumer.Init(0);
  GContenders[0].Run(AFileName, LConsumer, LStalls);   // make it warm

  LConsumer.Init(0);
  LMeasurement.Start;
  GContenders[0].Run(AFileName, LConsumer, LStalls);
  LMeasurement.Stop;
  LWarm := LMeasurement.Seconds;

  PurgeFileCache(AFileName);
  LConsumer.Init(0);
  LMeasurement.Start;
  GContenders[0].Run(AFileName, LConsumer, LStalls);
  LMeasurement.Stop;
  LCold := LMeasurement.Seconds;

  Writeln(Format('Cache purge check (%s): warm %.3f s, after purge %.3f s -> %s',
    [GContenders[0].Name, LWarm, LCold,
    System.StrUtils.IfThen(LCold > 1.5 * LWarm, 'purge works', 'PURGE DOES NOT SEEM TO WORK')], GInvariant));
  Writeln;
end;

{ Running }

function MeasureRun(const AContender: Integer; const AFileName: string; const AWorkMicroseconds: Cardinal;
  out AChecksum: UInt64; out ABytes: Int64): TRunResult;
var
  LConsumer: TBenchConsumer;
  LMeasurement: TBenchMeasurement;
  LStalls: UInt64;
begin
  LConsumer.Init(AWorkMicroseconds);
  LStalls := 0;
  LMeasurement.Start;
  GContenders[AContender].Run(AFileName, LConsumer, LStalls);
  LMeasurement.Stop;

  Result.Contender := AContender;
  Result.Seconds := LMeasurement.Seconds;
  Result.UserMilliseconds := LMeasurement.UserMilliseconds;
  Result.KernelMilliseconds := LMeasurement.KernelMilliseconds;
  Result.Stalls := LStalls;
  AChecksum := LConsumer.Checksum;
  ABytes := LConsumer.Bytes;
end;

procedure RunCase(const ASizeGiB: Integer; const AScenario: TScenario; const ACache: TCacheState;
  var AReferenceChecksum: UInt64; var AHaveReference: Boolean);
var
  LFileName: string;
  LWork: Cardinal;
  LRun: Integer;
  LIndex: Integer;
  LResult: TRunResult;
  LChecksum: UInt64;
  LBytes: Int64;
  LWarmUp: TBenchConsumer;
  LStalls: UInt64;
  LUnbufferedPass: Boolean;
begin
  LFileName := BenchFileName(ASizeGiB);

  if AScenario = scWork then
    LWork := GOptions.WorkMicroseconds
  else
    LWork := 0;

  Writeln(Format('--- %d GiB, %s, %s cache ---', [ASizeGiB, SCENARIO_NAMES[AScenario], CACHE_NAMES[ACache]]));

  if ACache = csWarm then
  begin
    LWarmUp.Init(0);
    LStalls := 0;
    GContenders[0].Run(LFileName, LWarmUp, LStalls);
  end;

  {
    Contenders take turns run by run, so slow drift (temperature, background work) affects all of them alike. In each
    run the buffered contenders go first, then (cold cache only) the unbuffered ones, after an untimed unbuffered read -
    see ReadUnbufferedUntimed.
  }
  for LRun := 1 to GOptions.Runs do
    for LUnbufferedPass in [False, True] do
    begin
      if LUnbufferedPass then
      begin
        if ACache = csWarm then
          Continue;

        ReadUnbufferedUntimed(LFileName);
      end;

      for LIndex := 0 to High(GContenders) do
      begin
        if GContenders[LIndex].Unbuffered <> LUnbufferedPass then
          Continue;

        if (AScenario = scWork) and not GContenders[LIndex].InOrder then
          Continue;

        if ACache = csCold then
          PurgeFileCache(LFileName);

        LResult := MeasureRun(LIndex, LFileName, LWork, LChecksum, LBytes);
        LResult.SizeGiB := ASizeGiB;
        LResult.Scenario := AScenario;
        LResult.Cache := ACache;
        LResult.Run := LRun;

        if not AHaveReference then
        begin
          AReferenceChecksum := LChecksum;
          AHaveReference := True;
        end;

        LResult.ChecksumOK := (LChecksum = AReferenceChecksum) and (LBytes = Int64(ASizeGiB) * 1024 * MiB);

        if not LResult.ChecksumOK then
          Writeln(Format('  CHECKSUM OR SIZE MISMATCH: %s run %d', [GContenders[LIndex].Name, LRun]));

        Write(Format('  run %d  %-48s %7.3f s'#13, [LRun, GContenders[LIndex].Name, LResult.Seconds], GInvariant));
        GResults.Add(LResult);
      end;
    end;

  Write(StringOfChar(' ', 79) + #13);
end;

{ Reporting }

function Median(AValues: TArray<Double>): Double;
var
  LCount: Integer;
begin
  LCount := Length(AValues);

  if LCount = 0 then
    Exit(0);

  TArray.Sort<Double>(AValues);

  if Odd(LCount) then
    Result := AValues[LCount div 2]
  else
    Result := (AValues[LCount div 2 - 1] + AValues[LCount div 2]) / 2;
end;

procedure PrintSummary(const ASizeGiB: Integer; const AScenario: TScenario; const ACache: TCacheState;
  const ASortByTime: Boolean);
type
  TLine = record
    Name: string;
    Seconds: Double;
    UserMilliseconds: Double;
    KernelMilliseconds: Double;
    Stalls: Double;
    AllOK: Boolean;
  end;
var
  LLines: TList<TLine>;
  LLine: TLine;
  LIndex: Integer;
  LSeconds, LUser, LKernel, LStalls: TArray<Double>;
  LResult: TRunResult;
  LMiB: Double;
begin
  LLines := TList<TLine>.Create;
  try
    for LIndex := 0 to High(GContenders) do
    begin
      LSeconds := nil;
      LUser := nil;
      LKernel := nil;
      LStalls := nil;
      LLine.AllOK := True;

      for LResult in GResults do
        if (LResult.SizeGiB = ASizeGiB) and (LResult.Scenario = AScenario) and (LResult.Cache = ACache)
          and (LResult.Contender = LIndex) then
        begin
          LSeconds := LSeconds + [LResult.Seconds];
          LUser := LUser + [LResult.UserMilliseconds];
          LKernel := LKernel + [LResult.KernelMilliseconds];
          LStalls := LStalls + [Double(LResult.Stalls)];
          LLine.AllOK := LLine.AllOK and LResult.ChecksumOK;
        end;

      if LSeconds = nil then
        Continue;

      LLine.Name := GContenders[LIndex].Name;
      LLine.Seconds := Median(LSeconds);
      LLine.UserMilliseconds := Median(LUser);
      LLine.KernelMilliseconds := Median(LKernel);
      LLine.Stalls := Median(LStalls);
      LLines.Add(LLine);
    end;

    if ASortByTime then
      LLines.Sort(TComparer<TLine>.Construct(
        function(const ALeft, ARight: TLine): Integer
        begin
          Result := CompareValue(ALeft.Seconds, ARight.Seconds);
        end));

    LMiB := ASizeGiB * 1024.0;
    Writeln(Format('%s, %d GiB, %s, %s cache (median of %d runs)',
      [PLATFORM_NAME, ASizeGiB, SCENARIO_NAMES[AScenario], CACHE_NAMES[ACache], GOptions.Runs]));
    Writeln(Format('  %-48s %8s %9s %9s %9s %7s', ['Contender', 'Seconds', 'MiB/s', 'User ms', 'Kernel ms', 'Stalls']));

    for LLine in LLines do
      Writeln(Format('  %-48s %8.3f %9.0f %9.0f %9.0f %7.0f%s',
        [LLine.Name, LLine.Seconds, LMiB / LLine.Seconds, LLine.UserMilliseconds, LLine.KernelMilliseconds,
         LLine.Stalls, System.StrUtils.IfThen(LLine.AllOK, '', '  CHECKSUM!')], GInvariant));

    Writeln;
  finally
    LLines.Free;
  end;
end;

procedure WriteCsv;
var
  LExists: Boolean;
  LLines: TStringList;
  LResult: TRunResult;
  LTimestamp: string;
begin
  if GOptions.CsvFileName = '' then
    Exit;

  LExists := FileExists(GOptions.CsvFileName);
  LLines := TStringList.Create;
  try
    if LExists then
      LLines.LoadFromFile(GOptions.CsvFileName)
    else
      LLines.Add('timestamp,platform,size_gib,scenario,cache,contender,run,seconds,mib_per_s,user_ms,kernel_ms,' +
        'stalls,checksum_ok');

    LTimestamp := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now, GInvariant);

    for LResult in GResults do
      LLines.Add(Format('%s,%s,%d,%s,%s,"%s",%d,%.4f,%.1f,%.1f,%.1f,%d,%s',
        [LTimestamp, PLATFORM_NAME, LResult.SizeGiB, SCENARIO_NAMES[LResult.Scenario], CACHE_NAMES[LResult.Cache],
         GContenders[LResult.Contender].Name, LResult.Run, LResult.Seconds,
         LResult.SizeGiB * 1024.0 / LResult.Seconds, LResult.UserMilliseconds, LResult.KernelMilliseconds,
         LResult.Stalls, BoolToStr(LResult.ChecksumOK, True)], GInvariant));

    LLines.SaveToFile(GOptions.CsvFileName);
  finally
    LLines.Free;
  end;
end;

{ Main }

procedure RunMain;
var
  LSizeIndex: Integer;
  LSize: Integer;
  LScenario: TScenario;
  LCache: TCacheState;
  LReference: UInt64;
  LHaveReference: Boolean;
begin
  for LSizeIndex := 0 to High(GOptions.Sizes) do
  begin
    LSize := GOptions.Sizes[LSizeIndex];
    LHaveReference := False;
    LReference := 0;

    for LScenario := Low(TScenario) to High(TScenario) do
    begin
      if (LScenario = scWork) and (LSizeIndex > 0) then
        Continue;

      for LCache := Low(TCacheState) to High(TCacheState) do
      begin
        RunCase(LSize, LScenario, LCache, LReference, LHaveReference);
        PrintSummary(LSize, LScenario, LCache, False);
      end;
    end;
  end;
end;

procedure RunTuning;
var
  LReference: UInt64;
  LHaveReference: Boolean;
begin
  LHaveReference := False;
  LReference := 0;
  RunCase(GOptions.Sizes[0], scReadThrough, csCold, LReference, LHaveReference);
  PrintSummary(GOptions.Sizes[0], scReadThrough, csCold, True);
end;

procedure RaiseNotAvailable; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseError(Exception, 'IoRing is not available on this system');
end;

var
  LSize: Integer;
begin
  GInvariant := TFormatSettings.Invariant;

  try
    ParseOptions;

    if not IORingAvailable then
      RaiseNotAvailable;

    if GOptions.Tune then
      GContenders := [MainContenders(GOptions.Threads)[0]] + TuningContenders
    else
      GContenders := MainContenders(GOptions.Threads);

    GResults := TList<TRunResult>.Create;
    try
      PrintMachine;

      for LSize in GOptions.Sizes do
        PrepareFile(LSize);

      CheckCachePurge(BenchFileName(GOptions.Sizes[0]));

      if GOptions.Tune then
        RunTuning
      else
        RunMain;

      WriteCsv;
    finally
      GResults.Free;

      if not GOptions.Keep then
        for LSize in GOptions.Sizes do
          DeleteFile(BenchFileName(LSize));
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
