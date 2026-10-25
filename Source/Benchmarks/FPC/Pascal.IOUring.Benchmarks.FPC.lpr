program Pascal.IOUring.Benchmarks.FPC;

{
  Free Pascal version of the sequential reading benchmark (Plan, Phase 9).

  The same method as the Delphi benchmark (Source\Benchmarks): same files,
  same consumer (PIRUnit.Benchmark.Common) and the same reading routines (PIRUnit.Benchmark.Readers),
  but only the main contenders - enough to compare the code Free Pascal makes
  for the library with Delphi's. The Delphi-only contenders (TBufferedFileStream,
  threads) are left out.

  On Linux the overlapped contenders (Windows only) are left out, and the
  plain read contender uses read instead of ReadFile.

  Pascal.IOUring.Benchmarks.FPC [options]
    --dir <folder>   where the test files are created (default <temp>/Pascal.IOUring.Bench)
    --sizes <list>   file sizes in GiB, comma separated (default 1,10)
    --runs <n>       runs per contender and case; the median is reported (default 3)
    --work-us <n>    CPU work per MiB in the work scenario (default 200; first size only)
    --keep           keep the test files

  Build: Source\Build-FPC.ps1 -Project Benchmarks -Platform Win32
         (Win64, or Linux64: built in WSL)
}

{$I PIRInclude.Compiler.inc}

uses
{$IFDEF UNIX}
  cthreads,           // threads on Linux: must come first
{$ENDIF}
  SysUtils, Classes, PIRUnit.IORing, PIRUnit.Types, PIRUnit.SequentialReader, PIRUnit.Benchmark.Common,
  PIRUnit.Benchmark.Readers;

type
  TContender = (cnFileStream64K, cnFileStream1M, cnReadFile1M, cnOverlapped, cnOverlappedUnbuffered,
    cnIORingStream, cnIORingStreamUnbuffered, cnIORingReader, cnIORingReaderUnbuffered);
  TScenario = (scReadThrough, scWork);
  TCacheState = (csCold, csWarm);

  TMeasurement = record
    Seconds: Double;
    UserMilliseconds: Double;
    KernelMilliseconds: Double;
    Stalls: UInt64;
    Valid: Boolean;
  end;

const
{$IFDEF MSWINDOWS}
  RING_NAME = 'IoRing';
  SEQUENTIAL_HINT_NAME = 'sequential scan';
{$ELSE}
  RING_NAME = 'io_uring';
  SEQUENTIAL_HINT_NAME = 'sequential hint';
{$ENDIF}
  CONTENDER_NAMES: array[TContender] of string = (
    'TFileStream 64 KiB reads',
    'TFileStream 1 MiB reads',
    READ_CALL_NAME + ' 1 MiB, ' + SEQUENTIAL_HINT_NAME,
    'Overlapped ReadFile 1 MiB x 8',
    'Overlapped ReadFile 1 MiB x 8, unbuffered',
    RING_NAME + ' stream, 64 KiB reads',
    RING_NAME + ' stream, 64 KiB reads, unbuffered',
    RING_NAME + ' reader, zero-copy',
    RING_NAME + ' reader, zero-copy, unbuffered');
  CONTENDER_UNBUFFERED: array[TContender] of Boolean = (False, False, False, False, True, False, True, False, True);
  // Overlapped I/O is Windows only
  CONTENDER_ON_THIS_SYSTEM: array[TContender] of Boolean = (
    True, True, True, {$IFDEF MSWINDOWS}True, True{$ELSE}False, False{$ENDIF}, True, True, True, True);
  SCENARIO_NAMES: array[TScenario] of string = ('read-through', 'work');
  CACHE_NAMES: array[TCacheState] of string = ('cold', 'warm');

var
  GFolder: string;
  GSizes: array of Integer;
  GRuns: Integer;
  GWorkMicroseconds: Cardinal;
  GKeep: Boolean;
  GInvariant: TFormatSettings;

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
  LParts: TStringList;
  LPart: Integer;
