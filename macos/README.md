# local-coding-agent — macOS (Apple Silicon)

macOS profile of the local coding agent. For the project overview, architecture
diagram, and shared concepts (Ollama, OpenCode, tuned aliases, KV-cache
tuning), see the [root README](../README.md).

This profile targets **Apple Silicon with ~64 GB unified memory**. It installs
Ollama as the macOS app, pulls larger MLX-optimized models, and points the
`opencode` CLI at the local Ollama endpoint.

## What gets installed

- **Ollama** (macOS app via the `ollama-app` Homebrew cask, or the official
  installer)
- **OpenCode** CLI (`opencode`) + Node.js ≥ 22 if missing
- **jq** (used to build and validate `opencode.json`)
- The models below, each pulled and given a tuned local alias
- `~/.config/opencode/opencode.json` configured to use Ollama's
  OpenAI-compatible endpoint

## Models

| Alias            | Base model                      | Context | Purpose |
|------------------|---------------------------------|---------|---------|
| `qcoder`         | `qwen3.8:27b-mlx`               | 65 536  | Daily driver (dense, MLX) |
| `qcoder-quality` | `qwen3.8:27b`                   | 65 536  | Hard bugs / large refactors (full precision) |
| `qcoder-vision`  | `qwen3.6:35b-a3b`               | 65 536  | Image input (MLX coding builds are text-only) |
| `qcoder-fast`    | `qwen3.5:4b`                    | 32 768  | Fast background tasks (thinking off) |
| `gptoss`         | `gpt-oss:20b`                   | 65 536  | Independent second opinion |

`qcoder` is the default; switch models from inside `opencode` with `/models`.
An optional `qcoder-speed` (`qwen3.6:35b-a3b-coding-nvfp4`) profile exists in
`setup.sh` (off by default). The vision, quality, fast, and gpt-oss models can
each be toggled via `INSTALL_*` flags near the top of `setup.sh`.

## Scripts

| Script      | Does |
|-------------|------|
| `setup.sh`  | Installs Ollama/OpenCode/jq, pulls models, creates aliases, writes `~/.config/opencode/opencode.json`. Validates each model endpoint. |
| `start.sh`  | Starts Ollama (prefers the macOS app). `--warm` preloads `qcoder`. |
| `stop.sh`   | Stops Ollama (the app and any CLI `ollama serve`) and frees RAM. |
| `cleanup.sh`| Removes all local Ollama models so you can start fresh. `--yes` skips the prompt. |

Configure by editing the variables at the top of each script (model names,
contexts, install toggles). No runtime flags except `--warm` on `start.sh`.

## Quick start

```bash
cd local-coding-agent/macos
./setup.sh
./start.sh --warm        # optional warm-up
cd <your-project> && opencode
./stop.sh                # when done
```

To wipe all local models and start over:

```bash
./cleanup.sh             # add --yes to skip the confirmation
```

## macOS notes

- The setup prefers Ollama.app and persists `OLLAMA_FLASH_ATTENTION` /
  `OLLAMA_KV_CACHE_TYPE` via `launchctl setenv` so the app picks them up. An
  already-running server keeps its previous environment until restarted, so
  apply changes with `./stop.sh && ./start.sh`.
- `stop.sh` quits the menubar app before killing `ollama serve`; the app
  supervises and would otherwise immediately respawn the server.
- The scripts target stock macOS bash 3.2 (no `mapfile`).

## Web search (optional)

Web search is disabled by default. To enable it:

1. Get a free Tavily API key at <https://app.tavily.com> (1 000 searches/month).
2. Open `setup.sh` and edit the two variables near the top:
   ```bash
   ENABLE_WEB_SEARCH="1"
   TAVILY_API_KEY="tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
   ```
3. Re-run `./setup.sh`.

The key is embedded directly in the generated `mcp.tavily.url` inside
`~/.config/opencode/opencode.json` (chmod 600) — there is no separate `.env`
file.

**Privacy:** when the agent invokes `tavily_search`, that query is sent to
Tavily's API (`api.tavily.com`). Everything else — model inference, code, file
contents — stays on `localhost`.

## Requirements

- macOS on Apple Silicon (arm64 recommended)
- Internet access, `curl`, and `sudo` for installs
- [Homebrew](https://brew.sh) recommended (used to install Ollama, jq, Node.js)
- Disk: a clean model install needs ~90 GB (less if Ollama shares blobs);
  `setup.sh` warns below ~140 GB free
