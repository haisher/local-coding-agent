#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
# Daily driver: Qwen3.8 27B dense, Apple-optimized MLX build.
# The 27B dense runs fully in 64 GB unified memory with strong throughput.
MODEL="qwen3.8:27b-mlx"
NUM_CTX="65536"
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"

# Thinking-mode "precise coding" sampling profile (Qwen recommended).
# Do NOT reuse these for non-thinking / background models.
TEMPERATURE="0.6"
TOP_P="0.95"
TOP_K="20"
REPEAT_PENALTY="1.0"

# Optional faster daily profile (4-bit MLX) for A/B comparison. Off by default
# so it does not add a large download.
INSTALL_SPEED_MODEL="0"
SPEED_MODEL="qwen3.6:35b-a3b-coding-nvfp4"
SPEED_NUM_CTX="65536"
SPEED_TUNED_NAME="qcoder-speed"

# Multimodal fallback so switching the default to a text-only MLX build does
# not silently drop image input. Reuses the standard (vision-capable) tag.
INSTALL_VISION_FALLBACK="1"
VISION_MODEL="qwen3.6:35b-a3b"
VISION_NUM_CTX="65536"
VISION_TUNED_NAME="qcoder-vision"

# Quality tier: Qwen3.8 27B full-precision (non-MLX). Slightly slower than the
# daily MLX build but potentially higher accuracy for hard bugs / big refactors.
# Switch to it on demand from OpenCode.
INSTALL_QUALITY_MODEL="1"
QUALITY_MODEL="qwen3.8:27b"
QUALITY_NUM_CTX="65536"
QUALITY_TUNED_NAME="qcoder-quality"

# Lightweight background model used by OpenCode's small_model.
INSTALL_FAST_MODEL="1"
FAST_MODEL="qwen3.5:4b"
FAST_NUM_CTX="32768"
FAST_TUNED_NAME="qcoder-fast"
# Fast model keeps its own (non-thinking-oriented) sampling.
FAST_TEMPERATURE="0.7"
FAST_TOP_P="0.8"
FAST_TOP_K="20"
FAST_REPEAT_PENALTY="1.0"

# Independent second-opinion reasoner.
INSTALL_GPTOSS_MODEL="1"
GPTOSS_MODEL="gpt-oss:20b"
GPTOSS_NUM_CTX="65536"
GPTOSS_TEMPERATURE="1.0"
GPTOSS_TOP_P="1.0"
GPTOSS_TOP_K="0"
GPTOSS_REPEAT_PENALTY="1.0"
GPTOSS_REASONING_EFFORT="medium"
GPTOSS_TUNED_NAME="gptoss"

INSTALL_OPENCODE="1"
TUNED_NAME="qcoder"

# Optional: web search via Tavily MCP (disabled by default).
# 1. Get a free API key at https://app.tavily.com (1 000 searches/month).
# 2. Set ENABLE_WEB_SEARCH="1" and paste your key below.
# 3. Re-run ./setup.sh to apply.
# Privacy: when the agent invokes tavily_search, the search query leaves your
# machine and is sent to Tavily's API (api.tavily.com). Model inference, source
# code, and all other tool calls stay on localhost. Disable at any time by
# setting ENABLE_WEB_SEARCH="0" and re-running ./setup.sh.
ENABLE_WEB_SEARCH="0"
TAVILY_API_KEY=""      # e.g. tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

# Behavior flags.
UPGRADE_TOOLS="0"                  # upgrade Ollama / OpenCode on this run
UPDATE_MODELS="0"                  # re-pull model tags even if present
RESTART_OLLAMA_ON_ENV_CHANGE="0"   # auto-restart Ollama to apply env changes
MIN_FREE_DISK_GB="140"             # warn below this (clean install ~110 GB + headroom)

API_URL="http://localhost:11434"
OPENAI_URL="http://localhost:11434/v1/chat/completions"

export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE

log() { echo "[setup] $*"; }
warn() { echo "[setup] warning: $*" >&2; }
fail() { echo "[setup] error: $*" >&2; exit 1; }

# Single cleanup path for success, failure, or interruption.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Clear upfront requirements so users know what must exist before setup.
log "Disclaimer: this setup expects macOS, internet access, curl, and sudo rights."
log "For best results, install Homebrew first (https://brew.sh)."

