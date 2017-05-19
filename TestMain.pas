unit TestMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ActnList, Menus;

type

  { TForm1 }

  TForm1 = class(TForm)
    ActionList1: TActionList;
    GroupBox1: TGroupBox;
    MainMenu1: TMainMenu;
    MainMenu2: TMainMenu;
    Memo1: TMemo;
    Memo3: TMemo;
    StartAction: TAction;
    StartBackendBTN: TButton;
    StopAction: TAction;
    StopBackendBTN: TButton;
    procedure StartActionExecute(Sender: TObject);
    procedure StartActionUpdate(Sender: TObject);
    procedure StopActionExecute(Sender: TObject);
    procedure StopActionUpdate(Sender: TObject);
  private
    { private declarations }
  public
    { public declarations }
  end;

var
  Form1: TForm1;

implementation
uses UltraSockets,UltraContext,UltraApp,UltraBackend;

{$R *.lfm}

type


     TMyApp=class (TUltraApp)
       public
         function HandleRequest(var AContext: TContext): TBaseHandler; override;
     end;

     MyModule=class (TBaseHandler)
                    public
                      procedure HandleRequest;override;
                    end;


var
    RespStr: String ='';

    MyApp: TMyApp;

function TMyApp.HandleRequest(var AContext: TContext): TBaseHandler;
begin
  Result:=MyModule.Create(AContext);
end;

procedure MyModule.HandleRequest;
var i: integer;
begin
  Form1.Memo1.Lines.BeginUpdate;
  Form1.Memo1.Lines.Clear;
 Form1.Memo1.Lines.Add(format('Processing request in thread %d -->"%s"',[GetCurrentThreadId,Copy(Pchar(Context^.Buffer^.DataPtr(0)),0,Context^.Buffer^.Len)]));
 Form1.Memo1.Lines.Add(format('Method:%d',[Context^.RequestMethod]));
 Form1.Memo1.Lines.Add(format('Version:%d',[Context^.RequestProtocol]));
  with Context^.RequestHeaders do for i:=0 to Count-1 do
   Form1.Memo1.Lines.Add(format('Header: "%s:%s"',[Keys[i].AsString,Vars[i].AsString]));
  Form1.Memo1.Lines.EndUpdate;
  RespStr:=Form1.Memo3.Lines.Text;
  Context^.Send(RespStr+#13#10);
end;

{ TForm1 }
procedure TForm1.StartActionExecute(Sender: TObject);
begin
  MyApp:=TMyApp.Create('myapp');
  UltraAddApp(MyApp);
  UltraStart('');
  GroupBox1.Caption:=format('Backend running [%d]',[UltraThread]);
end;



procedure TForm1.StartActionUpdate(Sender: TObject);
begin
  (Sender as TAction).Enabled:= not UltraRunning;
end;

procedure TForm1.StopActionExecute(Sender: TObject);
begin
  UltraStop;
  GroupBox1.Caption:=format('Backend Stopped',[UltraThread]);
end;

procedure TForm1.StopActionUpdate(Sender: TObject);
begin
  with (Sender as TAction) do
   begin
     Enabled:= UltraRunning;
     Caption:=format('Stop [%d]',[UltraThreadsCount]);
   end;
end;
end.

