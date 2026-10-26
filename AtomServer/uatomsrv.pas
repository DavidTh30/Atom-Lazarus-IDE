{ ============================================================================
  uatomsrv - NLAtom server: the simulated HV PLC (uplcsim) through global
  atoms (see uatomproto)
    items     DB_HMI.VoltSP_kV ... DB_HMI.Curve_VSP.Eng (values by ';'),
              Sim.Counter / Sine / Toggle / Clock, Data.<any name> (free text)
    commands  HELLO <name>        -> WELCOME <service> NLAtom/1 <items>
              ITEMS               -> ITEM <name> <type> <r|rw> ... END <n>
              GET <item>          -> VAL <item>=<value> | ERR <item> <why>
              SET <item>=<value>  -> OK <item>=<value> | ERR <item> <why>
              SUB <item>          -> VAL now, then VAL (id S.n) on every change
              UNSUB <item> | *    -> OK
              PING                -> PONG <server time>
              BYE                 the client leaves
    the server says BYE to its clients when it stops
  Everything runs in the main thread (the window gets its messages from the
  LCL message loop); only the PLC has a lock.
  ============================================================================ }
unit uatomsrv;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, Math, uatomproto, uaencode, uaserver, uplcsim;

type
  TAItemKind = (akTag, akCurve, akData);

  TAItem = class
    Name: string;
    Kind: TAItemKind;
    TagKind: TTagKind;
    Tag: Integer;
    Writable: Boolean;
    Data: string;
  end;

  TAClient = class
    Wnd: HWND;
    Name: string;
    Process: string;
    Since: TDateTime;
    MsgsIn, MsgsOut: Int64;
    Subs: TStringList;         // <item name lower case>=<last value sent>
    constructor Create;
    destructor Destroy; override;
  end;

  TAtomLogEvent = procedure(const S: string) of object;

  { TAtomSimServer }

  TAtomSimServer = class
  private
    FSim: TPlcSim;
    FWin: TAtomWindow;
    FService: string;
    FItems: TStringList;       // lower case name -> TAItem
    FClients: TList;
    FSeq: Int64;
    FLogMessages: Boolean;
    FOnLog: TAtomLogEvent;
    FFS: TFormatSettings;
    procedure Log(const S: string);
    procedure AddItem(const AName: string; AKind: TAItemKind; ATagKind: TTagKind; ATag: Integer;
      AWritable: Boolean);
    function FindClient(W: HWND): TAClient;
    procedure DropClient(C: TAClient; const Why: string);
    function Send(C: TAClient; const Id, Text: string): Boolean;
    function WriteItem(It: TAItem; const S: string; out Msg: string): Boolean;
    procedure HandleMessage(Msg: UINT; From: HWND; const Text: string);
  public
    MsgsIn, MsgsOut, Dropped, Refused: Int64;
    constructor Create(ASim: TPlcSim);
    destructor Destroy; override;
    function Start(const AService: string; out Err: string): Boolean;
    procedure Stop;
    function Running: Boolean;
    { subscriptions: send the changed values; drop clients whose window is gone }
    procedure Tick;
    function ItemCount: Integer;
    function Item(I: Integer): TAItem;
    function ClientCount: Integer;
    function Client(I: Integer): TAClient;
    function Value(const AName: string; out S: string): Boolean;
    function TypeText(It: TAItem): string;
    function SubsOf(It: TAItem): Integer;
    function WindowHandle: HWND;
    property Service: string read FService;
    property LogMessages: Boolean read FLogMessages write FLogMessages;
    property OnLog: TAtomLogEvent read FOnLog write FOnLog;
  end;

const
  MAX_DATA_ITEMS = 1000;
  MAX_DATA_TEXT = 200;

implementation

{ TAClient }

constructor TAClient.Create;
begin
  Subs := TStringList.Create;
end;

destructor TAClient.Destroy;
begin
  Subs.Free;
  inherited Destroy;
end;

{ TAtomSimServer }

constructor TAtomSimServer.Create(ASim: TPlcSim);
var
  I: Integer;