if [[ $# -ne 0 ]]; then
  fail "No runtime arguments supported. Edit config at the top of this file."
fi

command -v curl >/dev/null 2>&1 || fail "curl is required. Install curl, then re-run."

# Basic platform check for the intended setup target.
[[ "$(uname -s)" == "Darwin" ]] || fail "This script is for macOS."
if [[ "$(uname -m)" != "arm64" ]]; then
  warn "Apple Silicon (arm64) is recommended."
fi

check_disk_space() {
  local available_kb available_gb
  available_kb="$(df -Pk "$HOME" | awk 'NR == 2 {print $4}')"
  available_gb="$((available_kb / 1024 / 1024))"
  log "Available disk space: ${available_gb} GB"
  if (( available_gb < MIN_FREE_DISK_GB )); then
    warn "Less than ${MIN_FREE_DISK_GB} GB available."
    warn "A clean model install may need ~110 GB plus working headroom"
    warn "(less if Ollama already shares blobs with installed models)."
  fi
}
check_disk_space

# --- Ollama installation detection (macOS) ---
if command -v ollama >/dev/null 2>&1; then
  log "Ollama already installed."
  if [[ "$UPGRADE_TOOLS" == "1" ]] && command -v brew >/dev/null 2>&1; then
    log "Upgrading Ollama app..."
    brew upgrade --cask ollama-app || warn "Ollama upgrade skipped/failed."
  fi
elif [[ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]]; then
  export PATH="/Applications/Ollama.app/Contents/Resources:$PATH"
  log "Ollama.app found; added its CLI to PATH for this run."
else
  if command -v brew >/dev/null 2>&1; then
    log "Installing Ollama app..."
    brew install --cask ollama-app
  else
    fail "Install Ollama for macOS (DMG from https://ollama.com or 'brew install --cask ollama-app'), then rerun."
  fi
fi
command -v ollama >/dev/null 2>&1 || fail "Ollama CLI not on PATH after install."

# jq is required to build and validate opencode.json.
if [[ "$INSTALL_OPENCODE" == "1" ]] && ! command -v jq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "Installing jq..."
    brew install jq
  else
    fail "jq is required to build opencode.json. Install jq, then re-run."
  fi
fi

# --- Persist Ollama runtime env (Ollama.app does not inherit our exports) ---
persist_ollama_env() {
  command -v launchctl >/dev/null 2>&1 || return 0
  launchctl setenv OLLAMA_FLASH_ATTENTION "$OLLAMA_FLASH_ATTENTION" 2>/dev/null || true
  launchctl setenv OLLAMA_KV_CACHE_TYPE "$OLLAMA_KV_CACHE_TYPE" 2>/dev/null || true
  log "Persisted Ollama runtime environment via launchctl."
  if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    if [[ "$RESTART_OLLAMA_ON_ENV_CHANGE" == "1" ]]; then
      warn "Restarting Ollama to apply env changes..."
      ./stop.sh >/dev/null 2>&1 || true
      sleep 1
    else
      warn "Ollama is already running with its previous environment."
      warn "Apply Flash-Attention/KV changes with: ./stop.sh && ./start.sh"
    fi
  fi
}
persist_ollama_env

start_server() {
  if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    return
  fi
  log "Starting Ollama server..."
  if [[ -d "/Applications/Ollama.app" ]]; then
    open -a Ollama
  else
    nohup ollama serve >/tmp/ollama.log 2>&1 &
  fi
  for _ in $(seq 1 30); do
    curl -fsS "$API_URL/api/version" >/dev/null 2>&1 && return
    sleep 1
  done
  fail "Ollama did not start. Check Ollama.app or /tmp/ollama.log"
}

model_exists() {
  ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$1"
}

pull_and_tune() {
  local base="$1" tuned="$2" ctx="$3" rep="${4:-$REPEAT_PENALTY}"
  local temp="${5:-$TEMPERATURE}" topp="${6:-$TOP_P}" topk="${7:-$TOP_K}"
  local mf

  if [[ "$UPDATE_MODELS" == "1" ]] || ! model_exists "$base"; then
    log "Pulling $base..."
    ollama pull "$base"
  fi

  # Create a local alias with baked context and sampling defaults.
  mf="$TMP_DIR/Modelfile-${tuned//[:\/]/-}"
  cat >"$mf" <<EOF
FROM $base
PARAMETER num_ctx $ctx
PARAMETER temperature $temp
PARAMETER top_p $topp
PARAMETER top_k $topk
PARAMETER repeat_penalty $rep
EOF
  ollama create "$tuned" -f "$mf"
  log "Prepared model alias: $tuned"
}

preload_model() {
  local model="$1" keep_alive="${2:-30m}"
  curl -fsS "$API_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"messages\":[],\"keep_alive\":\"$keep_alive\"}" \
    >/dev/null
}

start_server

log "Versions: ollama=$(ollama --version 2>/dev/null | head -1 || echo unknown)"

pull_and_tune "$MODEL" "$TUNED_NAME" "$NUM_CTX"

if [[ "$INSTALL_SPEED_MODEL" == "1" ]]; then
  pull_and_tune "$SPEED_MODEL" "$SPEED_TUNED_NAME" "$SPEED_NUM_CTX"
fi

if [[ "$INSTALL_VISION_FALLBACK" == "1" ]]; then
  pull_and_tune "$VISION_MODEL" "$VISION_TUNED_NAME" "$VISION_NUM_CTX"
fi

if [[ "$INSTALL_QUALITY_MODEL" == "1" ]]; then
  pull_and_tune "$QUALITY_MODEL" "$QUALITY_TUNED_NAME" "$QUALITY_NUM_CTX"
fi

if [[ "$INSTALL_FAST_MODEL" == "1" ]]; then
  pull_and_tune "$FAST_MODEL" "$FAST_TUNED_NAME" "$FAST_NUM_CTX" \
    "$FAST_REPEAT_PENALTY" "$FAST_TEMPERATURE" "$FAST_TOP_P" "$FAST_TOP_K"
fi

if [[ "$INSTALL_GPTOSS_MODEL" == "1" ]]; then
  pull_and_tune "$GPTOSS_MODEL" "$GPTOSS_TUNED_NAME" "$GPTOSS_NUM_CTX" \
    "$GPTOSS_REPEAT_PENALTY" "$GPTOSS_TEMPERATURE" "$GPTOSS_TOP_P" "$GPTOSS_TOP_K"
fi

if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  else
    NODE_MAJOR=0
  fi

  if (( NODE_MAJOR < 22 )); then
    if command -v brew >/dev/null 2>&1; then
      log "Installing Node.js..."
      brew install node
    else
      fail "Node.js >= 22 is required."
    fi
  fi

  if ! command -v opencode >/dev/null 2>&1 || [[ "$UPGRADE_TOOLS" == "1" ]]; then
    log "Installing/upgrading opencode CLI..."
    NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
    if [[ -w "$NPM_PREFIX" ]]; then
      npm install -g opencode-ai@latest
    else
      sudo npm install -g opencode-ai@latest
    fi
  fi
  log "Versions: opencode=$(opencode --version 2>/dev/null | head -1 || echo unknown), node=$(node --version 2>/dev/null || echo unknown)"

  # uv is required at runtime to launch mcp-server-git.
  if ! command -v uvx >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      log "Installing uv (for mcp-server-git)..."
      brew install uv
    else
      log "Installing uv (for mcp-server-git)..."
      curl -LsSf https://astral.sh/uv/install.sh | sh
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi

  OPENCODE_DIR="$HOME/.config/opencode"
  OPENCODE_CONFIG="$OPENCODE_DIR/opencode.json"
  mkdir -p "$OPENCODE_DIR"

  # This script is the sole owner of opencode.json (no manual-edit merging is
  # needed/supported) — it is regenerated from the config variables above on
  # every run, so re-running setup.sh is always idempotent and reproducible.

  # --- Provider: a single "ollama" custom OpenAI-compatible provider exposing
  # every tuned local alias this setup creates. Extras (modalities, reasoning
  # options) are layered on incrementally per optional model. ---
  MODELS_JSON='{}'
  MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$TUNED_NAME" \
    '. + {($id): {"name": ($id + " (daily driver)")}}')"

  if [[ "$INSTALL_SPEED_MODEL" == "1" ]]; then
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$SPEED_TUNED_NAME" \
      '. + {($id): {"name": ($id + " (fast 4-bit MLX variant)")}}')"
  fi
  if [[ "$INSTALL_QUALITY_MODEL" == "1" ]]; then
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$QUALITY_TUNED_NAME" \
      '. + {($id): {"name": ($id + " (hard bugs / big refactors)")}}')"
  fi
  if [[ "$INSTALL_VISION_FALLBACK" == "1" ]]; then
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$VISION_TUNED_NAME" \
      '. + {($id): {"name": ($id + " (image input)"),
                    "modalities": {"input": ["text", "image"], "output": ["text"]},
                    "attachment": true}}')"
  fi
  if [[ "$INSTALL_GPTOSS_MODEL" == "1" ]]; then
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$GPTOSS_TUNED_NAME" --arg effort "$GPTOSS_REASONING_EFFORT" \
      '. + {($id): {"name": ($id + " (independent second opinion)"),
                    "reasoning": true,
                    "options": {"reasoning_effort": $effort}}}')"
  fi
  if [[ "$INSTALL_FAST_MODEL" == "1" ]]; then
    MODELS_JSON="$(echo "$MODELS_JSON" | jq --arg id "$FAST_TUNED_NAME" \
      '. + {($id): {"name": ($id + " (fast/background, thinking off)"),
                    "options": {"enableThinking": false}}}')"
  fi

  # --- MCP servers: git and memory are always included; Tavily is optional ---
  MEMORY_FILE_PATH="$OPENCODE_DIR/mcp-memory.jsonl"
  MCP_JSON="$(jq -n --arg mem "$MEMORY_FILE_PATH" '{
    "git":    {"type": "local", "command": ["uvx", "mcp-server-git"], "enabled": true},
    "memory": {"type": "local", "command": ["npx", "-y", "@modelcontextprotocol/server-memory"],
               "environment": {"MEMORY_FILE_PATH": $mem}, "enabled": true}
  }')"

  if [[ "$ENABLE_WEB_SEARCH" == "1" ]]; then
    [[ -z "$TAVILY_API_KEY" ]] && fail "ENABLE_WEB_SEARCH is 1 but TAVILY_API_KEY is empty. Paste your key in the config section."
    MCP_JSON="$(echo "$MCP_JSON" | jq --arg key "$TAVILY_API_KEY" '. + {
      "tavily": {"type": "remote", "url": ("https://mcp.tavily.com/mcp/?tavilyApiKey=" + $key), "enabled": true}
    }')"
    log "Web search: Tavily MCP will be configured in opencode.json."
  fi
  log "MCP servers configured: git (uvx), memory (npx)${ENABLE_WEB_SEARCH:+, tavily (remote)}"

  SMALL_MODEL_LINE=""
  [[ "$INSTALL_FAST_MODEL" == "1" ]] && SMALL_MODEL_LINE="  \"small_model\": \"ollama/$FAST_TUNED_NAME\","

  # Write the full config directly (this file is fully generated, not
  # hand-edited) and atomically replace any previous version.
  NEW_CONFIG="$TMP_DIR/opencode.json"
  cat >"$NEW_CONFIG" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "share": "disabled",
  "autoupdate": "notify",
  "model": "ollama/$TUNED_NAME",
