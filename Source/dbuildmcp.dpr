program dbuildmcp;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MCPServer.Types,
  MCPServer.IdHTTPServer,
  MCPServer.Settings,
  MCPServer.ManagerRegistry,
  MCPServer.CoreManager,
  MCPServer.ToolsManager,
  MCPServer.ResourcesManager,
  dbuildmcp.ConsoleLog in 'dbuildmcp.ConsoleLog.pas',
  dbuildmcp.Tool.MSBuild in 'dbuildmcp.Tool.MSBuild.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;

begin
  Writeln('nxmcp - Delphi MSBUILD MCP Server');
  Writeln('==========================');
  Writeln;

  Writeln('Reading settings.ini');
  Writeln;
  Settings := TMCPSettings.Create;
  try

    ManagerRegistry := TMCPManagerRegistry.Create;
    ManagerRegistry.RegisterManager(TMCPCoreManager.Create(Settings));
    ManagerRegistry.RegisterManager(TMCPToolsManager.Create);
    ManagerRegistry.RegisterManager(TMCPResourcesManager.Create);

    // Print a concise, color-coded line per incoming request so the console
    // can be glanced at to confirm the server is being used.
    InstallConsoleActivityLog;

    Server := TMCPIdHTTPServer.Create(nil);
    try
      Server.Settings := Settings;
      Server.ManagerRegistry := ManagerRegistry;
      Server.Start;

      Writeln('MCP Server running on http://', Settings.Host, ':', Settings.Port, Settings.Endpoint);
      Writeln;
      Writeln('Activity (time  method [-> tool]):');
      Writeln('Press ENTER to stop...');
      Writeln;
      Readln; // Keep running

      Server.Stop;
    finally
      Server.Free;
    end;
  finally
    Settings.Free;
  end;
end.
