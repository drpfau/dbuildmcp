unit dbuildmcp.ConsoleLog;

// Concise, glanceable console activity output for the MCP server.
//
// Taps TLogger.OnLogMessage (which fires independently of the logger's own
// console output, and under the logger lock so it is thread-safe) and prints
// one short colored line per incoming JSON-RPC request - the method name, plus
// the tool name for tools/call - instead of the full request/response bodies.

interface

procedure InstallConsoleActivityLog;

implementation

uses
  System.SysUtils,
  System.JSON,
  Winapi.Windows,
  MCPServer.Logger;

const
  COLOR_GRAY   = 7;
  COLOR_GREEN  = 10;
  COLOR_CYAN   = 11;
  COLOR_YELLOW = 14;
  COLOR_RED    = 12;

  REQUEST_MARKER = 'Request: ';

procedure WriteColoredLine(const AText: string; AColor: Word);
var
  H: THandle;
  Info: TConsoleScreenBufferInfo;
  Saved: Word;
begin
  H := GetStdHandle(STD_OUTPUT_HANDLE);
  if GetConsoleScreenBufferInfo(H, Info) then
    Saved := Info.wAttributes
  else
    Saved := COLOR_GRAY;
  SetConsoleTextAttribute(H, AColor);
  try
    Writeln(AText);
  finally
    SetConsoleTextAttribute(H, Saved);
  end;
end;

function ColorForMethod(const AMethod: string): Word;
begin
  if AMethod = 'tools/call' then
    Result := COLOR_CYAN
  else if AMethod.StartsWith('initialize') or AMethod.StartsWith('notifications') then
    Result := COLOR_GREEN
  else
    Result := COLOR_GRAY;
end;

procedure ReportRequestObject(const AObj: TJSONObject);
var
  MethodValue, ParamsValue, NameValue: TJSONValue;
  Method, ToolName, Line: string;
begin
  MethodValue := AObj.GetValue('method');
  if not Assigned(MethodValue) then
    Exit; // A response/result, not a request - nothing to report.

  Method := MethodValue.Value;
  ToolName := '';

  if Method = 'tools/call' then
  begin
    ParamsValue := AObj.GetValue('params');
    if ParamsValue is TJSONObject then
    begin
      NameValue := TJSONObject(ParamsValue).GetValue('name');
      if Assigned(NameValue) then
        ToolName := NameValue.Value;
    end;
  end;

  Line := FormatDateTime('hh:nn:ss', Now) + '  ' + Method;
  if ToolName <> '' then
    Line := Line + ' -> ' + ToolName;

  WriteColoredLine(Line, ColorForMethod(Method));
end;

procedure ReportRequestBody(const ABody: string);
var
  Value, Item: TJSONValue;
begin
  Value := nil;
  try
    try
      Value := TJSONObject.ParseJSONValue(ABody);
    except
      Value := nil; // Ignore malformed bodies.
    end;

    if Value is TJSONObject then
      ReportRequestObject(TJSONObject(Value))
    else if Value is TJSONArray then
      for Item in TJSONArray(Value) do
        if Item is TJSONObject then
          ReportRequestObject(TJSONObject(Item));
  finally
    Value.Free;
  end;
end;

procedure HandleLogMessage(const ALine: string);
var
  P: Integer;
begin
  // Surface problems prominently; keep everything else to a single request line.
  if Pos('[ERROR]', ALine) > 0 then
    WriteColoredLine(ALine, COLOR_RED)
  else if Pos('[WARN', ALine) > 0 then
    WriteColoredLine(ALine, COLOR_YELLOW)
  else
  begin
    P := Pos(REQUEST_MARKER, ALine);
    if P > 0 then
      ReportRequestBody(Copy(ALine, P + Length(REQUEST_MARKER), MaxInt));
  end;
end;

procedure InstallConsoleActivityLog;
begin
  TLogger.MinLogLevel := TLogLevel.Info;
  TLogger.OnLogMessage :=
    procedure(const Message: string)
    begin
      HandleLogMessage(Message);
    end;
end;

end.
