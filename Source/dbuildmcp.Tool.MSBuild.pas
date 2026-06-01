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
    FMaxErrors: Integer;
    FMaxErrorsProvided: Boolean;
    procedure SetShowHintsAndWarnings(const Value: Boolean);
    procedure SetMaxErrors(const Value: Integer);
  public
    [SchemaDescription('Path to the .dproj (forward slashes).')]
    property ProjectFile: string read FProjectFile write FProjectFile;

    [Optional]
    [SchemaDescription('Build (rebuild) or Make (incremental). Default Make.')]
    property BuildType: string read FBuildType write FBuildType;

    [Optional]
    [SchemaDescription('Win32 or Win64. Default Win64.')]
    property Platform: string read FPlatform write FPlatform;

    [Optional]
    [SchemaDescription('Debug or Release. Default Debug.')]
    property Config: string read FConfig write FConfig;

    [Optional]
    [SchemaDescription('quiet, normal, or detailed. Default quiet.')]
    property Verbosity: string read FVerbosity write FVerbosity;

    [Optional]
    [SchemaDescription('Show hints/warnings (else errors only). Default false.')]
    property ShowHintsAndWarnings: Boolean read FShowHintsAndWarnings write SetShowHintsAndWarnings;

    // Read-only: excluded from JSON schema and deserialization; tracks whether the caller explicitly provided ShowHintsAndWarnings.
    property ShowHintsAndWarningsProvided: Boolean read FShowHintsAndWarningsProvided;

    [Optional]
    [SchemaDescription('Emit a GraphViz .gv unit-dependency file (dcc --graphviz). Default false.')]
    property Graphviz: Boolean read FGraphviz write FGraphviz;

    [Optional]
    [SchemaDescription('Unit wildcards to exclude, ;-separated (graphviz only). ' +
      'Default: System.*;Vcl.*;Winapi.*;Data.*;Soap.*;Xml.*')]
    property GraphvizExclude: string read FGraphvizExclude write FGraphvizExclude;

    [Optional]
    [SchemaDescription('Dir to collect the .gv, forward slashes (graphviz only). Default: next to project.')]
    property GraphvizOutDir: string read FGraphvizOutDir write FGraphvizOutDir;

    [Optional]
    [SchemaDescription('Max error lines on failure; 1=first only, 0=all. Default 10.')]
    property MaxErrors: Integer read FMaxErrors write SetMaxErrors;

    // Read-only: excluded from JSON schema; tracks whether MaxErrors was explicitly provided.
    property MaxErrorsProvided: Boolean read FMaxErrorsProvided;
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
    FDefaultMaxErrors: Integer;
    FDefaultMaxHintsWarnings: Integer;
    FMaxOutputLines: Integer;

    procedure LoadSettings;
    function IsErrorLine(const ALine: string): Boolean;
    function CapTotalLines(const AText: string; AMaxLines: Integer): string;
    function ExecuteProcess(const ACommandLine, AWorkingDir: string;
      out AOutput: string; out AExitCode: DWORD): Boolean;
    function FilterOutput(const AOutput, AProjectFile: string;
      AShowHintsAndWarnings, ASuccess, AIsQuiet: Boolean;
      AMaxErrors, AMaxHintsWarnings, AMaxOutputLines: Integer): string;
    function BuildGraphvizArg(const Params: TMSBuildParams): string;
    function WrapWithRsvars(const APlatform, AMSBuildArgs: string): string;
    function ResolveExeOutputDir(const AProjectFile, AProjectDir, APlatform,
      AConfig: string): string;
    function FindGraphvizFile(const AProjectDir, AExeOutDir, AGvName, APlatform,
      AConfig: string; ABuildStart: TDateTime): string;
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

procedure TMSBuildParams.SetMaxErrors(const Value: Integer);
begin
  FMaxErrors := Value;
  FMaxErrorsProvided := True;
end;

{ TMSBuildTool }

