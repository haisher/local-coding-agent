#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
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

INSTALL_QWEN_CODE="1"
TUNED_NAME="qcoder"

UPDATE_MODELS="0"          # re-pull model tags even if present
MAX_SETTINGS_BACKUPS="10"  # cap settings.json backups

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

# jq is required to merge Qwen Code settings without clobbering user keys.
if [[ "$INSTALL_QWEN_CODE" == "1" ]] && ! command -v jq >/dev/null 2>&1; then
  log "Installing jq..."
  run_as_root apt-get update
  run_as_root apt-get install -y jq
fi

# ripgrep (rg) is used by Qwen Code's file crawler. Without it the crawler logs
# "spawn rg ENOENT" and falls back to a slower scanner.
if [[ "$INSTALL_QWEN_CODE" == "1" ]] && ! command -v rg >/dev/null 2>&1; then
  log "Installing ripgrep..."
  run_as_root apt-get update
  run_as_root apt-get install -y ripgrep
fi

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

if [[ "$INSTALL_QWEN_CODE" == "1" ]]; then
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

  if ! command -v qwen >/dev/null 2>&1; then
    log "Installing qwen CLI..."
    NPM_PREFIX="$(npm prefix -g 2>/dev/null || echo /usr/local)"
    if [[ -w "$NPM_PREFIX" ]]; then
      npm install -g @qwen-code/qwen-code@latest
    else
      run_as_root npm install -g @qwen-code/qwen-code@latest
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
  if [[ "$INSTALL_AGENTIC_MODEL" == "1" ]]; then
    OWNED_IDS+=("$AGENTIC_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$AGENTIC_TUNED_NAME" "$AGENTIC_MODEL" "$AGENTIC_NUM_CTX")")
  fi
  if [[ "$INSTALL_GENERAL_MODEL" == "1" ]]; then
    OWNED_IDS+=("$GENERAL_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$GENERAL_TUNED_NAME" "$GENERAL_MODEL" "$GENERAL_NUM_CTX")")
  fi
  if [[ "$INSTALL_FAST_MODEL" == "1" ]]; then
    OWNED_IDS+=("$FAST_TUNED_NAME")
    PROVIDER_LIST+=("$(provider_entry "$FAST_TUNED_NAME" "$FAST_MODEL" "$FAST_NUM_CTX")")
  fi

  PROVIDER_ENTRIES=""
  for i in "${!PROVIDER_LIST[@]}"; do
    (( i > 0 )) && PROVIDER_ENTRIES+=$',\n'
    PROVIDER_ENTRIES+="${PROVIDER_LIST[$i]}"
  done

  OWNED_IDS_JSON="$(printf '%s\n' "${OWNED_IDS[@]}" | jq -R . | jq -sc .)"

  FAST_MODEL_LINE=""
  [[ "$INSTALL_FAST_MODEL" == "1" ]] && FAST_MODEL_LINE="  \"fastModel\": \"$FAST_TUNED_NAME\","

  # Build only the keys this setup owns, then merge into any existing settings
  # so MCP servers, hooks, and unrelated OpenAI providers are preserved.
  OWNED_SETTINGS="$TMP_DIR/owned-settings.json"
  cat >"$OWNED_SETTINGS" <<EOF
{
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
    "approvalMode": "auto-edit"
  },
  "privacy": {
    "usageStatisticsEnabled": false
  },
  "ui": {
    "shellOutputMaxLines": 200
  }
}
EOF

  jq empty "$OWNED_SETTINGS" || fail "Generated settings are not valid JSON."

  prune_settings_backups() {
    local count=0 file
    while IFS= read -r file; do
      count=$((count + 1))
      (( count > MAX_SETTINGS_BACKUPS )) && rm -f "$file"
    done < <(ls -1t "$QWEN_DIR"/settings.json.bak.* 2>/dev/null)
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