$SMALL_MODEL_LINE
  "permission": {
    "edit": "allow",
    "bash": "ask",
    "webfetch": "ask"
  },
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": $MODELS_JSON
    }
  },
  "mcp": $MCP_JSON
}
EOF

  jq empty "$NEW_CONFIG" || fail "Generated opencode config is not valid JSON."
  mv "$NEW_CONFIG" "$OPENCODE_CONFIG"
  chmod 600 "$OPENCODE_CONFIG"
  log "Wrote $OPENCODE_CONFIG"

  # Personal, non-git-shared default instructions. Seeded once; re-running
  # setup.sh never overwrites it so any personal notes added later survive.
  GLOBAL_AGENTS_MD="$OPENCODE_DIR/AGENTS.md"
  if [[ ! -f "$GLOBAL_AGENTS_MD" ]]; then
    cat >"$GLOBAL_AGENTS_MD" <<'EOM'
# Personal defaults (local-coding-agent)

- This is a fully local, offline setup (Ollama + OpenCode). Prefer the local
  `git` and `memory` MCP tools over re-deriving the same information.
- Do not add a "Co-authored-by" trailer to git commits unless explicitly asked.
- Keep explanations concise; this is a terminal workflow.
EOM
    log "Wrote default global instructions to $GLOBAL_AGENTS_MD"
  fi
