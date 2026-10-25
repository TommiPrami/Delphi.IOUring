unit PIRUnit.Benchmark.Writes;

{
  Benchmark of writing a file front to back (Plan, Phase 17).

  Contenders (each writes the same bytes into a new file):
    TFileStream, 64 KiB / 1 MiB writes
    TBufferedFileStream     1 MiB buffer, 64 KiB writes (Delphi only, as in the
                            read benchmark)
    Write stream            TSequentialWriteOnlyFileStream (8 x 1 MiB, its own
                            engine), 64 KiB writes; once more unbuffered
  Scenarios: writing only; and "work": the program spends 200 µs of CPU time
  on every MiB before it writes it (it computes the data), to see whether the
  writing happens in the background meanwhile.
  Reported: the time until the stream is freed ("written": the data may still
  be in the file cache, which the system writes to the disk later), and until
  it is on the disk ("+ flush": FlushFileBuffers / fsync through a handle of
  its own afterwards); MiB/s of both; CPU time of all threads. Median of the
  runs.
  The file is deleted after every run.

  Shared by Delphi (Pascal.IOUring.Benchmarks.Writes.dpr) and Free Pascal
  (FPC\Pascal.IOUring.Benchmarks.Writes.FPC.lpr).

  Options:
    --dir <folder>     where the test file is written (default <temp>/Pascal.IOUring.Bench)
    --sizes <list>     file sizes in GiB, comma separated (default 1,10)
    --runs <n>         runs per contender and case; the median is reported (default 3)
    --work-us <n>      CPU work per MiB in the work scenario (default 200)
    --csv <file>       append every single run to this CSV file
}

{$I PIRInclude.Compiler.inc}

interface

  procedure RunWriteBenchmarks;

implementation

uses
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Types, PIRUnit.SequentialWriter, PIRUnit.Streams,
  PIRUnit.Benchmark.Common;

{$IFDEF FPC}
const
  COMPILER_NAME = 'FPC';
{$ELSE}
const
  COMPILER_NAME = 'Delphi';
{$ENDIF}

type
  TScenario = (scWriteOnly, scWork);
  TContender = (cnFileStream64K, cnFileStream1M, cnBufferedFileStream, cnWriteStream, cnWriteStreamUnbuffered);

const
  SCENARIO_NAMES: array[TScenario] of string = ('writing only', 'with work');
  CONTENDER_NAMES: array[TContender] of string = (
    'TFileStream, 64 KiB writes',
    'TFileStream, 1 MiB writes',
    'TBufferedFileStream, 1 MiB buffer, 64 KiB writes',
    'Write stream, 64 KiB writes',
    'Write stream, unbuffered, 64 KiB writes');
  PIECE_SIZE: array[TContender] of Integer = (64 * 1024, MiB, 64 * 1024, 64 * 1024, 64 * 1024);

type
  TRunResult = record
    WrittenSeconds: Double;
    FlushedSeconds: Double;
    CpuMilliseconds: Double;
  end;

var
  GInvariant: TFormatSettings;
  GFolder: string;
  GSizes: array of Integer;
  GRuns: Integer = 3;
  GWorkMicroseconds: Cardinal = 200;
  GCsvFile: string;
  GData: PByte;    // one MiB of data, written again and again

// Does this contender run with this compiler?
function Runs(const AContender: TContender): Boolean;
begin
{$IFDEF FPC}
  Result := AContender <> cnBufferedFileStream;
{$ELSE}
  Result := True;
{$ENDIF}
end;

function CreateStream(const AContender: TContender; const AFileName: string): TStream;
begin
  case AContender of
    cnFileStream64K, cnFileStream1M: Result := TFileStream.Create(AFileName, fmCreate);
{$IFNDEF FPC}
    cnBufferedFileStream: Result := TBufferedFileStream.Create(AFileName, fmCreate, MiB);
{$ENDIF}
    cnWriteStream: Result := TSequentialWriteOnlyFileStream.Create(AFileName);
    else
      Result := TSequentialWriteOnlyFileStream.Create(AFileName, [swoUnbuffered]);
  end;
end;

function RunContender(const AContender: TContender; const AFileName: string; const ASizeGiB: Integer;
  const AScenario: TScenario): TRunResult;
var
  LMeasurement: TBenchMeasurement;
  LStart: UInt64;
  LStream: TStream;
  LMiB: Integer;
  LOffset: Integer;
begin
  DeleteFile(AFileName);
  LMeasurement.Start;
  LStart := BenchMicroseconds;
  LStream := CreateStream(AContender, AFileName);
  try
    for LMiB := 1 to ASizeGiB * 1024 do
    begin
      if AScenario = scWork then
        SpinMicroseconds(GWorkMicroseconds);

      LOffset := 0;

      while LOffset < MiB do
      begin
        LStream.WriteBuffer((GData + LOffset)^, PIECE_SIZE[AContender]);
        Inc(LOffset, PIECE_SIZE[AContender]);
      end;
    end;
  finally
    LStream.Free;
  end;

  Result.WrittenSeconds := (BenchMicroseconds - LStart) / 1000000;
  BenchFlushFile(AFileName);
  LMeasurement.Stop;
  Result.FlushedSeconds := LMeasurement.Seconds;
  Result.CpuMilliseconds := LMeasurement.UserMilliseconds + LMeasurement.KernelMilliseconds;
  DeleteFile(AFileName);
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

