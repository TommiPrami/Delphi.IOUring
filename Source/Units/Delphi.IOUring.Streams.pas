unit Delphi.IOUring.Streams;

// TStream classes on top of the ring (Docs/Design.md §8).
//
// Small, specific classes: each one supports only what it really can do and
// raises EIORingStreamError for the rest, instead of one stream class with
// many modes.

{$I Delphi.IOUring.inc}

interface

uses
{$IFDEF FPC}
  Classes,
  SysUtils,
{$ELSE}
  System.Classes,
  System.SysUtils,
{$ENDIF}
  Delphi.IOUring,
  Delphi.IOUring.SequentialReader;

type
  // Misuse of an IoRing stream (writing to a read-only stream, seeking a
  // sequential one). An EStreamError, so code that catches EStreamError keeps
  // working.
  EIORingStreamError = class(EStreamError);

  // Read-only, forward-only file stream with read-ahead
  // (TIORingSequentialReader inside).
  //
  // Works:  Read (all overloads), Position and Size, and "seeking" to the
  //         current position: Seek(0, soCurrent), Position := Position, and
  //         CopyFrom(Stream, 0) / LoadFromStream on a stream not read yet.
  // Raises EIORingStreamError: Write (all overloads), setting Size, seeking
  //         anywhere else.
  // A file that cannot be opened raises EFOpenError, like TFileStream.
  // Size is the size when the file was opened; data appended later is not read.
  TSequentialReadOnlyFileStream = class(TStream)
  private
    FReader: TIORingSequentialReader;
    FFileName: string;
    function GetStats: TIORingReaderStats;
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
    property Stats: TIORingReaderStats read GetStats;
  end;

implementation

{ TSequentialReadOnlyFileStream }

constructor TSequentialReadOnlyFileStream.Create(const AFileName: string;
  const AOptions: TIORingSequentialReaderOptions; const ABufferSize, ABufferCount: Cardinal);
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
      raise EFOpenError.CreateFmt('Cannot open file "%s". %s',
        [ExpandFileName(AFileName), IORingErrorMessage(E.NativeCode)]);
  end;

  // The reader owns the handle from here on, also if Open fails
  FReader.Open(LHandle, True, AOptions, ABufferSize, ABufferCount);
end;

destructor TSequentialReadOnlyFileStream.Destroy;
begin
  FReader.Close;
  inherited;
end;

function TSequentialReadOnlyFileStream.GetStats: TIORingReaderStats;
begin
  Result := FReader.Stats;
end;

procedure TSequentialReadOnlyFileStream.RaiseReadOnly;
begin
  raise EIORingStreamError.CreateFmt('%s is read-only', [ClassName]);
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
var
  LTarget: Int64;
begin
  case Origin of
    soBeginning:
      LTarget := Offset;
    soCurrent:
      LTarget := FReader.Position + Offset;
  else
    LTarget := FReader.Size + Offset;   // soEnd
  end;

  // TStream.Position and CopyFrom/LoadFromStream "seek" to where the stream
  // already is; that is fine. Anything else is not possible.
  if LTarget <> FReader.Position then
    raise EIORingStreamError.CreateFmt('%s is sequential: it cannot move from position %d to %d',
      [ClassName, FReader.Position, LTarget]);

  Result := FReader.Position;
end;

end.
