# local-coding-agent

A fully local, offline coding agent. **No cloud, no API keys, no telemetry.**

It wires the [OpenCode](https://opencode.ai) CLI (`opencode`) to
local models served by [Ollama](https://ollama.com), so agentic coding — edits,
shell commands, tool calls — runs entirely on your machine. Prompts, code, and
model inference never leave `localhost`.

This repository ships tuned setups for three platforms. Each lives in its own
folder with scripts and a focused README:

| Platform | Folder | Target hardware |
|----------|--------|-----------------|
| 🍎 macOS    | [`macos/`](macos/README.md)     | Apple Silicon (tuned for 64 GB) |
| 🐧 Linux    | [`linux/`](linux/README.md)     | Debian/Ubuntu + NVIDIA RTX (~8 GB VRAM) |
| 🪟 Windows  | [`windows/`](windows/README.md) | Windows 11 + NVIDIA RTX (~8 GB VRAM) |

## How it works

```mermaid
flowchart TB
    you["You (terminal)"] --> opencode["opencode CLI<br/>(OpenCode)"]
    opencode -->|"OpenAI-compatible API<br/>localhost:11434/v1"| ollama["Ollama server"]
    ollama --> models["Tuned local model aliases<br/>(baked context + sampling)"]
    ollama --> hw["Local hardware<br/>Apple Silicon · NVIDIA RTX"]

    subgraph scripts["Per-platform scripts"]
        setup["setup · start · stop · cleanup"]
    end
    scripts -.->|install · pull · configure · run| ollama

    subgraph ui["Optional desktop chat UI"]
        macui["macOS: Ollama.app"]
        linuxui["Linux: Alpaca (GTK)"]
        winui["Windows: Ollama tray"]
    end
    ui -.-> ollama

    classDef local fill:#e7f5e7,stroke:#2e7d32,color:#1b1b1b;
    class you,opencode,ollama,models,hw,scripts,ui,setup,macui,linuxui,winui local;
```

Everything in the green graph runs on your machine. The only network access is
during installation and the initial model downloads.

## Core concepts (shared across platforms)

- **Ollama** serves models locally and exposes an OpenAI-compatible endpoint at
  `http://localhost:11434/v1` (Windows uses the explicit IPv4 form
  `http://127.0.0.1:11434`).
- **OpenCode** (`opencode`) is the agentic CLI. It is pointed at the local
  Ollama endpoint via a custom OpenAI-compatible provider, so no cloud
  provider or API key is involved.
- **Tuned model aliases.** Each setup pulls base models and creates local
  aliases (e.g. `qcoder`) with a baked-in context window and sampling profile.
  Switch models from inside `opencode` with `/models`. `qcoder` is the default
  everywhere.
- **Memory tuning.** Flash attention and a quantized `q8_0` KV cache are enabled
  so larger context windows fit in limited VRAM:
  ```text
  OLLAMA_FLASH_ATTENTION=1
  OLLAMA_KV_CACHE_TYPE=q8_0
  ```
- **OpenCode config.** The installer fully regenerates
  `~/.config/opencode/opencode.json` (same path on Windows, under
  `%USERPROFILE%`) from scratch on every run — it is the sole owner of this
  file, so re-running `setup` is always safe and idempotent. A one-time
  personal `AGENTS.md` is seeded alongside it and is never overwritten. No
  `OLLAMA_API_KEY` or `.env` file is needed — the local Ollama provider
  requires no API key at all.

## Shared script pattern

Every platform exposes the same four core scripts (`.sh` on macOS/Linux,
`.ps1` on Windows):

| Script    | Does |
|-----------|------|
| `setup`   | Installs Ollama, OpenCode, and dependencies; pulls models; creates tuned aliases; writes `opencode.json`; validates each model endpoint. |
| `start`   | Starts the Ollama server. `--warm` preloads the default model into memory. |
| `stop`    | Stops Ollama and frees RAM/VRAM. |
| `cleanup` | Removes **all** local Ollama models so you can start fresh (does not uninstall Ollama or OpenCode). |

Linux and Windows add a few platform-specific helpers (GPU driver install,
GPU health/validation, desktop UI). See each folder's README.

Configuration lives in variables at the top of each script (model names,
contexts, install toggles). The only runtime flag is `--warm` on `start`.

## Models at a glance

| Alias            | macOS (Apple Silicon) | Linux / Windows (RTX 8 GB) | Purpose |
|------------------|-----------------------|----------------------------|---------|
| `qcoder` (default) | `qwen3.6:35b-a3b-coding-mxfp8` | `qwen3-coder:8b` | Daily coding driver |
| `qcoder-fast`    | `qwen3.5:4b`          | `qwen3-coder:4b`         | Fast/background tasks |
| `qcoder-quality` | `qwen3.6:27b-coding-mxfp8` | —                     | Hard bugs / big refactors (macOS) |
| `qcoder-vision`  | `qwen3.6:35b-a3b`     | —                          | Image input (macOS) |
| `gptoss`         | `gpt-oss:20b`         | —                          | Independent second opinion (macOS) |
| `agentic`        | —                     | `granite4:7b-a1b-h`        | Deterministic tool calling (Linux/Windows) |
| `general`        | —                     | `qwen3.5:4b`               | General chat / reasoning (Linux/Windows) |

Larger macOS models exploit Apple Silicon unified memory; the RTX profiles keep
models ≤ 7B so weights plus KV cache fit in ~8 GB VRAM. Exact aliases and
defaults are documented in each platform README.

## Typical workflow

The shape is identical on every platform — only the script extension and folder
differ:

```text
setup            # one time: install + pull + configure
start --warm     # start Ollama and preload the default model
opencode         # run the agent inside your project
stop             # release RAM/VRAM when done
```

Platform-specific quick starts:

- 🍎 **macOS** → [`macos/README.md`](macos/README.md)
- 🐧 **Linux** → [`linux/README.md`](linux/README.md)
- 🪟 **Windows** → [`windows/README.md`](windows/README.md)

## MCP servers

[MCP (Model Context Protocol)](https://modelcontextprotocol.io) servers extend
what the agent can do. The setup scripts wire in two fully local servers
automatically, and one optional cloud server for web search.

### git — structured repository access

Powered by [`mcp-server-git`](https://github.com/modelcontextprotocol/servers/tree/main/src/git)
(run via `uvx`, installed by `setup`). Exposes structured git operations that
are more reliable than parsing raw shell output:

`git_status` · `git_diff` · `git_diff_staged` · `git_log` · `git_commit` ·
`git_add` · `git_branch` · `git_checkout` · `git_create_branch` · `git_show`

No configuration needed. Runs entirely on `localhost`.

### memory — persistent knowledge graph

Powered by [`@modelcontextprotocol/server-memory`](https://github.com/modelcontextprotocol/servers/tree/main/src/memory)
(run via `npx`). Stores entities, relations, and observations in
`~/.config/opencode/mcp-memory.jsonl` and exposes them as queryable tools,
giving the agent a structured long-term memory that survives across sessions.

No configuration needed. Runs entirely on `localhost`.

### Tavily web search (optional, disabled by default)

When enabled, the agent can search the web for documentation, error messages,
or release notes via [Tavily](https://app.tavily.com).

**Enabling:** open the platform setup script, set the two variables, then
re-run `setup`:

| Platform | Script | Enable flag | API key variable |
|---|---|---|---|
| 🍎 macOS | `macos/setup.sh` | `ENABLE_WEB_SEARCH="1"` | `TAVILY_API_KEY="tvly-..."` |
| 🐧 Linux | `linux/setup.sh` | `ENABLE_WEB_SEARCH="1"` | `TAVILY_API_KEY="tvly-..."` |
| 🪟 Windows | `windows/setup.ps1` | `$EnableWebSearch = $true` | `$TavilyApiKey = 'tvly-...'` |

Get a free key at <https://app.tavily.com> (1 000 searches/month on the free
tier). The key is embedded directly in the generated `mcp.tavily.url` inside
`opencode.json` (chmod 600) — there is no separate `.env` file.

**Privacy:** web search is the only feature that sends data outside
`localhost`. When the agent calls `tavily_search`, the query is sent to
Tavily's API (`api.tavily.com`). All other tool calls — including git and
memory — stay on your machine. Disable at any time by setting
`ENABLE_WEB_SEARCH="0"` / `$EnableWebSearch = $false` and re-running `setup`.

## Editor integration (optional)

Prefer working inside your editor instead of the terminal? OpenCode has a
built-in VS Code (and Cursor/Windsurf/VSCodium) integration that installs
itself automatically — no marketplace step needed. Just open the integrated
terminal in your editor and run `opencode`; the extension installs on first
run.

It adds a native OpenCode panel, shares your current file selection as
context, in-editor diff review, and file-reference shortcuts (`Cmd/Ctrl+Alt+K`)
— all driven by the same local Ollama models configured here. Because it
launches the same `opencode` CLI pointed at your local
`~/.config/opencode/opencode.json`, inference still stays entirely on
`localhost`. Quick-launch with `Cmd+Esc` / `Ctrl+Esc`.

## Requirements

- One of: macOS (Apple Silicon recommended), Debian/Ubuntu Linux, or Windows 11
- Internet access during installation and model downloads
- `curl` and admin rights (`sudo` / Administrator) for installs
- A supported GPU/accelerator: Apple Silicon, or an NVIDIA RTX GPU (~8 GB VRAM)
  on Linux/Windows
- Enough disk for Ollama plus the selected models (a clean macOS model set needs
  ~110 GB; the RTX profiles are much smaller)

`setup` installs all runtime dependencies automatically, including Node.js,
OpenCode, `jq`, and `uv` (for `mcp-server-git`).

## Privacy

After installation and model downloads, prompts, code, tool calls, and
inference all stay on your machine via Ollama's local API. The two built-in MCP
servers (`mcp-server-git`, `server-memory`) are local processes — no data
leaves `localhost`. OpenCode's `share` setting is disabled in the generated
config (`opencode.json`), so sessions are never uploaded. The only exception
is the optional Tavily web search feature; see
[Tavily web search](#tavily-web-search-optional-disabled-by-default) above.
