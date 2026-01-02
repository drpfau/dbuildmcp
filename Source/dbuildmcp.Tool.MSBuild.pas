unit dbuildmcp.Tool.MSBuild;

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  MCPServer.Tool.Base,
  MCPServer.Types;

type
  TMSBuildParams = class
  private
    FProjectFile: string;
    FBuildType: string;
    FPlatform: string;
    FConfig: string;
    FVerbosity: string;
  public
    [SchemaDescription('Full path to the Delphi project file (.dproj). Use forward slashes (/) in path.')]
    property ProjectFile: string read FProjectFile write FProjectFile;

    [Optional]
    [SchemaDescription('Build type: Build (full rebuild) or Make (incremental). Default: Make')]
    property BuildType: string read FBuildType write FBuildType;

    [Optional]
    [SchemaDescription('Target platform: Win32 or Win64. Default: Win64')]
    property Platform: string read FPlatform write FPlatform;

    [Optional]
    [SchemaDescription('Build configuration: Debug or Release. Default: Debug')]
    property Config: string read FConfig write FConfig;

    [Optional]
    [SchemaDescription('MSBuild verbosity: quiet, normal, or detailed. Default: quiet')]
    property Verbosity: string read FVerbosity write FVerbosity;
  end;

  TMSBuildTool = class(TMCPToolBase<TMSBuildParams>)
  private
    // Settings loaded from ini file
    FBDSPath: string;
    FFrameworkDir: string;
    FDefaultBuildType: string;
    FDefaultPlatform: string;
    FDefaultConfig: string;
    FDefaultVerbosity: string;
    FBuildTimeoutMs: Integer;

    procedure LoadSettings;
    function ExecuteProcess(const ACommandLine, AWorkingDir: string;
      out AOutput: string; out AExitCode: DWORD): Boolean;
  protected
    function ExecuteWithParams(const Params: TMSBuildParams): string; override;
  public
    constructor Create; override;
  end;

implementation

uses
  System.IOUtils,
  System.IniFiles,
  System.StrUtils,
  MCPServer.Registration;

{ TMSBuildTool }

constructor TMSBuildTool.Create;
begin
  inherited;
  FName := 'msbuild';
  FTitle := 'Delphi MSBuild';
  FDescription := 'Build Delphi projects using MSBuild with RAD Studio environment. ' +
    'IMPORTANT: Use forward slashes (/) in file paths, not backslashes.';
  LoadSettings;
end;

procedure TMSBuildTool.LoadSettings;
var
  IniFile: TMemIniFile;
  SettingsPath: string;
begin
  // Set defaults first
  FBDSPath := 'C:\Program Files (x86)\Embarcadero\Studio\37.0';
  FFrameworkDir := 'C:\Windows\Microsoft.NET\Framework\v4.0.30319';
  FDefaultBuildType := 'Make';
  FDefaultPlatform := 'Win64';
  FDefaultConfig := 'Debug';
  FDefaultVerbosity := 'quiet';
  FBuildTimeoutMs := 600000;

  // Load from settings.ini if exists
  SettingsPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'settings.ini');
  if TFile.Exists(SettingsPath) then
  begin
    IniFile := TMemIniFile.Create(SettingsPath);
    try
      FBDSPath := IniFile.ReadString('MSBuild', 'BDSPath', FBDSPath);
      FFrameworkDir := IniFile.ReadString('MSBuild', 'FrameworkDir', FFrameworkDir);
      FDefaultBuildType := IniFile.ReadString('MSBuild', 'DefaultBuildType', FDefaultBuildType);
      FDefaultPlatform := IniFile.ReadString('MSBuild', 'DefaultPlatform', FDefaultPlatform);
      FDefaultConfig := IniFile.ReadString('MSBuild', 'DefaultConfig', FDefaultConfig);
      FDefaultVerbosity := IniFile.ReadString('MSBuild', 'DefaultVerbosity', FDefaultVerbosity);
      FBuildTimeoutMs := IniFile.ReadInteger('MSBuild', 'BuildTimeoutMs', FBuildTimeoutMs);
    finally
      IniFile.Free;
    end;
  end;
end;

function TMSBuildTool.ExecuteProcess(const ACommandLine, AWorkingDir: string;
  out AOutput: string; out AExitCode: DWORD): Boolean;
var
  SecurityAttr: TSecurityAttributes;
  StartupInfo: TStartupInfoW;
  ProcessInfo: TProcessInformation;
  StdOutReadPipe, StdOutWritePipe: THandle;
  Buffer: array[0..4095] of AnsiChar;
  BytesRead: DWORD;
  OutputBuilder: TStringBuilder;
  WaitResult: DWORD;
  CmdLine: string;
