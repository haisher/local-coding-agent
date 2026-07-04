# local-coding-agent — Windows 11 (NVIDIA RTX)

Windows profile of the local coding agent. For the project overview,
architecture diagram, and shared concepts (Ollama, OpenCode, tuned aliases,
KV-cache tuning), see the [root README](../README.md).

This profile targets **Windows 11 with an NVIDIA RTX GPU (~8 GB VRAM)**. The
`opencode` CLI talks to models served by Ollama on the local IPv4 endpoint:

```text
http://127.0.0.1:11434
```

Flash attention and a `q8_0` KV cache help larger context windows fit within
8 GB. IPv4 is used explicitly to avoid a PowerShell 5.1 delay where `localhost`
may resolve to IPv6 first.

## Scripts

| Script | Purpose |
|---|---|
| `setup.ps1` | Installs dependencies, downloads selected models, creates tuned aliases, configures OpenCode, validates inference, and preloads the default model. |
| `start.ps1` | Starts the Ollama API. Pass `--warm` to load the default model into GPU memory for 30 minutes. |
| `stop.ps1` | Stops Ollama and its inference processes, releasing RAM and VRAM. |
| `cleanup.ps1` | Removes **all** local Ollama models so you can start fresh. Pass `--yes` to skip the confirmation. |
| `detect-gpu.ps1` | Loads a model and confirms through Ollama's API that it is fully GPU-resident. It also diagnoses common Windows and NVIDIA problems. |

Configuration variables are near the top of each script.

## Requirements

- Windows 11
- PowerShell 5.1 or newer
- Internet access during installation and model downloads
- `winget` from Microsoft App Installer
- An NVIDIA GPU and current NVIDIA driver for GPU acceleration
- Approximately 8 GB VRAM for the supplied model/context configuration
- Enough disk space for Ollama plus the selected models

The scripts install these components when missing:

- Ollama
- Git
- Node.js 22 or newer
- OpenCode CLI

The installer uses the community `winget` source rather than the Microsoft
Store source.

## Execution Policy

Windows may initially refuse to run local PowerShell scripts:

```text
running scripts is disabled on this system
```

Before running these scripts, allow them for only the current PowerShell
process:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

`-Scope Process` is important. It changes policy only for the current
PowerShell window. Closing that window restores the previous policy, so this
does not permanently weaken the machine-wide or user-wide execution policy.

`Bypass` tells PowerShell not to block or prompt for these local scripts. Use it
only after reviewing scripts from a source you trust. It does not bypass
Windows Smart App Control, App Control for Business, antivirus, or administrator
permissions.

Alternatively, invoke one script without changing the current shell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\detect-gpu.ps1
```

## Quick Start

Open PowerShell in this directory:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\setup.ps1
.\detect-gpu.ps1
opencode
```

