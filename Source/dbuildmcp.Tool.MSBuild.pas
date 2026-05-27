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
    FShowHintsAndWarnings: Boolean;
    FShowHintsAndWarningsProvided: Boolean;
    FGraphviz: Boolean;
    FGraphvizExclude: string;
    FGraphvizOutDir: string;
    procedure SetShowHintsAndWarnings(const Value: Boolean);
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

    [Optional]
    [SchemaDescription('Show hints and warnings in output. Default: false (only errors shown)')]
    property ShowHintsAndWarnings: Boolean read FShowHintsAndWarnings write SetShowHintsAndWarnings;

    // Read-only: excluded from JSON schema and deserialization; tracks whether the caller explicitly provided ShowHintsAndWarnings.
    property ShowHintsAndWarningsProvided: Boolean read FShowHintsAndWarningsProvided;

    [Optional]
    [SchemaDescription('Generate a GraphViz .gv unit-dependency file for each compiled project ' +
      '(passes --graphviz to the Delphi compiler). Default: false')]
    property Graphviz: Boolean read FGraphviz write FGraphviz;

    [Optional]
    [SchemaDescription('Semicolon-separated unit-name wildcards to exclude from the graph ' +
      '(passes --graphviz-exclude). Only used when graphviz is true. ' +
      'Default: System.*;Vcl.*;Winapi.*;Data.*;Soap.*;Xml.*')]
    property GraphvizExclude: string read FGraphvizExclude write FGraphvizExclude;

    [Optional]
    [SchemaDescription('Directory to collect the generated .gv file(s). Use forward slashes (/). ' +
      'Only used when graphviz is true. Default: next to the project.')]
    property GraphvizOutDir: string read FGraphvizOutDir write FGraphvizOutDir;
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
    FDefaultShowHintsAndWarnings: Boolean;
    FBuildTimeoutMs: Integer;

    procedure LoadSettings;
    function ExecuteProcess(const ACommandLine, AWorkingDir: string;
      out AOutput: string; out AExitCode: DWORD): Boolean;
    function FilterOutput(const AOutput, AProjectFile: string;
      AShowHintsAndWarnings, ASuccess, AIsQuiet: Boolean): string;
    function BuildGraphvizArg(const Params: TMSBuildParams): string;
    function FindGraphvizFile(const AProjectDir, AGvName, APlatform, AConfig: string;
      ABuildStart: TDateTime): string;
    function CollectGraphviz(const Params: TMSBuildParams;
      const AProjectDir, AProjectFile, APlatform, AConfig: string;
      ABuildStart: TDateTime; ASuccess: Boolean): string;
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

const
  // System, SysInit and System.Variants are always excluded by dcc regardless.
  DefaultGraphvizExclude = 'System.*;Vcl.*;Winapi.*;Data.*;Soap.*;Xml.*';

{ TMSBuildParams }

procedure TMSBuildParams.SetShowHintsAndWarnings(const Value: Boolean);
begin
  FShowHintsAndWarnings := Value;
  FShowHintsAndWarningsProvided := True;
end;

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
  FDefaultShowHintsAndWarnings := False;
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
      FDefaultShowHintsAndWarnings := IniFile.ReadBool('MSBuild', 'DefaultShowHintsAndWarnings', FDefaultShowHintsAndWarnings);
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

function TMSBuildTool.FilterOutput(const AOutput, AProjectFile: string;
  AShowHintsAndWarnings, ASuccess, AIsQuiet: Boolean): string;
var
  Lines: TStringList;
  FilteredLines: TStringList;
  Line: string;
  ProjectSuffix: string;
  IsHint, IsWarning: Boolean;
  I: Integer;
begin
  // On successful quiet builds there's nothing useful in the output; drop it.
  if ASuccess and AIsQuiet and not AShowHintsAndWarnings then
    Exit('');

  ProjectSuffix := ' [' + AProjectFile + ']';

  Lines := TStringList.Create;
  FilteredLines := TStringList.Create;
  try
    Lines.Text := AOutput;

    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];

      // MSBuild appends " [<full project path>]" to every diagnostic line — we
      // already show Project in the header, so strip it for brevity.
      if EndsText(ProjectSuffix, Line) then
        Line := Copy(Line, 1, Length(Line) - Length(ProjectSuffix));

      if not AShowHintsAndWarnings then
      begin
        IsHint := ContainsText(Line, ': Hinweis ') or ContainsText(Line, ': hint ');
        IsWarning := ContainsText(Line, ': warning W') and not IsHint;
        if IsHint or IsWarning then
          Continue;
      end;

      FilteredLines.Add(Line);
    end;

    Result := TrimRight(FilteredLines.Text);
  finally
    Lines.Free;
    FilteredLines.Free;
  end;
