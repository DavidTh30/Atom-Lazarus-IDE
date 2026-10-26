{ ============================================================================
  uatomproto - the NLAtom protocol: messages between programs on one PC,
  carried by Windows global atoms (the way DDE passes its names).
    - the server has a message-only window, class NLAtomServer, title =
      service name (NLHV); clients find it with FindWindowEx(HWND_MESSAGE)
    - a client posts  NLAtom.Command.v1  wParam = its window, lParam = atom
      the server posts NLAtom.Reply.v1    wParam = its window, lParam = atom
    - the atom holds one line of text (at most 255 characters):
        <id> <COMMAND> <arguments>         17A2C4.12 GET DB_HMI.VoltAct_kV
        <id> <REPLY> <arguments>           17A2C4.12 VAL DB_HMI.VoltAct_kV=5.25
      the id is <sender window hex>.<counter>; a reply repeats the id of its
      command, an update from a subscription has the id S.<counter>
    - the sender adds the atom (GlobalAddAtom), the receiver reads and deletes
      it (GlobalDeleteAtom); a failed PostMessage deletes it at once, and a
      window that closes deletes the atoms still in its queue. So no atom
      stays in the table, which holds only about 16000 strings for the
      whole session.
    - atoms ignore case and the same text gives the same atom; the unique id
      at the start keeps "SET x=Abc" and "SET x=abc" apart
  Also: TAtomWindow (message-only window), the list of all global atoms.
  ============================================================================ }
unit uatomproto;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils;

const
  ATOM_SERVER_CLASS = 'NLAtomServer';
  ATOM_CLIENT_CLASS = 'NLAtomClient';
  ATOM_PROTOCOL = 'NLAtom/1';
  MAX_ATOM_TEXT = 255;

type
  TAtomMsgEvent = procedure(Msg: UINT; From: HWND; const Text: string) of object;

  { a message-only window that receives the two NLAtom messages }

  TAtomWindow = class
  private
    FHandle: HWND;
    FOnMessage: TAtomMsgEvent;
  public
    constructor Create(const AClass, ATitle: string);
    destructor Destroy; override;
    property Handle: HWND read FHandle;
    property OnMessage: TAtomMsgEvent read FOnMessage write FOnMessage;
  end;

var
  WM_NLATOM_CMD: UINT = 0;
  WM_NLATOM_REPLY: UINT = 0;

