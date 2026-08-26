# local-coding-agent — Linux (NVIDIA RTX)

Linux profile of the local coding agent. For the project overview, architecture
diagram, and shared concepts (Ollama, OpenCode, tuned aliases, KV-cache
tuning), see the [root README](../README.md).

This profile is tuned for a single **NVIDIA RTX (8 GB VRAM)** on Debian/Ubuntu.
Ollama runs as a `systemd` service and models are kept ≤ 8B so weights plus a
`q8_0` KV cache fit in 8 GB.

## What gets installed

- **NVIDIA driver** (optional, via `install-nvidia.sh`) + nouveau blacklist
- **Ollama** (official Linux installer) as a `systemd` service
- A `systemd` drop-in override that persists `OLLAMA_FLASH_ATTENTION` and
  `OLLAMA_KV_CACHE_TYPE=q8_0` so the daemon actually uses them
- **OpenCode** CLI (`opencode`) + Node.js ≥ 22 if missing
- **jq** (used to build and validate `opencode.json`)
- The models below, each pulled and given a tuned local alias
- `~/.config/opencode/opencode.json` configured to use Ollama's
  OpenAI-compatible endpoint

## Models

| Alias         | Base model            | Context | Purpose |
|---------------|-----------------------|---------|---------|
| `qcoder`      | `qwen3:8b`            | 32 768  | Daily driver / code review |
| `agentic`     | `granite4:7b-a1b-h`   | 32 768  | Tool-calling / agentic (Granite 4 hybrid MoE, ~1B active, greedy decoding) |
| `general`     | `qwen3.5:4b`          | 32 768  | General-purpose chat / reasoning (Qwen3.5, hybrid DeltaNet + MoE) |
| `qcoder-fast` | `qwen3:3b`            | 32 768  | Fast autocomplete / simple tasks |

`qcoder` is the default; switch models from inside `opencode` with `/models`.
A `q8_0` KV cache + flash attention keep all models within 8 GB. Each model can
be toggled via `INSTALL_*` flags near the top of `setup.sh`.

## Scripts

| Script             | Does |
|--------------------|------|
| `setup.sh`         | Installs Ollama/OpenCode/jq, pulls models, creates aliases, writes the `systemd` env override and `~/.config/opencode/opencode.json`. Validates each model endpoint. |
| `start.sh`         | Starts the Ollama service (`systemd`-aware). `--warm` preloads `qcoder`. |
| `stop.sh`          | Stops Ollama (handles `Restart=always`) and frees VRAM. |
| `cleanup.sh`       | Removes all local Ollama models so you can start fresh. |
| `install-nvidia.sh`| Installs the proprietary NVIDIA driver (Debian 13 / Trixie), enrolls a Secure Boot MOK key, and blacklists nouveau. **Requires a reboot.** |
| `check-nvidia.sh`  | NVIDIA driver / GPU health check. |
| `install-alpaca.sh`| Installs [Alpaca](https://flathub.org/apps/com.jeffser.Alpaca), a native desktop chat UI (Flatpak), and points it at the local Ollama server. |

Configure by editing the variables at the top of each script (model names,
contexts, install toggles). No runtime flags except `--warm` on `start.sh`.

## Quick start

```bash
cd local-coding-agent
./linux/install-nvidia.sh   # optional, if the GPU driver isn't set up (reboot after)
./linux/check-nvidia.sh     # optional, verify the GPU is healthy
./linux/setup.sh
./linux/start.sh --warm     # optional warm-up
cd <your-project> && opencode
./linux/stop.sh             # when done
```

## NVIDIA driver (optional)

`install-nvidia.sh` targets **Debian 13 (Trixie)**. It installs the stable
proprietary driver from NVIDIA's CUDA repository, blacklists nouveau, and
enrolls a DKMS signing key for Secure Boot. After it runs, **reboot** and
complete MOK enrollment at the blue MOK Manager screen (Enroll MOK → Continue →
enter the password you set → Reboot). Verify afterwards with `check-nvidia.sh`.

## Desktop chat UI (optional)

Ollama ships **no GUI on Linux** — only the CLI/server. For a desktop chat
experience, `install-alpaca.sh` installs **Alpaca** (a native GTK4 app, via
Flathub) and wires it to your existing local Ollama server, so the tuned aliases
(`qcoder`, `agentic`, `general`, `qcoder-fast`) appear in a chat window:

```bash
./linux/install-alpaca.sh
flatpak run com.jeffser.Alpaca   # or launch "Alpaca" from your app menu
```

In Alpaca's preferences, add an Ollama instance pointing at
`http://localhost:11434` to use the local models and GPU tuning. Enable
"Run in Background" for tray-like behavior.

## Web search (optional)

Web search is disabled by default. To enable it:

1. Get a free Tavily API key at <https://app.tavily.com> (1 000 searches/month).
2. Open `setup.sh` and edit the two variables near the top:
   ```bash
   ENABLE_WEB_SEARCH="1"
   TAVILY_API_KEY="tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
   ```
3. Re-run `./linux/setup.sh`.

The key is embedded directly in the generated `mcp.tavily.url` inside
`~/.config/opencode/opencode.json` (chmod 600) — there is no separate `.env`
file.

**Privacy:** when the agent invokes `tavily_search`, that query is sent to
Tavily's API (`api.tavily.com`). Everything else — model inference, code, file
contents — stays on `localhost`.

## Requirements

- Linux (Debian/Ubuntu; the driver installer targets Debian 13 / Trixie)
- NVIDIA RTX GPU with ~8 GB VRAM
- Internet access, `curl`, and `sudo` for installs
