unit PIRUnit.Linux.Extras.Tests;

{
  The Linux extras of TLinuxIORing (Docs/Design.md §5.8): PrepareSqe, which
  puts any io_uring operation into the ring's queue (here: socket operations
  and a read of a registered file), and LinkToNext, which links an entry to
  the next one.
}

{$I PIRInclude.Compiler.inc}

interface

uses
  PIRUnit.Test.PlatformHelpers, PIRUnit.Test.Support;

type
  TLinuxExtrasTests = class(TIORingTestCase)
  private
    FResources: TTestResources;
    // A new file with the bytes 1, 2, 3, 4
    function FourByteFile: THandle;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    // PrepareSqe
    procedure PrepareSqe_Nop_CompletesWithUserData;
    procedure PrepareSqe_FullQueue_ReturnsFalse;
    procedure PrepareSqe_ReadsARegisteredFile;
    procedure Sockets_SendAndReceive;
    procedure Sockets_AcceptConnectAndTalk;
    procedure Sockets_WaitingReceive_IsCancelled;
    // LinkToNext
    procedure Link_WriteThenFlush_InOrder;
    procedure Link_FailedRead_CancelsTheNext;
    procedure Link_ShortRead_CancelsTheNext;
    procedure HardLink_NextRunsAnyway;
    procedure LinkToNext_NothingPrepared_Raises;
  end;

implementation

uses
  SysUtils, BaseUnix, Sockets, PIRUnit.IORing, PIRUnit.Types, PIRUnit.Linux.API;

// A pointer as a __u64 of an SQE (addr)
function AddressOf(const APointer: Pointer): UInt64;
begin
  Result := PByte(APointer) - PByte(nil);
end;

// The next completion, waiting up to 5 s for it
function WaitCompletion(var ARing: TIORing): TIORingCompletion;

  procedure RaiseNoCompletion; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'No completion within 5 s');
  end;

begin
  if not ARing.TryPopCompletion(Result) then
  begin
    ARing.WaitForCompletions(1, 5000);

    if not ARing.TryPopCompletion(Result) then
      RaiseNoCompletion;
  end;
end;

// The completions of AUserData1 and AUserData2, in either order
procedure WaitTwo(var ARing: TIORing; const AUserData1: TIORingUserData; out ACompletion1, ACompletion2: TIORingCompletion);
var
  LFirst: TIORingCompletion;
begin
  LFirst := WaitCompletion(ARing);

  if LFirst.UserData = AUserData1 then
  begin
    ACompletion1 := LFirst;
    ACompletion2 := WaitCompletion(ARing);
  end
  else
  begin
    ACompletion2 := LFirst;
    ACompletion1 := WaitCompletion(ARing);
  end;
end;

procedure PrepareNop(var ARing: TIORing; const AUserData: TIORingUserData);

  procedure RaiseNoRoom; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'No room for a NOP');
  end;

var
  LSqe: Pio_uring_sqe;
begin
  if not ARing.PrepareSqe(AUserData, LSqe) then
    RaiseNoRoom;

  LSqe^.opcode := IORING_OP_NOP;
end;

{ TLinuxExtrasTests }

procedure TLinuxExtrasTests.SetUp;
begin
  FResources := TTestResources.Create;
end;

procedure TLinuxExtrasTests.TearDown;
begin
  FreeAndNil(FResources);
end;

function TLinuxExtrasTests.FourByteFile: THandle;

  procedure RaiseWriteFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseError(Exception, 'Could not write the test file');
  end;

const
  DATA: array[0..3] of Byte = (1, 2, 3, 4);
begin
  Result := FResources.CreateNewFile;

  if FpWrite(Result, DATA, SizeOf(DATA)) <> SizeOf(DATA) then
    RaiseWriteFailed;
end;

{ PrepareSqe }

procedure TLinuxExtrasTests.PrepareSqe_Nop_CompletesWithUserData;
var
  LRing: TIORing;
  LCompletion: TIORingCompletion;
begin
  LRing.Open(8);
  PrepareNop(LRing, 77);
  AssertEquals('Prepared', 1, LRing.PreparedCount);
  AssertEquals('Submitted', 1, LRing.Submit(1));
  LCompletion := WaitCompletion(LRing);
  AssertEquals('User data', 77, LCompletion.UserData);
  AssertTrue('Succeeded', LCompletion.Succeeded);
  AssertEquals('Nothing pending', 0, LRing.PendingCount);