begin
  GFolder := DefaultBenchFolder;
  SetLength(GSizes, 2);
  GSizes[0] := 1;
  GSizes[1] := 10;
  GRuns := 3;
  GWorkMicroseconds := 200;
  GKeep := False;

  LIndex := 1;

  while LIndex <= ParamCount do
  begin
    LName := LowerCase(ParamStr(LIndex));

    if LName = '--dir' then
      GFolder := NextValue(LIndex, LName)
    else if LName = '--sizes' then
    begin
      LParts := TStringList.Create;
      try
        LParts.CommaText := NextValue(LIndex, LName);
        SetLength(GSizes, LParts.Count);

        for LPart := 0 to LParts.Count - 1 do
          GSizes[LPart] := StrToInt(Trim(LParts[LPart]));
      finally
        LParts.Free;
      end;
    end
    else if LName = '--runs' then
      GRuns := StrToInt(NextValue(LIndex, LName))
    else if LName = '--work-us' then
      GWorkMicroseconds := StrToInt(NextValue(LIndex, LName))
    else if LName = '--keep' then
      GKeep := True
    else
      RaiseUnknownOption(LIndex);

    Inc(LIndex);
  end;
end;

function BenchFileName(const ASizeGiB: Integer): string;
begin
  Result := IncludeTrailingPathDelimiter(GFolder) + Format('Bench-%dGiB.bin', [ASizeGiB]);
end;

procedure PrepareFile(const ASizeGiB: Integer);
var
  LFileName: string;
  LSize: Int64;
begin
  LFileName := BenchFileName(ASizeGiB);
  LSize := Int64(ASizeGiB) * 1024 * MiB;

  if FileSizeOf(LFileName) = LSize then
    Exit;

  Writeln('Creating ', LFileName, ' ...');
  ForceDirectories(GFolder);
  CreateBenchFile(LFileName, LSize);
end;

function RunContender(const AContender: TContender; const AFileName: string; var AConsumer: TBenchConsumer): UInt64;
begin
  Result := 0;

  case AContender of
    cnFileStream64K: ReadWithFileStream(AFileName, 64 * 1024, AConsumer);
    cnFileStream1M: ReadWithFileStream(AFileName, MiB, AConsumer);
    cnReadFile1M: ReadWithReadFile(AFileName, MiB, True, AConsumer);
{$IFDEF MSWINDOWS}
    cnOverlapped: ReadWithOverlapped(AFileName, False, MiB, 8, AConsumer);
    cnOverlappedUnbuffered: ReadWithOverlapped(AFileName, True, MiB, 8, AConsumer);
{$ENDIF}
    cnIORingStream: Result := ReadWithIORingStream(AFileName, [], AConsumer);
    cnIORingStreamUnbuffered: Result := ReadWithIORingStream(AFileName, [sroUnbuffered], AConsumer);
    cnIORingReader:
      Result := ReadWithIORingZeroCopy(AFileName, [], IORING_READER_DEFAULT_BUFFER_SIZE,
        IORING_READER_DEFAULT_BUFFER_COUNT, AConsumer);
    cnIORingReaderUnbuffered:
      Result := ReadWithIORingZeroCopy(AFileName, [sroUnbuffered], IORING_READER_DEFAULT_BUFFER_SIZE,
        IORING_READER_DEFAULT_BUFFER_COUNT, AConsumer);
  end;
end;

function Median(AValues: array of Double): Double;
var
  LCount: Integer;
  LIndex: Integer;
  LInner: Integer;
  LValue: Double;
begin
  LCount := Length(AValues);

  // Insertion sort: a handful of values
  for LIndex := 1 to LCount - 1 do
  begin
    LValue := AValues[LIndex];
    LInner := LIndex - 1;

    while (LInner >= 0) and (AValues[LInner] > LValue) do
    begin
      AValues[LInner + 1] := AValues[LInner];
      Dec(LInner);
    end;

    AValues[LInner + 1] := LValue;
  end;

  if Odd(LCount) then
    Result := AValues[LCount div 2]
  else
    Result := (AValues[LCount div 2 - 1] + AValues[LCount div 2]) / 2;
end;

procedure RunCase(const ASizeGiB: Integer; const AScenario: TScenario; const ACache: TCacheState);
var
  LFileName: string;
  LWork: Cardinal;
  LResults: array[TContender] of array of TMeasurement;
  LContender: TContender;
  LRun: Integer;
  LUnbufferedPass: Boolean;
  LConsumer: TBenchConsumer;
  LMeasurement: TBenchMeasurement;
  LStalls: UInt64;
  LReference: UInt64;
  LHaveReference: Boolean;
  LSeconds: array of Double;
  LUser: array of Double;
  LKernel: array of Double;
  LStallValues: array of Double;
  LAllValid: Boolean;
  LMedian: Double;
