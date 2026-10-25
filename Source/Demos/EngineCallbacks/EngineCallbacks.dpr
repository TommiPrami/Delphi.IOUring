program EngineCallbacks;

{
  The I/O engine: one for the whole program, used from any thread. Three
  ways to use it:

    1. Start a read, do other work meanwhile, then wait for it (Wait).
    2. Start many reads, each with a callback; the callbacks run on the
       engine's I/O thread. BeginBatch / EndBatch hands the whole batch to the
       kernel with few system calls.
    3. Four threads read at the same time through the same engine.

    EngineCallbacks [<file>]

  The reads are 4 KiB blocks at many places of the file. Without a file name
  it uses a temporary file of 64 MiB and deletes it afterwards.
}

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
{$IFDEF UNIX}
  cthreads,          // Free Pascal on Linux: threads (the library uses them)
{$ENDIF}
{$IFDEF FPC}
  SysUtils, Classes,
{$ELSE}
  System.SysUtils, System.Classes,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Atomics, PIRUnit.Types, PIRUnit.Engine,
  PIRUnit.Demo.Common in '..\Common\PIRUnit.Demo.Common.pas';

const
  BLOCK_SIZE = 4096;
  BATCH_READS = 1000;
  THREAD_COUNT = 4;
  READS_PER_THREAD = 250;

type
  // Counts what the callbacks report. A callback is a method ("of object").
  TReadCounter = class
  public
    Completed: Integer;
    Failed: Integer;
    Bytes: Int64;
    procedure ReadDone(const ACompletion: TIORingCompletion);
  end;

  // One of the threads of part 3
  TReaderThread = class(TThread)
  private
    FEngine: TIORingEngine;
    FFile: THandle;
    FBlockCount: Cardinal;
    FSeed: Cardinal;
  protected
    procedure Execute; override;
  public
    Bytes: Int64;
    constructor Create(const AEngine: TIORingEngine; const AFile: THandle; const ABlockCount, ASeed: Cardinal);
  end;

// Runs on the engine's I/O thread: keep it short and never block there
procedure TReadCounter.ReadDone(const ACompletion: TIORingCompletion);
begin
  if ACompletion.Succeeded then
    TAtomic.FetchAdd(Bytes, Int64(ACompletion.BytesTransferred))
  else
    TAtomic.Increment(Failed);

  // Last: the main thread waits for this count
  TAtomic.Increment(Completed);
end;

constructor TReaderThread.Create(const AEngine: TIORingEngine; const AFile: THandle;
  const ABlockCount, ASeed: Cardinal);
begin
  FEngine := AEngine;
  FFile := AFile;
  FBlockCount := ABlockCount;
  FSeed := ASeed;

  inherited Create(False);
end;

procedure TReaderThread.Execute;
var
  LBuffer: array[0..BLOCK_SIZE - 1] of Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LIndex: Integer;
begin
  for LIndex := 1 to READS_PER_THREAD do
  begin
    // A different block each time (xorshift: Random is not for threads)
    FSeed := FSeed xor (FSeed shl 13);
    FSeed := FSeed xor (FSeed shr 17);
    FSeed := FSeed xor (FSeed shl 5);
    LHandle := FEngine.ReadAsync(FFile, LBuffer, BLOCK_SIZE, UInt64(FSeed mod FBlockCount) * BLOCK_SIZE);
    FEngine.Wait(LHandle, LCompletion);
    LCompletion.RaiseIfFailed('Read');
    Inc(Bytes, LCompletion.BytesTransferred);
  end;
end;

// 1. Start, work, wait
procedure StartWorkWait(const AEngine: TIORingEngine; const AFile: THandle);
var
  LBuffer: array[0..BLOCK_SIZE - 1] of Byte;
  LHandle: TIORingRequestHandle;
  LCompletion: TIORingCompletion;
  LWork: Integer;
  LIndex: Integer;
begin
  // The buffer and the file must stay valid until the read has completed
  LHandle := AEngine.ReadAsync(AFile, LBuffer, BLOCK_SIZE, 0);
  LWork := 0;

  for LIndex := 1 to 1000000 do        // other work while the read runs
    Inc(LWork, LIndex and 7);

  AEngine.Wait(LHandle, LCompletion);
  LCompletion.RaiseIfFailed('Read');
  Writeln(Format('1. Started a read, worked meanwhile (%d), then waited: %d bytes',
    [LWork, LCompletion.BytesTransferred]));
end;

