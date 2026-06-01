# dbuildmcp

MCP (Model Context Protocol) server for building Delphi projects with MSBuild.

## Overview

dbuildmcp enables AI assistants to compile Delphi projects by providing an MCP-compatible HTTP API. It automatically sets up the correct RAD Studio build environment and executes MSBuild, returning the complete build output.

## Features

- Build Delphi projects (.dproj) via MCP protocol
- Automatic RAD Studio environment setup
  - Win32: uses `bin\rsvars.bat`
  - Win64: uses `bin64\rsvars64.bat`
- Support for Win32 and Win64 platforms
- Debug and Release configurations
- Build (full rebuild) or Make (incremental) build types
- Configurable MSBuild verbosity (quiet, normal, detailed)
- Concise, token-efficient output: a one-line result header, errors-only on failure with a configurable error cap, plus hint/warning and total-line ceilings
- Configurable build timeout (default 10 minutes)

## Requirements

- RAD Studio 13 (Delphi 37.0)
- https://github.com/GDKsoftware/Delphi-MCP-Server (may have additional depencies)

## Installation

1. Clone the repository
2. Open `Source/dbuildmcp.dproj` in RAD Studio
3. Compile the project
4. Run the executable

The server starts on port 3001 by default.

## Usage

### Starting the Server

Run the compiled executable. The server will start and display:
```
MCP Server running on port 3001

Press ENTER to stop...
```

### Building a Project

Send a POST request to `http://localhost:3001/mcp`:

```bash
curl -X POST http://localhost:3001/mcp \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "msbuild",
      "arguments": {
        "projectFile": "C:/projects/MyApp/MyApp.dproj",
        "platform": "Win64",
        "config": "Release",
        "buildType": "Build",
        "verbosity": "normal"
      }
    }
  }'
```