begin
  Result := False;
  AOutput := '';
  AExitCode := 0;

  SecurityAttr.nLength := SizeOf(TSecurityAttributes);
  SecurityAttr.bInheritHandle := True;
  SecurityAttr.lpSecurityDescriptor := nil;

  if not CreatePipe(StdOutReadPipe, StdOutWritePipe, @SecurityAttr, 0) then
  begin
    AOutput := 'Error: Failed to create pipe: ' + SysErrorMessage(GetLastError);
    Exit;
  end;

  try
    SetHandleInformation(StdOutReadPipe, HANDLE_FLAG_INHERIT, 0);

    FillChar(StartupInfo, SizeOf(TStartupInfoW), 0);
    StartupInfo.cb := SizeOf(TStartupInfoW);
    StartupInfo.dwFlags := STARTF_USESTDHANDLES or STARTF_USESHOWWINDOW;
    StartupInfo.wShowWindow := SW_HIDE;
    StartupInfo.hStdOutput := StdOutWritePipe;
    StartupInfo.hStdError := StdOutWritePipe;
    StartupInfo.hStdInput := 0;

    FillChar(ProcessInfo, SizeOf(TProcessInformation), 0);

    CmdLine := ACommandLine;
    UniqueString(CmdLine);

    if not CreateProcessW(
      nil,
      PChar(CmdLine),
      nil,
      nil,
      True,
      CREATE_NO_WINDOW,
      nil,
      PChar(AWorkingDir),
      StartupInfo,
      ProcessInfo) then
    begin
      AOutput := 'Error: Failed to create process: ' + SysErrorMessage(GetLastError);
      Exit;
    end;

    try
      CloseHandle(StdOutWritePipe);
      StdOutWritePipe := 0;

      OutputBuilder := TStringBuilder.Create;
      try
        repeat
          BytesRead := 0;
          if ReadFile(StdOutReadPipe, Buffer, SizeOf(Buffer) - 1, BytesRead, nil) and (BytesRead > 0) then
          begin
            Buffer[BytesRead] := #0;
            OutputBuilder.Append(string(AnsiString(Buffer)));
          end;
        until BytesRead = 0;

        AOutput := OutputBuilder.ToString;
      finally
        OutputBuilder.Free;
      end;

      WaitResult := WaitForSingleObject(ProcessInfo.hProcess, FBuildTimeoutMs);
      if WaitResult = WAIT_TIMEOUT then
      begin
        TerminateProcess(ProcessInfo.hProcess, 1);
        AOutput := AOutput + #13#10 + 'Error: Build timed out';
        AExitCode := 1;
      end
      else
        GetExitCodeProcess(ProcessInfo.hProcess, AExitCode);

      Result := True;
    finally
      CloseHandle(ProcessInfo.hProcess);
      CloseHandle(ProcessInfo.hThread);
    end;
  finally
    if StdOutReadPipe <> 0 then
      CloseHandle(StdOutReadPipe);
    if StdOutWritePipe <> 0 then
      CloseHandle(StdOutWritePipe);
  end;
end;

function TMSBuildTool.ExecuteWithParams(const Params: TMSBuildParams): string;
var
  CommandLine: string;
  ProjectDir: string;
  ProjectFile: string;
  BuildType, Platform, Config, Verbosity: string;
  ExitCode: DWORD;
  Output: string;
  Success: Boolean;
begin
  // Convert forward slashes to backslashes for Windows
  ProjectFile := StringReplace(Params.ProjectFile, '/', '\', [rfReplaceAll]);

  // Apply defaults from settings
  if Params.BuildType = '' then
    BuildType := FDefaultBuildType
  else
    BuildType := Params.BuildType;

  if Params.Platform = '' then
    Platform := FDefaultPlatform
  else
    Platform := Params.Platform;

  if Params.Config = '' then
    Config := FDefaultConfig
  else
    Config := Params.Config;

  if Params.Verbosity = '' then
    Verbosity := FDefaultVerbosity
  else
    Verbosity := Params.Verbosity;

  // Validate project file
  if not TFile.Exists(ProjectFile) then
  begin
    Result := Format('ERROR: Project file not found: %s', [ProjectFile]);
    Exit;
  end;

  // Get project directory
  ProjectDir := TPath.GetDirectoryName(TPath.GetFullPath(ProjectFile));

  // Use appropriate rsvars script based on platform
  // Win32: bin\rsvars.bat, Win64: bin64\rsvars64.bat
  if SameText(Platform, 'Win64') then
    CommandLine := Format(
      'cmd.exe /c "call "%s\bin64\rsvars64.bat" && msbuild "%s" /t:%s /p:Platform=%s /p:Config=%s -verbosity:%s"',
      [FBDSPath, ProjectFile, BuildType, Platform, Config, Verbosity])
  else
    CommandLine := Format(
      'cmd.exe /c "call "%s\bin\rsvars.bat" && msbuild "%s" /t:%s /p:Platform=%s /p:Config=%s -verbosity:%s"',
      [FBDSPath, ProjectFile, BuildType, Platform, Config, Verbosity]);

  // Execute
  if ExecuteProcess(CommandLine, ProjectDir, Output, ExitCode) then
  begin
    Success := (ExitCode = 0);
    Result := Format(
      'BUILD %s'#13#10 +
      '==============='#13#10 +
      'Project: %s'#13#10 +
      'BuildType: %s'#13#10 +
      'Platform: %s'#13#10 +
      'Config: %s'#13#10 +
      'ExitCode: %d'#13#10 +
      '==============='#13#10 +
      '%s',
      [IfThen(Success, 'SUCCEEDED', 'FAILED'),
       ProjectFile, BuildType, Platform, Config, ExitCode, Output]);
  end
  else
    Result := 'ERROR: ' + Output;
end;

initialization
  TMCPRegistry.RegisterTool('msbuild',
    function: IMCPTool
    begin
      Result := TMSBuildTool.Create;
    end
  );

end.
