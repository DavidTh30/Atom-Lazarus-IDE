program AtomServer;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Forms, uatmain, uatomproto, uatomsrv, ufrmsnap;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Atom Server';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