// 2. A batch with callbacks
procedure BatchWithCallbacks(const AEngine: TIORingEngine; const AFile: THandle; const ABlockCount: Cardinal);

  procedure RaiseReadsFailed(const ACount: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, '%d reads failed', [ACount]);
  end;

var
  LCounter: TReadCounter;
  LBuffers: TBytes;
  LIndex: Integer;
  LSubmitsBefore: UInt64;
begin
  // Every read in flight needs a buffer of its own
  SetLength(LBuffers, BATCH_READS * BLOCK_SIZE);
  LCounter := TReadCounter.Create;
  try
    LSubmitsBefore := AEngine.Stats.Submits;
    AEngine.BeginBatch;

    try
      for LIndex := 0 to BATCH_READS - 1 do
        AEngine.ReadAsync(AFile, LBuffers[LIndex * BLOCK_SIZE], BLOCK_SIZE,
          UInt64((Cardinal(LIndex) * 7919) mod ABlockCount) * BLOCK_SIZE, LIndex, LCounter.ReadDone);
    finally
      AEngine.EndBatch;                // now the I/O thread takes them all
    end;

    // The callbacks count; wait until all have run
    while TAtomic.LoadAcquire(LCounter.Completed) < BATCH_READS do
      Sleep(1);

    if LCounter.Failed > 0 then
      RaiseReadsFailed(LCounter.Failed);

    Writeln(Format('2. %d reads with callbacks: %d bytes; the I/O thread submitted them in %d calls',
      [BATCH_READS, LCounter.Bytes, AEngine.Stats.Submits - LSubmitsBefore]));
  finally
    LCounter.Free;
  end;
end;

// 3. Several threads, one engine
procedure SeveralThreads(const AEngine: TIORingEngine; const AFile: THandle; const ABlockCount: Cardinal);

  procedure RaiseThreadFailed(const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, 'A reader thread failed: %s', [AMessage]);
  end;

var
  LThreads: array[0..THREAD_COUNT - 1] of TReaderThread;
  LIndex: Integer;
  LBytes: Int64;
  LError: string;
begin
  for LIndex := 0 to THREAD_COUNT - 1 do
    LThreads[LIndex] := TReaderThread.Create(AEngine, AFile, ABlockCount, 12345 + LIndex * 7);

  LBytes := 0;
  LError := '';

  for LIndex := 0 to THREAD_COUNT - 1 do
  begin
    LThreads[LIndex].WaitFor;

    if LThreads[LIndex].FatalException <> nil then
      LError := Exception(LThreads[LIndex].FatalException).Message;

    Inc(LBytes, LThreads[LIndex].Bytes);
    LThreads[LIndex].Free;
  end;

  if LError <> '' then
    RaiseThreadFailed(LError);

  Writeln(Format('3. %d threads, %d reads each, through the same engine: %d bytes',
    [THREAD_COUNT, READS_PER_THREAD, LBytes]));
end;

procedure RaiseFileTooShort; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseError(Exception, 'The file is shorter than one block');
end;

var
  LFileName: string;
  LTemporary: Boolean;
  LEngine: TIORingEngine;
  LFile: THandle;
  LBlockCount: Cardinal;
begin
  try
    LTemporary := ParamCount = 0;

    if LTemporary then
    begin
      LFileName := DemoFileName('EngineCallbacks.dat');
      CreateDemoFile(LFileName, 64 * 1024 * 1024);
    end
    else
      LFileName := ParamStr(1);

    try
      LBlockCount := DemoFileSize(LFileName) div BLOCK_SIZE;

      if LBlockCount = 0 then
        RaiseFileTooShort;

      LEngine := TIORingEngine.Create;           // starts the I/O thread
      try
        // On Windows the handle must allow overlapped I/O (it does), or Windows runs its reads one at a time
        LFile := TIORingPlatform.OpenFileForRead(LFileName, False, False);
        try
          StartWorkWait(LEngine, LFile);
          BatchWithCallbacks(LEngine, LFile, LBlockCount);
          SeveralThreads(LEngine, LFile, LBlockCount);
        finally
          TIORingPlatform.CloseFile(LFile);
        end;

        Writeln(Format('The engine: %d requests, %d system calls to submit them',
          [LEngine.Stats.Requests, LEngine.Stats.Submits]));
      finally
        LEngine.Free;                            // cancels what is left and waits for it
      end;
    finally
      if LTemporary then
        DeleteFile(LFileName);
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
