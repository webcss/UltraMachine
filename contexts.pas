unit contexts;

{$mode objfpc}{$H+}
{$modeswitch AdvancedRecords}

interface

uses

 APIHttp,UltraSockets,xtypes,xon;

type

  PContext= ^TContext;
  TContext=record
            private
             FSocket: TAPISocket;

             FRequestMethod: HTTP_Method;
             FRequestURL: String;
             FRequestProtocol: HTTP_Protocol;
             FRequestHost: String;
             FRequestPort: Word;
             FRequestHeaders: XVar;

             FResponse: XVar;

             FBuffer: PUBuffer;
            public
             ResponseCode: Integer;
             procedure Init(ASocket: TSocket);
             procedure Cleanup;
             function ReadBuffer: Integer;
             procedure Send(const Data: AnsiString);
             procedure SendResponse; // send default response in case of error, empty response, or unhandled

             function ParseHTTPHeader: Integer;

             property Buffer: PUBuffer read FBuffer;

             property RequestMethod: HTTP_Method read FRequestMethod;
             property RequestURL: String read FRequestURL;
             property RequestProtocol: HTTP_Protocol read FRequestProtocol;
             property RequestHost: String read FRequestHost;
             property RequestPort: Word read FRequestPort;
             property RequestHeaders: XVar read FRequestHeaders;

             property Response: XVar read FResponse;

  end;

implementation

uses sysutils;

procedure TContext.init(ASocket: TSocket);
begin
 FRequestHeaders:=XVar.New(xtObject,XVar.Null);
 FResponse:=XVar.Null;
 FSocket.Init(ASocket);
 FBuffer:=TUBuffer.Alloc;

 FRequestMethod := mtUnknown;
 FRequestURL := '';
 FRequestProtocol := HTTP10;
 FRequestHost := '';
 FRequestPort := 0;
 ResponseCode:=0;
end;

procedure TContext.Cleanup;
begin
  FSocket.Close;
  FRequestHeaders.Free;
  FResponse.Free;
  FBuffer^.Release;
  FBuffer:=nil;
end;

function TContext.ReadBuffer: Integer; inline;
begin
  Result:=FSocket.RecvPacket(FBuffer,UltraTimeOut);
end;

procedure TContext.Send(const Data: AnsiString);inline;
begin
  FSocket.SendString(Data);
end;

procedure TContext.SendResponse;
begin
  Send(Format('HTTP/1.1 %d %s'#13#10,[ResponseCode,HTTPStatusPhrase(ResponseCode)]));
  Send('Connection: Closed'#1310#13#10);
end;

function TContext.ParseHTTPHeader: Integer;
var StartPos,
         Pos,
          Sz,
         Len: Integer;
         Buf: PChar;

         k,v: string;

function Tokenize(Delimiter: Char): Integer;
begin

 // Skip CRLF
  if Buf[Pos]=#13 then
   begin
     Inc(Pos);
     if Buf[Pos]<>#10 then exit(-1); // wrong char!
     inc(Pos);
     exit(0)
   end;

 // skip leading spaces
  while Buf[Pos]=#32 do
   begin
     Inc(Pos);
     if Len<Pos then exit(-1) // end of string
   end;

  StartPos:=Pos;
  while (Pos<len) do
    if  (Buf[Pos] = #13) or (Buf[pos]=Delimiter) then exit(Pos-StartPos)
                                                 else inc(pos);
  Result:=-1; // end of string
end;

function ParseMethod: HTTP_Method;
var sz: Integer;
begin
 Result := mtUnknown;
 Sz:=Tokenize(#32);
 case Buf[StartPos] of
  'g','G':  if (sz=3) and // GET
              (buf[StartPos+1] in ['e','E']) and
              (buf[StartPos+2] in ['t','T']) then Result := mtGET;

  'p','P': Result := mtPOST;
 end;
 // writeln(format('METHOD: "%s" size %d -> %d',[Copy(Pchar(@Buf[startpos]),0,sz),sz,Result]));
end;

function TokenStr: String;
begin
  if sz<=0 then exit('');
  SetLength(Result,Sz);
  Move(Buf[StartPos],Result[1],Sz);
end;

function KeyValueLn( out Key: String; out Value: String):boolean;
begin
 sz:=Tokenize(':');
 if (sz=0) or (sz=-1) then exit(false);
 Key:=TokenStr;
 inc(Pos);
 sz:=Tokenize(#13);
 if sz=-1 then exit(false);
 Value:=TokenStr;
 inc(pos);
 if (pos>=Len) or (buf[Pos]<>#10) then exit(false);
 inc(pos);
 result:=true;
end;

begin
  Pos:=0;
  StartPos:=0;
  Len:=FBuffer^.Len;
  Buf:=FBuffer^.DataPtr(0);

  FRequestMethod:=ParseMethod; // Method
  if FRequestMethod=mtUnknown then exit (HTTP_BadRequest);

  sz:=Tokenize(#32); //URL
  FRequestURL:=TokenStr;

  sz:=Tokenize(#32); // HTTP Version

  if sz<>8 then FRequestProtocol:=HTTPUnknown
   else if (Buf[StartPos+5]='1') and (Buf[StartPos+7]='0') then FRequestProtocol:=HTTP10
     else if (Buf[StartPos+5]='1') and (Buf[StartPos+7]='1') then FRequestProtocol:=HTTP11
      else if (Buf[StartPos+5]='2') and (Buf[StartPos+7]='0') then FRequestProtocol:=HTTP20
       else FRequestProtocol:=HTTPUnknown;

  if FRequestProtocol<>HTTP11 then exit(HTTP_VersionNotSupported);

  Tokenize(#32);// skip first line crlf

  while KeyValueLn(k,v) do RequestHeaders.Add(xtString,k).AsString:=v;

  if Pos<=Len then Result:=HTTP_ERROR_NONE
             else Result:=HTTP_ERROR_PARTIAL;
end;

end.