constructor TMSBuildTool.Create;
begin
  inherited;
  FName := 'msbuild';
  FTitle := 'Delphi MSBuild';
  FDescription := 'Build a Delphi .dproj with MSBuild (RAD Studio). Use forward slashes in paths.';
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
  FDefaultMaxErrors := 10;
  FDefaultMaxHintsWarnings := 30;
  FMaxOutputLines := 200;

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
      FDefaultMaxErrors := IniFile.ReadInteger('MSBuild', 'DefaultMaxErrors', FDefaultMaxErrors);
      FDefaultMaxHintsWarnings := IniFile.ReadInteger('MSBuild', 'DefaultMaxHintsWarnings', FDefaultMaxHintsWarnings);
      FMaxOutputLines := IniFile.ReadInteger('MSBuild', 'MaxOutputLines', FMaxOutputLines);
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

function TMSBuildTool.IsErrorLine(const ALine: string): Boolean;
begin
  // MSBuild surfaces dcc diagnostics in its canonical "file(line,col): error CODE:"
  // form (category in English even on a German MSBuild — cf. ": warning W" below).
  // German fallbacks are belt-and-suspenders; missing a match only means the line
  // is treated as ordinary text and therefore kept, never hidden.
  Result := ContainsText(ALine, ': error ')
         or ContainsText(ALine, ': fatal error ')
         or ContainsText(ALine, ': Fehler ')
         or ContainsText(ALine, ': schwerwiegender Fehler ');
end;

function TMSBuildTool.CapTotalLines(const AText: string; AMaxLines: Integer): string;
var
  Lines: TStringList;
  Sb: TStringBuilder;
  HeadKeep, TailKeep, Dropped, I: Integer;
begin
  if AMaxLines <= 0 then
    Exit(AText);

  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    if Lines.Count <= AMaxLines then
      Exit(AText);

    // Keep a head and a tail so the trailing "N Error(s)" summary survives.
    TailKeep := AMaxLines div 4;
    if TailKeep > 15 then
      TailKeep := 15;
    if TailKeep < 1 then
      TailKeep := 1;
    HeadKeep := AMaxLines - TailKeep;
    Dropped := Lines.Count - HeadKeep - TailKeep;

    Sb := TStringBuilder.Create;
    try
      for I := 0 to HeadKeep - 1 do
        Sb.AppendLine(Lines[I]);
      Sb.AppendLine(Format('... (%d lines truncated) ...', [Dropped]));
      for I := Lines.Count - TailKeep to Lines.Count - 1 do
        Sb.AppendLine(Lines[I]);
      Result := TrimRight(Sb.ToString);
    finally
      Sb.Free;
    end;
  finally
    Lines.Free;
  end;
end;

function TMSBuildTool.FilterOutput(const AOutput, AProjectFile: string;
  AShowHintsAndWarnings, ASuccess, AIsQuiet: Boolean;
  AMaxErrors, AMaxHintsWarnings, AMaxOutputLines: Integer): string;
var
  Lines: TStringList;
  FilteredLines: TStringList;
  Line: string;
  ProjectSuffix: string;
  IsHint, IsWarning: Boolean;
  ErrorsShown, ErrorsDropped: Integer;
  HWShown, HWDropped: Integer;
  I: Integer;