end;

procedure TLinuxExtrasTests.PrepareSqe_FullQueue_ReturnsFalse;
var
  LRing: TIORing;
  LSqe: Pio_uring_sqe;
  LIndex: Integer;
begin
  LRing.Open(4);

  for LIndex := 1 to LRing.SubmissionQueueSize do
    PrepareNop(LRing, LIndex);

  AssertFalse('No room', LRing.PrepareSqe(99, LSqe));
  AssertTrue('No entry', LSqe = nil);
  AssertEquals('Submitted', LRing.SubmissionQueueSize, LRing.Submit(LRing.SubmissionQueueSize));

  for LIndex := 1 to LRing.SubmissionQueueSize do
    AssertTrue('Succeeded', WaitCompletion(LRing).Succeeded);
end;

procedure TLinuxExtrasTests.PrepareSqe_ReadsARegisteredFile;
var
  LRing: TIORing;
  LFile: THandle;
  LBuffer: array[0..3] of Byte;
  LSqe: Pio_uring_sqe;
  LCompletion: TIORingCompletion;
begin
  LFile := FourByteFile;
  LRing.Open(8);
  LRing.PrepareRegisterFiles([LFile], 1);
  AssertTrue('Registered', WaitCompletion(LRing).Succeeded);

  FillChar(LBuffer, SizeOf(LBuffer), 0);
  AssertTrue('Prepared', LRing.PrepareSqe(2, LSqe));
  LSqe^.opcode := IORING_OP_READ;
  LSqe^.flags := IOSQE_FIXED_FILE;
  LSqe^.fd := 0;                      // index 0 of the registered files
  LSqe^.addr := AddressOf(@LBuffer);
  LSqe^.len := SizeOf(LBuffer);
  LSqe^.off := 0;
  LRing.Submit(1);
  LCompletion := WaitCompletion(LRing);
  LCompletion.RaiseIfFailed('Read');
  AssertEquals('Bytes', 4, LCompletion.BytesTransferred);
  AssertEquals('Data', 4, LBuffer[3]);
end;

procedure TLinuxExtrasTests.Sockets_SendAndReceive;
var
  LRing: TIORing;
  LServer: THandle;
  LClient: THandle;
  LText: AnsiString;
  LIn: array[0..15] of AnsiChar;
  LSqe: Pio_uring_sqe;
  LReceive: TIORingCompletion;
  LSend: TIORingCompletion;
begin
  FResources.OpenPipePair(LServer, LClient);    // a Unix socket pair
  LRing.Open(8);
  FillChar(LIn, SizeOf(LIn), 0);
  AssertTrue(LRing.PrepareSqe(1, LSqe));
  LSqe^.opcode := IORING_OP_RECV;
  LSqe^.fd := LClient;
  LSqe^.addr := AddressOf(@LIn);
  LSqe^.len := SizeOf(LIn);
  LRing.Submit;
  AssertFalse('The receive waits', LRing.WaitForCompletions(1, 50));

  LText := 'hello';
  AssertTrue(LRing.PrepareSqe(2, LSqe));
  LSqe^.opcode := IORING_OP_SEND;
  LSqe^.fd := LServer;
  LSqe^.addr := AddressOf(PAnsiChar(LText));
  LSqe^.len := Length(LText);
  LRing.Submit;
  WaitTwo(LRing, 1, LReceive, LSend);
  LSend.RaiseIfFailed('Send');
  LReceive.RaiseIfFailed('Receive');
  AssertEquals('Sent', 5, LSend.BytesTransferred);
  AssertEquals('Received', 5, LReceive.BytesTransferred);
  AssertEquals('Text', 'hello', string(PAnsiChar(@LIn[0])));
end;

procedure TLinuxExtrasTests.Sockets_AcceptConnectAndTalk;
var
  LRing: TIORing;
  LListen: THandle;
  LClient: THandle;
  LAccepted: THandle;
  LAddress: TInetSockAddr;
  LLength: TSockLen;
  LSqe: Pio_uring_sqe;
  LAccept: TIORingCompletion;
  LConnect: TIORingCompletion;
  LOut: array[0..2] of Byte;
  LIn: array[0..2] of Byte;
  LReceive: TIORingCompletion;
  LSend: TIORingCompletion;
