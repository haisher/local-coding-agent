#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# NVIDIA Driver Health Check — Debian 13 (Trixie)
# ============================================================

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
RESET="\033[0m"

pass() { echo -e "  ${GREEN}✓${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }

ERRORS=0

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " NVIDIA Driver Health Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# --- GPU Detection ---
echo "[GPU Hardware]"
LSPCI_OUTPUT="$(lspci 2>/dev/null || true)"
GPU_LINE="$(echo "$LSPCI_OUTPUT" | grep -i -E 'vga.*nvidia|3d.*nvidia' || true)"
if [[ -n "$GPU_LINE" ]]; then
  pass "$GPU_LINE"
else
  fail "No NVIDIA GPU detected via lspci"
  ((ERRORS++))
fi
echo ""

# --- Driver ---
echo "[Driver]"
if command -v nvidia-smi >/dev/null 2>&1; then
  DRIVER_VER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || true)"
  if [[ -n "$DRIVER_VER" ]]; then
    pass "nvidia-smi working — driver ${DRIVER_VER}"
  else
    fail "nvidia-smi found but cannot query GPU"
    ((ERRORS++))
  fi
else
  fail "nvidia-smi not found"
  ((ERRORS++))
fi

PKG_VER="$(dpkg-query -W -f='${Version}' nvidia-driver 2>/dev/null || echo "not installed")"
echo "    Package: nvidia-driver ${PKG_VER}"
echo ""

# --- CUDA ---
echo "[CUDA]"
CUDA_VER="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null || true)"
CUDA_UMD="$(nvidia-smi 2>/dev/null | grep -oP 'CUDA UMD Version: \K[0-9.]+' || true)"
if [[ -n "$CUDA_UMD" ]]; then
  pass "CUDA UMD Version: ${CUDA_UMD}"
else
  warn "Could not detect CUDA version from nvidia-smi"
fi
if [[ -n "$CUDA_VER" ]]; then
  pass "Compute capability: ${CUDA_VER}"
fi
echo ""

# --- VRAM ---
echo "[VRAM]"
VRAM_TOTAL="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
VRAM_USED="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || true)"
VRAM_FREE="$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null || true)"
if [[ -n "$VRAM_TOTAL" ]]; then
  pass "Total: ${VRAM_TOTAL} MiB"
  echo "    Used:  ${VRAM_USED} MiB"
  echo "    Free:  ${VRAM_FREE} MiB"
else
  fail "Cannot query VRAM"
  ((ERRORS++))
fi
echo ""

# --- Kernel Modules ---
echo "[Kernel Modules]"
for mod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
  if lsmod | grep -qw "$mod"; then
    pass "${mod} loaded"
  else
    fail "${mod} NOT loaded"
    ((ERRORS++))
  fi
done

if lsmod | grep -qw "nouveau"; then
  fail "nouveau is loaded (conflicts with nvidia!)"
  ((ERRORS++))
else
  pass "nouveau not loaded"
fi
echo ""

# --- Secure Boot / MOK ---
echo "[Secure Boot]"
SB_STATE="$(mokutil --sb-state 2>/dev/null || echo "unknown")"
echo "    ${SB_STATE}"

if echo "$SB_STATE" | grep -qi "enabled"; then
  MOK_PUB="/var/lib/dkms/mok.pub"
  if [[ -f "$MOK_PUB" ]]; then
    MOK_FP="$(openssl x509 -in "$MOK_PUB" -inform DER -noout -fingerprint -sha1 2>/dev/null \
      | sed 's/.*=//;s/://g' || true)"
    ENROLLED="$(mokutil --list-enrolled 2>/dev/null | grep "SHA1" | sed 's/.*: //;s/://g' || true)"
    if echo "$ENROLLED" | grep -qi "$MOK_FP" 2>/dev/null; then
      pass "DKMS signing key enrolled in MOK"
    else
      fail "DKMS signing key NOT enrolled in MOK"
      ((ERRORS++))
    fi
  else
    warn "No DKMS MOK key found at ${MOK_PUB}"
  fi
fi
echo ""

# --- Blacklist ---
echo "[Nouveau Blacklist]"
BLACKLIST="/etc/modprobe.d/blacklist-nouveau.conf"
if [[ -f "$BLACKLIST" ]] && grep -q "blacklist nouveau" "$BLACKLIST"; then
  pass "${BLACKLIST}"
else
  warn "Nouveau blacklist file missing or incomplete"
fi
echo ""

# --- nvidia-drm modeset ---
echo "[DRM Modeset]"
MODESET_FILE="/etc/modprobe.d/nvidia-drm.conf"
if [[ -f "$MODESET_FILE" ]] && grep -q "modeset=1" "$MODESET_FILE"; then
  pass "nvidia-drm modeset=1 configured"
else
  warn "nvidia-drm modeset not configured"
fi
echo ""

# --- Ollama ---
echo "[Ollama Integration]"
if curl -fsS http://localhost:11434/api/version >/dev/null 2>&1; then
  OLLAMA_VER="$(curl -s http://localhost:11434/api/version 2>/dev/null)"
  pass "Ollama running (${OLLAMA_VER})"

  GPU_APPS="$(nvidia-smi --query-compute-apps=process_name --format=csv,noheader 2>/dev/null || true)"
  OLLAMA_LOG="$(cat /tmp/ollama.log 2>/dev/null || journalctl -u ollama --no-pager -n 100 2>/dev/null || true)"
  if echo "$GPU_APPS" | grep -qi "ollama"; then
    pass "Ollama using GPU (CUDA)"
  elif echo "$OLLAMA_LOG" | grep -qi "cuda"; then
    pass "Ollama using CUDA"
  elif echo "$OLLAMA_LOG" | grep -qi "vulkan"; then
    warn "Ollama using Vulkan (not CUDA — restart Ollama)"
  else
    echo "    No model resident on GPU — load one to confirm CUDA backend"
  fi
else
  warn "Ollama not running"
fi
echo ""

# --- Summary ---
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e " ${GREEN}All checks passed!${RESET}"
else
  echo -e " ${RED}${ERRORS} issue(s) found.${RESET}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