**Important:** Use forward slashes (`/`) in file paths, not backslashes.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `projectFile` | Yes | - | Path to .dproj file (use `/` not `\`) |
| `buildType` | No | `Make` | `Build` (full) or `Make` (incremental) |
| `platform` | No | `Win64` | `Win32` or `Win64` |
| `config` | No | `Debug` | `Debug` or `Release` |
| `verbosity` | No | `quiet` | `quiet`, `normal`, or `detailed` |
| `showHintsAndWarnings` | No | `false` | Show hints/warnings in output (default: filtered) |
| `graphviz` | No | `false` | Emit a `<ProjectName>.gv` GraphViz unit-dependency file (passes `--graphviz` to dcc) |
| `graphvizExclude` | No | `System.*;Vcl.*;Winapi.*;Data.*;Soap.*;Xml.*` | `;`-separated unit-name wildcards to exclude (only used when `graphviz=true`) |
| `graphvizOutDir` | No | next to project | Directory to collect the `.gv` file, use `/` not `\` (only used when `graphviz=true`) |
| `maxErrors` | No | `10` (from settings.ini) | Max error lines shown on a failed build. `1` = first error only, `0` = all |

> GraphViz switches are forwarded to the compiler via the project's `DCC_AdditionalSwitches` property. dcc only writes the `.gv` when it actually compiles, so use `buildType=Build` to force generation on an unchanged project.

### Response

On a successful `quiet` build (the default), the response is a single status line — no MSBuild output:

```
BUILD SUCCEEDED | MyApp.dproj | Win64/Release/Build (exit 0)
```

On failure — or when `verbosity` is `normal`/`detailed`, or `showHintsAndWarnings=true` — the filtered MSBuild output follows on the next lines:

```
BUILD FAILED | MyApp.dproj | Win64/Release/Build (exit 1)
MyApp.dpr(42): error E2003: Undeclared identifier: 'Foo'
... (+4 more error(s); set maxErrors=0 to show all) ...
```

The header is one line (status, project file name, `Platform/Config/BuildType`, exit code) with an ASCII `|` separator. The ` [<project path>]` suffix MSBuild appends to each diagnostic is stripped automatically.

To keep results small (they count against the model's context), the output is bounded after filtering:

- **`maxErrors`** / **`DefaultMaxErrors`** (default `10`) — caps error lines on failure; MSBuild's `N Error(s)` summary is always kept. `1` = first/root error only, `0` = all.
- **`DefaultMaxHintsWarnings`** (default `30`) — caps hints/warnings when they are shown.
- **`MaxOutputLines`** (default `200`) — hard ceiling on total output lines; head and tail are kept so the summary survives, with a `... (K lines truncated) ...` marker.

Every limit treats `0` as unlimited.

## Configuration

The server uses `settings.ini` in the executable directory:

### Server Settings

```ini
[Server]
Port=3001
Host=localhost
Endpoint=/mcp
```

### MSBuild Settings

```ini
[MSBuild]
; RAD Studio installation path
BDSPath=C:\Program Files (x86)\Embarcadero\Studio\37.0
; .NET Framework path for MSBuild
FrameworkDir=C:\Windows\Microsoft.NET\Framework\v4.0.30319
; Default build settings
DefaultBuildType=Make
DefaultPlatform=Win64
DefaultConfig=Debug
DefaultVerbosity=quiet
; Show hints and warnings in output (0=filter, 1=show)
DefaultShowHintsAndWarnings=0
; Build timeout in milliseconds (10 minutes)
BuildTimeoutMs=600000
; Output-size limits (0 = unlimited)
DefaultMaxErrors=10
DefaultMaxHintsWarnings=30
MaxOutputLines=200
```

| Setting | Description |
|---------|-------------|
| `BDSPath` | RAD Studio installation path |
| `FrameworkDir` | .NET Framework path |
| `DefaultBuildType` | `Make` (incremental) or `Build` (full) |
| `DefaultPlatform` | `Win32` or `Win64` |
| `DefaultConfig` | `Debug` or `Release` |
| `DefaultVerbosity` | `quiet`, `normal`, or `detailed` |
| `DefaultShowHintsAndWarnings` | Filter hints/warnings from output |
| `BuildTimeoutMs` | Maximum build time in ms |
| `DefaultMaxErrors` | Max error lines on a failed build (0=all); per-call `maxErrors` overrides |
| `DefaultMaxHintsWarnings` | Max hint/warning lines when shown (0=all) |
| `MaxOutputLines` | Hard ceiling on total output lines after filtering (0=unlimited) |

## Project Structure

```
dbuildmcp/
├── Source/
│   ├── dbuildmcp.dpr           # Main program
│   ├── dbuildmcp.dproj         # Project file
│   ├── dbuildmcp.Tool.MSBuild.pas  # MSBuild tool
│   ├── dbuildmcp.ConsoleLog.pas    # Concise console activity log
│   └── settings.ini            # Server configuration
├── sample code/                # Reference implementations
├── CLAUDE.md                   # AI assistant instructions
└── README.md                   # This file
```

## Tested Configurations

All parameter combinations have been tested and verified working:

| Platform | Config | BuildType | Status |
|----------|--------|-----------|--------|
| Win64 | Release | Build | ✓ |
| Win64 | Release | Make | ✓ |
| Win64 | Debug | Build | ✓ |
| Win64 | Debug | Make | ✓ |
| Win32 | Release | Build | ✓ |
| Win32 | Release | Make | ✓ |
| Win32 | Debug | Build | ✓ |
| Win32 | Debug | Make | ✓ |

## Integration with Claude Code

Simply run 
```bash
 claude mcp add --transport http dbuildmcp http://localhost:3001/mcp
```

## Integration with Claude Desktop

Claude Desktop (currently?) does not support `localhost` URLs. You can try a proxy like `node mcp-remote`.


## License

The MIT License (MIT)

Copyright (c) 2026 Dr. Pfau Fernwirktechnik GmbH

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Known Issues

- File paths with backslashes (`\`) cause JSON parsing issues. Use forward slashes (`/`) instead - the tool converts them internally.
