program AtomClient;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uacmain, uatomcli, uatomproto, ufrmsnap;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Atom Client';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
