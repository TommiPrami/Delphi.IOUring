unit TestThreadHelpers;

{
  Helpers for the multi-thread tests (Delphi; the Free Pascal versions are in
  Tests.FPC.Support).
}

interface

uses
  System.SysUtils;

const
  RUN_THREADS_TIMEOUT_MILLISECONDS = 60000;

// Runs AWork(Index) in ACount threads (Index 0..ACount-1) that start at the
// same moment; returns when all are done. Fails the test if a thread raised
// an exception, or if the threads are not done after
// RUN_THREADS_TIMEOUT_MILLISECONDS (an endless loop: those threads cannot be
// stopped and are left running). AWork must not use Assert: count failures
// and check them after RunThreads.
procedure RunThreads(const ACount: Integer; const AWork: TProc<Integer>);

// Busy for AMicroseconds, without giving up the CPU
procedure SpinMicroseconds(const AMicroseconds: Int64);

implementation

uses
  Winapi.Windows,
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
  LReady: PInteger;    // on the heap: stuck threads may outlive this call
  LIndex: Integer;
  LDeadline: UInt64;
  LNow: UInt64;
begin
  New(LReady);
  LReady^ := 0;
  SetLength(LThreads, ACount);
  for LIndex := 0 to ACount - 1 do
    LThreads[LIndex] := TWorkerThread.Create(LIndex, ACount, LReady, AWork);
  for LIndex := 0 to ACount - 1 do
    LThreads[LIndex].Start;

  LDeadline := TThread.GetTickCount64 + RUN_THREADS_TIMEOUT_MILLISECONDS;
  for LIndex := 0 to ACount - 1 do
  begin
    LNow := TThread.GetTickCount64;
    if (LNow >= LDeadline) or
      (WaitForSingleObject(LThreads[LIndex].Handle, Cardinal(LDeadline - LNow)) <> WAIT_OBJECT_0) then
      // Left running on purpose (and not freed: freeing waits for them)
      Assert.Fail(Format('Thread %d still runs after %d s: an endless loop?',
        [LIndex, RUN_THREADS_TIMEOUT_MILLISECONDS div 1000]));
  end;

  try
    for LIndex := 0 to ACount - 1 do
      if LThreads[LIndex].FatalException <> nil then
        Assert.Fail(Format('Thread %d: %s', [LIndex, Exception(LThreads[LIndex].FatalException).Message]));
  finally
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].Free;
    Dispose(LReady);
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
