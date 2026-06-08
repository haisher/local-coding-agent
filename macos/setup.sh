#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
# Daily driver: Apple-optimized MLX 8-bit build of the 35B-A3B MoE.
# On a 64 GB Mac this trades some throughput for fidelity while staying fast
# (only ~3B params are active per token). MLX coding tags are text-only.
MODEL="qwen3.6:35b-a3b-coding-mxfp8"
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

# Quality tier: dense 27B (MLX 8-bit). Stronger on hard bugs / big refactors,
# slower to decode. Switch to it on demand from Qwen Code.
INSTALL_QUALITY_MODEL="1"
QUALITY_MODEL="qwen3.6:27b-coding-mxfp8"
QUALITY_NUM_CTX="65536"
QUALITY_TUNED_NAME="qcoder-quality"

# Lightweight background model used by Qwen Code's fastModel.
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

INSTALL_QWEN_CODE="1"
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
UPGRADE_TOOLS="0"                  # upgrade Ollama / Qwen Code on this run
UPDATE_MODELS="0"                  # re-pull model tags even if present
RESTART_OLLAMA_ON_ENV_CHANGE="0"   # auto-restart Ollama to apply env changes
MIN_FREE_DISK_GB="140"             # warn below this (clean install ~110 GB + headroom)
MAX_SETTINGS_BACKUPS="10"          # cap settings.json backups

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

# jq is required to merge Qwen Code settings without clobbering user keys.
if [[ "$INSTALL_QWEN_CODE" == "1" ]] && ! command -v jq >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "Installing jq..."
    brew install jq
  else
    fail "jq is required to safely merge Qwen Code settings. Install jq, then re-run."
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

