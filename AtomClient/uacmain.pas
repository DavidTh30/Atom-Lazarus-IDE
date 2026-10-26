{ ============================================================================
  Atom Client - NLAtom client (Windows global atoms) built with normal
  Lazarus forms, for AtomServer or any program that speaks NLAtom/1
    - find the servers, connect, the item list from ITEMS
    - GET, SET, SUB / UNSUB, any command (PING, ITEMS <filter>, ...)
    - subscriptions table, sent again when the server comes back
    - Atom table tab: every string atom of the global atom table, with a
      filter, "only NLAtom messages" (to see atoms that were not deleted)
    - settings and subscriptions in AtomClient.ini next to the exe
    - command line (for tests): --service= --find --connect --sub=a,b
      --get=item --set=item=value --raw=cmd --atoms --dump=<file.txt>
      --snapshot=<file.png> --after=<s>
  ============================================================================ }
unit uacmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  ComCtrls, Clipbrd, IniFiles, RegExpr, uatomproto, uatomcli, ufrmsnap;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonAtoms: TButton;
    ButtonConnect: TButton;
    ButtonDisconnect: TButton;
    ButtonFind: TButton;
    ButtonGet: TButton;
    ButtonRaw: TButton;
    ButtonSet: TButton;
    ButtonSub: TButton;
    CheckAutoConnect: TCheckBox;
    CheckAutoReconnect: TCheckBox;
    CheckLogMessages: TCheckBox;
    CheckOnlyOurs: TCheckBox;
    ComboItem: TComboBox;
    ComboService: TComboBox;
    EditAtomFilter: TEdit;
    EditRaw: TEdit;
    EditValue: TEdit;
    GridAtoms: TStringGrid;
    GridSubs: TStringGrid;
    GroupCmd: TGroupBox;
    LabelAtomCount: TLabel;
    LabelAtomFilter: TLabel;
    LabelItem: TLabel;
    LabelRaw: TLabel;
    LabelResult: TLabel;
    LabelService: TLabel;
    LabelState: TLabel;
    LabelStatus: TLabel;
    LabelValue: TLabel;
    MainMenu1: TMainMenu;
    MemoLog: TMemo;
    MenuAbout: TMenuItem;
    MenuClearLog: TMenuItem;
    MenuConnect: TMenuItem;
    MenuCopyValue: TMenuItem;
    MenuDisconnect: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuFind: TMenuItem;
    MenuHelp: TMenuItem;
    MenuSep1: TMenuItem;
    MenuToSet: TMenuItem;
    MenuUnsub: TMenuItem;
    MenuUnsubAll: TMenuItem;
    PageControl1: TPageControl;
    PanelAtoms: TPanel;
    PanelConn: TPanel;
    PopupSubs: TPopupMenu;
    ShapeState: TShape;
    SplitterLog: TSplitter;
    TabAtoms: TTabSheet;
    TabSubs: TTabSheet;
    Timer1: TTimer;
    procedure ButtonAtomsClick(Sender: TObject);
    procedure ButtonConnectClick(Sender: TObject);
    procedure ButtonDisconnectClick(Sender: TObject);
    procedure ButtonFindClick(Sender: TObject);
    procedure ButtonGetClick(Sender: TObject);
    procedure ButtonRawClick(Sender: TObject);
    procedure ButtonSetClick(Sender: TObject);
    procedure ButtonSubClick(Sender: TObject);
    procedure CheckAutoReconnectChange(Sender: TObject);
    procedure CheckLogMessagesChange(Sender: TObject);
    procedure EditKeyPress(Sender: TObject; var Key: Char);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridSubsDblClick(Sender: TObject);
    procedure GridResize(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuCopyValueClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure MenuToSetClick(Sender: TObject);
    procedure MenuUnsubAllClick(Sender: TObject);
    procedure MenuUnsubClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FClient: TAtomClient;
    FDirty: Boolean;
    FTicks: Integer;
    FDumpFile: string;
    FSnapFile: string;
    FEndAt: QWord;
    FReplies: TStringList;           // for --dump
    procedure Log(const S: string);
    procedure ClientChange(Sender: TObject);
    procedure ClientReply(const Id, Kind, Rest: string; RoundTripMs: Integer);
    function Service: string;
    function Item: string;
    procedure DoConnect;
    procedure ShowSubs;
    procedure ShowAtoms;
    procedure UpdateState;
    function SelectedSub: TAtomSub;
    procedure RunCommandLine;
    procedure Dump;
    procedure LoadIni;
    procedure SaveIni;
    function IniName: string;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

const
  MAX_LOG = 2000;
  SubStateText: array[TSubState] of string = ('waiting', 'active', 'refused');

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FReplies := TStringList.Create;
  FClient := TAtomClient.Create(Format('AtomClient-%d', [GetProcessID]));
  FClient.OnLog := @Log;
  FClient.OnChange := @ClientChange;
  FClient.OnReply := @ClientReply;
  GridSubs.Cells[0, 0] := 'Item';
  GridSubs.Cells[1, 0] := 'Value';
  GridSubs.Cells[2, 0] := 'Updates';
  GridSubs.Cells[3, 0] := 'Time';
  GridSubs.Cells[4, 0] := 'State';
  GridAtoms.Cells[0, 0] := 'Atom';
  GridAtoms.Cells[1, 0] := 'Text';
  LoadIni;
  FClient.AutoReconnect := CheckAutoReconnect.Checked;
  FClient.LogMessages := CheckLogMessages.Checked;
  ShowSubs;
  UpdateState;
  if Application.HasOption('service') or Application.HasOption('connect') or
    Application.HasOption('find') or Application.HasOption('atoms') or
    Application.HasOption('dump') or Application.HasOption('snapshot') then
    RunCommandLine
  else if CheckAutoConnect.Checked then
    DoConnect;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if FDumpFile = '' then SaveIni;      // a test run keeps the user's settings
  FClient.OnLog := nil;
  FClient.OnChange := nil;
  FClient.OnReply := nil;
  FClient.Free;
  FReplies.Free;
end;

procedure TMainForm.Log(const S: string);
begin
  MemoLog.Lines.BeginUpdate;
  try
    while MemoLog.Lines.Count > MAX_LOG do
      MemoLog.Lines.Delete(0);
    MemoLog.Lines.Add(FormatDateTime('hh:nn:ss.zzz  ', Now) + S);
  finally
    MemoLog.Lines.EndUpdate;
  end;
  MemoLog.SelStart := Length(MemoLog.Text);
end;

procedure TMainForm.ClientChange(Sender: TObject);
begin
  FDirty := True;
end;

{ the answers to our own commands (subscription updates go to the table) }
procedure TMainForm.ClientReply(const Id, Kind, Rest: string; RoundTripMs: Integer);
var
  I, P: Integer;
  Names: TStringList;
begin
  if Copy(Id, 1, 2) = 'S.' then Exit;
  if (FDumpFile <> '') and (Kind <> 'ITEM') then FReplies.Add(Kind + ' ' + Rest);
  if Kind = 'END' then
  begin
    { ITEMS done: the item list }
    Names := TStringList.Create;
    try
      for I := 0 to FClient.Items.Count - 1 do
        Names.Add(FClient.Items.Names[I]);
      P := ComboItem.SelStart;
      ComboItem.Items.Assign(Names);
      ComboItem.SelStart := P;
      Log(Format('%d items', [Names.Count]));
    finally
      Names.Free;
    end;
    Exit;
  end;
  if Kind = 'ITEM' then Exit;
  LabelResult.Caption := Format('%s %s   (%d ms)', [Kind, Rest, Max(RoundTripMs, 0)]);
  if Kind = 'ERR' then
    LabelResult.Font.Color := clRed
  else
    LabelResult.Font.Color := clDefault;
  { with "Log every message" the raw message is in the log already }
  if not CheckLogMessages.Checked then
    Log(Kind + ' ' + Rest);
end;

function TMainForm.Service: string;
begin
  Result := Trim(ComboService.Text);
end;

function TMainForm.Item: string;
begin
  Result := Trim(ComboItem.Text);
end;

procedure TMainForm.DoConnect;
var
  Err: string;
begin
  if not FClient.Connect(Service, Err) then
    Log('connect failed: ' + Err)
  else
  begin
    if ComboService.Items.IndexOf(Service) < 0 then ComboService.Items.Add(Service);
    FClient.RequestItems;
  end;
  UpdateState;
end;

procedure TMainForm.ShowSubs;
var
  I: Integer;
  S: TAtomSub;
begin
  FDirty := False;
  GridSubs.BeginUpdate;
  try
    GridSubs.RowCount := FClient.SubCount + 1;
    for I := 0 to FClient.SubCount - 1 do
    begin
      S := FClient.Sub(I);
      GridSubs.Cells[0, I + 1] := S.Item;
      if S.State = ssRefused then
        GridSubs.Cells[1, I + 1] := S.Error
      else
        GridSubs.Cells[1, I + 1] := S.Value;
      GridSubs.Cells[2, I + 1] := IntToStr(S.Updates);
      if S.Time > 0 then
        GridSubs.Cells[3, I + 1] := FormatDateTime('hh:nn:ss.zzz', S.Time)
      else
        GridSubs.Cells[3, I + 1] := '';
      GridSubs.Cells[4, I + 1] := SubStateText[S.State];
    end;
  finally
    GridSubs.EndUpdate;
  end;
end;

{ the global atom table: every string atom, or only those that look like
  NLAtom messages (an id and a word: atoms nobody deleted) }
procedure TMainForm.ShowAtoms;
var
  L: TStringList;
  I, N, Total: Integer;
  F, S: string;
  RE: TRegExpr;
begin
  L := TStringList.Create;
  RE := TRegExpr.Create('^([0-9A-F]+\.\d+|S\.\d+) [A-Z]+');
  try
    Total := ListGlobalAtoms(L);
    F := LowerCase(Trim(EditAtomFilter.Text));
    GridAtoms.BeginUpdate;
    try
      GridAtoms.RowCount := 1;
      N := 0;
      for I := 0 to L.Count - 1 do
      begin
        S := L.ValueFromIndex[I];
        if (F <> '') and (Pos(F, LowerCase(S)) = 0) then Continue;
        if CheckOnlyOurs.Checked and not RE.Exec(S) then Continue;
        Inc(N);
        GridAtoms.RowCount := N + 1;
        GridAtoms.Cells[0, N] := L.Names[I];
        GridAtoms.Cells[1, N] := S;
      end;
    finally
      GridAtoms.EndUpdate;
    end;
    LabelAtomCount.Caption := Format('%d of %d string atoms shown (the table holds about 16000)',
      [N, Total]);
  finally
    RE.Free;
    L.Free;
  end;
end;

procedure TMainForm.UpdateState;
begin
  case FClient.State of
    csConnected: ShapeState.Brush.Color := clLime;
    csConnecting: ShapeState.Brush.Color := clYellow;
    csLost: ShapeState.Brush.Color := clRed;
  else
    ShapeState.Brush.Color := clSilver;
  end;
  if FClient.State in [csConnected, csConnecting] then
    LabelState.Caption := Format('%s to %s (window %x)', [CliStateText[FClient.State],
      FClient.Service, FClient.Server])
  else
    LabelState.Caption := CliStateText[FClient.State];
  ButtonDisconnect.Enabled := FClient.State <> csIdle;
  MenuDisconnect.Enabled := ButtonDisconnect.Enabled;
  LabelStatus.Caption := Format('messages out %d   in %d   not sent %d   last round trip %d ms'
    + '   subscriptions %d   own window %x', [FClient.MsgsOut, FClient.MsgsIn, FClient.Dropped,
    FClient.LastRoundTrip, FClient.SubCount, FClient.WindowHandle]);
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  FClient.Tick;
  if FDirty then ShowSubs;
  Inc(FTicks);
  if FTicks mod 5 = 0 then UpdateState;
  if (FEndAt > 0) and (GetTickCount64 >= FEndAt) then
  begin
    FEndAt := 0;
    ShowSubs;
    UpdateState;
    Dump;
    Close;
  end;
end;

function TMainForm.SelectedSub: TAtomSub;
begin
  if (GridSubs.Row >= 1) and (GridSubs.Row <= FClient.SubCount) then
    Result := FClient.Sub(GridSubs.Row - 1)
  else
    Result := nil;
end;

procedure TMainForm.ButtonConnectClick(Sender: TObject);
begin
  DoConnect;
end;

procedure TMainForm.ButtonDisconnectClick(Sender: TObject);
begin
  FClient.Disconnect;
  UpdateState;
end;

procedure TMainForm.ButtonFindClick(Sender: TObject);
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    FindAtomServers(L);
    Log(Format('%d server(s) found', [L.Count]));
    for I := 0 to L.Count - 1 do
    begin
      Log(Format('  %s: window %x, %s', [L[I], PtrUInt(L.Objects[I]),
        WindowProcess(PtrUInt(L.Objects[I]))]));
      if ComboService.Items.IndexOf(L[I]) < 0 then
        ComboService.Items.Add(L[I]);
    end;
    if (L.Count > 0) and (ComboService.Items.IndexOf(Service) < 0) then
      ComboService.Text := L[0];
  finally
    L.Free;
  end;
end;

procedure TMainForm.ButtonGetClick(Sender: TObject);
begin
  if Item = '' then Exit;
  if FClient.Get(Item) = '' then Log('not connected');
end;

procedure TMainForm.ButtonSetClick(Sender: TObject);
begin
  if Item = '' then Exit;
  if FClient.SetValue(Item, EditValue.Text) = '' then Log('not connected');
end;

procedure TMainForm.ButtonSubClick(Sender: TObject);
begin
  if Item = '' then Exit;
  FClient.Subscribe(Item);
  Log('subscribe ' + Item);
  ShowSubs;
end;

procedure TMainForm.ButtonRawClick(Sender: TObject);
begin
  if Trim(EditRaw.Text) = '' then Exit;
  if FClient.Send(Trim(EditRaw.Text)) = '' then Log('not sent');
end;

procedure TMainForm.ButtonAtomsClick(Sender: TObject);
begin
  ShowAtoms;
end;

procedure TMainForm.EditKeyPress(Sender: TObject; var Key: Char);
begin
  if Key <> #13 then Exit;
  Key := #0;
  if Sender = EditValue then ButtonSetClick(nil)
  else if Sender = EditRaw then ButtonRawClick(nil)
  else if Sender = EditAtomFilter then ShowAtoms
  else if Sender = ComboItem then ButtonGetClick(nil);
end;

procedure TMainForm.CheckAutoReconnectChange(Sender: TObject);
begin
  if FClient <> nil then FClient.AutoReconnect := CheckAutoReconnect.Checked;
end;

procedure TMainForm.CheckLogMessagesChange(Sender: TObject);
begin
  if FClient <> nil then FClient.LogMessages := CheckLogMessages.Checked;
end;

{ double-click a subscription: its item and value go to Set }
procedure TMainForm.GridSubsDblClick(Sender: TObject);
begin
  MenuToSetClick(nil);
end;

{ the second column (Value / Text) takes the width the others leave }
procedure TMainForm.GridResize(Sender: TObject);
var
  G: TStringGrid;
  I, W: Integer;
begin
  G := Sender as TStringGrid;
  W := G.ClientWidth - 2;
  for I := 0 to G.ColCount - 1 do
    if I <> 1 then Dec(W, G.ColWidths[I]);
  if W > 120 then G.ColWidths[1] := W;
end;

procedure TMainForm.MenuToSetClick(Sender: TObject);
begin
  if SelectedSub = nil then Exit;
  ComboItem.Text := SelectedSub.Item;
  EditValue.Text := SelectedSub.Value;
  EditValue.SetFocus;
end;

procedure TMainForm.MenuCopyValueClick(Sender: TObject);
begin
  if SelectedSub <> nil then
    Clipboard.AsText := SelectedSub.Value;
end;

procedure TMainForm.MenuUnsubClick(Sender: TObject);
begin
  if SelectedSub = nil then Exit;
  Log('unsubscribe ' + SelectedSub.Item);
  FClient.Unsubscribe(SelectedSub);
  ShowSubs;
end;

procedure TMainForm.MenuUnsubAllClick(Sender: TObject);
begin
  while FClient.SubCount > 0 do
    FClient.Unsubscribe(FClient.Sub(0));
  ShowSubs;
end;

procedure TMainForm.MenuClearLogClick(Sender: TObject);
begin
  MemoLog.Clear;
end;

procedure TMainForm.MenuExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.MenuAboutClick(Sender: TObject);
begin
  MessageDlg('Atom Client',
    'NLAtom/1 client: commands and values as Windows global atoms, Free Pascal / Lazarus.' +
    LineEnding + LineEnding +
    'GET <item>, SET <item>=<value>, SUB / UNSUB <item>, ITEMS [filter], PING',
    mtInformation, [mbOK], 0);
end;

{ ---------------------------------------------------------------- command line }

procedure TMainForm.RunCommandLine;
var
  L: TStringList;
  I, P: Integer;
  S: string;
begin
  if Application.HasOption('service') then ComboService.Text := Application.GetOptionValue('service');
  FDumpFile := Application.GetOptionValue('dump');
  FSnapFile := Application.GetOptionValue('snapshot');
  if Application.HasOption('find') then ButtonFindClick(nil);
  if Application.HasOption('connect') then DoConnect;
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := Application.GetOptionValue('sub');
    for I := 0 to L.Count - 1 do
      if Trim(L[I]) <> '' then
        FClient.Subscribe(Trim(L[I]));
  finally
    L.Free;
  end;
  S := Application.GetOptionValue('set');
  P := Pos('=', S);
  if P > 1 then
  begin
    ComboItem.Text := Copy(S, 1, P - 1);
    EditValue.Text := Copy(S, P + 1, MaxInt);
    ButtonSetClick(nil);
  end;
  if Application.HasOption('get') then
  begin
    ComboItem.Text := Application.GetOptionValue('get');
    ButtonGetClick(nil);
  end;
  if Application.HasOption('raw') then
  begin
    EditRaw.Text := Application.GetOptionValue('raw');
    ButtonRawClick(nil);
  end;
  if Application.HasOption('atoms') then
  begin
    PageControl1.ActivePage := TabAtoms;
    ShowAtoms;
  end;
  if (FDumpFile <> '') or (FSnapFile <> '') then
    FEndAt := GetTickCount64 + Round(StrToFloatDef(Application.GetOptionValue('after'), 3) * 1000);
end;

procedure TMainForm.Dump;
var
  F: TStringList;
  R, C: Integer;
  S: string;
begin
  if Application.HasOption('atoms') then ShowAtoms;
  if FSnapFile <> '' then
    SaveFormSnapshot(Self, FSnapFile);
  if FDumpFile = '' then Exit;
  F := TStringList.Create;
  try
    F.Add('state: ' + LabelState.Caption);
    F.Add('status: ' + LabelStatus.Caption);
    F.Add('items: ' + IntToStr(ComboItem.Items.Count));
    F.Add('atoms: ' + LabelAtomCount.Caption);
    F.Add('--- replies');
    F.AddStrings(FReplies);
    F.Add('--- subscriptions');
    for R := 0 to GridSubs.RowCount - 1 do
    begin
      S := '';
      for C := 0 to GridSubs.ColCount - 1 do
        S := S + GridSubs.Cells[C, R] + ' ; ';
      F.Add(S);
    end;
    F.Add('--- log');
    F.AddStrings(MemoLog.Lines);
    F.SaveToFile(FDumpFile);
  finally
    F.Free;
  end;
end;

{ ---------------------------------------------------------------- settings }

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
  I, N: Integer;
begin
  Ini := TIniFile.Create(IniName);
  try
    ComboService.Text := Ini.ReadString('Connection', 'Service', 'NLHV');
    ComboItem.Text := Ini.ReadString('Connection', 'Item', 'DB_HMI.VoltAct_kV');
    CheckAutoReconnect.Checked := Ini.ReadBool('Connection', 'AutoReconnect', True);
    CheckAutoConnect.Checked := Ini.ReadBool('Connection', 'AutoConnect', False);
    CheckLogMessages.Checked := Ini.ReadBool('Connection', 'LogMessages', False);
    EditRaw.Text := Ini.ReadString('Connection', 'Command', 'PING');
    if Application.HasOption('dump') then Exit;   // a test run starts without saved subscriptions
    N := Ini.ReadInteger('Subscriptions', 'Count', 0);
    for I := 0 to N - 1 do
      if Trim(Ini.ReadString('Subscriptions', 'Item' + IntToStr(I), '')) <> '' then
        FClient.Subscribe(Trim(Ini.ReadString('Subscriptions', 'Item' + IntToStr(I), '')));
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
  I: Integer;
begin
  try
    Ini := TIniFile.Create(IniName);
    try
      Ini.WriteString('Connection', 'Service', Service);
      Ini.WriteString('Connection', 'Item', Item);
      Ini.WriteBool('Connection', 'AutoReconnect', CheckAutoReconnect.Checked);
      Ini.WriteBool('Connection', 'AutoConnect', CheckAutoConnect.Checked);
      Ini.WriteBool('Connection', 'LogMessages', CheckLogMessages.Checked);
      Ini.WriteString('Connection', 'Command', EditRaw.Text);
      Ini.EraseSection('Subscriptions');
      Ini.WriteInteger('Subscriptions', 'Count', FClient.SubCount);
      for I := 0 to FClient.SubCount - 1 do
        Ini.WriteString('Subscriptions', 'Item' + IntToStr(I), FClient.Sub(I).Item);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      Log('settings not saved: ' + E.Message);
  end;
end;

end.
