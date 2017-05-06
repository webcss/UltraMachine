{ Backend Singleton}
unit UltraBackend;

{$mode objfpc}{$H+}
{$modeswitch AdvancedRecords}

interface

uses
  Sockets,
  UltraSockets,
  Contexts,
  UltraHandlers;


const

  Max_Workers=16;

  procedure  UltraStart(const Config: String);
  procedure  BackendStop;
  function   BackendRunning: boolean;
  function   BackendThreadsCount: Integer;
  function   BackendThread: TThreadID;

type

  TRouteResolver = function ( var AContext : TContext ) : THandlerClass;

  function GetRouteResolver: TRouteResolver;

  procedure SetRouteResolver( AResolver: TRouteResolver );

implementation

uses sysutils,xtypes,xon,APIHttp;

type


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

  TWorkersArray= array [00..Max_Workers] of TWorker;


var

 // Config Vars
    FListenPort: Word = 9000;


// Runtime Vars


  RouteResolver: TRouteResolver =nil;

  FWorkers: TWorkersArray;

  FCurrenrWorker: Integer;

  FThreadCount: Integer =0;

  FBackendThread: TThreadID =0;

  FMustStop : boolean;

// Worker Threads
 procedure TWorker.Init(isPersistent:Boolean=false);
 begin
   if FInitialized then exit;
   FInitialized:=true;
   FKeepRunning:=false;
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
   //Writeln(format('Post  socket %d! to thread %d',[ASocket,Id]));
   RTLeventSetEvent(FEvent); // wake up and go to work!
   Result:=True;
 end;


 function WarpRun(Instance: Pointer): Integer;
 var
     HandlerClass: THandlerClass;
      ResolveProc: TRouteResolver;
                H: TBaseHandler;

     Context: TContext;
 begin
 Result:=0;
 H:=nil;
 InitBuffers;
 with TWorker(Instance^) do begin
   InterLockedIncrement(FThreadCount);
   FKeepRunning:=true;
   //Writeln(format('Starting thread %d',[FId]));
   repeat // main thread loop - we run this anleast once
        //at this point we have notning to do and are going to sleep till next request comes... zzzz
        // if the event was set to mark a new request (Socket<>0) the wait will return asap
        if FPersistent then RTLeventWaitFor(FEvent) // persistent thread sleeps forever
                       else RTLeventWaitFor(FEvent,1000); // other waits only 1 sec between requests

        // okay we got the event ... reset it for the future loops
        RTLeventResetEvent(FEvent);

        // good morning! new request is pending?
        if FNextSocket<>INVALID_SOCKET then
                 begin
                 Context.Init(FNextSocket);
                  FNextSocket:=INVALID_SOCKET;
                      try
                         if Context.ReadBuffer<>-1 then
                              Context.ResponseCode:=Context.ParseHTTPHeader;
                         if Context.ResponseCode=HTTP_ERROR_NONE then
                           begin
                            ResolveProc:=GetRouteResolver;
                            HandlerClass:= ResolveProc(Context);
                            if HandlerClass<>nil then
                              begin
                               H:=HandlerClass.Create(Context);
                               H.HandleRequest // no error so far;
                              end
                            end
                           else Context.SendResponse;
                       finally
                         FreeAndNil(H);
                         Context.Cleanup;
                       end;
                 end
         else
           if not FPersistent then break; // no.. we just woke up by timeout or by gracefull exit
      until not FKeepRunning;
      //writeln(format('thread %d is stopping.',[FId]));
      Result:=FReturnCode;
      Cleanup; //at this point we are exiting the threadfunc
      ReleaseBuffers;
      InterLockedDecrement(FThreadCount);
     end
 end;

 procedure TWorker.Start;
 begin
   if Initialized then BeginThread(@WarpRun,@Self,FId);
 end;

 // Backend

function GetRouteResolver: TRouteResolver;inline;
begin
  Result:=RouteResolver;
end;

procedure SetRouteResolver( AResolver: TRouteResolver );
begin
  if RouteResolver=nil then RouteResolver:=AResolver;
end;

function BackendPostRequest(NewSocket: TSocket):boolean;forward;

function BackendRunning: boolean;
 begin
   result:=FBackendThread<>0;
 end;

function BackendGraceful:integer;
var i:Integer;
begin
  Result:=0;
  if FThreadCount=0 then exit;
  for i:=0 To Max_Workers-1 do
    if FWorkers[i].Graceful then inc(Result);
end;

 function BackendRun(Params: Pointer): Integer;
var FPort: TApiSocket;
    NewSocket: TSocket;
    sock: TApiSocket;
begin
 FPort.Init( fpSocket(AF_INET, SOCK_STREAM, 0));
 FPort.Bind(FListenPort, 100);
 sock.Init;
 if FPort.Error = 0 then
 while not FMustStop do
  begin
        NewSocket := FPort.Accept(1000);
        if NewSocket <> 0 then BackendPostRequest(NewSocket);
  end;
 FPort.Close;
 While BackendGraceful>0 do;
 Result:=0;
 FBackendThread:=00;
end;

 procedure UltraStart(const Config: String);
 var i: Integer;
 begin
   if BackendRunning then exit;
   FillByte(FWorkers,SizeOf(FWorkers),0);
   for i:=0 to (Max_Workers+1) div 2 do
     with FWorkers[i] do
       begin
         Init(true);
         Start;
       end;
   FCurrenrWorker:=0;
   FMustStop:=False;
   BeginThread(@BackendRun,nil,FBackendThread);
 end;



 procedure  BackendStop;
 begin
    FMustStop:=True;
 end;

 function BackendPostRequest(NewSocket: TSocket):boolean;
 var i: Integer;
 begin
   if not BackendRunning then exit(false);
   i:=FCurrenrWorker;
    repeat
     //writeln(format('...testing worker %d',[FCurrenrWorker]));
     with FWorkers[FCurrenrWorker]  do
     begin
     if not Initialized then
      begin
        Init(False);
        Start;
      end;
     if NextRequest(NewSocket) then
      begin
       //  writeln(format('idle worker %d found [%d]',[FCurrenrWorker,Id]));
       exit(true);
      end else inc(FCurrenrWorker);
     if FCurrenrWorker>=Max_Workers then FCurrenrWorker:=0
     end;
    until i=FCurrenrWorker;
    Writeln(format('!!!!!!!!!!!!!!droping request on socket [%d]!',[NewSocket]));
   Result:=false;
 end;

function BackendThreadsCount: Integer;inline;
begin
 Result := FThreadCount;
end;

function   BackendThread: TThreadID;inline;
begin
 Result:=FBackendThread;
end;

initialization
finalization
 BackendStop
end.

