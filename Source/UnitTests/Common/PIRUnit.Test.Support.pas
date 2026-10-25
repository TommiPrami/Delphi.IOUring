unit PIRUnit.Test.Support;

{
  The base of the tests, the same for Delphi (DUnitX) and Free Pascal
  (FPCUnit, on Windows and Linux): a test case class with the same check
  methods on both, threads for the multi-thread tests, and pattern files that
  are created once and deleted at the end.

  A test unit:

    type
      TFooTests = class(TIORingTestCase)
      protected
        procedure SetUp; override;       // optional
        procedure TearDown; override;    // optional
      published
        procedure Foo_DoesThis;          // every published method is a test
      end;
    ...
    initialization
      RegisterTests(TFooTests);

  The checks have the FPCUnit names: AssertEquals(Message, Expected, Actual),
  AssertTrue, AssertFalse and Fail. With Delphi they call DUnitX's Assert.
  Every test starts with a new (zeroed) object, with both frameworks.
  No anonymous methods (Free Pascal 3.2.2 has none): the body of a thread is a
  method of the test (RunThreads).
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, fpcunit;
{$ELSE}
  System.SysUtils,
  System.Classes,
  DUnitX.TestFramework;
{$ENDIF}

const
  RUN_THREADS_TIMEOUT_MILLISECONDS = 60000;

type
{$IFDEF FPC}
  TIORingTestCaseBase = TTestCase;
{$ELSE}
  { The FPCUnit side for DUnitX: DUnitX runs the published methods of a registered class as tests, and the
    [Setup]/[TearDown] methods of this base class around each of them. }
  {$M+}
  TIORingTestCaseBase = class
  public
    [Setup]
    procedure RunSetUp;
    [TearDown]
    procedure RunTearDown;
  protected
    procedure SetUp; virtual;
    procedure TearDown; virtual;
  public
    procedure AssertTrue(const AMessage: string; const ACondition: Boolean); overload;
    procedure AssertTrue(const ACondition: Boolean); overload;
    procedure AssertFalse(const AMessage: string; const ACondition: Boolean); overload;
    procedure AssertFalse(const ACondition: Boolean); overload;
    procedure AssertEquals(const AMessage: string; const AExpected, AActual: Int64); overload;
    procedure AssertEquals(const AExpected, AActual: Int64); overload;
    procedure AssertEquals(const AMessage: string; const AExpected, AActual: string); overload;
    procedure Fail(const AMessage: string);
  end;
  {$M-}
{$ENDIF}

  // A method of the test that a check runs (for example: must it raise?)
  TRunMethod = procedure of object;

  // A thread body: a method of the test case
  TWorkMethod = procedure(AIndex: Integer) of object;

  // A name of its own: in units that use Windows, its PINTEGER would hide PInteger
  PReadyCount = ^Integer;

  { Runs FWork(FIndex). With AReady <> nil it first waits until all ACount threads of its group have started, so that
    they run at the same moment. }
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

  TIORingTestCase = class(TIORingTestCaseBase)
  protected
    {
      Runs AWork(Index) in ACount threads (Index 0..ACount-1) that start at the same moment; returns when all are done.
      Fails if a thread raised an exception, or if the threads are not done after RUN_THREADS_TIMEOUT_MILLISECONDS (an
      endless loop: those threads cannot be stopped and are left running). AWork must not use Assert*/Fail: count
      failures and check them after RunThreads.
    }
    procedure RunThreads(const ACount: Integer; const AWork: TWorkMethod);
    // Prints a line between the test results (findings worth seeing)
    procedure Log(const AText: string);
    // Fails if ABuffer does not hold the pattern bytes of the file offsets
    procedure CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
      const AContext: string = '');
    procedure CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
  end;

  TIORingTestCaseClass = class of TIORingTestCase;

  { Registers the published methods of AClass as tests (FPCUnit's RegisterTest, DUnitX's RegisterTestFixture). Call it in
    the initialization section. }
  procedure RegisterTests(const AClass: TIORingTestCaseClass);

  // A pattern file of ASize bytes; created on first use, deleted when the program ends
  function SharedPatternFile(const ASize: Int64): string;

  // Busy for AMicroseconds, without giving up the CPU
  procedure SpinMicroseconds(const AMicroseconds: Int64);