For later sessions:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1 --warm
opencode
```

When finished:

```powershell
.\stop.ps1
```

To wipe all local models and start over:

```powershell
.\cleanup.ps1            # add --yes to skip the confirmation
```

## Models

The installer can create these tuned aliases:

| Install flag | Alias | Base model | Context | Purpose |
|---|---|---|---:|---|
| `$InstallModel` | `qcoder` | `qwen3-coder:8b` | 24,576 | Coding and code review |
| `$InstallFastModel` | `qcoder-fast` | `qwen3-coder:4b` | 32,768 | Faster, smaller coding tasks |
| `$InstallAgenticModel` | `agentic` | `granite4:7b-a1b-h` | 32,768 | Deterministic tool calling |
| `$InstallGeneralModel` | `general` | `qwen3.5:4b` | 32,768 | General chat, reasoning, and coding |

Edit the Boolean install flags at the top of `setup.ps1` before running it:

```powershell
$InstallModel = $false
$InstallFastModel = $false
$InstallAgenticModel = $false
$InstallGeneralModel = $true
```

At least one model must be enabled. The first enabled model in the installer's
default-selection order becomes OpenCode's default model.

Keep `start.ps1` synchronized with the aliases you install:

```powershell
$DefaultModel = 'general'
$AvailableModels = @('general')
```

## Web search (optional)

Web search is disabled by default. To enable it:

1. Get a free Tavily API key at <https://app.tavily.com> (1,000 searches/month).
2. Open `setup.ps1` and edit the two variables near the top:
   ```powershell
   $EnableWebSearch = $true
   $TavilyApiKey = 'tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX'
   ```
3. Re-run `.\setup.ps1`.

The key is embedded directly in the generated `mcp.tavily.url` inside
`%USERPROFILE%\.config\opencode\opencode.json` — there is no separate `.env`
file.

**Privacy:** when the agent invokes `tavily_search`, that query is sent to
Tavily's API (`api.tavily.com`). Everything else — model inference, code, file
contents — stays on `localhost`.

## setup.ps1

Run:

```powershell
.\setup.ps1
```

The script:

1. Installs Ollama with `winget` if needed.
2. Installs Git for OpenCode's local git MCP server.
3. Installs Node.js 22 or newer.
4. Installs `opencode-ai` globally with npm.
5. Saves these user environment variables:

   ```text
   OLLAMA_FLASH_ATTENTION=1
   OLLAMA_KV_CACHE_TYPE=q8_0
   ```

6. Starts the local Ollama API.
7. Pulls each enabled base model.
8. Creates tuned Ollama model aliases.
9. Regenerates OpenCode's config from scratch (`opencode.json`).
10. Validates each enabled model through Ollama's OpenAI-compatible endpoint.
11. Preloads the default model.

The script accepts no runtime arguments. Change its configuration variables
instead.

### OpenCode files

The installer manages:

```text
C:\Users\<user>\.config\opencode\opencode.json
C:\Users\<user>\.config\opencode\AGENTS.md
```

No `OLLAMA_API_KEY` or `.env` file is needed — the local Ollama provider
requires no API key at all.

`setup.ps1` is the sole owner of `opencode.json`: it is fully regenerated from
the script's configuration variables on every run (no merge, no backups
needed), so re-running `setup.ps1` is always safe and idempotent.
`AGENTS.md` is the one exception — it is seeded once with default personal
instructions and never overwritten, so any notes you add there persist across
runs.

## start.ps1

Start only the Ollama server:

```powershell
.\start.ps1
```

Start Ollama and load the default model into VRAM:

```powershell
.\start.ps1 --warm
```

The warm model remains loaded for the configured duration:

```powershell
$KeepAlive = '30m'
```

The script is idempotent. If Ollama is already running, it leaves the existing
server in place. `--warm` is its only supported argument.

## stop.ps1

Run:

```powershell
.\stop.ps1
```

It stops:

- `llama-server`
- `ollama`
- `ollama app`

Stopping Ollama unloads models and releases their VRAM. The script accepts no
arguments.

If the Ollama desktop application or another service automatically restarts
the API, disable Ollama startup in Task Manager or exit the Ollama tray
application.

## detect-gpu.ps1

Validate the default `general` model:

```powershell
.\detect-gpu.ps1
```

Validate another alias:

```powershell
.\detect-gpu.ps1 -Model qcoder
```

Attempt a safe automatic repair:

```powershell
.\detect-gpu.ps1 -Model general -Repair
```

The script checks:

- Whether `nvidia-smi` can detect an NVIDIA GPU
- NVIDIA driver version and total/free VRAM
- Whether Ollama is installed and its API is running
- Whether the requested model is installed
- Recent Windows Code Integrity blocks involving Ollama
- Smart App Control state
- Actual model allocation from Ollama's `/api/ps` endpoint

Success looks like:

```text
[detect-gpu] PASS: 'general:latest' is 100% GPU-resident.
```

Without `-Repair`, the helper diagnoses and prints instructions. With `-Repair`,
it may start or restart Ollama so CUDA device discovery runs again, then reload
the model and recheck VRAM allocation.

It never disables Smart App Control or modifies Windows application-control
policies.

## Confirming GPU Use

Ollama's process table is the simplest manual check:

```powershell
ollama ps
```

Expected:

```text
NAME              PROCESSOR    CONTEXT
general:latest    100% GPU     32768
```

`100% CPU` means Ollama did not offload the model to the GPU.

Partial GPU percentages usually mean the complete model or its context cache
does not fit in available VRAM.

You can also monitor NVIDIA usage:

```powershell
nvidia-smi
```

## Smart App Control

Windows Smart App Control or an enterprise App Control policy may block
Ollama's native inference files, including:

```text
libmtmd.dll
llama-server.exe
```

Typical symptoms include:

```text
Error status 0xc0e90002
An Application Control policy has blocked this file
HTTP 500 Internal Server Error
```

Relevant events appear in:

```text
Event Viewer
  Applications and Services Logs
    Microsoft
      Windows
        CodeIntegrity
          Operational