if [[ "$INSTALL_QWEN_CODE" == "1" ]]; then
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

  if ! command -v qwen >/dev/null 2>&1 || [[ "$UPGRADE_TOOLS" == "1" ]]; then
    log "Installing/upgrading qwen CLI..."
    NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
    if [[ -w "$NPM_PREFIX" ]]; then
      npm install -g @qwen-code/qwen-code@latest
    else
      sudo npm install -g @qwen-code/qwen-code@latest
    fi
  fi
  log "Versions: qwen=$(qwen --version 2>/dev/null | head -1 || echo unknown), node=$(node --version 2>/dev/null || echo unknown)"

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

  QWEN_DIR="$HOME/.qwen"
  QWEN_SETTINGS="$QWEN_DIR/settings.json"
  mkdir -p "$QWEN_DIR"

  provider_entry() {
    local _id="$1" _base="$2" _ctx="$3"
    local _gen_extra=""
    [[ -n "${4:-}" ]] && _gen_extra=$',\n          '"$4"
    cat <<EOF
      {
        "id": "$_id",
        "name": "$_id (local Ollama)",
        "baseUrl": "http://localhost:11434/v1",
        "envKey": "OLLAMA_API_KEY",
        "description": "$_base served locally via Ollama",
        "generationConfig": {
          "contextWindowSize": $_ctx,
          "timeout": 300000$_gen_extra
        }
      }
EOF
  }

  PROVIDER_LIST=()
  OWNED_IDS=("$TUNED_NAME")
  PROVIDER_LIST+=("$(provider_entry "$TUNED_NAME" "$MODEL" "$NUM_CTX")")

  if [[ "$INSTALL_SPEED_MODEL" == "1" ]]; then
    OWNED_IDS+=("$SPEED_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$SPEED_TUNED_NAME" "$SPEED_MODEL" "$SPEED_NUM_CTX")")
  fi
  if [[ "$INSTALL_QUALITY_MODEL" == "1" ]]; then
    OWNED_IDS+=("$QUALITY_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$QUALITY_TUNED_NAME" "$QUALITY_MODEL" "$QUALITY_NUM_CTX")")
  fi
  if [[ "$INSTALL_VISION_FALLBACK" == "1" ]]; then
    OWNED_IDS+=("$VISION_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$VISION_TUNED_NAME" "$VISION_MODEL" "$VISION_NUM_CTX" \
      "\"modalities\": { \"image\": true }")")
  fi
  if [[ "$INSTALL_GPTOSS_MODEL" == "1" ]]; then
    OWNED_IDS+=("$GPTOSS_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$GPTOSS_TUNED_NAME" "$GPTOSS_MODEL" "$GPTOSS_NUM_CTX" \
      "\"extra_body\": { \"reasoning_effort\": \"$GPTOSS_REASONING_EFFORT\" }")")
  fi
  if [[ "$INSTALL_FAST_MODEL" == "1" ]]; then
    OWNED_IDS+=("$FAST_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$FAST_TUNED_NAME" "$FAST_MODEL" "$FAST_NUM_CTX" \
      "\"enableThinking\": false")")
  fi

  PROVIDER_ENTRIES=""
  for i in "${!PROVIDER_LIST[@]}"; do
    (( i > 0 )) && PROVIDER_ENTRIES+=$',\n'
    PROVIDER_ENTRIES+="${PROVIDER_LIST[$i]}"
  done

  OWNED_IDS_JSON="$(printf '%s\n' "${OWNED_IDS[@]}" | jq -R . | jq -sc .)"

  FAST_MODEL_LINE=""
  [[ "$INSTALL_FAST_MODEL" == "1" ]] && FAST_MODEL_LINE="  \"fastModel\": \"$FAST_TUNED_NAME\","

  # --- MCP servers: git and memory are always included; Tavily is optional ---
  MEMORY_FILE_PATH="$HOME/.qwen/mcp-memory.jsonl"
  MCP_SERVERS_JSON="$(jq -n --arg mem "$MEMORY_FILE_PATH" '{
    "git":    {"command": "uvx", "args": ["mcp-server-git"]},
    "memory": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory"],
               "env": {"MEMORY_FILE_PATH": $mem}}
  }')"

  if [[ "$ENABLE_WEB_SEARCH" == "1" ]]; then
    [[ -z "$TAVILY_API_KEY" ]] && fail "ENABLE_WEB_SEARCH is 1 but TAVILY_API_KEY is empty. Paste your key in the config section."
    MCP_SERVERS_JSON="$(echo "$MCP_SERVERS_JSON" | jq '. + {
      "tavily": {"httpUrl": "https://mcp.tavily.com/mcp/?tavilyApiKey=${TAVILY_API_KEY}"}
    }')"
    log "Web search: Tavily MCP will be configured in settings.json."
  fi
  log "MCP servers configured: git (uvx), memory (npx)${ENABLE_WEB_SEARCH:+, tavily (http)}"

  # Build only the keys this setup owns, then merge into any existing settings
  # so MCP servers, hooks, and unrelated OpenAI providers are preserved.
  OWNED_SETTINGS="$TMP_DIR/owned-settings.json"
  cat >"$OWNED_SETTINGS" <<EOF
{
  "mcpServers": $MCP_SERVERS_JSON,
  "modelProviders": {
    "openai": [
$PROVIDER_ENTRIES
    ]
  },
$FAST_MODEL_LINE
  "security": {
    "auth": {
      "selectedType": "openai"
    }
  },
  "model": {
    "name": "$TUNED_NAME",
    "skipLoopDetection": false
  },
  "general": {
    "showSessionRecap": true,
    "checkpointing": {
      "enabled": true
    }
  },
  "memory": {
    "enableManagedAutoDream": true
  },
  "tools": {
    "approvalMode": "auto-edit",
    "shell": {
      "enableInteractiveShell": true,
      "showColor": true
    }
  },
  "privacy": {
    "usageStatisticsEnabled": false
  },
  "ui": {
    "shellOutputMaxLines": 500
  }
}
EOF

  jq empty "$OWNED_SETTINGS" || fail "Generated settings are not valid JSON."

  prune_settings_backups() {
    local count=0 file
    while IFS= read -r file; do
      count=$((count + 1))
      if (( count > MAX_SETTINGS_BACKUPS )); then
        rm -f "$file"
      fi
    done < <(ls -1t "$QWEN_DIR"/settings.json.bak.* 2>/dev/null)
    return 0
  }

  MERGED_SETTINGS="$TMP_DIR/merged-settings.json"
  if [[ -f "$QWEN_SETTINGS" ]] && jq empty "$QWEN_SETTINGS" >/dev/null 2>&1; then
    cp "$QWEN_SETTINGS" "$QWEN_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
    prune_settings_backups
    # Deep-merge unrelated keys; replace only the provider entries we own,
    # preserving any other OpenAI-compatible providers by ID.
    jq -s --argjson owned_ids "$OWNED_IDS_JSON" '
      .[0] as $existing | .[1] as $owned |
      ($existing * $owned)
      | .modelProviders.openai =
          (
            (
              ($existing.modelProviders.openai // [])
              | map(select(.id as $i | ($owned_ids | index($i)) | not))
            )
            + ($owned.modelProviders.openai // [])
          )
    ' "$QWEN_SETTINGS" "$OWNED_SETTINGS" >"$MERGED_SETTINGS" \
      || fail "Failed to merge settings."
  else
    if [[ -f "$QWEN_SETTINGS" ]]; then
      warn "$QWEN_SETTINGS is not valid JSON; backing up and replacing it."
      cp "$QWEN_SETTINGS" "$QWEN_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
      prune_settings_backups
    fi
    cp "$OWNED_SETTINGS" "$MERGED_SETTINGS"
  fi
  cp "$MERGED_SETTINGS" "$QWEN_SETTINGS"

  QWEN_ENV="$QWEN_DIR/.env"
  touch "$QWEN_ENV"
  chmod 600 "$QWEN_ENV"
  if ! grep -q '^OLLAMA_API_KEY=' "$QWEN_ENV" 2>/dev/null; then
    echo 'OLLAMA_API_KEY=ollama' >> "$QWEN_ENV"
    log "Wrote OLLAMA_API_KEY to $QWEN_ENV"
  fi

  if [[ "$ENABLE_WEB_SEARCH" == "1" ]]; then
    # Remove any existing entry, then append the (possibly updated) key.
    grep -v '^TAVILY_API_KEY=' "$QWEN_ENV" > "$TMP_DIR/env-stripped" 2>/dev/null || true
    cat "$TMP_DIR/env-stripped" > "$QWEN_ENV"
    echo "TAVILY_API_KEY=$TAVILY_API_KEY" >> "$QWEN_ENV"
    log "Wrote TAVILY_API_KEY to $QWEN_ENV"
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
