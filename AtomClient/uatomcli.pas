{ ============================================================================
  uatomcli - NLAtom client (see ../AtomServer/uatomproto): finds a server by
  its service name, sends commands as global atoms and takes the replies
    - everything is asynchronous: a command goes out at once, its reply
      comes later through the window (OnReply, with the round trip time)
    - subscriptions are kept and sent again after a reconnect
    - the server's window is checked every 100 ms; when it is gone, the
      client looks for the service again every 2 s (and a server that says
      BYE is gone at once)
  ============================================================================ }
unit uatomcli;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, uatomproto;

type
  TSubState = (ssWaiting, ssActive, ssRefused);

  TAtomSub = class
    Item: string;
    Value: string;
    Updates: Integer;
    Time: TDateTime;
    State: TSubState;
    Error: string;
  end;

  TCliState = (csIdle, csConnecting, csConnected, csLost);

  TAtomReplyEvent = procedure(const Id, Kind, Rest: string; RoundTripMs: Integer) of object;
  TAtomCliLog = procedure(const S: string) of object;

  { TAtomClient }

  TAtomClient = class
  private
    FWin: TAtomWindow;
    FServer: HWND;
    FService: string;
    FName: string;
    FState: TCliState;
    FSeq: Int64;
    FPending: TStringList;     // id -> GetTickCount64 of the send
    FSubs: TList;
    FItems: TStringList;       // from ITEMS: name=type access
    FItemsId: string;
    FLastTry: QWord;
    FAutoReconnect: Boolean;
    FLogMessages: Boolean;
    FOnLog: TAtomCliLog;
    FOnReply: TAtomReplyEvent;
    FOnChange: TNotifyEvent;
    procedure Log(const S: string);
    procedure Changed;
    procedure HandleMessage(Msg: UINT; From: HWND; const Text: string);
    procedure Lost(const Why: string);
    function FindSub(const AItem: string): TAtomSub;
  public
    MsgsOut, MsgsIn, Dropped: Int64;
    LastRoundTrip: Integer;
    constructor Create(const AName: string);
    destructor Destroy; override;
    { find the service and say HELLO; the WELCOME comes later }
    function Connect(const AService: string; out Err: string): Boolean;
    procedure Disconnect;
    { sends "<id> <Text>", returns the id ('' = not sent) }
    function Send(const Text: string): string;
    function Get(const AItem: string): string;
    function SetValue(const AItem, AValue: string): string;
    function Subscribe(const AItem: string): TAtomSub;
    procedure Unsubscribe(S: TAtomSub);
    function RequestItems: string;
    procedure Tick;
    function SubCount: Integer;
    function Sub(I: Integer): TAtomSub;
    function WindowHandle: HWND;
    property State: TCliState read FState;
    property Server: HWND read FServer;
    property Service: string read FService;
    property Items: TStringList read FItems;
    property AutoReconnect: Boolean read FAutoReconnect write FAutoReconnect;
    property LogMessages: Boolean read FLogMessages write FLogMessages;
    property OnLog: TAtomCliLog read FOnLog write FOnLog;
    property OnReply: TAtomReplyEvent read FOnReply write FOnReply;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
  end;

const
  CliStateText: array[TCliState] of string = ('not connected', 'connecting', 'connected',
    'waiting for the server');

implementation

const
  RETRY_MS = 2000;
  PENDING_MAX = 5000;

{ TAtomClient }

constructor TAtomClient.Create(const AName: string);
begin
  FName := AName;
  FWin := TAtomWindow.Create(ATOM_CLIENT_CLASS, AName);
  FWin.OnMessage := @HandleMessage;
  FPending := TStringList.Create;
  FPending.Sorted := True;
  FSubs := TList.Create;
  FItems := TStringList.Create;
  FAutoReconnect := True;
end;

destructor TAtomClient.Destroy;
var
  I: Integer;