begin
  // On successful quiet builds there's nothing useful in the output; drop it.
  if ASuccess and AIsQuiet and not AShowHintsAndWarnings then
    Exit('');

  ProjectSuffix := ' [' + AProjectFile + ']';
  ErrorsShown := 0;
  ErrorsDropped := 0;
  HWShown := 0;
  HWDropped := 0;

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

      IsHint := ContainsText(Line, ': Hinweis ') or ContainsText(Line, ': hint ');
      IsWarning := ContainsText(Line, ': warning W') and not IsHint;

      if IsHint or IsWarning then
      begin
        // Drop entirely unless the caller asked to see hints/warnings; when shown,
        // still cap their number so a noisy project can't flood the result.
        if not AShowHintsAndWarnings then
          Continue;
        if (AMaxHintsWarnings > 0) and (HWShown >= AMaxHintsWarnings) then
        begin
          Inc(HWDropped);
          Continue;
        end;
        Inc(HWShown);
        FilteredLines.Add(Line);
        Continue;
      end;

      // On a failed build, cap the number of error lines. Undetected errors fall
      // through to the "kept as-is" path below, so nothing is ever hidden — only
      // detected errors beyond the cap are collapsed into a count.
      if (not ASuccess) and IsErrorLine(Line) then
      begin
        if (AMaxErrors > 0) and (ErrorsShown >= AMaxErrors) then
        begin
          Inc(ErrorsDropped);
          Continue;
        end;
        Inc(ErrorsShown);
        FilteredLines.Add(Line);
        Continue;
      end;

      FilteredLines.Add(Line);
    end;

    if ErrorsDropped > 0 then
      FilteredLines.Add(Format('... (+%d more error(s); set maxerrors=0 to show all) ...',
        [ErrorsDropped]));
    if HWDropped > 0 then
      FilteredLines.Add(Format('... (+%d more hint(s)/warning(s) suppressed) ...',
        [HWDropped]));

    Result := TrimRight(FilteredLines.Text);
  finally
    Lines.Free;
    FilteredLines.Free;
  end;

  // Final hard ceiling on total volume, regardless of how the lines were classified.
  Result := CapTotalLines(Result, AMaxOutputLines);
end;

function TMSBuildTool.WrapWithRsvars(const APlatform, AMSBuildArgs: string): string;
begin
  // Win32: bin\rsvars.bat, Win64: bin64\rsvars64.bat
  if SameText(APlatform, 'Win64') then
    Result := Format('cmd.exe /c "call "%s\bin64\rsvars64.bat" && %s"',
      [FBDSPath, AMSBuildArgs])
  else
    Result := Format('cmd.exe /c "call "%s\bin\rsvars.bat" && %s"',
      [FBDSPath, AMSBuildArgs]);
end;

function TMSBuildTool.ResolveExeOutputDir(const AProjectFile, AProjectDir,
  APlatform, AConfig: string): string;
const
  Marker = '__EXEOUTPUT__=';
var
  WrapperPath: string;
  WrapperXml: string;
  MSBuildArgs: string;
  Output: string;
  ExitCode: DWORD;
  Lines: TStringList;
  Line: string;
  Value: string;
  P: Integer;
