{ Backend Singleton}
unit UltraBackend;

{$mode objfpc}{$H+}
{$modeswitch AdvancedRecords}

interface

uses
  Sockets,
  UltraSockets,
  UltraContext,
  UltraApp,
  PtrVectors,
  xon,
  ultrabuffers,
  UltraHttp;

  procedure  UltraStart(const Config: String);
  procedure  UltraStop;
  function   UltraRunning: boolean;
  function   UltraThreadsCount: Integer;
  function   UltraThread: TThreadID;

  function UltraAddApp( App: TUltraApp):boolean;


implementation

uses sysutils,UltraParser;

type
  PWorker = ^TWorker;
  TWorker=record
             private
              FInitialized: Boolean;
              FId: TThreadID;
              FEvent: PRTLEvent;
              FKeepRunning: Boolean;
              FPersistent: Boolean;
              FNextSocket: TSocket;
              FReturnCode: Integer;
              procedure Cleanup;
              function GetRunning: Boolean;
              function GetWillStop: Boolean;
             public
              procedure Init(isPersistent:Boolean=false);
              procedure Start;
              function Graceful:boolean;
              function NextRequest(ASocket: TSocket): boolean;
              property WillStop: Boolean read GetWillStop;
              property Running: Boolean read GetRunning;
              property Initialized: boolean read FInitialized;
              property Id: TThreadID read FId;
   end;




var

 // Config Vars
    FListenPort: Word = 9000;

    MaxThreads: Integer = 16;

    MaxPersistentThreads: Integer = 0;


// Runtime Vars

  FWorkers: PWorker;

  FCurrentWorker: Integer;

  FThreadCount: Integer =0;

  FBackendThread: TThreadID =0;

  FMustStop : boolean;

  FApps: PtrVector;

// Worker Threads
 procedure TWorker.Init(isPersistent:Boolean=false);
 begin
   if FInitialized then exit;
   FInitialized:=true;
   FKeepRunning:=true;
   FId:=0;
   FEvent:=RTLEventCreate;
   FPersistent:=isPersistent;
   FNextSocket:=INVALID_SOCKET;
   FReturnCode:=0;
 end;

 procedure TWorker.Cleanup;
 begin
   if Not FInitialized then exit;
   FId:=0;
   FKeepRunning:=false;
   RTLeventdestroy(FEvent);
   FInitialized:=false; //now we can recycle the thread
   FReturnCode:=0;
   FNextSocket:=INVALID_SOCKET;
 end;

 function TWorker.GetRunning:boolean;inline;
 begin
   Result:= FInitialized and (FId<>0);
 end;

 function TWorker.GetWillStop:boolean;
 begin
   Result:= (not FInitialized) or (not FKeepRunning);
 end;


 function TWorker.Graceful:boolean;
 begin
    if not FInitialized then exit(false);
    FKeepRunning:=False;
    RTLeventSetEvent(FEvent); // wakeup if sleeping!
    Result:=True;
 end;

 function TWorker.NextRequest(ASocket: TSocket):boolean;
 begin
   // push only if new requests are accepted and no other is pending
   if WillStop  or
      (InterlockedCompareExchange(FNextSocket,ASocket,INVALID_SOCKET)<>INVALID_SOCKET) then exit(false);
   Writeln(format('Post  socket %d! to thread %d',[ASocket,Id]));
   RTLeventSetEvent(FEvent); // wake up and go to work!
   Result:=True;
 end;


function FindApp(const AName: String; AVersion: Integer): TUltraApp;
var i: PtrUInt;
begin
 Result:=nil;
 if FApps.Count=0 then exit;
 for i:=0 to FApps.Count-1 do
   begin
    Result:=TUltraApp(FApps[i]);
    if (Result.Name=AName) and (Result.Version=AVersion) then exit;
   end;
 Result:=nil;
