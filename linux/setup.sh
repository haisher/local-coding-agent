#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
# qwen2.5-coder:7b (dense): purpose-built code model, the best fit for 8GB
# VRAM GPUs (~5-6GB resident, fully GPU-offloaded). Note: qwen3-coder has no
# small dense release (only 30b/480b MoE), so it doesn't fit this hardware
# tier. Native context is 32768 (32K); capped below for VRAM headroom.
# Sampling matches Qwen's official Qwen2.5-Coder-7B-Instruct
# generation_config.json: temperature=0.7, top_p=0.8, top_k=20,
# repetition_penalty=1.1.
MODEL="qwen2.5-coder:7b"
NUM_CTX="24576"
NUM_PREDICT="4096"
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
TEMPERATURE="0.7"
TOP_P="0.8"
TOP_K="20"
REPEAT_PENALTY="1.1"

INSTALL_FAST_MODEL="1"
FAST_MODEL="qwen2.5-coder:3b"
FAST_NUM_CTX="32768"
FAST_NUM_PREDICT="4096"
FAST_REPEAT_PENALTY="1.05"
FAST_TUNED_NAME="qcoder-fast"

# Agentic / tool-calling model. granite4:7b-a1b-h (IBM Granite 4 "tiny-h"):
# hybrid Mamba-2/Transformer MoE, 7B total / ~1B active, Q4_K_M (4.2GB), native
# tool-calling, Apache-2.0. Constant-size Mamba state keeps KV cheap, so large
# context fits comfortably on the RTX's 8GB VRAM.
# Tuned for deterministic agentic use: IBM ships Granite 4 with greedy decoding
# (empty generation_config) and its tool-calling examples use greedy, so
# temperature is 0.0 for the most reliable, reproducible tool calls. top_p/top_k
# are ignored under greedy; a small repeat_penalty guards against decode loops.
INSTALL_AGENTIC_MODEL="1"
AGENTIC_MODEL="granite4:7b-a1b-h"
AGENTIC_NUM_CTX="32768"
AGENTIC_NUM_PREDICT="4096"
AGENTIC_TEMPERATURE="0.0"
AGENTIC_TOP_P="0.9"
AGENTIC_TOP_K="40"
AGENTIC_REPEAT_PENALTY="1.05"
AGENTIC_TUNED_NAME="agentic"

# General-purpose model. qwen3.5:4b (Qwen3.5 4B): hybrid Gated DeltaNet + sparse
# MoE, multimodal-capable, native tool-calling, 256K context window, Q4_K_M
# (~3.4GB). Strong instruction following and agentic reasoning for its size.
# Context is capped below the model's 256K max so it fits the RTX's 8GB VRAM.
# Sampling defaults follow Qwen3.5's shipped recommendation (temperature 1.0,
# top_p 0.95, top_k 20, presence_penalty 1.5 to curb repetition).
INSTALL_GENERAL_MODEL="1"
GENERAL_MODEL="qwen3.5:4b"
GENERAL_NUM_CTX="32768"
GENERAL_NUM_PREDICT="4096"
GENERAL_TEMPERATURE="1.0"
GENERAL_TOP_P="0.95"
GENERAL_TOP_K="20"
GENERAL_REPEAT_PENALTY="1.0"
GENERAL_PRESENCE_PENALTY="1.5"
GENERAL_TUNED_NAME="general"

INSTALL_OPENCODE="1"
TUNED_NAME="qcoder"

# Optional: web search via Tavily MCP (disabled by default).
# 1. Get a free API key at https://app.tavily.com (1 000 searches/month).
# 2. Set ENABLE_WEB_SEARCH="1" and paste your key below.
# 3. Re-run ./linux/setup.sh to apply.
# Privacy: when the agent invokes the Tavily MCP tool, the search query leaves
# your machine and is sent to Tavily's API (api.tavily.com). Model inference,
# source code, and all other tool calls stay on localhost. Disable at any time
# by setting ENABLE_WEB_SEARCH="0" and re-running ./linux/setup.sh.
ENABLE_WEB_SEARCH="0"
TAVILY_API_KEY=""      # e.g. tvly-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX

UPDATE_MODELS="0"          # re-pull model tags even if present

API_URL="http://localhost:11434"
OPENAI_URL="http://localhost:11434/v1/chat/completions"

export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE

log() { echo "[setup-linux] $*"; }
warn() { echo "[setup-linux] warning: $*" >&2; }
fail() { echo "[setup-linux] error: $*" >&2; exit 1; }

# Single cleanup path for success, failure, or interruption.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "This step requires root privileges (install sudo or run as root)."
  fi
}

