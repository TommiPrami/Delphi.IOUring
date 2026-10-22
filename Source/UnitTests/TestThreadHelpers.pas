unit TestThreadHelpers;

{
  Helpers for the multi-thread tests (Delphi; the Free Pascal versions are in
  Tests.FPC.Support).
}

interface

uses
  System.SysUtils;

// Runs AWork(Index) in ACount threads (Index 0..ACount-1) that start at the
// same moment; returns when all are done. Fails the test if a thread raised
// an exception. AWork must not use Assert: count failures and check them
// after RunThreads.
procedure RunThreads(const ACount: Integer; const AWork: TProc<Integer>);

// Busy for AMicroseconds, without giving up the CPU
procedure SpinMicroseconds(const AMicroseconds: Int64);

implementation

uses
  System.Classes,
  System.Diagnostics,
  DUnitX.TestFramework,
  Delphi.IOUring.Atomics;

type
  // Waits until all threads of its group have started, then runs FWork
  TWorkerThread = class(TThread)
  private
    FIndex: Integer;
    FCount: Integer;
    FReady: PInteger;
    FWork: TProc<Integer>;
  protected
    procedure Execute; override;
  public
    constructor Create(const AIndex, ACount: Integer; const AReady: PInteger; const AWork: TProc<Integer>);
  end;

constructor TWorkerThread.Create(const AIndex, ACount: Integer; const AReady: PInteger; const AWork: TProc<Integer>);
begin
  FIndex := AIndex;
  FCount := ACount;
  FReady := AReady;
  FWork := AWork;
  inherited Create(True);
end;

procedure TWorkerThread.Execute;
begin
  TAtomic.Increment(FReady^);
  while TAtomic.LoadAcquire(FReady^) < FCount do
    TThread.Yield;
  FWork(FIndex);
end;

procedure RunThreads(const ACount: Integer; const AWork: TProc<Integer>);
var
  LThreads: TArray<TWorkerThread>;
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
        Assert.Fail(Format('Thread %d: %s', [LIndex, Exception(LThreads[LIndex].FatalException).Message]));
  finally
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].Free;
  end;
end;

procedure SpinMicroseconds(const AMicroseconds: Int64);
var
  LWatch: TStopwatch;
begin
  LWatch := TStopwatch.StartNew;
  while LWatch.ElapsedTicks * 1000000 < AMicroseconds * TStopwatch.Frequency do
    TAtomic.CpuPause;
end;

end.