```

Common event IDs are `3033` and `3077`.

On a managed computer, ask the administrator to permit Ollama using an App
Control supplemental policy.

On a personal computer, Smart App Control is under:

```text
Settings
  Privacy & security
    Windows Security
      App & browser control
        Smart App Control
```

Disabling Smart App Control lowers Windows security. Microsoft normally does
not allow it to be turned back on without resetting or reinstalling Windows.
Review that consequence before changing it.

After changing an application-control policy, restart Ollama. A server started
while CUDA helpers were blocked can retain a CPU-only device list until it is
restarted:

```powershell
.\stop.ps1
.\start.ps1 --warm
.\detect-gpu.ps1
```

Old Code Integrity events remain in Event Viewer after the issue is resolved;
their presence alone does not mean the current process is still blocked.

## VRAM and Context

An RTX 3070 has 8 GB of VRAM, but Windows and desktop applications also consume
some of it. Model weights, KV cache, context length, and other GPU applications
all affect whether a model fits.

If GPU validation reports partial offload:

1. Close games, creative applications, and other GPU-heavy programs.
2. Stop other local models.
3. Reduce the model's `num_ctx` value in `setup.ps1`.
4. Rerun `setup.ps1` to recreate the alias.
5. Restart and validate Ollama again.

Flash attention and the quantized KV cache are enabled by:

```text
OLLAMA_FLASH_ATTENTION=1
OLLAMA_KV_CACHE_TYPE=q8_0
```

These variables must be present when the Ollama server starts. The setup and
start scripts set them before launching Ollama.

## Troubleshooting

### PowerShell scripts are disabled

Run this in the same PowerShell window:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

### Microsoft Store agreement prompt

The installer pins packages to:

```text
--source winget
```

If an older copy of the installer still queries `msstore`, update the local
script before continuing.

### Ollama API does not start

The scripts use IPv4 explicitly:

```text
http://127.0.0.1:11434
```

This avoids a PowerShell 5.1 delay where `localhost` may resolve to IPv6 before
falling back to IPv4.

Inspect logs in:

```text
%TEMP%\ollama-setup-error.log
%TEMP%\ollama-start-error.log
%TEMP%\ollama-gpu-check-error.log
```

### Model validation returns HTTP 500

Run:

```powershell
.\detect-gpu.ps1 -Model general
```

An HTTP 500 during model loading is commonly caused by Windows Code Integrity
blocking an Ollama DLL or runner, not by OpenCode.

### Model runs on CPU after a policy change

Restart Ollama so it repeats GPU discovery:

```powershell
.\detect-gpu.ps1 -Model general -Repair
```

### Model alias is missing

Enable its install flag in `setup.ps1`, then rerun:

```powershell
.\setup.ps1
```

Already downloaded Ollama layers are reused.

### git MCP tools fail or are unavailable

OpenCode's local `git` MCP server (`mcp-server-git`, run via `uvx`) shells out
to the `git` binary. If git-related tools error out, confirm Git is on PATH:

```powershell
git --version
```

If the command is not found, rerun `setup.ps1` — the installer installs Git
automatically.

### Node.js is already installed

The installer reads the executable's version metadata and requires Node.js 22
or newer. It will not reinstall a compatible version.

## Daily Workflow

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start.ps1 --warm
.\detect-gpu.ps1
opencode
```

When the session is finished:

```powershell
.\stop.ps1
```

This keeps Ollama and its models available only when needed and releases GPU
memory afterward.