fi

# --- Validation ---
openai_check() {
  local model="$1" extra="${2:-}" response
  response="$(curl -fsS "$OPENAI_URL" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\"$extra,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with OK\"}]}")" || {
      warn "OpenAI endpoint request failed for $model"; return 1; }
  if ! jq -e '.choices[0].message.content' >/dev/null 2>&1 <<<"$response"; then
    warn "Unexpected OpenAI response for $model"; return 1
  fi
}

openai_check "$TUNED_NAME"
[[ "$INSTALL_FAST_MODEL" == "1" ]] && openai_check "$FAST_TUNED_NAME"
[[ "$INSTALL_QUALITY_MODEL" == "1" ]] && openai_check "$QUALITY_TUNED_NAME"
[[ "$INSTALL_VISION_FALLBACK" == "1" ]] && openai_check "$VISION_TUNED_NAME"
[[ "$INSTALL_SPEED_MODEL" == "1" ]] && openai_check "$SPEED_TUNED_NAME"
[[ "$INSTALL_GPTOSS_MODEL" == "1" ]] && \
  openai_check "$GPTOSS_TUNED_NAME" ",\"reasoning_effort\":\"$GPTOSS_REASONING_EFFORT\""

# Preload the daily model last so it is the resident model after setup.
log "Preloading daily model: $TUNED_NAME"
preload_model "$TUNED_NAME" "30m" || warn "Unable to preload $TUNED_NAME"

PROC_INFO="$(ollama ps 2>/dev/null || true)"
if [[ -n "$PROC_INFO" ]]; then
  log "ollama ps:"
  printf '%s\n' "$PROC_INFO"
  if printf '%s\n' "$PROC_INFO" | awk 'NR > 1 && $0 !~ /100% GPU/ {found=1} END {exit !found}'; then
    warn "At least one loaded model may not be fully GPU-resident."
  fi
fi

log "Done. Start with: ./start.sh --warm (or without --warm)"
