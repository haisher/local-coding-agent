#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# cleanup.sh (Linux) — remove ALL local Ollama models so you
# can start fresh. Aliases and base models alike are deleted.
# Does NOT uninstall Ollama or Qwen Code; only removes models.
#
# Usage:
#   ./linux/cleanup.sh         # lists models, asks for confirmation
#   ./linux/cleanup.sh --yes   # skip the confirmation prompt
# =========================================================

ASSUME_YES="0"
case "${1:-}" in
  "") ;;
  -y|--yes|--force) ASSUME_YES="1" ;;
  *) echo "[cleanup-linux] error: only --yes is supported." >&2; exit 1 ;;
esac

log()  { echo "[cleanup-linux] $*"; }
fail() { echo "[cleanup-linux] error: $*" >&2; exit 1; }

command -v ollama >/dev/null 2>&1 || fail "ollama not found on PATH; nothing to clean."

# This script targets Debian/Ubuntu (Ollama runs under systemd).
[[ "$(uname -s)" == "Linux" ]] || fail "this is the Linux/Debian cleanup; on macOS use ../cleanup.sh instead."

# `ollama list`/`rm` need the daemon. On Debian it's the systemd service.
if ! ollama list >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-active --quiet ollama; then
    fail "Ollama service is not running. Start it with: sudo systemctl start ollama"
  fi
  fail "cannot reach the Ollama server. Start it first (sudo systemctl start ollama, or 'ollama serve')."
fi

# Debian ships bash 4+/5, so mapfile is available.
mapfile -t MODELS < <(ollama list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}')

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  log "No local models found. Already clean."
  exit 0
fi

log "The following ${#MODELS[@]} model(s) will be removed:"
printf '  - %s\n' "${MODELS[@]}"

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "[cleanup-linux] Remove all of these? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) log "Aborted. Nothing removed."; exit 0 ;;
  esac
fi

failed=0
for m in "${MODELS[@]}"; do
  if ollama rm "$m" >/dev/null 2>&1; then
    log "removed $m"
  else
    echo "[cleanup-linux] warning: failed to remove $m" >&2
    failed=1
  fi
done

[[ "$failed" -eq 0 ]] || fail "one or more models could not be removed."
log "Done. All local models removed. Run ./linux/setup.sh to start fresh."
