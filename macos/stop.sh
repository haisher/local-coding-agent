#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration (edit here)
# =========================
API_URL="http://localhost:11434"

log() { echo "[stop] $*"; }
warn() { echo "[stop] warning: $*" >&2; }
fail() { echo "[stop] error: $*" >&2; exit 1; }

if [[ $# -ne 0 ]]; then
  fail "No runtime arguments supported."
fi

command -v curl >/dev/null 2>&1 || fail "curl is required."

# If the API is already down, there is nothing to stop.
if ! curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
  log "Ollama is not running."
  exit 0
fi

log "Stopping Ollama..."

# Gracefully quit the macOS menubar app first. It supervises the `ollama serve`
# process and will immediately respawn it if only the child is killed, so the
# app itself must exit before the server can stay down.
if pgrep -x "Ollama" >/dev/null 2>&1; then
  osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
fi

# Give the app a brief chance to exit on its own.
for _ in $(seq 1 5); do
  pgrep -x "Ollama" >/dev/null 2>&1 || break
  sleep 1
done

# Force-terminate the GUI supervisor if the graceful quit did not take; without
# this it keeps relaunching the server. The [o]llama pattern avoids matching the
# pgrep command itself.
for pid in $(pgrep -x "Ollama" || true) $(pgrep -f '[o]llama serve' || true); do
  kill "$pid" 2>/dev/null || true
done

# Escalate to SIGKILL for anything that refuses to exit.
sleep 2
for pid in $(pgrep -x "Ollama" || true) $(pgrep -f '[o]llama serve' || true); do
  kill -9 "$pid" 2>/dev/null || true
done

# Require the API to stay down across consecutive checks. A single down reading
# can occur transiently while the app relaunches the server, so confirm it is
# really gone before reporting success.
down_streak=0
for _ in $(seq 1 15); do
  if curl -fsS "$API_URL/api/version" >/dev/null 2>&1; then
    down_streak=0
  else
    down_streak=$((down_streak + 1))
    if (( down_streak >= 3 )); then
      log "Stopped."
      exit 0
    fi
  fi
  sleep 1
done

warn "Ollama still responds at $API_URL."
exit 1