begin
  FSim := ASim;
  FItems := TStringList.Create;
  FItems.Sorted := True;
  FItems.OwnsObjects := True;
  FClients := TList.Create;
  FFS := DefaultFormatSettings;
  FFS.DecimalSeparator := '.';
  FFS.ThousandSeparator := #0;
  FService := 'NLHV';
  for I := 0 to High(FSim.Tags) do
    if FSim.Tags[I].Kind = tkRealArray then
      AddItem(FSim.Tags[I].Name, akCurve, tkRealArray, FSim.Tags[I].Id, True)
    else
      AddItem(FSim.Tags[I].Name, akTag, FSim.Tags[I].Kind, FSim.Tags[I].Id, FSim.Tags[I].Writable);
end;

destructor TAtomSimServer.Destroy;
begin
  Stop;
  FItems.Free;
  FClients.Free;
  inherited Destroy;
end;

procedure TAtomSimServer.Log(const S: string);
begin
  if Assigned(FOnLog) then FOnLog(S);
end;

procedure TAtomSimServer.AddItem(const AName: string; AKind: TAItemKind; ATagKind: TTagKind;
  ATag: Integer; AWritable: Boolean);
var
  It: TAItem;
begin
  It := TAItem.Create;
  It.Name := AName;
  It.Kind := AKind;
  It.TagKind := ATagKind;
  It.Tag := ATag;
  It.Writable := AWritable;
  FItems.AddObject(LowerCase(AName), It);
end;

function TAtomSimServer.Start(const AService: string; out Err: string): Boolean;
begin
  Err := '';
  if FWin <> nil then Exit(True);
  FService := Trim(AService);
  if (FService = '') or (Length(FService) > 64) then
  begin
    Err := 'service name: 1..64 characters';
    Exit(False);
  end;
  if FindAtomServer(FService) <> 0 then
  begin
    Err := Format('service "%s" runs already (%s)', [FService,
      WindowProcess(FindAtomServer(FService))]);
    Exit(False);
  end;
  try
    FWin := TAtomWindow.Create(ATOM_SERVER_CLASS, FService);
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit(False);
    end;
  end;
  FWin.OnMessage := @HandleMessage;
  MsgsIn := 0; MsgsOut := 0; Dropped := 0; Refused := 0;
  Log(Format('service "%s" started, window %x, %d items', [FService, FWin.Handle, FItems.Count]));
  Result := True;
end;

procedure TAtomSimServer.Stop;
var
  I: Integer;
begin
  if FWin = nil then Exit;
  Inc(FSeq);
  for I := 0 to FClients.Count - 1 do
    Send(TAClient(FClients[I]), 'S.' + IntToStr(FSeq), 'BYE server stops');
  for I := 0 to FClients.Count - 1 do
    TAClient(FClients[I]).Free;
  FClients.Clear;
  FreeAndNil(FWin);           // deletes the atoms still in its queue
  Log('service "' + FService + '" stopped');
end;

function TAtomSimServer.Running: Boolean;
begin
  Result := FWin <> nil;
end;

function TAtomSimServer.WindowHandle: HWND;
begin
  if FWin = nil then Result := 0 else Result := FWin.Handle;
end;

function TAtomSimServer.ItemCount: Integer;
begin
  Result := FItems.Count;
end;

function TAtomSimServer.Item(I: Integer): TAItem;
begin
  Result := TAItem(FItems.Objects[I]);
end;

function TAtomSimServer.ClientCount: Integer;
begin
  Result := FClients.Count;
end;

function TAtomSimServer.Client(I: Integer): TAClient;
begin
  Result := TAClient(FClients[I]);
end;

function TAtomSimServer.SubsOf(It: TAItem): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FClients.Count - 1 do
    if TAClient(FClients[I]).Subs.IndexOfName(LowerCase(It.Name)) >= 0 then
      Inc(Result);
end;

function TAtomSimServer.FindClient(W: HWND): TAClient;
var
  I: Integer;
begin
  for I := 0 to FClients.Count - 1 do
    if TAClient(FClients[I]).Wnd = W then
      Exit(TAClient(FClients[I]));
  Result := nil;