begin
  // A listening socket on loopback, any free port
  LListen := fpsocket(AF_INET, SOCK_STREAM, 0);
  AssertTrue('Socket', Integer(LListen) >= 0);
  FResources.AddHandle(LListen);
  FillChar(LAddress, SizeOf(LAddress), 0);
  LAddress.sin_family := AF_INET;
  LAddress.sin_addr.s_addr := htonl($7F000001);
  AssertEquals('bind', 0, fpbind(LListen, psockaddr(@LAddress), SizeOf(LAddress)));
  AssertEquals('listen', 0, fplisten(LListen, 1));
  LLength := SizeOf(LAddress);
  AssertEquals('getsockname', 0, fpgetsockname(LListen, psockaddr(@LAddress), @LLength));
  LClient := fpsocket(AF_INET, SOCK_STREAM, 0);
  FResources.AddHandle(LClient);

  LRing.Open(8);
  AssertTrue(LRing.PrepareSqe(1, LSqe));
  LSqe^.opcode := IORING_OP_ACCEPT;
  LSqe^.fd := LListen;
  AssertTrue(LRing.PrepareSqe(2, LSqe));
  LSqe^.opcode := IORING_OP_CONNECT;
  LSqe^.fd := LClient;
  LSqe^.addr := AddressOf(@LAddress);
  LSqe^.off := SizeOf(LAddress);      // the address length
  LRing.Submit(2);
  WaitTwo(LRing, 1, LAccept, LConnect);
  LAccept.RaiseIfFailed('Accept');
  LConnect.RaiseIfFailed('Connect');
  // The result of an accept is the new descriptor
  LAccepted := THandle(LAccept.BytesTransferred);
  FResources.AddHandle(LAccepted);
  AssertTrue('New descriptor', LAccepted > 2);

  LOut[0] := 7;
  LOut[1] := 8;
  LOut[2] := 9;
  FillChar(LIn, SizeOf(LIn), 0);
  AssertTrue(LRing.PrepareSqe(3, LSqe));
  LSqe^.opcode := IORING_OP_RECV;
  LSqe^.fd := LClient;
  LSqe^.addr := AddressOf(@LIn);
  LSqe^.len := SizeOf(LIn);
  AssertTrue(LRing.PrepareSqe(4, LSqe));
  LSqe^.opcode := IORING_OP_SEND;
  LSqe^.fd := LAccepted;
  LSqe^.addr := AddressOf(@LOut);
  LSqe^.len := SizeOf(LOut);
  LRing.Submit(2);
  WaitTwo(LRing, 3, LReceive, LSend);
  LSend.RaiseIfFailed('Send');
  LReceive.RaiseIfFailed('Receive');
  AssertEquals('Received', 3, LReceive.BytesTransferred);
  AssertEquals('Data', 9, LIn[2]);
end;

procedure TLinuxExtrasTests.Sockets_WaitingReceive_IsCancelled;
var
  LRing: TIORing;
  LServer: THandle;
  LClient: THandle;
  LIn: Byte;
  LSqe: Pio_uring_sqe;
  LReceive: TIORingCompletion;
  LCancel: TIORingCompletion;
begin
  FResources.OpenPipePair(LServer, LClient);
  LRing.Open(8);
  AssertTrue(LRing.PrepareSqe(1, LSqe));
  LSqe^.opcode := IORING_OP_RECV;
  LSqe^.fd := LClient;
  LSqe^.addr := AddressOf(@LIn);
  LSqe^.len := 1;
  LRing.Submit;
  AssertTrue('Cancel prepared', LRing.PrepareCancel(TIORingFileRef.FromHandle(LClient), 1, 2));
  LRing.Submit(2);
  WaitTwo(LRing, 1, LReceive, LCancel);
  AssertTrue('Receive cancelled', LReceive.IsCancelled);
  AssertTrue('Cancel succeeded', LCancel.Succeeded);
end;

{ LinkToNext }

procedure TLinuxExtrasTests.Link_WriteThenFlush_InOrder;
var
  LRing: TIORing;
  LFile: THandle;
  LData: array[0..3] of Byte;
  LFirst: TIORingCompletion;
  LSecond: TIORingCompletion;
