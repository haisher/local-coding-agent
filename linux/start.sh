#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
TUNED_NAME="qcoder"
AGENTIC_TUNED_NAME="agentic"
FAST_TUNED_NAME="qcoder-fast"
OLLAMA_FLASH_ATTENTION="1"
OLLAMA_KV_CACHE_TYPE="q8_0"
API_URL="http://localhost:11434"

export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE

log() { echo "[start-linux] $*"; }
fail() { echo "[start-linux] error: $*" >&2; exit 1; }

if [[ $# -gt 1 ]]; then
  fail "Only --warm is supported."
fi
if [[ $# -eq 1 && "${1:-}" != "--warm" ]]; then
  fail "Only --warm is supported."
fi

command -v ollama >/dev/null 2>&1 || fail "Ollama is not installed. Run ./linux/setup.sh first."
command -v curl >/dev/null 2>&1 || fail "curl is required."

if curl -fsS --connect-timeout 5 --max-time 10 "$API_URL/api/version" >/dev/null 2>&1; then
  log "Ollama is already running."
else
  if systemctl is-enabled ollama >/dev/null 2>&1; then
    log "Starting Ollama via systemd..."
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
      systemctl start ollama
    elif command -v sudo >/dev/null 2>&1; then
      sudo systemctl start ollama
    else
      fail "Need sudo to start the systemd-managed Ollama service."
    fi
  else
    log "Starting Ollama..."
    nohup ollama serve >/tmp/ollama.log 2>&1 &
  fi
  for _ in $(seq 1 30); do
    curl -fsS --connect-timeout 2 --max-time 5 "$API_URL/api/version" >/dev/null 2>&1 && break
    sleep 1
  done
  curl -fsS --connect-timeout 5 --max-time 10 "$API_URL/api/version" >/dev/null 2>&1 || fail "Ollama did not start. See /tmp/ollama.log or journalctl -u ollama"
  log "Ollama is running."
fi

if [[ "${1:-}" == "--warm" ]]; then
  log "Preloading model: $TUNED_NAME"
  curl -fsS --max-time 120 "$API_URL/api/chat" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$TUNED_NAME\",\"messages\":[],\"keep_alive\":\"30m\"}" \
    >/dev/null || fail "Preload failed for model '$TUNED_NAME'."
fi

log "Ready. Use qwen in your project."
log "Models: $TUNED_NAME, $AGENTIC_TUNED_NAME, $FAST_TUNED_NAME"