implementation

uses
{$IFDEF FPC}
  testregistry,
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IFDEF LINUX}
  unixtype, Linux,
  {$ENDIF}
{$ELSE}
  Winapi.Windows,
{$ENDIF}
  PIRUnit.Test.FileHelpers;

{$IFNDEF FPC}

{ TIORingTestCaseBase }

procedure TIORingTestCaseBase.RunSetUp;
begin
  { FPCUnit makes a new object for every test, DUnitX runs all tests of a class on one object. Start every test with
    zeroed fields, as in FPCUnit. }
  CleanupInstance;
  ClassType.InitInstance(Self);
  SetUp;
end;

procedure TIORingTestCaseBase.RunTearDown;
begin
  TearDown;
end;

procedure TIORingTestCaseBase.SetUp;
begin
end;

procedure TIORingTestCaseBase.TearDown;
begin
end;

// The messages are those of FPCUnit
function ComparisonMessage(const AMessage, AExpected, AActual: string): string;
begin
  Result := 'expected: <' + AExpected + '> but was: <' + AActual + '>';

  if AMessage <> '' then
    Result := '"' + AMessage + '" ' + Result;
end;

procedure TIORingTestCaseBase.AssertTrue(const AMessage: string; const ACondition: Boolean);
begin
  if ACondition then
    Assert.IsTrue(True)  // counts the check: the runner fails tests without one
  else
    Assert.Fail(AMessage, ReturnAddress);
end;

procedure TIORingTestCaseBase.AssertTrue(const ACondition: Boolean);
begin
  AssertTrue('', ACondition);
end;

procedure TIORingTestCaseBase.AssertFalse(const AMessage: string; const ACondition: Boolean);
begin
  AssertTrue(AMessage, not ACondition);
end;

procedure TIORingTestCaseBase.AssertFalse(const ACondition: Boolean);
begin
  AssertTrue('', not ACondition);
end;

procedure TIORingTestCaseBase.AssertEquals(const AMessage: string; const AExpected, AActual: Int64);
begin
  if AExpected = AActual then
    Assert.IsTrue(True)
  else
    Assert.Fail(ComparisonMessage(AMessage, IntToStr(AExpected), IntToStr(AActual)), ReturnAddress);
end;

procedure TIORingTestCaseBase.AssertEquals(const AExpected, AActual: Int64);
begin
  AssertEquals('', AExpected, AActual);
end;

procedure TIORingTestCaseBase.AssertEquals(const AMessage: string; const AExpected, AActual: string);
begin
  if AExpected = AActual then
    Assert.IsTrue(True)
  else
    Assert.Fail(ComparisonMessage(AMessage, AExpected, AActual), ReturnAddress);
end;

procedure TIORingTestCaseBase.Fail(const AMessage: string);
begin
  Assert.Fail(AMessage, ReturnAddress);
end;

{$ENDIF}

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
    { The RTL's interlocked calls (PIRUnit.Atomics is not for Linux yet); a compare-exchange that changes
      nothing is a full-barrier read }
{$IFDEF FPC}
    InterLockedIncrement(FReady^);

    while InterlockedCompareExchange(FReady^, 0, 0) < FCount do
      TThread.Yield;
{$ELSE}
    AtomicIncrement(FReady^);

    while AtomicCmpExchange(FReady^, 0, 0) < FCount do
      TThread.Yield;
{$ENDIF}
  end;

  FWork(FIndex);
end;

{$IFDEF MSWINDOWS}
procedure SpinMicroseconds(const AMicroseconds: Int64);
var
  LFrequency: Int64;
  LStart: Int64;
  LNow: Int64;
begin
  LNow := 0;
  QueryPerformanceFrequency(LFrequency);
  QueryPerformanceCounter(LStart);

  repeat
    QueryPerformanceCounter(LNow);
  until (LNow - LStart) * 1000000 >= AMicroseconds * LFrequency;