end;

 function WarpRun(Instance: Pointer): Integer;
 var
     App: TUltraApp;

     Context: TUltraContext;
 begin
 Result:=0;
 TUltraBuffer.InitializeBuffers;
 with TWorker(Instance^) do begin
   InterLockedIncrement(FThreadCount);
   //Writeln(format('Starting thread %d',[FId]));
   repeat //  thread loop - we run this anleast once
        //at this point we have notning to do and are going to sleep till next request comes... zzzz
        // if the event was set to mark a new request (NextSocket<>0) the wait will return asap
        if FPersistent then RTLeventWaitFor(FEvent) // persistent thread sleeps forever
                       else RTLeventWaitFor(FEvent,1000); // other waits only 1 sec between requests

        // okay we got the event ... reset it for the future loops
        RTLeventResetEvent(FEvent);

        // good morning! new request is pending?


        if FNextSocket<>INVALID_SOCKET then
                 begin
                 Context.Prepare(FNextSocket,@FKeepRunning);
                 App:=nil;
                      try
                         Context.Response.Code:=ParseHTTPRequest(Context.Buffer^,Context.Request);
                         if Context.Response.Code=HTTP_ERROR_NONE then
                           begin
                             App:=FindApp(Context.Request.Path[1].AsString,Context.Request.APIVersion);
                             if (App<>nil) and (App.Key=Context.Request.Headers[HEADER_API_KEY].AsString)
                                then App.HandleRequest(Context)
                                else Context.Response.Code:=HTTP_NotFound;
                           end
                       finally
                         if not Context.isHandled then Context.SendErrorResponse;
                         Context.Cleanup;
                         FNextSocket:=INVALID_SOCKET;
                       end;

                 end
         else
           if not FPersistent then break; // no.. we just woke up by timeout or by gracefull exit
      until not FKeepRunning;
      //writeln(format('thread %d is stopping.',[FId]));
      Result:=FReturnCode;
      Cleanup; //at this point we are exiting the threadfunc
      TUltraBuffer.FinalizeBuffers;
      InterLockedDecrement(FThreadCount);
     end
 end;

 procedure TWorker.Start;
 begin
   if Initialized then BeginThread(@WarpRun,@Self,FId);
 end;

 // Backend

function BackendDispachRequest(NewSocket: TSocket):boolean;forward;

function UltraRunning: boolean;
 begin
   result:=FBackendThread<>0;
 end;

function BackendGraceful:integer;
var i:Integer;
begin
  Result:=0;
  if FThreadCount=0 then exit;
  for i:=0 To MaxThreads-1 do
    if FWorkers[i].Graceful then inc(Result);
end;

 function BackendRun(Params: Pointer): Integer;
var FPort: TApiSocket;
    NewSocket: TSocket;
    sock: TApiSocket;
    var i: PtrUInt;
begin
 FPort.Init( fpSocket(AF_INET, SOCK_STREAM, 0));
 FPort.Bind(FListenPort, 100);
 sock.Init;
 if FPort.Error = 0 then
 while not FMustStop do
  begin
        NewSocket := FPort.Accept(1000);
        if NewSocket <> 0 then BackendDispachRequest(NewSocket);
  end;
 FPort.Close;
 While BackendGraceful>0 do;
 Result:=0;
 FBackendThread:=00;
 FreeMem(FWorkers);
 if FApps.Count>0 then
   for i:=0 to FApps.Count-1 do TUltraApp(FApps[i]).free;
 FApps.Finalize;
end;

 procedure UltraStart(const Config: String);
 var i,sz: Integer;
 begin
   if UltraRunning then exit;
   sz:=MaxThreads*SizeOf(TWorker);
   GetMem(FWorkers,sz);
   FillByte(FWorkers^,Sz,0);
   for i:=0 to MaxPersistentThreads do
     with FWorkers[i] do
       begin
         Init(true);
         Start;
       end;
   FCurrentWorker:=0;
   FMustStop:=False;
   BeginThread(@BackendRun,nil,FBackendThread);
 end;

 procedure  UltraStop;
 begin
    FMustStop:=True;
 end;

 function BackendDispachRequest(NewSocket: TSocket):boolean;
 var StartWorker: Integer;
     DummySock: TApiSocket;
 begin
   if not UltraRunning then exit(false);
   StartWorker:=FCurrentWorker;
    repeat
     write(format('testing worker %d...',[FCurrentWorker]));
     with FWorkers[FCurrentWorker]  do
     begin
     if not Initialized then
      begin
        Init(False);
        Start;
      end;
     if NextRequest(NewSocket) then
      begin
       writeln(format('%d Running Threads',[FThreadCount,Id]));
       exit(true);
      end else inc(FCurrentWorker);
      writeln('nope!');
     if FCurrentWorker>MaxThreads-1 then FCurrentWorker:=0
     end;
    until FCurrentWorker=StartWorker;
    DummySock.Init(NewSocket);
    if  DummySock.CanRead(UltraTimeOut) then DummySock.Purge;
    DummySock.Send(Format('HTTP/1.1 %d %s'#13#10,[HTTP_BadGateway,HTTPStatusPhrase(HTTP_BadGateway)]));
    DummySock.Send('Connection: Closed'#13#10#13#10);
    DummySock.Close;
    Writeln(format('!!!!!!!!!!!!!!droping request on socket [%d]!',[NewSocket]));
   Result:=false;
 end;

function UltraThreadsCount: Integer;inline;
begin
 Result := FThreadCount;
end;

function UltraThread: TThreadID;inline;
begin
 Result:=FBackendThread;
end;

function UltraAddApp(App: TUltraApp): boolean;
begin
 if FindApp(App.Name,App.Version)<>nil then exit(false);
 FApps.Push(App);
 Result:=True;
end;

initialization
 FApps.Initialize(16,16);
finalization
 UltraStop;
end.
