{ ============================================================================
  Atom Server - the simulated HV PLC for other programs on this PC through
  Windows global atoms (NLAtom protocol, see uatomproto), built with normal
  Lazarus forms
    - service name, 10 points (Set 1) or 2 points (Set 2)
    - item table with value, type, access and subscribers
    - clients: name, program, window, messages, subscriptions
    - status: messages, dropped, refused, string atoms in the global table
    - settings in AtomServer.ini next to the exe; --start starts at once,
      --snapshot=<png> --after=<s> saves the window and exits (tests)
  ============================================================================ }
unit uatmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, Menus, ExtCtrls, StdCtrls, Grids,
  ComCtrls, Clipbrd, IniFiles, uplcsim, uatomproto, uatomsrv, ufrmsnap;

type

  { TMainForm }

  TMainForm = class(TForm)
    ButtonStart: TButton;
    ButtonStop: TButton;
    CheckAutoStart: TCheckBox;
    CheckLogMessages: TCheckBox;
    ComboPoints: TComboBox;
    EditService: TEdit;
    GridClients: TStringGrid;
    GridItems: TStringGrid;
    LabelPoints: TLabel;
    LabelService: TLabel;
    LabelState: TLabel;
    LabelStatus: TLabel;
    MainMenu1: TMainMenu;
    MemoLog: TMemo;
    MenuAbout: TMenuItem;
    MenuClearLog: TMenuItem;
    MenuCopyName: TMenuItem;
    MenuCopyValue: TMenuItem;
    MenuExit: TMenuItem;
    MenuFile: TMenuItem;
    MenuHelp: TMenuItem;
    MenuSep1: TMenuItem;
    MenuStart: TMenuItem;
    MenuStop: TMenuItem;
    PageControl1: TPageControl;
    PanelTop: TPanel;
    PopupItems: TPopupMenu;
    ShapeState: TShape;
    SplitterLog: TSplitter;
    TabClients: TTabSheet;
    TabItems: TTabSheet;
    Timer1: TTimer;
    procedure ButtonStartClick(Sender: TObject);
    procedure ButtonStopClick(Sender: TObject);
    procedure CheckLogMessagesChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure GridItemsResize(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure MenuClearLogClick(Sender: TObject);
    procedure MenuCopyNameClick(Sender: TObject);
    procedure MenuCopyValueClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
  private
    FSim: TPlcSim;
    FServer: TAtomSimServer;
    FTicks: Integer;
    FAtoms: Integer;                 // string atoms in the global table
    FSnapFile: string;
    FEndAt: QWord;
    procedure Log(const S: string);
    procedure DoStart;
    procedure DoStop;
    procedure ShowItems;
    procedure ShowClients;
    procedure CountAtoms;
    procedure UpdateControls;
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

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  MaskFPUExceptions;
  LoadIni;
  GridItems.Cells[0, 0] := 'Item';
  GridItems.Cells[1, 0] := 'Value';
  GridItems.Cells[2, 0] := 'Type';
  GridItems.Cells[3, 0] := 'Access';
  GridItems.Cells[4, 0] := 'Subscribers';
  GridClients.Cells[0, 0] := 'Client';
  GridClients.Cells[1, 0] := 'Program';
  GridClients.Cells[2, 0] := 'Window';
  GridClients.Cells[3, 0] := 'Connected';
  GridClients.Cells[4, 0] := 'Messages in';
  GridClients.Cells[5, 0] := 'Messages out';
  GridClients.Cells[6, 0] := 'Subscriptions';
  CountAtoms;
  UpdateControls;
  if CheckAutoStart.Checked or Application.HasOption('start') then
    DoStart;
  if Application.HasOption('snapshot') then
  begin
    FSnapFile := Application.GetOptionValue('snapshot');
    FEndAt := GetTickCount64 + Round(StrToFloatDef(Application.GetOptionValue('after'), 3) * 1000);
  end;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if FSnapFile = '' then SaveIni;      // a test run keeps the user's settings
  DoStop;
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

procedure TMainForm.DoStart;
var
  Err: string;
begin
  if FServer <> nil then Exit;
  if ComboPoints.ItemIndex = 1 then
    FSim := TPlcSim.Create(2)
  else
    FSim := TPlcSim.Create(10);
  FSim.Start;
  FServer := TAtomSimServer.Create(FSim);
  FServer.OnLog := @Log;
  FServer.LogMessages := CheckLogMessages.Checked;
  if not FServer.Start(EditService.Text, Err) then
  begin
    Log('start failed: ' + Err);
    FreeAndNil(FServer);
    FreeAndNil(FSim);
  end
  else
    Log(Format('PLC simulation with %d curve points (Set %d)', [FSim.Points,
      Ord(FSim.Points = 2) + 1]));
  ShowItems;
  UpdateControls;
end;

procedure TMainForm.DoStop;
begin
  if FServer = nil then Exit;
  FServer.Stop;
  FreeAndNil(FServer);
  FreeAndNil(FSim);
  GridItems.RowCount := 1;
  GridClients.RowCount := 1;
  UpdateControls;
end;

procedure TMainForm.ShowItems;
var
  I, N: Integer;
  It: TAItem;
  S: string;
begin
  if FServer = nil then Exit;
  GridItems.BeginUpdate;
  try
    GridItems.RowCount := FServer.ItemCount + 1;
    for I := 0 to FServer.ItemCount - 1 do
    begin
      It := FServer.Item(I);
      GridItems.Cells[0, I + 1] := It.Name;
      if not FServer.Value(It.Name, S) then S := '?';
      GridItems.Cells[1, I + 1] := S;
      GridItems.Cells[2, I + 1] := FServer.TypeText(It);
      GridItems.Cells[3, I + 1] := BoolToStr(It.Writable, 'read / set', 'read');
      N := FServer.SubsOf(It);
      if N > 0 then
        GridItems.Cells[4, I + 1] := IntToStr(N)
      else
        GridItems.Cells[4, I + 1] := '';
    end;
  finally
    GridItems.EndUpdate;
  end;
end;

procedure TMainForm.ShowClients;
var
  I: Integer;
  C: TAClient;
begin
  if FServer = nil then Exit;
  GridClients.BeginUpdate;
  try
    GridClients.RowCount := FServer.ClientCount + 1;
    for I := 0 to FServer.ClientCount - 1 do
    begin
      C := FServer.Client(I);
      GridClients.Cells[0, I + 1] := C.Name;
      GridClients.Cells[1, I + 1] := C.Process;
      GridClients.Cells[2, I + 1] := IntToHex(C.Wnd, 6);
      GridClients.Cells[3, I + 1] := FormatDateTime('hh:nn:ss', C.Since);
      GridClients.Cells[4, I + 1] := IntToStr(C.MsgsIn);
      GridClients.Cells[5, I + 1] := IntToStr(C.MsgsOut);
      GridClients.Cells[6, I + 1] := IntToStr(C.Subs.Count);
    end;
  finally
    GridClients.EndUpdate;
  end;
end;

procedure TMainForm.CountAtoms;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    FAtoms := ListGlobalAtoms(L);
  finally
    L.Free;
  end;
end;

procedure TMainForm.UpdateControls;
var
  Run: Boolean;
begin
  Run := FServer <> nil;
  ButtonStart.Enabled := not Run;
  MenuStart.Enabled := not Run;
  ButtonStop.Enabled := Run;
  MenuStop.Enabled := Run;
  EditService.Enabled := not Run;
  ComboPoints.Enabled := not Run;
  if Run then
  begin
    ShapeState.Brush.Color := clLime;
    LabelState.Caption := Format('running, service %s, window %x', [FServer.Service,
      FServer.WindowHandle]);
  end
  else
  begin
    ShapeState.Brush.Color := clSilver;
    LabelState.Caption := 'stopped';
    LabelStatus.Caption := Format('global atom table: %d string atoms', [FAtoms]);
  end;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  if (FEndAt > 0) and (GetTickCount64 >= FEndAt) then
  begin
    FEndAt := 0;
    ShowItems;
    ShowClients;
    SaveFormSnapshot(Self, FSnapFile);
    Close;
    Exit;
  end;
  Inc(FTicks);
  if FTicks mod 20 = 0 then CountAtoms;
  if FServer = nil then
  begin
    if FTicks mod 20 = 0 then UpdateControls;
    Exit;
  end;
  FServer.Tick;
  if FTicks mod 5 <> 0 then Exit;
  ShowItems;
  ShowClients;
  LabelStatus.Caption := Format('clients %d   messages in %d   out %d   dropped %d   '
    + 'refused %d   global atom table: %d string atoms', [FServer.ClientCount, FServer.MsgsIn,
    FServer.MsgsOut, FServer.Dropped, FServer.Refused, FAtoms]);
end;

{ the Value column takes the width the others leave }
procedure TMainForm.GridItemsResize(Sender: TObject);
var
  I, W: Integer;
begin
  W := GridItems.ClientWidth - 2;
  for I := 0 to GridItems.ColCount - 1 do
    if I <> 1 then Dec(W, GridItems.ColWidths[I]);
  if W > 120 then GridItems.ColWidths[1] := W;
end;

procedure TMainForm.MenuCopyNameClick(Sender: TObject);
begin
  if GridItems.Row > 0 then
    Clipboard.AsText := GridItems.Cells[0, GridItems.Row];
end;

procedure TMainForm.MenuCopyValueClick(Sender: TObject);
begin
  if GridItems.Row > 0 then
    Clipboard.AsText := GridItems.Cells[1, GridItems.Row];
end;

procedure TMainForm.ButtonStartClick(Sender: TObject);
begin
  DoStart;
end;

procedure TMainForm.ButtonStopClick(Sender: TObject);
begin
  DoStop;
end;

procedure TMainForm.CheckLogMessagesChange(Sender: TObject);
begin
  if FServer <> nil then FServer.LogMessages := CheckLogMessages.Checked;
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
  MessageDlg('Atom Server',
    'Simulated HV PLC through Windows global atoms (NLAtom/1), Free Pascal / Lazarus.' +
    LineEnding + LineEnding +
    'Commands: HELLO, ITEMS, GET, SET, SUB, UNSUB, PING, BYE' + LineEnding +
    'Message: <id> GET DB_HMI.VoltAct_kV -> <id> VAL DB_HMI.VoltAct_kV=5.25',
    mtInformation, [mbOK], 0);
end;

function TMainForm.IniName: string;
begin
  Result := ChangeFileExt(Application.ExeName, '.ini');
end;

procedure TMainForm.LoadIni;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(IniName);
  try
    EditService.Text := Ini.ReadString('Server', 'Service', 'NLHV');
    if Ini.ReadInteger('Server', 'Points', 10) = 2 then
      ComboPoints.ItemIndex := 1
    else
      ComboPoints.ItemIndex := 0;
    CheckAutoStart.Checked := Ini.ReadBool('Server', 'AutoStart', False);
    CheckLogMessages.Checked := Ini.ReadBool('Server', 'LogMessages', False);
    Timer1.Interval := Ini.ReadInteger('Server', 'UpdateMs', 100);
  finally
    Ini.Free;
  end;
end;

procedure TMainForm.SaveIni;
var
  Ini: TIniFile;
begin
  try
    Ini := TIniFile.Create(IniName);
    try
      Ini.WriteString('Server', 'Service', EditService.Text);
      if ComboPoints.ItemIndex = 1 then
        Ini.WriteInteger('Server', 'Points', 2)
      else
        Ini.WriteInteger('Server', 'Points', 10);
      Ini.WriteBool('Server', 'AutoStart', CheckAutoStart.Checked);
      Ini.WriteBool('Server', 'LogMessages', CheckLogMessages.Checked);
      Ini.WriteInteger('Server', 'UpdateMs', Timer1.Interval);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      Log('settings not saved: ' + E.Message);
  end;
end;

end.