{ text -> atom -> PostMessage; False (and no atom left) when it can't be sent }
function PostAtom(ToWnd: HWND; Msg: UINT; FromWnd: HWND; const Text: string): Boolean;
{ the text of an atom from a message, and delete the atom }
function TakeAtom(A: ATOM): string;
function AtomName(A: ATOM): string;
{ <id> <WORD> <rest> }
procedure SplitMessage(const S: string; out Id, Word, Rest: string);
{ every string atom of the global table as "C0A1=text" (hex number = text) }
function ListGlobalAtoms(List: TStrings): Integer;
function WindowProcess(Wnd: HWND): string;
function WindowTitle(Wnd: HWND): string;
{ the windows of every running server (title = service) }
function FindAtomServers(List: TStrings): Integer;
function FindAtomServer(const Service: string): HWND;

implementation

const
  HWND_MESSAGE = HWND(-3);
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

function QueryFullProcessImageNameW(hProcess: THandle; dwFlags: DWORD; lpExeName: PWideChar;
  var lpdwSize: DWORD): BOOL; stdcall; external 'kernel32' name 'QueryFullProcessImageNameW';

var
  Registered: TStringList = nil;

function AtomWndProc(Wnd: HWND; Msg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  W: TAtomWindow;
  S: string;
begin
  if ((Msg = WM_NLATOM_CMD) or (Msg = WM_NLATOM_REPLY)) and (Msg <> 0) then
  begin
    S := TakeAtom(ATOM(lParam));
    W := TAtomWindow(GetWindowLongPtrW(Wnd, GWLP_USERDATA));
    if (W <> nil) and Assigned(W.FOnMessage) then
    try
      W.FOnMessage(Msg, HWND(wParam), S);
    except
      { an error in the handler must not end in the window procedure }
    end;
    Exit(0);
  end;
  Result := DefWindowProcW(Wnd, Msg, wParam, lParam);
end;

{ TAtomWindow }

constructor TAtomWindow.Create(const AClass, ATitle: string);
var
  WC: TWndClassW;
  C, T: UnicodeString;
begin
  C := UTF8Decode(AClass);
  T := UTF8Decode(ATitle);
  if Registered.IndexOf(AClass) < 0 then
  begin
    FillChar(WC, SizeOf(WC), 0);
    WC.lpfnWndProc := @AtomWndProc;
    WC.hInstance := HInstance;
    WC.lpszClassName := PWideChar(C);
    if RegisterClassW(WC) = 0 then
      raise Exception.CreateFmt('RegisterClass %s: %s', [AClass, SysErrorMessage(GetLastError)]);
    Registered.Add(AClass);
  end;
  FHandle := CreateWindowExW(0, PWideChar(C), PWideChar(T), 0, 0, 0, 0, 0, HWND_MESSAGE, 0,
    HInstance, nil);
  if FHandle = 0 then
    raise Exception.Create('CreateWindow: ' + SysErrorMessage(GetLastError));
  SetWindowLongPtrW(FHandle, GWLP_USERDATA, LONG_PTR(Self));
end;

destructor TAtomWindow.Destroy;
var
  M: TMsg;
begin
  if FHandle <> 0 then
  begin
    SetWindowLongPtrW(FHandle, GWLP_USERDATA, 0);
    { atoms of messages nobody will read }
    while PeekMessageW(M, FHandle, WM_NLATOM_CMD, WM_NLATOM_CMD, PM_REMOVE) do
      GlobalDeleteAtom(ATOM(M.lParam));
    while PeekMessageW(M, FHandle, WM_NLATOM_REPLY, WM_NLATOM_REPLY, PM_REMOVE) do
      GlobalDeleteAtom(ATOM(M.lParam));
    DestroyWindow(FHandle);
  end;
  inherited Destroy;
end;

{ ---------------------------------------------------------------- atoms }

function PostAtom(ToWnd: HWND; Msg: UINT; FromWnd: HWND; const Text: string): Boolean;
var
  W: UnicodeString;
  A: ATOM;
begin
  Result := False;
  W := UTF8Decode(Text);
  if (Length(W) = 0) or (Length(W) > MAX_ATOM_TEXT) or (ToWnd = 0) then Exit;
  A := GlobalAddAtomW(PWideChar(W));
  if A = 0 then Exit;                    // atom table full
  Result := PostMessageW(ToWnd, Msg, WPARAM(FromWnd), LPARAM(A));
  if not Result then
    GlobalDeleteAtom(A);                 // queue full or window gone
end;

function AtomName(A: ATOM): string;
var
  Buf: array[0..MAX_ATOM_TEXT] of WideChar;
  N: UINT;
begin
  N := GlobalGetAtomNameW(A, @Buf[0], Length(Buf));
  if N = 0 then Exit('');
  Result := UTF8Encode(Copy(UnicodeString(PWideChar(@Buf[0])), 1, N));
end;

function TakeAtom(A: ATOM): string;
begin
  Result := AtomName(A);
  if Result <> '' then
    GlobalDeleteAtom(A);
end;

procedure SplitMessage(const S: string; out Id, Word, Rest: string);
var
  P: Integer;
begin
  Rest := Trim(S);
  P := Pos(' ', Rest);
  if P = 0 then
  begin
    Id := Rest;
    Word := '';
    Rest := '';
    Exit;
  end;
  Id := Copy(Rest, 1, P - 1);
  Rest := TrimLeft(Copy(Rest, P + 1, MaxInt));
  P := Pos(' ', Rest);
  if P = 0 then
  begin
    Word := UpperCase(Rest);
    Rest := '';
  end
  else
  begin
    Word := UpperCase(Copy(Rest, 1, P - 1));
    Rest := Copy(Rest, P + 1, MaxInt);
  end;
end;

function ListGlobalAtoms(List: TStrings): Integer;
var
  A: Integer;
  S: string;
begin
  List.Clear;
  { string atoms are $C000..$FFFF; integer atoms (#123) are below }
  for A := $C000 to $FFFF do
  begin
    S := AtomName(ATOM(A));
    if S <> '' then
      List.Add(IntToHex(A, 4) + '=' + S);
  end;
  Result := List.Count;
end;

{ ---------------------------------------------------------------- windows }

function WindowProcess(Wnd: HWND): string;
var
  Pid, N: DWORD;
  P: THandle;
  Buf: array[0..MAX_PATH] of WideChar;
begin
  Pid := 0;
  GetWindowThreadProcessId(Wnd, @Pid);
  if Pid = 0 then Exit('?');
  Result := 'pid ' + IntToStr(Pid);
  P := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if P = 0 then Exit;
  try
    N := Length(Buf);
    if QueryFullProcessImageNameW(P, 0, @Buf[0], N) then
      Result := ExtractFileName(UTF8Encode(Copy(UnicodeString(PWideChar(@Buf[0])), 1, N))) +
        ' (' + IntToStr(Pid) + ')';
  finally
    CloseHandle(P);
  end;
end;

function WindowTitle(Wnd: HWND): string;
var
  Buf: array[0..259] of WideChar;
  N: Integer;
begin
  N := GetWindowTextW(Wnd, @Buf[0], Length(Buf));
  Result := UTF8Encode(Copy(UnicodeString(PWideChar(@Buf[0])), 1, N));
end;

function FindAtomServers(List: TStrings): Integer;
var
  W: HWND;
  C: UnicodeString;
begin
  List.Clear;
  C := ATOM_SERVER_CLASS;
  W := 0;
  repeat
    W := FindWindowExW(HWND_MESSAGE, W, PWideChar(C), nil);
    if W <> 0 then
      List.AddObject(WindowTitle(W), TObject(PtrUInt(W)));
  until W = 0;
  Result := List.Count;
end;

function FindAtomServer(const Service: string): HWND;
var
  C, T: UnicodeString;
begin
  C := ATOM_SERVER_CLASS;
  T := UTF8Decode(Service);
  Result := FindWindowExW(HWND_MESSAGE, 0, PWideChar(C), PWideChar(T));
end;

initialization
  Registered := TStringList.Create;
  WM_NLATOM_CMD := RegisterWindowMessageW('NLAtom.Command.v1');
  WM_NLATOM_REPLY := RegisterWindowMessageW('NLAtom.Reply.v1');

finalization
  Registered.Free;
end.