end;
{$ENDIF}

{$IFDEF LINUX}
function MonotonicMicroseconds: Int64;
var
  LTime: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @LTime);

  Result := Int64(LTime.tv_sec) * 1000000 + LTime.tv_nsec div 1000;
end;

procedure SpinMicroseconds(const AMicroseconds: Int64);
var
  LStart: Int64;
begin
  LStart := MonotonicMicroseconds;

  repeat
  until MonotonicMicroseconds - LStart >= AMicroseconds;
end;
{$ENDIF}

var
  GSharedSizes: array of Int64;
  GSharedFiles: array of string;

{ TIORingTestCase }

// True when AThread has ended within AMilliseconds
function WaitForThread(const AThread: TThread; const AMilliseconds: Cardinal): Boolean;
{$IFNDEF MSWINDOWS}
var
  LDeadline: UInt64;
{$ENDIF}
begin
{$IFDEF MSWINDOWS}
  Result := WaitForSingleObject(AThread.Handle, AMilliseconds) = WAIT_OBJECT_0;
{$ELSE}
  LDeadline := TThread.GetTickCount64 + AMilliseconds;

  while not AThread.Finished and (TThread.GetTickCount64 < LDeadline) do
    Sleep(1);

  Result := AThread.Finished;
{$ENDIF}
end;

procedure TIORingTestCase.RunThreads(const ACount: Integer; const AWork: TWorkMethod);
var
  LThreads: array of TWorkerThread;
  LReady: PReadyCount;    // on the heap: stuck threads may outlive this call
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

    if (LNow >= LDeadline) or not WaitForThread(LThreads[LIndex], Cardinal(LDeadline - LNow)) then
      // Left running on purpose (and not freed: freeing waits for them)
      Fail(Format('Thread %d still runs after %d s: an endless loop?',
        [LIndex, RUN_THREADS_TIMEOUT_MILLISECONDS div 1000]));
  end;

  try
    for LIndex := 0 to ACount - 1 do
      if LThreads[LIndex].FatalException <> nil then
        Fail(Format('Thread %d: %s', [LIndex, Exception(LThreads[LIndex].FatalException).Message]));
  finally
    for LIndex := 0 to ACount - 1 do
      LThreads[LIndex].Free;

    Dispose(LReady);
  end;
end;

procedure TIORingTestCase.Log(const AText: string);
begin
{$IFDEF FPC}
  Writeln('    ', AText);
{$ELSE}
  TDUnitX.CurrentRunner.Log(TLogLevel.Information, AText);
{$ENDIF}
end;

procedure TIORingTestCase.CheckPattern(const AFileOffset: UInt64; const ABuffer: Pointer; const ACount: NativeInt;
  const AContext: string);
var
  LBadOffset: UInt64;
begin
  if TTestFileHelpers.CheckPattern(AFileOffset, ABuffer^, ACount, LBadOffset) then
    AssertTrue(True)
  else
    Fail(Format('%s: wrong data at file offset %d', [AContext, LBadOffset]));
end;

procedure TIORingTestCase.CheckEqualsU64(const AMessage: string; const AExpected, AActual: UInt64);
begin
  if AExpected = AActual then
    AssertTrue(True)
  else
    Fail(Format('%s: expected %d but was %d', [AMessage, AExpected, AActual]));
end;

procedure RegisterTests(const AClass: TIORingTestCaseClass);
begin
{$IFDEF FPC}
  RegisterTest(AClass);
{$ELSE}
  TDUnitX.RegisterTestFixture(AClass);
{$ENDIF}
end;

function SharedPatternFile(const ASize: Int64): string;
var
  LIndex: Integer;
begin
  for LIndex := 0 to High(GSharedSizes) do
    if GSharedSizes[LIndex] = ASize then
      Exit(GSharedFiles[LIndex]);

  Result := TTestFileHelpers.CreatePatternFile(ASize, 'SharedPattern');
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

initialization

finalization
  DeleteSharedFiles;

end.