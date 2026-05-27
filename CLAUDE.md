# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**dbuildmcp** is an MCP (Model Context Protocol) server for building Delphi Applications with MSBuild. This project enables AI assistants to invoke MSBuild using the correct Delphi build environment through the standardized MCP protocol. The server is written in Delphi.

## Repository Structure

- `Source/` - Main source code
  - `dbuildmcp.dpr` - Main program
  - `dbuildmcp.Tool.MSBuild.pas` - MSBuild tool implementation
- `sample code/` - Reference code (not used at runtime)
  - `Delphi-MCP-Server-Reference/` - MCP Library reference implementation
  - `DOSCommand-reference/` - DOSCommand Library reference

## Development Workflow

### Manual workflow

1. Open `Source/dbuildmcp.dproj` in RAD Studio
2. Compile and run (F9)
3. Server starts on `http://localhost:3001/mcp`
4. Claude can then interact via curl or MCP client

### Agent workflow

1. Build/Compile via `dbuildmcp`
2. run the process
3. Server starts on `http://localhost:3001/mcp`
4. Claude can then interact via curl or MCP client

## MCP Tools

- `dbuildmcp` to compile/build the project

### msbuild

Build Delphi projects using MSBuild with the correct RAD Studio environment.

**IMPORTANT:** Use forward slashes (`/`) in file paths, not backslashes. The tool converts them internally.

**Parameters:** (JSON keys are lowercase)

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `projectfile` | Yes | - | Full path to .dproj file. **Use forward slashes!** |
| `buildtype` | No | `Make` | `Build` (full rebuild) or `Make` (incremental) |
| `platform` | No | `Win64` | Target platform: `Win32` or `Win64` |
| `config` | No | `Debug` | Build configuration: `Debug` or `Release` |
| `verbosity` | No | `quiet` | MSBuild verbosity: `quiet`, `normal`, or `detailed` |
| `showhintsandwarnings` | No | from settings.ini | Show hints and warnings in output. Defaults to the `DefaultShowHintsAndWarnings` ini value when omitted; an explicit `true`/`false` overrides it. |
| `graphviz` | No | `false` | Generate a GraphViz `.gv` unit-dependency file. Passes `--graphviz` (and `--graphviz-exclude`) to dcc. |
| `graphvizexclude` | No | `System.*;Vcl.*;Winapi.*;Data.*;Soap.*;Xml.*` | Semicolon-separated unit-name wildcards to exclude from the graph. Only used when `graphviz=true`. |
| `graphvizoutdir` | No | next to project | Directory to collect the generated `.gv` file. **Use forward slashes!** Only used when `graphviz=true`. |

### GraphViz unit-dependency graphs

When `graphviz=true`, the build forwards the dcc switches `--graphviz` and `--graphviz-exclude=<patterns>` to the Delphi compiler through the project's `DCC_AdditionalSwitches` MSBuild property (these are raw compiler switches, not native MSBuild flags). The compiler emits a `<ProjectName>.gv` GraphViz DOT file describing the unit `uses` graph (implementation-section uses are drawn `style=dashed`). Process the `.gv` with [GraphViz](https://graphviz.org/) to render a diagram.

- Semicolons in the exclude list are escaped to `%3B` internally so MSBuild does not mistake them for `/p:` property separators.
- `System`, `SysInit`, and `System.Variants` are always excluded by the compiler regardless of the exclude list.
- dcc only emits the `.gv` when it actually compiles. An incremental `Make` build that recompiles nothing produces no file — use `buildtype=Build` to force it.
- The result header gains a `GraphViz:` line reporting the final `.gv` path (or a note if none was generated).

**Example curl call:**
```bash
curl -X POST http://localhost:3001/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"msbuild","arguments":{"projectfile":"C:/projects/MyApp/MyApp.dproj","platform":"Win64","config":"Release"}}}'
```

**Response Format:**

On a successful `quiet` build (the default), the response omits the raw MSBuild output entirely — only the header block is returned:
```
BUILD SUCCEEDED
===============
Project: C:\projects\MyApp\MyApp.dproj
BuildType: Make
Platform: Win64
Config: Release
ExitCode: 0
```

On failure, or when `verbosity` is `normal`/`detailed`, or when `showhintsandwarnings=true`, the header is followed by a separator and the filtered MSBuild output:
```
BUILD FAILED
===============
Project: C:\projects\MyApp\MyApp.dproj
BuildType: Make
Platform: Win64
Config: Release
ExitCode: 1
===============
[filtered MSBuild output here]
```

The MSBuild banner is suppressed via `-nologo`, and the trailing ` [<project path>]` suffix that MSBuild appends to each diagnostic line is stripped automatically.

## Configuration (settings.ini)

The `[MSBuild]` section in `settings.ini` configures the build tool:

```ini
[MSBuild]
BDSPath=C:\Program Files (x86)\Embarcadero\Studio\37.0
FrameworkDir=C:\Windows\Microsoft.NET\Framework\v4.0.30319
DefaultBuildType=Make
DefaultPlatform=Win64
DefaultConfig=Debug
DefaultVerbosity=quiet
DefaultShowHintsAndWarnings=0
BuildTimeoutMs=600000
```

| Setting | Description |
|---------|-------------|
| `BDSPath` | RAD Studio installation path |
| `FrameworkDir` | .NET Framework path for MSBuild |
| `DefaultBuildType` | Default: Make or Build |
| `DefaultPlatform` | Default: Win32 or Win64 |
| `DefaultConfig` | Default: Debug or Release |
| `DefaultVerbosity` | Default: quiet, normal, or detailed |
| `DefaultShowHintsAndWarnings` | Show hints/warnings: 0=false (filter), 1=true (show) |
| `BuildTimeoutMs` | Build timeout in milliseconds |

## Build Environment Setup

The tool automatically selects the correct environment script based on platform:
- **Win32**: Uses `bin\rsvars.bat`
- **Win64**: Uses `bin64\rsvars64.bat`

## Error Handling

- **Project not found**: Returns error message with path
- **Build failure**: Returns full MSBuild output with exit code
- **Timeout**: 10 minutes maximum build time (configurable via BuildTimeoutMs)

## Implementation Notes

- Uses Windows CreateProcess API with pipes to capture build output
- Reads settings from `settings.ini` using TMemIniFile
- Converts forward slashes to backslashes internally before calling MSBuild
- Registered via TMCPRegistry in the initialization section

## Known Issues

- Paths with backslashes (`\`) cause crashes in JSON parsing - use forward slashes (`/`) instead
- Cannot build Win64 Debug of the server itself while running (exe locked)