end;

function TMSBuildTool.BuildGraphvizArg(const Params: TMSBuildParams): string;
var
  Exclude: string;
  Switches: string;
begin
  if not Params.Graphviz then
    Exit('');

  Switches := '--graphviz';

  if Params.GraphvizExclude <> '' then
    Exclude := Params.GraphvizExclude
  else
    Exclude := DefaultGraphvizExclude;

  if Exclude <> '' then
    // Escape ';' as %3B so MSBuild does not split the value into separate /p: properties.
    Switches := Switches + ' --graphviz-exclude=' +
      StringReplace(Exclude, ';', '%3B', [rfReplaceAll]);

  Result := Format(' /p:DCC_AdditionalSwitches="%s"', [Switches]);
end;

function TMSBuildTool.FindGraphvizFile(const AProjectDir, AGvName, APlatform,
  AConfig: string; ABuildStart: TDateTime): string;

  procedure Consider(const APath: string; var ABest: string; var ABestTime: TDateTime);
  var
    T: TDateTime;
  begin
    if not TFile.Exists(APath) then
      Exit;
    T := TFile.GetLastWriteTime(APath);
    // Only accept a .gv that was (re)written by this build, not a leftover.
    if (T >= ABuildStart) and (T >= ABestTime) then
    begin
      ABest := APath;
      ABestTime := T;
    end;
  end;

var
  Best: string;
  BestTime: TDateTime;
  Path: string;
begin
  Best := '';
  BestTime := 0;

  // dcc writes <ProjectName>.gv next to the output executable. Check the default
  // exe-output layout (<Platform>\<Config>) and the project directory first.
  Consider(TPath.Combine(TPath.Combine(TPath.Combine(AProjectDir, APlatform), AConfig), AGvName), Best, BestTime);
  Consider(TPath.Combine(AProjectDir, AGvName), Best, BestTime);
  Consider(TPath.Combine(TPath.Combine(AProjectDir, APlatform), AGvName), Best, BestTime);

  if Best <> '' then
    Exit(Best);

  // Fallback for custom DCC_ExeOutput: search the project tree.
  try
    for Path in TDirectory.GetFiles(AProjectDir, AGvName, TSearchOption.soAllDirectories) do
      Consider(Path, Best, BestTime);
  except
    // Ignore enumeration errors (e.g. inaccessible subdirectories).
  end;

  Result := Best;
end;

function TMSBuildTool.CollectGraphviz(const Params: TMSBuildParams;
  const AProjectDir, AProjectFile, APlatform, AConfig: string;
  ABuildStart: TDateTime; ASuccess: Boolean): string;
var
  GvName: string;
  GvSource: string;
  SourceDir: string;
  OutDir: string;
  GvDest: string;