begin
  LFile := FResources.CreateNewFile;
  LData[0] := 5;
  LRing.Open(8);
  AssertTrue(LRing.PrepareWrite(TIORingFileRef.FromHandle(LFile), TIORingBufferRef.FromPointer(@LData), 4, 0, 1));
  LRing.LinkToNext;
  AssertTrue(LRing.PrepareFlush(TIORingFileRef.FromHandle(LFile), rfmData, 2));
  AssertEquals('Submitted', 2, LRing.Submit(2));
  // The flush starts only after the write has completed
  LFirst := WaitCompletion(LRing);
  LSecond := WaitCompletion(LRing);
  AssertEquals('Write first', 1, LFirst.UserData);
  AssertEquals('Then the flush', 2, LSecond.UserData);
  LFirst.RaiseIfFailed('Write');
  LSecond.RaiseIfFailed('Flush');
  AssertEquals('Written', 4, LFirst.BytesTransferred);
end;

procedure TLinuxExtrasTests.Link_FailedRead_CancelsTheNext;
var
  LRing: TIORing;
  LBuffer: array[0..3] of Byte;
  LRead: TIORingCompletion;
  LNop: TIORingCompletion;
begin
  LRing.Open(8);
  AssertTrue(LRing.PrepareRead(TIORingFileRef.FromHandle(BAD_HANDLE), TIORingBufferRef.FromPointer(@LBuffer), 4, 0, 1));
  LRing.LinkToNext;
  PrepareNop(LRing, 2);
  LRing.Submit(2);
  WaitTwo(LRing, 1, LRead, LNop);
  AssertFalse('Read failed', LRead.Succeeded);
  AssertTrue('The next is cancelled', LNop.IsCancelled);
end;

procedure TLinuxExtrasTests.Link_ShortRead_CancelsTheNext;
var
  LRing: TIORing;
  LFile: THandle;
  LBuffer: array[0..7] of Byte;
  LRead: TIORingCompletion;
  LNop: TIORingCompletion;
begin
  LFile := FourByteFile;
  LRing.Open(8);
  // 8 bytes asked, 4 there
  AssertTrue(LRing.PrepareRead(TIORingFileRef.FromHandle(LFile), TIORingBufferRef.FromPointer(@LBuffer), 8, 0, 1));
  LRing.LinkToNext;
  PrepareNop(LRing, 2);
  LRing.Submit(2);
  WaitTwo(LRing, 1, LRead, LNop);
  LRead.RaiseIfFailed('Read');
  AssertEquals('Short read', 4, LRead.BytesTransferred);
  AssertTrue('The next is cancelled', LNop.IsCancelled);
end;

procedure TLinuxExtrasTests.HardLink_NextRunsAnyway;
var
  LRing: TIORing;
  LBuffer: array[0..3] of Byte;
  LRead: TIORingCompletion;
  LNop: TIORingCompletion;
begin
  LRing.Open(8);
  AssertTrue(LRing.PrepareRead(TIORingFileRef.FromHandle(BAD_HANDLE), TIORingBufferRef.FromPointer(@LBuffer), 4, 0, 1));
  LRing.LinkToNext(True);
  PrepareNop(LRing, 2);
  LRing.Submit(2);
  WaitTwo(LRing, 1, LRead, LNop);
  AssertFalse('Read failed', LRead.Succeeded);
  AssertTrue('The next ran', LNop.Succeeded);
end;

procedure TLinuxExtrasTests.LinkToNext_NothingPrepared_Raises;

  function Raises(var ARing: TIORing): Boolean;
  begin
    Result := False;

    try
      ARing.LinkToNext;
    except
      on EIORingError do
        Result := True;
    end;
  end;

var
  LRing: TIORing;
begin
  AssertTrue('Closed ring', Raises(LRing));
  LRing.Open(8);
  AssertTrue('Nothing prepared', Raises(LRing));
  PrepareNop(LRing, 1);
  LRing.Submit(1);
  WaitCompletion(LRing);
  AssertTrue('Everything submitted', Raises(LRing));
end;

initialization
  RegisterTests(TLinuxExtrasTests);

end.