begin
  Disconnect;
  FreeAndNil(FWin);             // deletes the atoms still in its queue
  for I := 0 to FSubs.Count - 1 do
    TAtomSub(FSubs[I]).Free;
  FSubs.Free;
  FPending.Free;
  FItems.Free;
  inherited Destroy;
end;

procedure TAtomClient.Log(const S: string);
begin
  if Assigned(FOnLog) then FOnLog(S);
end;

procedure TAtomClient.Changed;
begin
  if Assigned(FOnChange) then FOnChange(Self);
end;

function TAtomClient.WindowHandle: HWND;
begin
  Result := FWin.Handle;
end;

function TAtomClient.SubCount: Integer;
begin
  Result := FSubs.Count;
end;

function TAtomClient.Sub(I: Integer): TAtomSub;
begin
  Result := TAtomSub(FSubs[I]);
end;

function TAtomClient.FindSub(const AItem: string): TAtomSub;
var
  I: Integer;
begin
  for I := 0 to FSubs.Count - 1 do
    if SameText(TAtomSub(FSubs[I]).Item, AItem) then
      Exit(TAtomSub(FSubs[I]));
  Result := nil;
end;

function TAtomClient.Connect(const AService: string; out Err: string): Boolean;
var
  W: HWND;
  I: Integer;
begin
  Err := '';
  if (FState = csConnected) and SameText(AService, FService) and IsWindow(FServer) then
    Exit(True);
  if FState = csConnected then Disconnect;
  FService := Trim(AService);
  W := FindAtomServer(FService);
  if W = 0 then
  begin
    Err := Format('no server with the service "%s"', [FService]);
    if FSubs.Count > 0 then FState := csLost else FState := csIdle;
    FLastTry := GetTickCount64;
    Changed;
    Exit(False);
  end;
  FServer := W;
  FState := csConnecting;
  FPending.Clear;
  Send('HELLO ' + FName);
  { the subscriptions again (a new server or a reconnect) }
  for I := 0 to FSubs.Count - 1 do
  begin
    TAtomSub(FSubs[I]).State := ssWaiting;
    Send('SUB ' + TAtomSub(FSubs[I]).Item);
  end;
  Log(Format('server "%s" found: window %x, %s', [FService, W, WindowProcess(W)]));
  Changed;
  Result := True;
end;

procedure TAtomClient.Disconnect;
var
  I: Integer;
begin
  if (FServer <> 0) and IsWindow(FServer) then
    Send('BYE');
  if FServer <> 0 then
    Log('disconnected from ' + FService);
  FServer := 0;
  FState := csIdle;
  for I := 0 to FSubs.Count - 1 do
    TAtomSub(FSubs[I]).State := ssWaiting;
  Changed;
end;

procedure TAtomClient.Lost(const Why: string);
var
  I: Integer;
begin
  Log(Format('server "%s" lost: %s', [FService, Why]));
  FServer := 0;
  FState := csLost;
  FLastTry := GetTickCount64;
  for I := 0 to FSubs.Count - 1 do
    TAtomSub(FSubs[I]).State := ssWaiting;
  Changed;
end;

function TAtomClient.Send(const Text: string): string;
var
  S: string;
begin
  Result := '';
  if FServer = 0 then Exit;
  Inc(FSeq);
  Result := Format('%x.%d', [FWin.Handle, FSeq]);
  S := Result + ' ' + Text;
  if Length(UTF8Decode(S)) > MAX_ATOM_TEXT then
  begin
    Log('not sent, longer than 255 characters: ' + Copy(Text, 1, 60) + '...');
    Exit('');
  end;
  if not PostAtom(FServer, WM_NLATOM_CMD, FWin.Handle, S) then
  begin
    Inc(Dropped);
    if not IsWindow(FServer) then
      Lost('window gone')
    else
      Log('not sent (message queue of the server full): ' + Text);
    Exit('');
  end;
  Inc(MsgsOut);
  if FPending.Count > PENDING_MAX then FPending.Clear;
  FPending.Values[Result] := IntToStr(GetTickCount64);
  if FLogMessages then Log('-> ' + S);
