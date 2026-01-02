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
  dbuildmcp.Tool.MSBuild in 'dbuildmcp.Tool.MSBuild.pas';

var
  Server: TMCPIdHTTPServer;
  Settings: TMCPSettings;
  ManagerRegistry: IMCPManagerRegistry;

begin
  Settings := TMCPSettings.Create;
  try
    ManagerRegistry := TMCPManagerRegistry.Create;
    ManagerRegistry.RegisterManager(TMCPCoreManager.Create(Settings));
    ManagerRegistry.RegisterManager(TMCPToolsManager.Create);
    ManagerRegistry.RegisterManager(TMCPResourcesManager.Create);

    Server := TMCPIdHTTPServer.Create(nil);
    try
      Server.Settings := Settings;
      Server.ManagerRegistry := ManagerRegistry;
      Server.Start;

      Writeln('MCP Server running on port ', Settings.Port);
      Writeln;
      Writeln('Press ENTER to stop...');
      Readln; // Keep running

      Server.Stop;
    finally
      Server.Free;
    end;
  finally
    Settings.Free;
  end;
end.