begin
  LFileName := BenchFileName(ASizeGiB);

  if AScenario = scWork then
    LWork := GWorkMicroseconds
  else
    LWork := 0;

  for LContender := Low(TContender) to High(TContender) do
    SetLength(LResults[LContender], 0);

  if ACache = csWarm then
  begin
    LConsumer.Init(0);
    RunContender(cnFileStream64K, LFileName, LConsumer);
  end;

  LHaveReference := False;
  LReference := 0;

  for LRun := 1 to GRuns do
    for LUnbufferedPass := False to True do
    begin
      if LUnbufferedPass then
      begin
        if ACache = csWarm then
          Continue;

        ReadUnbufferedUntimed(LFileName);
      end;

      for LContender := Low(TContender) to High(TContender) do
      begin
        if (CONTENDER_UNBUFFERED[LContender] <> LUnbufferedPass) or not CONTENDER_ON_THIS_SYSTEM[LContender] then
          Continue;

        if ACache = csCold then
          PurgeFileCache(LFileName);

        LConsumer.Init(LWork);
        LMeasurement.Start;
        LStalls := RunContender(LContender, LFileName, LConsumer);
        LMeasurement.Stop;

        if not LHaveReference then
        begin
          LReference := LConsumer.Checksum;
          LHaveReference := True;
        end;

        SetLength(LResults[LContender], Length(LResults[LContender]) + 1);

        with LResults[LContender][High(LResults[LContender])] do
        begin
          Seconds := LMeasurement.Seconds;
          UserMilliseconds := LMeasurement.UserMilliseconds;
          KernelMilliseconds := LMeasurement.KernelMilliseconds;
          Stalls := LStalls;
          Valid := (LConsumer.Checksum = LReference) and (LConsumer.Bytes = Int64(ASizeGiB) * 1024 * MiB);
        end;
      end;
    end;

  Writeln(Format('%s FPC, %d GiB, %s, %s cache (median of %d runs)',
    [BenchPlatformName, ASizeGiB, SCENARIO_NAMES[AScenario], CACHE_NAMES[ACache], GRuns]));
  Writeln(Format('  %-48s %8s %9s %9s %9s %7s', ['Contender', 'Seconds', 'MiB/s', 'User ms', 'Kernel ms', 'Stalls']));

  for LContender := Low(TContender) to High(TContender) do
  begin
    if Length(LResults[LContender]) = 0 then
      Continue;

    SetLength(LSeconds, Length(LResults[LContender]));
    SetLength(LUser, Length(LResults[LContender]));
    SetLength(LKernel, Length(LResults[LContender]));
    SetLength(LStallValues, Length(LResults[LContender]));
    LAllValid := True;

    for LRun := 0 to High(LResults[LContender]) do
    begin
      LSeconds[LRun] := LResults[LContender][LRun].Seconds;
      LUser[LRun] := LResults[LContender][LRun].UserMilliseconds;
      LKernel[LRun] := LResults[LContender][LRun].KernelMilliseconds;
      LStallValues[LRun] := LResults[LContender][LRun].Stalls;
      LAllValid := LAllValid and LResults[LContender][LRun].Valid;
    end;

    LMedian := Median(LSeconds);
    Write(Format('  %-48s %8.3f %9.0f %9.0f %9.0f %7.0f',
      [CONTENDER_NAMES[LContender], LMedian, ASizeGiB * 1024.0 / LMedian, Median(LUser), Median(LKernel),
       Median(LStallValues)], GInvariant));

    if not LAllValid then
      Write('  CHECKSUM!');

    Writeln;
  end;

  Writeln;
end;

procedure RaiseNotAvailable; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseError(Exception, RING_NAME + ' is not available on this system');
end;

var
  LSizeIndex: Integer;
  LScenario: TScenario;
  LCache: TCacheState;
begin
  GInvariant := DefaultFormatSettings;
  GInvariant.DecimalSeparator := '.';
  GInvariant.ThousandSeparator := ',';

  try
    ParseOptions;

    if not IORingAvailable then
      RaiseNotAvailable;

    Writeln(Format('Free Pascal %s, %s, %d runs, files in %s', [{$I %FPCVERSION%}, BenchPlatformName, GRuns, GFolder]));
    Writeln;

    for LSizeIndex := 0 to High(GSizes) do
      PrepareFile(GSizes[LSizeIndex]);

    try
      for LSizeIndex := 0 to High(GSizes) do
        for LScenario := Low(TScenario) to High(TScenario) do
        begin
          if (LScenario = scWork) and (LSizeIndex > 0) then
            Continue;

          for LCache := Low(TCacheState) to High(TCacheState) do
            RunCase(GSizes[LSizeIndex], LScenario, LCache);
        end;
    finally
      if not GKeep then
        for LSizeIndex := 0 to High(GSizes) do
          DeleteFile(BenchFileName(GSizes[LSizeIndex]));
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