end;

procedure TAtomSimServer.DropClient(C: TAClient; const Why: string);
begin
  Log(Format('client %s %s left: %s (%d messages in, %d out)', [C.Name, C.Process, Why,
    C.MsgsIn, C.MsgsOut]));
  FClients.Remove(C);
  C.Free;
end;

function TAtomSimServer.Send(C: TAClient; const Id, Text: string): Boolean;
var
  S: string;
begin
  S := Id + ' ' + Text;
  if Length(UTF8Decode(S)) > MAX_ATOM_TEXT then
    S := Copy(S, 1, MAX_ATOM_TEXT - 3) + '...';
  Result := PostAtom(C.Wnd, WM_NLATOM_REPLY, FWin.Handle, S);
  if Result then
  begin
    Inc(MsgsOut);
    Inc(C.MsgsOut);
    if FLogMessages then Log('-> ' + C.Name + ': ' + S);
  end
  else
    Inc(Dropped);
end;

{ ---------------------------------------------------------------- values }

function TAtomSimServer.TypeText(It: TAItem): string;
begin
  case It.Kind of
    akCurve: Result := IntToStr(FSim.Points) + ' x Real';
    akData: Result := 'text';
  else
    case It.TagKind of
      tkReal: Result := 'Real';
      tkInt: Result := 'Int';
      tkBool: Result := 'Bool';
      tkUInt16: Result := 'UInt16';
      tkDouble: Result := 'Double';
      tkDateTime: Result := 'DateTime';
    else
      Result := '?';
    end;
  end;
end;

function TAtomSimServer.Value(const AName: string; out S: string): Boolean;
var
  I, K: Integer;
  It: TAItem;
  V: TUAVariant;
begin
  S := '';
  I := FItems.IndexOf(LowerCase(AName));
  if I < 0 then Exit(False);
  It := TAItem(FItems.Objects[I]);
  Result := True;
  if It.Kind = akData then
  begin
    S := It.Data;
    Exit;
  end;
  if It.TagKind = tkDateTime then
  begin
    S := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now);
    Exit;
  end;
  if not FSim.ReadTag(It.Tag, V) or (Length(V.D) = 0) then Exit(False);
  if It.Kind = akCurve then
  begin
    for K := 0 to High(V.D) do
    begin
      if K > 0 then S := S + ';';
      S := S + FloatToStrF(V.D[K], ffGeneral, 7, 0, FFS);
    end;
    Exit;
  end;
  case It.TagKind of
    tkBool: S := IntToStr(Ord(V.D[0] <> 0));
    tkReal: S := FloatToStrF(V.D[0], ffGeneral, 7, 0, FFS);
    tkDouble: S := FloatToStrF(V.D[0], ffGeneral, 10, 0, FFS);
  else
    S := IntToStr(Round(V.D[0]));
  end;
end;

function TAtomSimServer.WriteItem(It: TAItem; const S: string; out Msg: string): Boolean;
var
  T: string;
  X: Double;
  Code: Cardinal;
  P: TStringList;
  D: array of Double;
  I: Integer;
