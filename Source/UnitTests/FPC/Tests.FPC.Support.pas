unit Tests.FPC.Support;

{
  Shared pieces of the Free Pascal tests: a test case base class with a few
  helpers, threads for the multi-thread tests, and pattern files that are
  created once and deleted at the end.
}

{$I Delphi.IOUring.inc}

interface

uses
  SysUtils,
  Classes,
  fpcunit;

type
  // Writes one byte to a pipe after a delay (FPC 3.2.2 has no anonymous
  // methods for TThread.CreateAnonymousThread). Create, then Start; WaitFor
  // and Free when done.
  TDelayedPipeWriter = class(TThread)
  private
    FPipe: THandle;
    FDelayMilliseconds: Cardinal;
    FValue: Byte;
  protected
    procedure Execute; override;
  public
    constructor Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
  end;

  // A thread body: a method of the test case (FPC 3.2.2 has no anonymous
  // methods)
  TWorkMethod = procedure(AIndex: Integer) of object;

  // A name of its own: in the implementation the Windows unit's PINTEGER
  // would hide PInteger
  PReadyCount = ^Integer;

  // Runs FWork(FIndex). With AReady <> nil it first waits until all ACount
  // threads of its group have started, so that they run at the same moment.
  TWorkerThread = class(TThread)
  private
    FIndex: Integer;
    FCount: Integer;
    FReady: PReadyCount;
    FWork: TWorkMethod;
  protected
    procedure Execute; override;
  public
    constructor Create(const AIndex, ACount: Integer; const AReady: PReadyCount; const AWork: TWorkMethod);
  end;

  TIORingTestCase = class(TTestCase)
  protected
    // Runs AWork(Index) in ACount threads (Index 0..ACount-1) that start at
    // the same moment; returns when all are done. Fails if a thread raised an
    // exception. AWork must not use Assert*/Check*: count failures and check
    // them after RunThreads.
    procedure RunThreads(const ACount: Integer; const AWork: TWorkMethod);
    // Prints a line between the test results (findings worth seeing)
    procedure Log(const AText: string);
    // Fails if ABuffer does not hold the pattern bytes of the file offsets
    procedure CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
      const AContext: string = '');
    procedure CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
  end;

// A pattern file of ASize bytes; created on first use, deleted when the
// program ends
function SharedPatternFile(const ASize: Int64): string;

// Busy for AMicroseconds, without giving up the CPU
procedure SpinMicroseconds(const AMicroseconds: Int64);

implementation

uses
  Windows,
  Delphi.IOUring.Atomics,
  TestFileHelpers,
  TestPlatformHelpers;

{ TDelayedPipeWriter }

constructor TDelayedPipeWriter.Create(const APipe: THandle; const ADelayMilliseconds: Cardinal; const AValue: Byte);
begin
  FPipe := APipe;
  FDelayMilliseconds := ADelayMilliseconds;
  FValue := AValue;
  inherited Create(True);
end;

procedure TDelayedPipeWriter.Execute;
begin
  Sleep(FDelayMilliseconds);
  WriteByteToPipe(FPipe, FValue);
end;

{ TWorkerThread }

constructor TWorkerThread.Create(const AIndex, ACount: Integer; const AReady: PReadyCount; const AWork: TWorkMethod);
begin
  FIndex := AIndex;
  FCount := ACount;
  FReady := AReady;
  FWork := AWork;
  inherited Create(True);
end;

procedure TWorkerThread.Execute;
begin
  if FReady <> nil then
  begin
    TAtomic.Increment(FReady^);
    while TAtomic.LoadAcquire(FReady^) < FCount do
      TThread.Yield;
  end;
  FWork(FIndex);
end;

procedure SpinMicroseconds(const AMicroseconds: Int64);
var
  LFrequency: TLargeInteger;
  LStart: TLargeInteger;
  LNow: TLargeInteger;
begin
  LNow := 0;
  QueryPerformanceFrequency(LFrequency);
  QueryPerformanceCounter(LStart);
  repeat
    TAtomic.CpuPause;
    QueryPerformanceCounter(LNow);
  until (LNow - LStart) * 1000000 >= AMicroseconds * LFrequency;
end;

var
  GSharedSizes: array of Int64;
  GSharedFiles: array of string;

{ TIORingTestCase }

procedure TIORingTestCase.RunThreads(const ACount: Integer; const AWork: TWorkMethod);
var
  LThreads: array of TWorkerThread;
  LReady: Integer;
  LIndex: Integer;
begin
  LReady := 0;
  SetLength(LThreads, ACount);
  for LIndex := 0 to ACount - 1 do
    LThreads[LIndex] := TWorkerThread.Create(LIndex, ACount, @LReady, AWork);
  try
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].Start;
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].WaitFor;
    for LIndex := 0 to ACount - 1 do
      if LThreads[LIndex].FatalException <> nil then
        Fail(Format('Thread %d: %s', [LIndex, Exception(LThreads[LIndex].FatalException).Message]));
  finally
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].Free;
  end;
end;

procedure TIORingTestCase.Log(const AText: string);
begin
  Writeln('    ', AText);
end;

procedure TIORingTestCase.CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
  const AContext: string);
var
  LBadOffset: UInt64;
begin
  if not TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset) then
    Fail(Format('%s: wrong data at file offset %d', [AContext, LBadOffset]));
end;

procedure TIORingTestCase.CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
begin
  if AExpected <> AActual then
    Fail(Format('%s: expected %d but was %d', [AMessage, AExpected, AActual]));
end;

function SharedPatternFile(const ASize: Int64): string;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(GSharedSizes) do
    if GSharedSizes[LIndex] = ASize then
      Exit(GSharedFiles[LIndex]);

  Result := TTestFileHelpers.CreatePatternFile(ASize, 'FpcPattern');
  SetLength(GSharedSizes, Length(GSharedSizes) + 1);
  SetLength(GSharedFiles, Length(GSharedFiles) + 1);
  GSharedSizes[High(GSharedSizes)] := ASize;
  GSharedFiles[High(GSharedFiles)] := Result;
end;

procedure DeleteSharedFiles;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(GSharedFiles) do
    TTestFileHelpers.DeleteTestFile(GSharedFiles[LIndex]);
  GSharedFiles := nil;
  GSharedSizes := nil;
end;

finalization
  DeleteSharedFiles;

end.