is_debian_like() {
  [[ -f /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" || "${ID:-}" == "debian" || "${ID_LIKE:-}" == *debian* ]]
}

log "Disclaimer: this setup expects Debian/Ubuntu Linux, internet access, curl, and sudo rights."

if [[ $# -ne 0 ]]; then
  fail "No runtime arguments supported. Edit config at the top of this file."
fi

command -v curl >/dev/null 2>&1 || fail "curl is required. Install curl, then re-run."
[[ "$(uname -s)" == "Linux" ]] || fail "This script is for Linux."
is_debian_like || fail "This script supports Debian/Ubuntu only."

if ! command -v ollama >/dev/null 2>&1; then
  log "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
else
  log "Ollama already installed."
fi

# jq is required to build and validate opencode.json.
if [[ "$INSTALL_OPENCODE" == "1" ]] && ! command -v jq >/dev/null 2>&1; then
  log "Installing jq..."
  run_as_root apt-get update
  run_as_root apt-get install -y jq
fi

# Note: unlike Qwen Code, OpenCode bundles its own ripgrep binary internally
# (packages/core/src/ripgrep.ts), so no separate system ripgrep install is
# required for its file search tool.

# Ensure systemd service has required environment variables
if systemctl is-enabled ollama >/dev/null 2>&1; then
  OVERRIDE_DIR="/etc/systemd/system/ollama.service.d"
  OVERRIDE_FILE="$OVERRIDE_DIR/override.conf"
  DESIRED_CONTENT="[Service]
Environment=\"OLLAMA_FLASH_ATTENTION=$OLLAMA_FLASH_ATTENTION\"
Environment=\"OLLAMA_KV_CACHE_TYPE=$OLLAMA_KV_CACHE_TYPE\""

  if [[ ! -f "$OVERRIDE_FILE" ]] || [[ "$(cat "$OVERRIDE_FILE" 2>/dev/null)" != "$DESIRED_CONTENT" ]]; then
    log "Configuring systemd environment (flash_attention=$OLLAMA_FLASH_ATTENTION, kv_cache=$OLLAMA_KV_CACHE_TYPE)..."
    run_as_root mkdir -p "$OVERRIDE_DIR"
    echo "$DESIRED_CONTENT" | run_as_root tee "$OVERRIDE_FILE" >/dev/null
    run_as_root systemctl daemon-reload
    run_as_root systemctl restart ollama
    sleep 3
  fi
fi

start_server() {
  if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    return
  fi
  if systemctl is-enabled ollama >/dev/null 2>&1; then
    log "Starting Ollama via systemd..."
    run_as_root systemctl start ollama
  else
    log "Starting Ollama server..."
    nohup ollama serve >/tmp/ollama.log 2>&1 &
  fi
  for _ in $(seq 1 30); do
    curl -fsS "$API_URL/api/version" >/dev/null 2>&1 && return
    sleep 1
  done
  fail "Ollama did not start. See /tmp/ollama.log or journalctl -u ollama"
}

pull_and_tune() {
  local base="$1" tuned="$2" ctx="$3" rep="${4:-$REPEAT_PENALTY}"
  local temp="${5:-$TEMPERATURE}" topp="${6:-$TOP_P}" topk="${7:-$TOP_K}"
  local predict="${8:-$NUM_PREDICT}" presence="${9:-}"
  local mf

  if [[ "$UPDATE_MODELS" == "1" ]] || ! ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "$base"; then
    log "Pulling $base..."
    ollama pull "$base"
  fi

  mf="$TMP_DIR/Modelfile-${tuned//[:\/]/-}"
  cat >"$mf" <<EOF
FROM $base
PARAMETER num_ctx $ctx
PARAMETER num_predict $predict
PARAMETER temperature $temp
PARAMETER top_p $topp
PARAMETER top_k $topk
PARAMETER repeat_penalty $rep
EOF
  if [[ -n "$presence" ]]; then
    echo "PARAMETER presence_penalty $presence" >>"$mf"
  fi
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
pull_and_tune "$MODEL" "$TUNED_NAME" "$NUM_CTX"

if [[ "$INSTALL_FAST_MODEL" == "1" ]]; then
  pull_and_tune "$FAST_MODEL" "$FAST_TUNED_NAME" "$FAST_NUM_CTX" "$FAST_REPEAT_PENALTY" \
    "$TEMPERATURE" "$TOP_P" "$TOP_K" "$FAST_NUM_PREDICT"
fi

if [[ "$INSTALL_AGENTIC_MODEL" == "1" ]]; then
  pull_and_tune "$AGENTIC_MODEL" "$AGENTIC_TUNED_NAME" "$AGENTIC_NUM_CTX" \
    "$AGENTIC_REPEAT_PENALTY" "$AGENTIC_TEMPERATURE" "$AGENTIC_TOP_P" "$AGENTIC_TOP_K" \
    "$AGENTIC_NUM_PREDICT"
fi

if [[ "$INSTALL_GENERAL_MODEL" == "1" ]]; then
  pull_and_tune "$GENERAL_MODEL" "$GENERAL_TUNED_NAME" "$GENERAL_NUM_CTX" \
    "$GENERAL_REPEAT_PENALTY" "$GENERAL_TEMPERATURE" "$GENERAL_TOP_P" "$GENERAL_TOP_K" \
    "$GENERAL_NUM_PREDICT" "$GENERAL_PRESENCE_PENALTY"
fi

if [[ "$INSTALL_OPENCODE" == "1" ]]; then
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  else
    NODE_MAJOR=0
  fi

  if (( NODE_MAJOR < 22 )); then
    log "Installing Node.js 22..."
    run_as_root apt-get update
    run_as_root apt-get install -y ca-certificates curl gnupg
    run_as_root mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | run_as_root gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    NODE_MAJOR=22
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | run_as_root tee /etc/apt/sources.list.d/nodesource.list >/dev/null
    run_as_root apt-get update
    run_as_root apt-get install -y nodejs
  fi

  if ! command -v opencode >/dev/null 2>&1; then
    log "Installing opencode CLI..."
    NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
    if [[ -w "$NPM_PREFIX" ]]; then
      npm install -g opencode-ai@latest
    else
      run_as_root npm install -g opencode-ai@latest
    fi
  fi

  # uv is required at runtime to launch mcp-server-git.
  if ! command -v uvx >/dev/null 2>&1; then
    log "Installing uv (for mcp-server-git)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
  fi

  OPENCODE_DIR="$HOME/.config/opencode"
  OPENCODE_CONFIG="$OPENCODE_DIR/opencode.json"
  mkdir -p "$OPENCODE_DIR"

  # This script is the sole owner of opencode.json (no manual-edit merging is
  # needed/supported) — it is regenerated from the config variables above on
  # every run, so re-running setup.sh is always idempotent and reproducible.

  # --- Provider: a single "ollama" custom OpenAI-compatible provider exposing
  # every tuned local alias this setup creates. ---
  MODELS_JSON="$(jq -n \
    --arg qcoder "$TUNED_NAME" \
    --arg agentic "$AGENTIC_TUNED_NAME" \
    --arg general "$GENERAL_TUNED_NAME" \
    --arg fast "$FAST_TUNED_NAME" \
    --argjson install_agentic "$([[ "$INSTALL_AGENTIC_MODEL" == "1" ]] && echo true || echo false)" \
    --argjson install_general "$([[ "$INSTALL_GENERAL_MODEL" == "1" ]] && echo true || echo false)" \
    --argjson install_fast "$([[ "$INSTALL_FAST_MODEL" == "1" ]] && echo true || echo false)" \
    '
    {($qcoder): {"name": ($qcoder + " (daily driver)")}}
    + (if $install_agentic then {($agentic): {"name": ($agentic + " (tool calling)")}} else {} end)
    + (if $install_general then {($general): {"name": ($general + " (general chat/reasoning)")}} else {} end)
    + (if $install_fast then {($fast): {"name": ($fast + " (fast/background)")}} else {} end)
    ')"

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
[[ "$INSTALL_AGENTIC_MODEL" == "1" ]] && openai_check "$AGENTIC_TUNED_NAME"
[[ "$INSTALL_GENERAL_MODEL" == "1" ]] && openai_check "$GENERAL_TUNED_NAME"

# Preload the daily model last so it is the resident model after setup.
log "Preloading daily model: $TUNED_NAME"
preload_model "$TUNED_NAME" "30m" || warn "Unable to preload $TUNED_NAME"

PROC_INFO="$(ollama ps 2>/dev/null || true)"
if [[ -n "$PROC_INFO" ]]; then
  log "ollama ps:"
  printf '%s\n' "$PROC_INFO"
  if printf '%s\n' "$PROC_INFO" | awk 'NR > 1 && $0 !~ /100% GPU/ {found=1} END {exit !found}'; then
    warn "At least one loaded model may not be fully GPU-resident (check VRAM / num_ctx)."
  fi
fi

log "Done. Start with: ./linux/start.sh --warm (or without --warm)"