end;

function TAtomClient.Get(const AItem: string): string;
begin
  Result := Send('GET ' + AItem);
end;

function TAtomClient.SetValue(const AItem, AValue: string): string;
begin
  Result := Send('SET ' + AItem + '=' + AValue);
end;

function TAtomClient.RequestItems: string;
begin
  FItems.Clear;
  FItemsId := Send('ITEMS');
  Result := FItemsId;
end;

function TAtomClient.Subscribe(const AItem: string): TAtomSub;
begin
  Result := FindSub(AItem);
  if Result = nil then
  begin
    Result := TAtomSub.Create;
    Result.Item := AItem;
    FSubs.Add(Result);
  end;
  Result.State := ssWaiting;
  if FServer <> 0 then
    Send('SUB ' + AItem);
  Changed;
end;

procedure TAtomClient.Unsubscribe(S: TAtomSub);
begin
  if FServer <> 0 then
    Send('UNSUB ' + S.Item);
  FSubs.Remove(S);
  S.Free;
  Changed;
end;

procedure TAtomClient.HandleMessage(Msg: UINT; From: HWND; const Text: string);
var
  Id, Kind, Rest, Item, V: string;
  I, P, Ms: Integer;
  S: TAtomSub;
begin
  if Msg <> WM_NLATOM_REPLY then Exit;
  if (From <> FServer) or (FServer = 0) then Exit;    // an old server or a stranger
  Inc(MsgsIn);
  if FLogMessages then Log('<- ' + Text);
  SplitMessage(Text, Id, Kind, Rest);
  Ms := -1;
  I := FPending.IndexOfName(Id);
  if I >= 0 then
  begin
    Ms := Integer(GetTickCount64 - StrToQWordDef(FPending.ValueFromIndex[I], 0));
    LastRoundTrip := Ms;
    if (Kind <> 'ITEM') then FPending.Delete(I);
  end;
  if Kind = 'WELCOME' then
  begin
    FState := csConnected;
    Log('connected: ' + Rest);
  end
  else if Kind = 'BYE' then
  begin
    Lost('the server says ' + Rest);
    Exit;
  end
  else if Kind = 'ITEM' then
  begin
    P := Pos(' ', Rest);
    if P > 0 then
      FItems.Add(Copy(Rest, 1, P - 1) + '=' + Copy(Rest, P + 1, MaxInt))
    else
      FItems.Add(Rest + '=');
  end
  else if (Kind = 'VAL') or (Kind = 'ERR') then
  begin
    P := Pos('=', Rest);
    if Kind = 'VAL' then
    begin
      Item := Copy(Rest, 1, P - 1);
      V := Copy(Rest, P + 1, MaxInt);
    end
    else
    begin
      P := Pos(' ', Rest);
      if P = 0 then P := Length(Rest) + 1;
      Item := Copy(Rest, 1, P - 1);
      V := Copy(Rest, P + 1, MaxInt);
    end;
    S := FindSub(Item);
    if S <> nil then
    begin
      if Kind = 'VAL' then
      begin
        S.Value := V;
        S.Time := Now;
        S.State := ssActive;
        Inc(S.Updates);
      end
      else if S.State = ssWaiting then
      begin
        S.State := ssRefused;
        S.Error := V;
      end;
    end;
  end;
  if Assigned(FOnReply) then FOnReply(Id, Kind, Rest, Ms);
  Changed;
end;

procedure TAtomClient.Tick;
var
  Err: string;
begin
  if (FServer <> 0) and not IsWindow(FServer) then
    Lost('window gone');
  if (FState = csLost) and FAutoReconnect and (GetTickCount64 - FLastTry >= RETRY_MS) then
  begin
    FLastTry := GetTickCount64;
    if FindAtomServer(FService) <> 0 then
      Connect(FService, Err);
  end;
end;

end.