procedure AppendCsv(const ASizeGiB: Integer; const AScenario: TScenario; const AContender: TContender;
  const ARun: Integer; const AResult: TRunResult);
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
      Writeln(LFile, 'timestamp,compiler,platform,size_gib,scenario,contender,run,written_s,flushed_s,cpu_ms');

    Writeln(LFile, Format('%s,%s,%s,%d,%s,"%s",%d,%.4f,%.4f,%.1f',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now, GInvariant), COMPILER_NAME, BenchPlatformName, ASizeGiB,
       SCENARIO_NAMES[AScenario], CONTENDER_NAMES[AContender], ARun, AResult.WrittenSeconds,
       AResult.FlushedSeconds, AResult.CpuMilliseconds], GInvariant));
  finally
    CloseFile(LFile);
  end;
end;

procedure ParseOptions;

  procedure RaiseUnknownOption(const AIndex: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'Unknown option: %s', [ParamStr(AIndex)]);
  end;

  procedure RaiseBadCounts; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, '--runs and --sizes must be at least 1');
  end;

var
  LIndex: Integer;
  LName: string;
  LList: TStringList;
  LItem: Integer;
begin
  GFolder := DefaultBenchFolder;
  SetLength(GSizes, 2);
  GSizes[0] := 1;
  GSizes[1] := 10;
  LIndex := 1;

  while LIndex <= ParamCount do
  begin
    LName := LowerCase(ParamStr(LIndex));

    if (LName = '--dir') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GFolder := ParamStr(LIndex);
    end
    else if (LName = '--sizes') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      LList := TStringList.Create;
      try
        LList.CommaText := ParamStr(LIndex);
        SetLength(GSizes, LList.Count);

        for LItem := 0 to LList.Count - 1 do
          GSizes[LItem] := StrToInt(LList[LItem]);
      finally
        LList.Free;
      end;
    end
    else if (LName = '--runs') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GRuns := StrToInt(ParamStr(LIndex));
    end
    else if (LName = '--work-us') and (LIndex < ParamCount) then
    begin
      Inc(LIndex);
      GWorkMicroseconds := StrToInt(ParamStr(LIndex));
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

  if (GRuns < 1) or (Length(GSizes) = 0) then
    RaiseBadCounts;
end;

procedure RunWriteBenchmarks;
var
  LFileName: string;
  LSizeIndex: Integer;
  LSizeGiB: Integer;
  LScenario: TScenario;
  LContender: TContender;
  LRun: Integer;
  LResult: TRunResult;
  LWritten: array[TContender] of array of Double;
  LFlushed: array[TContender] of array of Double;
  LCpu: array[TContender] of array of Double;
  LIndex: Integer;
  LMedianWritten: Double;
  LMedianFlushed: Double;
begin
  ParseOptions;
  ForceDirectories(GFolder);
  LFileName := IncludeTrailingPathDelimiter(GFolder) + 'writes.dat';
  Writeln(Format('Writing a file front to back: %s %s, %s', [COMPILER_NAME, BenchPlatformName,
    FormatDateTime('yyyy-mm-dd hh:nn', Now, GInvariant)], GInvariant));
  Writeln(Format('Median of %d runs; work: %d us of CPU time per MiB', [GRuns, GWorkMicroseconds], GInvariant));

  GData := TIORingPlatform.AllocPages(MiB);
  try
    for LIndex := 0 to MiB - 1 do
      GData[LIndex] := Byte(LIndex * 7 + LIndex shr 8);

    for LSizeIndex := 0 to High(GSizes) do
    begin
      LSizeGiB := GSizes[LSizeIndex];

      for LScenario := Low(TScenario) to High(TScenario) do
      begin
        Writeln;
        Writeln(Format('%d GiB, %s', [LSizeGiB, SCENARIO_NAMES[LScenario]]));
        Writeln(Format('  %-50s %10s %8s %10s %8s %9s', ['Contender', 'written s', 'MiB/s', '+ flush s', 'MiB/s',
          'CPU ms'], GInvariant));

        for LContender := Low(TContender) to High(TContender) do
        begin
          SetLength(LWritten[LContender], GRuns);
          SetLength(LFlushed[LContender], GRuns);
          SetLength(LCpu[LContender], GRuns);
        end;

        // The contenders take turns, so that a slow moment of the machine hits all of them
        for LRun := 1 to GRuns do
          for LContender := Low(TContender) to High(TContender) do
          begin
            if not Runs(LContender) then
              Continue;

            LResult := RunContender(LContender, LFileName, LSizeGiB, LScenario);
            LWritten[LContender][LRun - 1] := LResult.WrittenSeconds;
            LFlushed[LContender][LRun - 1] := LResult.FlushedSeconds;
            LCpu[LContender][LRun - 1] := LResult.CpuMilliseconds;
            AppendCsv(LSizeGiB, LScenario, LContender, LRun, LResult);
          end;

        for LContender := Low(TContender) to High(TContender) do
        begin
          if not Runs(LContender) then
            Continue;

          LMedianWritten := Median(LWritten[LContender]);
          LMedianFlushed := Median(LFlushed[LContender]);
          Writeln(Format('  %-50s %10.2f %8.0f %10.2f %8.0f %9.0f', [CONTENDER_NAMES[LContender], LMedianWritten,
            LSizeGiB * 1024 / LMedianWritten, LMedianFlushed, LSizeGiB * 1024 / LMedianFlushed,
            Median(LCpu[LContender])], GInvariant));
        end;
      end;
    end;
  finally
    TIORingPlatform.FreePages(GData, MiB);
  end;
end;

initialization
{$IFDEF FPC}
  GInvariant := DefaultFormatSettings;
{$ELSE}
  GInvariant := TFormatSettings.Create('en-US');
{$ENDIF}

end.