begin
  Msg := '';
  Result := False;
  if It.Kind = akData then
  begin
    if Length(S) > MAX_DATA_TEXT then
    begin
      Msg := 'text longer than ' + IntToStr(MAX_DATA_TEXT);
      Exit;
    end;
    It.Data := S;
    Exit(True);
  end;
  if not It.Writable then
  begin
    Msg := 'read only';
    Exit;
  end;
  T := LowerCase(Trim(S));
  if It.Kind = akCurve then
  begin
    P := TStringList.Create;
    try
      for I := 1 to Length(T) do
        if T[I] in [';', #9, ','] then T[I] := ' ';
      P.Delimiter := ' ';
      P.DelimitedText := T;
      for I := P.Count - 1 downto 0 do
        if P[I] = '' then P.Delete(I);
      if P.Count <> FSim.Points then
      begin
        Msg := Format('%d values instead of %d', [P.Count, FSim.Points]);
        Exit;
      end;
      SetLength(D, P.Count);
      for I := 0 to P.Count - 1 do
        if not TryStrToFloat(P[I], D[I], FFS) then
        begin
          Msg := '"' + P[I] + '" is not a number';
          Exit;
        end;
      Code := FSim.WriteTag(It.Tag, VarArray(vtFloat, D));
    finally
      P.Free;
    end;
  end
  else
    case It.TagKind of
      tkBool:
        begin
          if (T = '1') or (T = 'true') or (T = 'on') then X := 1
          else if (T = '0') or (T = 'false') or (T = 'off') then X := 0
          else
          begin
            Msg := 'expected 1/0/true/false/on/off';
            Exit;
          end;
          Code := FSim.WriteTag(It.Tag, VarScalar(vtBoolean, X));
        end;
      tkReal, tkInt:
        begin
          if not TryStrToFloat(StringReplace(T, ',', '.', []), X, FFS) then
          begin
            Msg := 'not a number';
            Exit;
          end;
          if It.TagKind = tkReal then
            Code := FSim.WriteTag(It.Tag, VarScalar(vtFloat, X))
          else
            Code := FSim.WriteTag(It.Tag, VarScalar(vtInt16, X));
        end;
    else
      Code := UA_BadNotWritable;
    end;
  case Code of
    UA_GOOD: Result := True;
    UA_BadTypeMismatch: Msg := 'wrong type or number of values';
    UA_BadOutOfRange: Msg := 'out of range';
    UA_BadNotWritable: Msg := 'read only';
  else
    Msg := Format('error 0x%.8x', [Code]);
  end;
end;

{ ---------------------------------------------------------------- messages }

procedure TAtomSimServer.HandleMessage(Msg: UINT; From: HWND; const Text: string);
var
  C: TAClient;
  Id, Cmd, Rest, Name, V, Why: string;
  I, N: Integer;
  It: TAItem;
begin
  if Msg <> WM_NLATOM_CMD then Exit;
  Inc(MsgsIn);
  if (Text = '') or not IsWindow(From) then
  begin
    Inc(Refused);
    Exit;
  end;
  C := FindClient(From);
  if C = nil then
  begin
    C := TAClient.Create;
    C.Wnd := From;
    C.Name := '?';
    C.Process := WindowProcess(From);
    C.Since := Now;
    FClients.Add(C);
  end;
  Inc(C.MsgsIn);
  if FLogMessages then Log('<- ' + C.Name + ': ' + Text);
  SplitMessage(Text, Id, Cmd, Rest);
  if Cmd = 'HELLO' then
  begin
    if Rest <> '' then C.Name := Rest;
    Log(Format('client %s %s, window %x', [C.Name, C.Process, From]));
    Send(C, Id, Format('WELCOME %s %s %d', [FService, ATOM_PROTOCOL, FItems.Count]));
  end
  else if Cmd = 'BYE' then
    DropClient(C, 'bye')
  else if Cmd = 'PING' then
    Send(C, Id, 'PONG ' + FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now))
  else if Cmd = 'ITEMS' then
  begin
    N := 0;
    for I := 0 to FItems.Count - 1 do
    begin
      It := TAItem(FItems.Objects[I]);
      if (Rest <> '') and (Pos(LowerCase(Rest), LowerCase(It.Name)) = 0) then Continue;
      if Send(C, Id, Format('ITEM %s %s %s', [It.Name, StringReplace(TypeText(It), ' ', '',
        [rfReplaceAll]), BoolToStr(It.Writable, 'rw', 'r')])) then
        Inc(N);
    end;
    Send(C, Id, 'END ' + IntToStr(N));
  end
  else if (Cmd = 'GET') or (Cmd = 'SUB') then
  begin
    Name := Trim(Rest);
    I := FItems.IndexOf(LowerCase(Name));
    if (I < 0) and (Cmd = 'SUB') and SameText(Copy(Name, 1, 5), 'Data.') and (Length(Name) > 5)
      and (FItems.Count < MAX_DATA_ITEMS + 100) then
    begin
      AddItem(Name, akData, tkReal, -1, True);     // a subscription makes a Data item
      I := FItems.IndexOf(LowerCase(Name));
    end;
    if I < 0 then
    begin
      Inc(Refused);
      Send(C, Id, 'ERR ' + Name + ' unknown item');
      Exit;
    end;
    It := TAItem(FItems.Objects[I]);
    Value(It.Name, V);
    if Cmd = 'SUB' then
    begin
      I := C.Subs.IndexOfName(LowerCase(It.Name));
      if I < 0 then
        C.Subs.Add(LowerCase(It.Name) + '=' + V)
      else
        C.Subs[I] := LowerCase(It.Name) + '=' + V;
      Log(Format('%s subscribes %s', [C.Name, It.Name]));
    end;
    Send(C, Id, 'VAL ' + It.Name + '=' + V);
  end
  else if Cmd = 'UNSUB' then
  begin
    Name := LowerCase(Trim(Rest));
    if Name = '*' then
      C.Subs.Clear
    else
      for I := C.Subs.Count - 1 downto 0 do
        if C.Subs.Names[I] = Name then
          C.Subs.Delete(I);
    Log(Format('%s unsubscribes %s', [C.Name, Trim(Rest)]));
    Send(C, Id, 'OK ' + Trim(Rest));
  end
  else if Cmd = 'SET' then
  begin
    I := Pos('=', Rest);
    if I = 0 then
    begin
      Inc(Refused);
      Send(C, Id, 'ERR ' + Rest + ' SET <item>=<value> expected');
      Exit;
    end;
    Name := Trim(Copy(Rest, 1, I - 1));
    V := Copy(Rest, I + 1, MaxInt);
    I := FItems.IndexOf(LowerCase(Name));
    if (I < 0) and SameText(Copy(Name, 1, 5), 'Data.') and (Length(Name) > 5) then
    begin
      N := 0;
      for I := 0 to FItems.Count - 1 do
        if TAItem(FItems.Objects[I]).Kind = akData then Inc(N);
      if N < MAX_DATA_ITEMS then
        AddItem(Name, akData, tkReal, -1, True);
      I := FItems.IndexOf(LowerCase(Name));
    end;
    if I < 0 then
    begin
      Inc(Refused);
      Send(C, Id, 'ERR ' + Name + ' unknown item');
      Log(Format('%s: SET %s refused, unknown item', [C.Name, Name]));
      Exit;
    end;
    It := TAItem(FItems.Objects[I]);
    if WriteItem(It, V, Why) then
    begin
      Value(It.Name, V);
      Log(Format('%s: SET %s = %s', [C.Name, It.Name, V]));
      Send(C, Id, 'OK ' + It.Name + '=' + V);
      if It.Kind = akData then Tick;      // the subscribers see it at once
    end
    else
    begin
      Inc(Refused);
      Log(Format('%s: SET %s = %s refused (%s)', [C.Name, It.Name, V, Why]));
      Send(C, Id, 'ERR ' + It.Name + ' ' + Why);
    end;
  end
  else
  begin
    Inc(Refused);
    Send(C, Id, 'ERR ' + Cmd + ' unknown command');
  end;
end;

procedure TAtomSimServer.Tick;
var
  I, J: Integer;
  C: TAClient;
  Name, Last, V: string;
begin
  if FWin = nil then Exit;
  for I := FClients.Count - 1 downto 0 do
  begin
    C := TAClient(FClients[I]);
    if not IsWindow(C.Wnd) then
    begin
      DropClient(C, 'window gone');
      Continue;
    end;
    for J := 0 to C.Subs.Count - 1 do
    begin
      Name := C.Subs.Names[J];
      Last := C.Subs.ValueFromIndex[J];
      if not Value(Name, V) then Continue;
      if V <> Last then
      begin
        Inc(FSeq);
        if Send(C, 'S.' + IntToStr(FSeq), 'VAL ' + TAItem(FItems.Objects[FItems.IndexOf(Name)]).Name
          + '=' + V) then
          C.Subs[J] := Name + '=' + V;   // a dropped update is sent again next time
      end;
    end;
  end;
end;

end.
