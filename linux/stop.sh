#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
API_URL="http://localhost:11434"
OLLAMA_PROCESS_MATCH="ollama serve"

log() { echo "[stop-linux] $*"; }
warn() { echo "[stop-linux] warning: $*" >&2; }
fail() { echo "[stop-linux] error: $*" >&2; exit 1; }

if [[ $# -ne 0 ]]; then
  fail "No runtime arguments supported."
fi

command -v curl >/dev/null 2>&1 || fail "curl is required."

if ! curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
  log "Ollama is not running."
  exit 0
fi

if systemctl is-active ollama >/dev/null 2>&1; then
  log "Stopping Ollama via systemd..."
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    systemctl stop ollama
  elif command -v sudo >/dev/null 2>&1; then
    sudo systemctl stop ollama
  else
    fail "Need sudo to stop the systemd-managed Ollama service."
  fi
else
  PIDS="$(pgrep -f "$OLLAMA_PROCESS_MATCH" || true)"
  if [[ -z "$PIDS" ]]; then
    warn "API is up, but no '$OLLAMA_PROCESS_MATCH' process was found."
    warn "It may have been started another way. Stop it manually if needed."
    exit 0
  fi

  log "Stopping Ollama..."
  for pid in $PIDS; do
    kill "$pid" 2>/dev/null || true
  done
fi

for _ in $(seq 1 10); do
  if ! curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    log "Stopped."
    exit 0
  fi
  sleep 1
done

warn "Ollama still responds at $API_URL."