begin
  GvName := ChangeFileExt(ExtractFileName(AProjectFile), '.gv');
  GvSource := FindGraphvizFile(AProjectDir, GvName, APlatform, AConfig, ABuildStart);

  if GvSource = '' then
  begin
    if ASuccess then
      // An incremental (Make) build that recompiled nothing won't emit a .gv.
      Result := GvName + ' (not generated - incremental build may have recompiled nothing; use buildtype=Build)'
    else
      Result := GvName + ' (not generated)';
    Exit;
  end;

  // No target directory requested: leave the file where dcc wrote it.
  if Params.GraphvizOutDir = '' then
    Exit(GvSource);

  OutDir := StringReplace(Params.GraphvizOutDir, '/', '\', [rfReplaceAll]);
  if not TPath.IsPathRooted(OutDir) then
    OutDir := TPath.Combine(AProjectDir, OutDir);
  OutDir := TPath.GetFullPath(OutDir);

  // Already in place.
  SourceDir := TPath.GetDirectoryName(GvSource);
  if SameText(OutDir, SourceDir) then
    Exit(GvSource);

  try
    if not TDirectory.Exists(OutDir) then
      TDirectory.CreateDirectory(OutDir);
    GvDest := TPath.Combine(OutDir, GvName);
    TFile.Copy(GvSource, GvDest, True);
    TFile.Delete(GvSource);
    Result := GvDest;
  except
    on E: Exception do
      Result := GvSource + Format(' (could not move to %s: %s)', [OutDir, E.Message]);
  end;
end;

function TMSBuildTool.ExecuteWithParams(const Params: TMSBuildParams): string;
var
  CommandLine: string;
  MSBuildCmd: string;
  GraphvizArg: string;
  GraphvizInfo: string;
  ProjectDir: string;
  ProjectFile: string;
  BuildType, Platform, Config, Verbosity: string;
  ShowHintsAndWarnings: Boolean;
  ExitCode: DWORD;
  Output: string;
  Success: Boolean;
  BuildStart: TDateTime;
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

  // Use the explicit request value when provided; fall back to the ini default otherwise.
  if Params.ShowHintsAndWarningsProvided then
    ShowHintsAndWarnings := Params.ShowHintsAndWarnings
  else
    ShowHintsAndWarnings := FDefaultShowHintsAndWarnings;

  // Validate project file
  if not TFile.Exists(ProjectFile) then
  begin
    Result := Format('ERROR: Project file not found: %s', [ProjectFile]);
    Exit;
  end;

  // Get project directory
  ProjectDir := TPath.GetDirectoryName(TPath.GetFullPath(ProjectFile));

  // GraphViz: pass --graphviz (+ --graphviz-exclude) to dcc via DCC_AdditionalSwitches.
  // These are raw compiler switches, not native MSBuild flags. Semicolons in the
  // exclude list must be escaped as %3B, otherwise MSBuild's command-line parser
  // treats them as additional /p: property separators.
  GraphvizArg := BuildGraphvizArg(Params);

  // Use appropriate rsvars script based on platform
  // Win32: bin\rsvars.bat, Win64: bin64\rsvars64.bat
  MSBuildCmd := Format('msbuild -nologo "%s" /t:%s /p:Platform=%s /p:Config=%s -verbosity:%s%s',
    [ProjectFile, BuildType, Platform, Config, Verbosity, GraphvizArg]);
  if SameText(Platform, 'Win64') then
    CommandLine := Format('cmd.exe /c "call "%s\bin64\rsvars64.bat" && %s"',
      [FBDSPath, MSBuildCmd])
  else
    CommandLine := Format('cmd.exe /c "call "%s\bin\rsvars.bat" && %s"',
      [FBDSPath, MSBuildCmd]);

  // Record the start time (minus a small tolerance) so we can tell a freshly
  // emitted .gv from a leftover of an earlier build.
  BuildStart := Now - (5 / SecsPerDay);

  // Execute
  if ExecuteProcess(CommandLine, ProjectDir, Output, ExitCode) then
  begin
    Success := (ExitCode = 0);
    Output := FilterOutput(Output, ProjectFile, ShowHintsAndWarnings, Success,
      SameText(Verbosity, 'quiet'));

    // Collect / report the GraphViz .gv file dcc emits next to the project.
    if Params.Graphviz then
      GraphvizInfo := CollectGraphviz(Params, ProjectDir, ProjectFile, Platform,
        Config, BuildStart, Success)
    else
      GraphvizInfo := '';

    Result := Format(
      'BUILD %s'#13#10 +
      '==============='#13#10 +
      'Project: %s'#13#10 +
      'BuildType: %s'#13#10 +
      'Platform: %s'#13#10 +
      'Config: %s'#13#10 +
      'ExitCode: %d',
      [IfThen(Success, 'SUCCEEDED', 'FAILED'),
       ProjectFile, BuildType, Platform, Config, ExitCode]);
    if GraphvizInfo <> '' then
      Result := Result + #13#10 + 'GraphViz: ' + GraphvizInfo;
    if Output <> '' then
      Result := Result + #13#10 + '===============' + #13#10 + Output;
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
