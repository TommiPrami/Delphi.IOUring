program SocketEcho;

{
  Linux only (Free Pascal): an echo server on TCP loopback whose socket I/O
  goes through the ring. Accept, receive and send are io_uring operations,
  put into the ring with TIORing.PrepareSqe and the names of
  PIRUnit.Linux.API (Docs/Design.md 5.8). A client thread
  connects with plain socket calls, sends a few messages and checks that each
  one comes back.

    SocketEcho

  Windows IoRing has no socket operations: there IORingCapabilities.Extras
  does not contain ieSockets.
}

{$IFNDEF LINUX}
  {$MESSAGE FATAL 'SocketEcho is for Linux (Free Pascal).'}
{$ENDIF}

{$MODE DELPHI}

uses
  cthreads,          // threads (the client thread)
  SysUtils, Classes, BaseUnix, Sockets, PIRUnit.IORing, PIRUnit.Types, PIRUnit.Linux.API;

const
  MESSAGES: array[0..2] of string = ('hello', 'io_uring', 'goodbye');
  { sys/socket.h: no SIGPIPE (which would end the program) when the other side has closed the
    connection; send fails instead }
  MSG_NOSIGNAL_FLAG = $4000;

type
  // Connects, sends each message, and reads it back
  TClientThread = class(TThread)
  private
    FAddress: TInetSockAddr;
  protected
    procedure Execute; override;
  public
    Error: string;
    constructor Create(const AAddress: TInetSockAddr);
  end;

constructor TClientThread.Create(const AAddress: TInetSockAddr);
begin
  FAddress := AAddress;

  inherited Create(False);
end;

procedure TClientThread.Execute;
var
  LSocket: cint;
  LIndex: Integer;
  LText: AnsiString;
  LAnswer: AnsiString;
  LReceived: Integer;
  LCount: ssize_t;
begin
  LSocket := fpsocket(AF_INET, SOCK_STREAM, 0);
  try
    if fpconnect(LSocket, psockaddr(@FAddress), SizeOf(FAddress)) <> 0 then
    begin
      Error := 'connect failed: errno ' + IntToStr(socketerror);

      Exit;
    end;

    for LIndex := Low(MESSAGES) to High(MESSAGES) do
    begin
      LText := AnsiString(MESSAGES[LIndex]);

      if fpsend(LSocket, PAnsiChar(LText), Length(LText), MSG_NOSIGNAL_FLAG) <> Length(LText) then
      begin
        Error := 'send failed: errno ' + IntToStr(socketerror);

        Exit;
      end;

      SetLength(LAnswer, Length(LText));
      LReceived := 0;

      while LReceived < Length(LText) do
      begin
        LCount := fprecv(LSocket, @LAnswer[LReceived + 1], Length(LText) - LReceived, 0);

        if LCount <= 0 then
          Break;

        Inc(LReceived, LCount);
      end;

      if LAnswer <> LText then
      begin
        Error := Format('sent "%s", got back "%s"', [LText, LAnswer]);

        Exit;
      end;
    end;
  finally
    CloseSocket(LSocket);              // the server then receives 0 bytes
  end;
end;

// A pointer as a __u64 of an SQE (addr)
function AddressOf(const APointer: Pointer): UInt64;
begin
  Result := PByte(APointer) - PByte(nil);
end;

procedure RaiseClientFailed(const AMessage: string); {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseErrorFmt(Exception, 'Client: %s', [AMessage]);
end;

procedure RaiseBindFailed; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseErrorFmt(Exception, 'bind/listen failed: errno %d', [socketerror]);
end;

procedure RaiseNoSockets; {$IFNDEF FPC} noreturn; {$ENDIF}
begin
  RaiseError(Exception, 'This system has no socket operations in its ring');
end;

// Submits what is prepared and returns the one completion
function SubmitAndWait(var ARing: TIORing; const AOperation: string): TIORingCompletion;

  procedure RaiseNoCompletion(const AName: string); {$IFNDEF FPC} noreturn; {$ENDIF}
  begin
    RaiseErrorFmt(Exception, '%s: no completion', [AName]);
  end;

begin
  ARing.Submit(1);

  if not ARing.TryPopCompletion(Result) then
    RaiseNoCompletion(AOperation);

  Result.RaiseIfFailed(AOperation);
end;

var
  LListen: cint;
  LConnection: cint;
  LAddress: TInetSockAddr;
  LLength: TSockLen;
  LClient: TClientThread;
  LRing: TIORing;                      // a record: closed at the end of the scope
  LSqe: Pio_uring_sqe;
  LBuffer: array[0..255] of AnsiChar;
  LCompletion: TIORingCompletion;
  LText: AnsiString;
begin
  try
    if not (ieSockets in IORingCapabilities.Extras) then
      RaiseNoSockets;

    // A listening socket on 127.0.0.1, any free port (plain socket calls)
    LListen := fpsocket(AF_INET, SOCK_STREAM, 0);
    FillChar(LAddress, SizeOf(LAddress), 0);
    LAddress.sin_family := AF_INET;
    LAddress.sin_addr.s_addr := htonl($7F000001);

    if (fpbind(LListen, psockaddr(@LAddress), SizeOf(LAddress)) <> 0) or (fplisten(LListen, 1) <> 0) then
      RaiseBindFailed;

    LLength := SizeOf(LAddress);
    fpgetsockname(LListen, psockaddr(@LAddress), @LLength);
    Writeln(Format('Listening on 127.0.0.1:%d', [ntohs(LAddress.sin_port)]));

    LConnection := -1;
    LClient := TClientThread.Create(LAddress);
    try
      LRing.Open(8);

      // Accept through the ring: the result is the new connection's descriptor
      LRing.PrepareSqe(1, LSqe);
      LSqe^.opcode := IORING_OP_ACCEPT;
      LSqe^.fd := LListen;
      LConnection := cint(SubmitAndWait(LRing, 'accept').BytesTransferred);
      Writeln(Format('Accepted a connection (descriptor %d)', [LConnection]));

      // Receive and send back through the ring, until the client closes
      repeat
        LRing.PrepareSqe(2, LSqe);
        LSqe^.opcode := IORING_OP_RECV;
        LSqe^.fd := LConnection;
        LSqe^.addr := AddressOf(@LBuffer);
        LSqe^.len := SizeOf(LBuffer);
        LCompletion := SubmitAndWait(LRing, 'receive');

        if LCompletion.BytesTransferred = 0 then
          Break;                       // the client has closed the connection

        SetString(LText, PAnsiChar(@LBuffer[0]), LCompletion.BytesTransferred);

        LRing.PrepareSqe(3, LSqe);
        LSqe^.opcode := IORING_OP_SEND;
        LSqe^.fd := LConnection;
        LSqe^.addr := AddressOf(@LBuffer);
        LSqe^.len := LCompletion.BytesTransferred;
        SubmitAndWait(LRing, 'send');
        Writeln(Format('Echoed %d bytes: %s', [Length(LText), LText]));
      until False;

      LRing.Close;
      LClient.WaitFor;

      if LClient.Error <> '' then
        RaiseClientFailed(LClient.Error);

      Writeln('The client got every message back.');
    finally
      { Closing the sockets first ends a client that still waits for an answer (after an error),
        so freeing it does not hang }
      if LConnection >= 0 then
        FpClose(LConnection);

      FpClose(LListen);
      LClient.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
end.
