#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# cleanup.sh (macOS) — remove ALL local Ollama models so you
# can start fresh. Aliases and base models alike are deleted.
# Does NOT uninstall Ollama or OpenCode; only removes models.
#
# Usage:
#   ./cleanup.sh         # lists models, asks for confirmation
#   ./cleanup.sh --yes   # skip the confirmation prompt
# =========================================================

ASSUME_YES="0"
case "${1:-}" in
  "") ;;
  -y|--yes|--force) ASSUME_YES="1" ;;
  *) echo "[cleanup-mac] error: only --yes is supported." >&2; exit 1 ;;
esac

log()  { echo "[cleanup-mac] $*"; }
fail() { echo "[cleanup-mac] error: $*" >&2; exit 1; }

command -v ollama >/dev/null 2>&1 || fail "ollama not found on PATH; nothing to clean."

# This script targets macOS (Ollama runs as an app, on stock bash 3.2).
[[ "$(uname -s)" == "Darwin" ]] || fail "this is the macOS cleanup; on Debian/Linux use linux/cleanup.sh instead."

# `ollama list`/`rm` need the daemon. On macOS it's Ollama.app or `ollama serve`.
if ! ollama list >/dev/null 2>&1; then
  fail "cannot reach the Ollama server. Start it first (open Ollama.app or run 'ollama serve')."
fi

# macOS ships bash 3.2 (no mapfile), so read into the array portably.
MODELS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && MODELS+=("$line")
done < <(ollama list 2>/dev/null | awk 'NR>1 && NF>0 {print $1}')

if [[ "${#MODELS[@]}" -eq 0 ]]; then
  log "No local models found. Already clean."
  exit 0
fi

log "The following ${#MODELS[@]} model(s) will be removed:"
printf '  - %s\n' "${MODELS[@]}"

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "[cleanup-mac] Remove all of these? [y/N] " reply
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
    echo "[cleanup-mac] warning: failed to remove $m" >&2
    failed=1
  fi
done

[[ "$failed" -eq 0 ]] || fail "one or more models could not be removed."
log "Done. All local models removed. Run ./setup.sh to start fresh."
