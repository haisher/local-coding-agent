#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Alpaca — native desktop chat UI for local Ollama (Linux)
# ============================================================
# Ollama ships no GUI on Linux (CLI/server only). Alpaca is a
# native GTK4 app that talks to your existing Ollama server, so
# the tuned aliases (qcoder, agentic, qcoder-fast) show up in a
# desktop chat window — the closest match to the macOS app.

# =========================
# Configuration (edit here)
# =========================
FLATPAK_APP_ID="com.jeffser.Alpaca"
FLATHUB_NAME="flathub"
FLATHUB_REPO="https://flathub.org/repo/flathub.flatpakrepo"
INSTALL_SCOPE="user"            # "user" (no sudo) or "system" (sudo)
OLLAMA_URL="http://localhost:11434"
UPDATE_IF_INSTALLED="1"         # re-pull latest Alpaca if already present
LAUNCH_AFTER_INSTALL="0"        # 1 = open Alpaca when done

log()  { echo "[alpaca-linux] $*"; }
warn() { echo "[alpaca-linux] warning: $*" >&2; }
fail() { echo "[alpaca-linux] error: $*" >&2; exit 1; }

if [[ $# -ne 0 ]]; then
  fail "No runtime arguments supported. Edit config at the top of this file."
fi

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

[[ "$(uname -s)" == "Linux" ]] || fail "This script is for Linux."
is_debian_like || fail "This script supports Debian/Ubuntu only."

case "$INSTALL_SCOPE" in
  user)   FP=(flatpak --user) ;;
  system) FP=(run_as_root flatpak) ;;
  *)      fail "INSTALL_SCOPE must be 'user' or 'system'." ;;
esac

# --- Flatpak ---
if ! command -v flatpak >/dev/null 2>&1; then
  log "Installing flatpak..."
  run_as_root apt-get update
  run_as_root apt-get install -y flatpak
else
  log "flatpak already installed."
fi

# --- Flathub remote ---
if ! "${FP[@]}" remotes --columns=name 2>/dev/null | grep -Fxq "$FLATHUB_NAME"; then
  log "Adding Flathub remote ($INSTALL_SCOPE scope)..."
  "${FP[@]}" remote-add --if-not-exists "$FLATHUB_NAME" "$FLATHUB_REPO"
else
  log "Flathub remote already present."
fi

# --- Alpaca ---
if "${FP[@]}" info "$FLATPAK_APP_ID" >/dev/null 2>&1; then
  if [[ "$UPDATE_IF_INSTALLED" == "1" ]]; then
    log "Alpaca already installed — updating to latest..."
    "${FP[@]}" update -y "$FLATPAK_APP_ID" || warn "Update failed; keeping existing version."
  else
    log "Alpaca already installed."
  fi
else
  log "Installing Alpaca ($FLATPAK_APP_ID)..."
  "${FP[@]}" install -y "$FLATHUB_NAME" "$FLATPAK_APP_ID"
fi

"${FP[@]}" info "$FLATPAK_APP_ID" >/dev/null 2>&1 \
  || fail "Alpaca does not appear to be installed."
ALPACA_VER="$("${FP[@]}" info --show-ref "$FLATPAK_APP_ID" 2>/dev/null || echo "$FLATPAK_APP_ID")"
log "Installed: $ALPACA_VER"

# --- Local Ollama sanity check (non-fatal) ---
if command -v curl >/dev/null 2>&1 && curl -fsS "$OLLAMA_URL/api/version" >/dev/null 2>&1; then
  log "Ollama is reachable at $OLLAMA_URL"
  if command -v ollama >/dev/null 2>&1; then
    MODELS="$(ollama list 2>/dev/null | awk 'NR>1{a = a sep $1; sep=", "} END{print a}' || true)"
    [[ -n "$MODELS" ]] && log "Local models Alpaca can use: $MODELS"
  fi
else
  warn "Ollama is not reachable at $OLLAMA_URL."
  warn "Start it first: ./linux/start.sh   (Alpaca needs the server running)."
fi

cat <<EOF

[alpaca-linux] Done.

Launch Alpaca:
  flatpak run $FLATPAK_APP_ID
(It also appears in your app menu as "Alpaca".)

Point Alpaca at your existing local Ollama server (so qcoder / agentic /
qcoder-fast and your GPU tuning are used instead of a bundled instance):
  1. Open Alpaca → Preferences (or the menu) → Instances / "Manage Instances".
  2. Add or select a remote/Ollama instance with URL:
       $OLLAMA_URL
  3. Pick a model (e.g. qcoder) from the model selector and start chatting.

Tray / background: enable "Run in Background" in Alpaca's preferences to keep
it resident with a background/tray presence similar to the macOS app.
EOF

if [[ "$LAUNCH_AFTER_INSTALL" == "1" ]]; then
  log "Launching Alpaca..."
  nohup flatpak run "$FLATPAK_APP_ID" >/dev/null 2>&1 &
fi
