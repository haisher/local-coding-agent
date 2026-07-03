#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
TUNED_NAME="qcoder"
QUALITY_TUNED_NAME="qcoder-quality"
VISION_TUNED_NAME="qcoder-vision"
GPTOSS_TUNED_NAME="gptoss"
FAST_TUNED_NAME="qcoder-fast"
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
API_URL="http://localhost:11434"

export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE

log() { echo "[start] $*"; }
fail() { echo "[start] error: $*" >&2; exit 1; }

# Only allow --warm so usage stays simple and predictable.
if [[ $# -gt 1 ]]; then
  fail "Only --warm is supported."
fi
if [[ $# -eq 1 && "${1:-}" != "--warm" ]]; then
  fail "Only --warm is supported."
fi

command -v ollama >/dev/null 2>&1 || fail "Ollama is not installed. Run ./setup.sh first."
command -v curl >/dev/null 2>&1 || fail "curl is required."

# Persist runtime env for Ollama.app (it does not inherit this script's exports
# when already running or launched from the Dock). Newly started processes pick
# these up; an already-running server keeps its previous environment.
if command -v launchctl >/dev/null 2>&1; then
  launchctl setenv OLLAMA_FLASH_ATTENTION "$OLLAMA_FLASH_ATTENTION" 2>/dev/null || true
  launchctl setenv OLLAMA_KV_CACHE_TYPE "$OLLAMA_KV_CACHE_TYPE" 2>/dev/null || true
fi

# Prefer the macOS app as the service owner; fall back to a CLI server.
start_ollama() {
  if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    log "Ollama is already running."
    return
  fi

  if [[ -d "/Applications/Ollama.app" ]]; then
    log "Starting Ollama.app..."
    open -a Ollama
  else
    log "Starting Ollama CLI server..."
    nohup ollama serve >/tmp/ollama.log 2>&1 &
  fi

  for _ in $(seq 1 30); do
    if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
      log "Ollama is running."
      return
    fi
    sleep 1
  done

  fail "Ollama did not start. Check Ollama.app or /tmp/ollama.log."
}

start_ollama

# Optional warm-up: preload (not generate) so first response is faster and the
# daily model is the resident one.
if [[ "${1:-}" == "--warm" ]]; then
  log "Preloading model: $TUNED_NAME"
  curl -fsS "$API_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$TUNED_NAME\",\"messages\":[],\"keep_alive\":\"30m\"}" \
    >/dev/null || fail "Preload failed for model '$TUNED_NAME'."
fi

log "Ready. Use opencode in your project."
log "Models: $TUNED_NAME (daily), $QUALITY_TUNED_NAME (quality), $VISION_TUNED_NAME (vision), $FAST_TUNED_NAME (fast), $GPTOSS_TUNED_NAME (second opinion)"