begin
  Result := '';

  // dcc emits <Project>.gv next to the output executable, whose directory is the
  // project's resolved DCC_ExeOutput. That value may be absolute (e.g. L:\) and
  // therefore outside the project tree, so we ask MSBuild to evaluate it for us
  // via a throwaway wrapper project that imports the real .dproj.
  WrapperPath := TPath.Combine(TPath.GetTempPath,
    'dbuildmcp_exeout_' + TPath.GetGUIDFileName(False) + '.proj');

  WrapperXml :=
    '<?xml version="1.0" encoding="utf-8"?>'#13#10 +
    '<Project DefaultTargets="__GetExeOutput" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">'#13#10 +
    '  <Import Project="' + AProjectFile + '"/>'#13#10 +
    '  <Target Name="__GetExeOutput">'#13#10 +
    '    <Message Importance="high" Text="' + Marker + '$(DCC_ExeOutput)"/>'#13#10 +
    '  </Target>'#13#10 +
    '</Project>'#13#10;

  try
    TFile.WriteAllText(WrapperPath, WrapperXml, TEncoding.UTF8);
    try
      MSBuildArgs := Format(
        'msbuild -nologo "%s" /t:__GetExeOutput /p:Platform=%s /p:Config=%s -verbosity:minimal',
        [WrapperPath, APlatform, AConfig]);

      if not ExecuteProcess(WrapWithRsvars(APlatform, MSBuildArgs), AProjectDir, Output, ExitCode) then
        Exit;
      if ExitCode <> 0 then
        Exit;

      Lines := TStringList.Create;
      try
        Lines.Text := Output;
        for Line in Lines do
        begin
          P := Pos(Marker, Line);
          if P > 0 then
          begin
            Value := Trim(Copy(Line, P + Length(Marker), MaxInt));
            Break;
          end;
        end;
      finally
        Lines.Free;
      end;
    finally
      TFile.Delete(WrapperPath);
    end;
  except
    // Any failure here just means we fall back to the relative-path candidates.
    Exit('');
  end;

  if Value = '' then
    Exit('');

  Value := StringReplace(Value, '/', '\', [rfReplaceAll]);
  if not TPath.IsPathRooted(Value) then
    Value := TPath.Combine(AProjectDir, Value);
  Result := TPath.GetFullPath(Value);
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

function TMSBuildTool.FindGraphvizFile(const AProjectDir, AExeOutDir, AGvName,
  APlatform, AConfig: string; ABuildStart: TDateTime): string;

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

  // dcc writes <ProjectName>.gv next to the output executable. Prefer the
  // MSBuild-resolved exe-output directory (handles absolute DCC_ExeOutput such
  // as L:\), then fall back to the default <Platform>\<Config> layout and the
  // project directory.
  if AExeOutDir <> '' then
    Consider(TPath.Combine(AExeOutDir, AGvName), Best, BestTime);
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
  ExeOutDir: string;
begin
  GvName := ChangeFileExt(ExtractFileName(AProjectFile), '.gv');
  ExeOutDir := ResolveExeOutputDir(AProjectFile, AProjectDir, APlatform, AConfig);
  GvSource := FindGraphvizFile(AProjectDir, ExeOutDir, GvName, APlatform, AConfig, ABuildStart);

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
  MaxErrors: Integer;
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

  if Params.MaxErrorsProvided then
    MaxErrors := Params.MaxErrors
  else
    MaxErrors := FDefaultMaxErrors;

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

  MSBuildCmd := Format('msbuild -nologo "%s" /t:%s /p:Platform=%s /p:Config=%s -verbosity:%s%s',
    [ProjectFile, BuildType, Platform, Config, Verbosity, GraphvizArg]);
  CommandLine := WrapWithRsvars(Platform, MSBuildCmd);

  // Record the start time (minus a small tolerance) so we can tell a freshly
  // emitted .gv from a leftover of an earlier build.
  BuildStart := Now - (5 / SecsPerDay);

  // Execute
  if ExecuteProcess(CommandLine, ProjectDir, Output, ExitCode) then
  begin
    Success := (ExitCode = 0);
    Output := FilterOutput(Output, ProjectFile, ShowHintsAndWarnings, Success,
      SameText(Verbosity, 'quiet'), MaxErrors, FDefaultMaxHintsWarnings, FMaxOutputLines);

    // Collect / report the GraphViz .gv file dcc emits next to the project.
    if Params.Graphviz then
      GraphvizInfo := CollectGraphviz(Params, ProjectDir, ProjectFile, Platform,
        Config, BuildStart, Success)
    else
      GraphvizInfo := '';

    // One-line header to keep the common (repeated) result small. The full project
    // path is omitted - the caller supplied it and the filename disambiguates.
    // ASCII '|' separator on purpose: it is a single byte (cheaper than a multi-byte
    // dash) and sidesteps any source/transport encoding pitfalls.
    Result := Format('BUILD %s | %s | %s/%s/%s (exit %d)',
      [IfThen(Success, 'SUCCEEDED', 'FAILED'),
       ExtractFileName(ProjectFile), Platform, Config, BuildType, ExitCode]);
    if GraphvizInfo <> '' then
      Result := Result + #13#10 + 'GraphViz: ' + GraphvizInfo;
    if Output <> '' then
      Result := Result + #13#10 + Output;
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
