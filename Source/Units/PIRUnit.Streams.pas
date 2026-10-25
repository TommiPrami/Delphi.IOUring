unit PIRUnit.Streams;

{
  TStream classes on top of the ring and the engine (Docs/Design.md §8).

  Small, specific classes: each one supports only what it really can do and raises EIORingStreamError for the rest,
  instead of one stream class with many modes.
}

{$I PIRInclude.Compiler.inc}

interface

uses
{$IFDEF FPC}
  Classes, SysUtils,
{$ELSE}
  System.Classes, System.SysUtils,
{$ENDIF}
  PIRUnit.IORing, PIRUnit.Engine, PIRUnit.SequentialReader, PIRUnit.SequentialWriter;

type
  { Misuse of an IoRing stream (writing to a read-only stream, seeking a sequential one). An EStreamError, so code that
    catches EStreamError keeps working. }
  EIORingStreamError = class(EStreamError);

  {
    Read-only, forward-only file stream with read-ahead (TIORingSequentialReader inside).

    Works:  Read (all overloads), Position and Size, and "seeking" to the
            current position: Seek(0, soCurrent), Position := Position, and
            CopyFrom(Stream, 0) / LoadFromStream on a stream not read yet.
    Raises EIORingStreamError: Write (all overloads), setting Size, seeking
            anywhere else.
    A file that cannot be opened raises EFOpenError, like TFileStream.
    Size is the size when the file was opened; data appended later is not read.
  }
  TSequentialReadOnlyFileStream = class(TStream)
  private
    FReader: TIORingSequentialReader;
    FFileName: string;
    function GetStats: TIORingSequentialReaderStats;
    procedure RaiseReadOnly;
  protected
    function GetSize: Int64; override;
{$IFNDEF FPC}
    {$WARN SYMBOL_DEPRECATED OFF}
{$ENDIF}
    procedure SetSize(NewSize: Longint); overload; override;
{$IFNDEF FPC}
    {$WARN SYMBOL_DEPRECATED ON}
{$ENDIF}
    procedure SetSize(const NewSize: Int64); overload; override;
  public
    constructor Create(const AFileName: string; const AOptions: TIORingSequentialReaderOptions = [];
      const ABufferSize: Cardinal = IORING_READER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_READER_DEFAULT_BUFFER_COUNT);
    destructor Destroy; override;

    function Read(var Buffer; Count: Longint): Longint; overload; override;
    function Write(const Buffer; Count: Longint): Longint; overload; override;
{$IFNDEF FPC}
  {$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Read(var Buffer; Count: NativeInt): NativeInt; overload; override;
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
  {$IFEND}
{$ENDIF}
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; overload; override;

    property FileName: string read FFileName;
    property Stats: TIORingSequentialReaderStats read GetStats;
  end;

  {
    Write-only, forward-only file stream that writes in the background (TIORingSequentialWriter inside): Write copies
    into a buffer, and full buffers are written by an engine's I/O thread while the program goes on.

    Creates the file, or empties it if it exists (like TFileStream with
    fmCreate); other programs may read it meanwhile, not write.
    Works:  Write (all overloads), Position and Size (= the bytes written),
            "seeking" to the current position, Flush.
    Raises EIORingStreamError: Read (all overloads), setting Size, seeking
            anywhere else.
    A file that cannot be created raises EFCreateError, like TFileStream.
    A write fails after Write has returned, so its error comes later, as
    EWriteError: at a later Write or at Flush - and at Free, if it was never
    raised before (after everything is released; the stream object itself is
    then not freed). To see errors in the normal flow, call Flush before Free.
    Free waits for all writes but does not flush to the disk (as TFileStream);
    Flush(True) does.
  }
  TSequentialWriteOnlyFileStream = class(TStream)
  private
    FWriter: TIORingSequentialWriter;
    FFileName: string;
    function GetStats: TIORingSequentialWriterStats;
    procedure RaiseWriteOnly;
    procedure OpenWriter(const AFileName: string; const AOptions: TIORingSequentialWriterOptions;
      const ABufferSize, ABufferCount: Cardinal; const AEngine: TIORingEngine);
  protected
    function GetSize: Int64; override;
{$IFNDEF FPC}
    {$WARN SYMBOL_DEPRECATED OFF}
{$ENDIF}
    procedure SetSize(NewSize: Longint); overload; override;
{$IFNDEF FPC}
    {$WARN SYMBOL_DEPRECATED ON}
{$ENDIF}
    procedure SetSize(const NewSize: Int64); overload; override;
  public
    // With an engine of its own (one I/O thread)
    constructor Create(const AFileName: string; const AOptions: TIORingSequentialWriterOptions = [];
      const ABufferSize: Cardinal = IORING_WRITER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_WRITER_DEFAULT_BUFFER_COUNT); overload;
    // With a shared engine: it must allow at least ABufferCount requests and live longer than the stream
    constructor Create(const AFileName: string; const AEngine: TIORingEngine;
      const AOptions: TIORingSequentialWriterOptions = [];
      const ABufferSize: Cardinal = IORING_WRITER_DEFAULT_BUFFER_SIZE;
      const ABufferCount: Cardinal = IORING_WRITER_DEFAULT_BUFFER_COUNT); overload;
    destructor Destroy; override;

    function Read(var Buffer; Count: Longint): Longint; overload; override;
    function Write(const Buffer; Count: Longint): Longint; overload; override;
{$IFNDEF FPC}
  {$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
    function Read(var Buffer; Count: NativeInt): NativeInt; overload; override;
    function Write(const Buffer; Count: NativeInt): NativeInt; overload; override;
  {$IFEND}
{$ENDIF}
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; overload; override;

    { Writes everything written so far into the file and waits for it. AToDisk: also flushes
      the file to the disk (slow). }
    procedure Flush(const AToDisk: Boolean = False);

    property FileName: string read FFileName;
    property Stats: TIORingSequentialWriterStats read GetStats;
  end;

implementation

uses
  PIRUnit.Types;

{ TSequentialReadOnlyFileStream }

constructor TSequentialReadOnlyFileStream.Create(const AFileName: string;
  const AOptions: TIORingSequentialReaderOptions; const ABufferSize, ABufferCount: Cardinal);

  procedure RaiseCannotOpen(const AName: string; const ACode: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EFOpenError, 'Cannot open file "%s". %s', [ExpandFileName(AName), IORingErrorMessage(ACode)]);
  end;

var
  LHandle: THandle;
begin
  inherited Create;

  FFileName := AFileName;

  try
    LHandle := TIORingPlatform.OpenFileForRead(AFileName, sroUnbuffered in AOptions,
      not (sroNoSequentialScanHint in AOptions));
  except
    on E: EIORingError do
      RaiseCannotOpen(AFileName, E.NativeCode);
  end;

  // The reader owns the handle from here on, also if Open fails
  FReader.Open(LHandle, True, AOptions, ABufferSize, ABufferCount);
end;

destructor TSequentialReadOnlyFileStream.Destroy;
begin
  FReader.Close;

  inherited Destroy;
end;

function TSequentialReadOnlyFileStream.GetStats: TIORingSequentialReaderStats;
begin
  Result := FReader.Stats;
end;

procedure TSequentialReadOnlyFileStream.RaiseReadOnly;
begin
  RaiseErrorFmt(EIORingStreamError, '%s is read-only', [ClassName]);
end;

function TSequentialReadOnlyFileStream.GetSize: Int64;
begin
  Result := FReader.Size;
end;

{$IFNDEF FPC}
  {$WARN SYMBOL_DEPRECATED OFF}
{$ENDIF}
procedure TSequentialReadOnlyFileStream.SetSize(NewSize: Longint);
begin
  RaiseReadOnly;
end;
{$IFNDEF FPC}
  {$WARN SYMBOL_DEPRECATED ON}
{$ENDIF}

procedure TSequentialReadOnlyFileStream.SetSize(const NewSize: Int64);
begin
  RaiseReadOnly;
end;

function TSequentialReadOnlyFileStream.Read(var Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);

  Result := Longint(FReader.Read(Buffer, Count));
end;

function TSequentialReadOnlyFileStream.Write(const Buffer; Count: Longint): Longint;
begin
  RaiseReadOnly;

  Result := 0;
end;

{$IFNDEF FPC}
  {$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TSequentialReadOnlyFileStream.Read(var Buffer; Count: NativeInt): NativeInt;
begin
  if Count <= 0 then
    Exit(0);

  Result := FReader.Read(Buffer, Count);
end;

function TSequentialReadOnlyFileStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  RaiseReadOnly;

  Result := 0;
end;
  {$IFEND}
{$ENDIF}

function TSequentialReadOnlyFileStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;

  procedure RaiseCannotSeek(const AClass: TClass; const APosition: Int64; const ATarget: Int64);
      {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EIORingStreamError, '%s is sequential: it cannot move from position %d to %d',
      [AClass.ClassName, APosition, ATarget]);
  end;

var
  LTarget: Int64;

begin
  case Origin of
    soBeginning: LTarget := Offset;
    soCurrent: LTarget := FReader.Position + Offset;
    else
      LTarget := FReader.Size + Offset;   // soEnd
  end;

  { TStream.Position and CopyFrom/LoadFromStream "seek" to where the stream already is; that is fine.
    Anything else is not possible. }
  if LTarget <> FReader.Position then
    RaiseCannotSeek(ClassType, FReader.Position, LTarget);

  Result := FReader.Position;
end;

{ TSequentialWriteOnlyFileStream }

constructor TSequentialWriteOnlyFileStream.Create(const AFileName: string;
  const AOptions: TIORingSequentialWriterOptions; const ABufferSize, ABufferCount: Cardinal);
begin
  inherited Create;

  OpenWriter(AFileName, AOptions, ABufferSize, ABufferCount, nil);
end;

constructor TSequentialWriteOnlyFileStream.Create(const AFileName: string; const AEngine: TIORingEngine;
  const AOptions: TIORingSequentialWriterOptions; const ABufferSize, ABufferCount: Cardinal);

  procedure RaiseNoEngine; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseIORingError('TSequentialWriteOnlyFileStream: no engine');
  end;

begin
  inherited Create;

  if AEngine = nil then
    RaiseNoEngine;

  OpenWriter(AFileName, AOptions, ABufferSize, ABufferCount, AEngine);
end;

procedure TSequentialWriteOnlyFileStream.OpenWriter(const AFileName: string;
  const AOptions: TIORingSequentialWriterOptions; const ABufferSize, ABufferCount: Cardinal;
  const AEngine: TIORingEngine);

  procedure RaiseCannotCreate(const AName: string; const ACode: Integer); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EFCreateError, 'Cannot create file "%s". %s', [ExpandFileName(AName), IORingErrorMessage(ACode)]);
  end;

var
  LHandle: THandle;
begin
  FFileName := AFileName;

  try
    LHandle := TIORingPlatform.CreateFileForWrite(AFileName, swoUnbuffered in AOptions);
  except
    on E: EIORingError do
      RaiseCannotCreate(AFileName, E.NativeCode);
  end;

  // The writer owns the handle from here on, also if Open fails
  FWriter.Open(LHandle, True, AOptions, ABufferSize, ABufferCount, AEngine);
end;

procedure RaiseWriteError(const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseError(EWriteError, AMessage);
end;

destructor TSequentialWriteOnlyFileStream.Destroy;
begin
  // Waits for the writes and releases everything; then raises a failure that was never raised before
  try
    FWriter.Close(not FWriter.ErrorReported);
  except
    on E: EIORingError do
      RaiseWriteError(E.Message);
  end;

  inherited Destroy;
end;

function TSequentialWriteOnlyFileStream.GetStats: TIORingSequentialWriterStats;
begin
  Result := FWriter.Stats;
end;

procedure TSequentialWriteOnlyFileStream.RaiseWriteOnly;
begin
  RaiseErrorFmt(EIORingStreamError, '%s is write-only', [ClassName]);
end;

function TSequentialWriteOnlyFileStream.GetSize: Int64;
begin
  Result := FWriter.Position;
end;

{$IFNDEF FPC}
  {$WARN SYMBOL_DEPRECATED OFF}
{$ENDIF}
procedure TSequentialWriteOnlyFileStream.SetSize(NewSize: Longint);
begin
  SetSize(Int64(NewSize));
end;
{$IFNDEF FPC}
  {$WARN SYMBOL_DEPRECATED ON}
{$ENDIF}

procedure TSequentialWriteOnlyFileStream.SetSize(const NewSize: Int64);

  procedure RaiseCannotSetSize(const AClass: TClass); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EIORingStreamError, '%s grows only by writing: its size cannot be set', [AClass.ClassName]);
  end;

begin
  RaiseCannotSetSize(ClassType);
end;

function TSequentialWriteOnlyFileStream.Read(var Buffer; Count: Longint): Longint;
begin
  RaiseWriteOnly;

  Result := 0;
end;

function TSequentialWriteOnlyFileStream.Write(const Buffer; Count: Longint): Longint;
begin
  if Count <= 0 then
    Exit(0);

  try
    FWriter.Write(Buffer, Count);
  except
    on E: EIORingError do
      RaiseWriteError(E.Message);
  end;

  Result := Count;
end;

{$IFNDEF FPC}
  {$IF SizeOf(LongInt) <> SizeOf(NativeInt)}
function TSequentialWriteOnlyFileStream.Read(var Buffer; Count: NativeInt): NativeInt;
begin
  RaiseWriteOnly;

  Result := 0;
end;

function TSequentialWriteOnlyFileStream.Write(const Buffer; Count: NativeInt): NativeInt;
begin
  if Count <= 0 then
    Exit(0);

  try
    FWriter.Write(Buffer, Count);
  except
    on E: EIORingError do
      RaiseWriteError(E.Message);
  end;

  Result := Count;
end;
  {$IFEND}
{$ENDIF}

function TSequentialWriteOnlyFileStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;

  procedure RaiseCannotSeek(const AClass: TClass; const APosition: Int64; const ATarget: Int64);
      {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(EIORingStreamError, '%s is sequential: it cannot move from position %d to %d',
      [AClass.ClassName, APosition, ATarget]);
  end;

var
  LTarget: Int64;
begin
  // The end is where the stream is: Position = Size
  case Origin of
    soBeginning: LTarget := Offset;
    else
      LTarget := FWriter.Position + Offset;    // soCurrent, soEnd
  end;

  if LTarget <> FWriter.Position then
    RaiseCannotSeek(ClassType, FWriter.Position, LTarget);

  Result := FWriter.Position;
end;

procedure TSequentialWriteOnlyFileStream.Flush(const AToDisk: Boolean);
begin
  try
    FWriter.Flush(AToDisk);
  except
    on E: EIORingError do
      RaiseWriteError(E.Message);
  end;
end;

end.
