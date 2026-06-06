#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# NVIDIA Driver Installer for Debian 13 (Trixie)
# ============================================================
# Installs the stable NVIDIA proprietary driver from the
# official NVIDIA CUDA repository, blacklists nouveau,
# enrolls the DKMS signing key for Secure Boot (MOK), and
# configures the system for GPU-accelerated Ollama (CUDA).
#
# After running this script, a REBOOT is required.
# During reboot, the MOK Manager (blue screen) will appear:
#   1. Select "Enroll MOK"
#   2. Select "Continue"
#   3. Enter the password you set during this script
#   4. Select "Reboot"
# ============================================================

log()  { echo "[nvidia-setup] $*"; }
warn() { echo "[nvidia-setup] WARNING: $*" >&2; }
fail() { echo "[nvidia-setup] ERROR: $*" >&2; exit 1; }

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    fail "Root privileges required (install sudo or run as root)."
  fi
}

# -----------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || fail "This script is for Linux only."
[[ -f /etc/os-release ]] || fail "Cannot detect OS."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "debian" ]] || fail "This script targets Debian (detected: ${ID:-unknown})."
[[ "${VERSION_CODENAME:-}" == "trixie" ]] || warn "Expected Debian Trixie, got '${VERSION_CODENAME:-unknown}'. Proceeding anyway."

command -v curl >/dev/null 2>&1 || fail "curl is required."
command -v apt-get >/dev/null 2>&1 || fail "apt-get is required."

LSPCI_OUTPUT="$(lspci 2>/dev/null || true)"
if echo "$LSPCI_OUTPUT" | grep -qi "nvidia"; then
  log "NVIDIA GPU detected: $(echo "$LSPCI_OUTPUT" | grep -i -E 'vga.*nvidia|3d.*nvidia')"
else
  fail "No NVIDIA GPU detected via lspci."
fi

# -----------------------------------------------------------
# Step 1: Enable non-free + contrib in APT sources
# -----------------------------------------------------------
log "Step 1: Ensuring non-free and contrib components are enabled..."

# Check across all source files (sources.list + sources.list.d/)
HAS_NON_FREE=0
grep -rqE "^deb .*(contrib|non-free)" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null && HAS_NON_FREE=1

if [[ "$HAS_NON_FREE" -eq 1 ]]; then
  log "contrib/non-free already enabled (via sources.list or sources.list.d/)."
else
  # Add a dedicated file rather than modifying sources.list to avoid duplicates
  NONFREE_LIST="/etc/apt/sources.list.d/nvidia-nonfree.list"
  log "Adding non-free sources to ${NONFREE_LIST}..."
  cat <<'SRCEOF' | run_as_root tee "$NONFREE_LIST" >/dev/null
deb http://deb.debian.org/debian/ trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ trixie-updates main contrib non-free non-free-firmware
SRCEOF
  log "non-free sources added."
fi

# -----------------------------------------------------------
# Step 2: Set up NVIDIA CUDA repository (if missing)
# -----------------------------------------------------------
log "Step 2: Ensuring NVIDIA CUDA repository is configured..."

CUDA_LIST="/etc/apt/sources.list.d/cuda-debian13-x86_64.list"
CUDA_KEYRING="/usr/share/keyrings/cuda-archive-keyring.gpg"

if [[ -f "$CUDA_LIST" ]]; then
  log "CUDA repository already configured."
else
  log "Adding NVIDIA CUDA repository for Debian 13..."
  CUDA_PIN_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-debian13.pin"
  CUDA_KEY_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/3bf863cc.pub"
  CUDA_REPO="deb [signed-by=${CUDA_KEYRING}] https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/ /"

  curl -fsSL "$CUDA_PIN_URL" | run_as_root tee /etc/apt/preferences.d/cuda-repository-pin-600 >/dev/null
  curl -fsSL "$CUDA_KEY_URL" | run_as_root gpg --dearmor -o "$CUDA_KEYRING"
  echo "$CUDA_REPO" | run_as_root tee "$CUDA_LIST" >/dev/null
  log "CUDA repository added."
fi

# -----------------------------------------------------------
# Step 3: Update package lists
# -----------------------------------------------------------
log "Step 3: Updating package lists..."
run_as_root apt-get update -qq

# -----------------------------------------------------------
# Step 4: Install kernel headers and build tools
# -----------------------------------------------------------
log "Step 4: Ensuring kernel headers and build tools are installed..."

KERNEL="$(uname -r)"
HEADERS_PKG="linux-headers-${KERNEL}"

PKGS_TO_INSTALL=()

if ! dpkg -l "$HEADERS_PKG" 2>/dev/null | grep -q "^ii"; then
  PKGS_TO_INSTALL+=("$HEADERS_PKG")
fi
if ! dpkg -l build-essential 2>/dev/null | grep -q "^ii"; then
  PKGS_TO_INSTALL+=("build-essential")
fi
if ! dpkg -l dkms 2>/dev/null | grep -q "^ii"; then
  PKGS_TO_INSTALL+=("dkms")
fi

if [[ ${#PKGS_TO_INSTALL[@]} -gt 0 ]]; then
  log "Installing: ${PKGS_TO_INSTALL[*]}"
  run_as_root apt-get install -y "${PKGS_TO_INSTALL[@]}"
else
  log "Kernel headers and build tools already installed."
fi

# -----------------------------------------------------------
# Step 5: Install NVIDIA driver (stable branch)
# -----------------------------------------------------------
log "Step 5: Installing NVIDIA driver..."

INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' nvidia-driver 2>/dev/null || echo "none")"

# Use the candidate (highest priority) version from apt
CANDIDATE_VERSION="$(apt-cache policy nvidia-driver 2>/dev/null | grep 'Candidate:' | awk '{print $2}')"

if [[ "$INSTALLED_VERSION" != "none" ]]; then
  log "nvidia-driver already installed: ${INSTALLED_VERSION}"
  # Only upgrade if candidate is newer (never downgrade)
  if dpkg --compare-versions "$CANDIDATE_VERSION" gt "$INSTALLED_VERSION" 2>/dev/null; then
    log "Newer version available (${CANDIDATE_VERSION}), upgrading..."
    run_as_root apt-get install -y nvidia-driver \
      nvidia-smi \
      libnvidia-cfg1 \
      nvidia-kernel-dkms
  else
    log "Installed version is current or newer. Skipping."
  fi
else
  log "Installing nvidia-driver (version: ${CANDIDATE_VERSION})..."
  run_as_root apt-get install -y nvidia-driver \
    nvidia-smi \
    libnvidia-cfg1 \
    nvidia-kernel-dkms
fi

# -----------------------------------------------------------
# Step 6: Blacklist nouveau
# -----------------------------------------------------------
log "Step 6: Blacklisting nouveau driver..."

BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"

if [[ -f "$BLACKLIST_FILE" ]] && grep -q "blacklist nouveau" "$BLACKLIST_FILE"; then
  log "nouveau already blacklisted."
else
  cat <<'EOF' | run_as_root tee "$BLACKLIST_FILE" >/dev/null
# Disable nouveau to allow NVIDIA proprietary driver
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
  log "Created ${BLACKLIST_FILE}"
fi

# -----------------------------------------------------------
# Step 7: Enable nvidia-drm modeset (for Wayland/DRM)
# -----------------------------------------------------------
log "Step 7: Configuring nvidia-drm modeset..."

MODESET_FILE="/etc/modprobe.d/nvidia-drm.conf"
if [[ -f "$MODESET_FILE" ]] && grep -q "modeset=1" "$MODESET_FILE"; then
  log "nvidia-drm modeset already enabled."
else
  echo "options nvidia-drm modeset=1" | run_as_root tee "$MODESET_FILE" >/dev/null
  log "Enabled nvidia-drm modeset=1"
fi

# -----------------------------------------------------------
# Step 8: Enroll DKMS signing key in MOK (Secure Boot)
# -----------------------------------------------------------
log "Step 8: Handling Secure Boot MOK enrollment..."

SECUREBOOT_ENABLED=0
if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
  SECUREBOOT_ENABLED=1
  log "Secure Boot is ENABLED."
else
  log "Secure Boot is disabled — skipping MOK enrollment."
fi

MOK_KEY="/var/lib/dkms/mok.key"
MOK_PUB="/var/lib/dkms/mok.pub"

if [[ "$SECUREBOOT_ENABLED" -eq 1 ]]; then
  # Ensure the DKMS MOK keypair exists
  if [[ ! -f "$MOK_KEY" || ! -f "$MOK_PUB" ]]; then
    log "Generating DKMS module signing key..."
    run_as_root openssl req -new -x509 -newkey rsa:2048 -keyout "$MOK_KEY" \
      -outform DER -out "$MOK_PUB" -nodes -days 36500 \
      -subj "/CN=DKMS module signing key ($(hostname))/"
    run_as_root chmod 600 "$MOK_KEY"
  fi

  # Check if DKMS key is already enrolled
  MOK_FINGERPRINT="$(openssl x509 -in "$MOK_PUB" -inform DER -noout -fingerprint -sha1 2>/dev/null \
    | sed 's/.*=//;s/://g' || true)"
  ENROLLED_KEYS="$(mokutil --list-enrolled 2>/dev/null | grep "SHA1" | sed 's/.*: //;s/://g' || true)"

  if echo "$ENROLLED_KEYS" | grep -qi "$MOK_FINGERPRINT" 2>/dev/null; then
    log "DKMS signing key is already enrolled in MOK. ✓"
  else
    log "DKMS signing key is NOT enrolled in MOK."
    log ""
    log "You will be asked to set a one-time password."
    log "Remember it — you must enter it at the MOK Manager during reboot."
    log ""
    run_as_root mokutil --import "$MOK_PUB"
    log ""
    log "Key queued for enrollment. It will activate on next reboot."
    log "IMPORTANT: At the blue MOK Manager screen during reboot:"
    log "  1. Select 'Enroll MOK'"
    log "  2. Select 'Continue'"
    log "  3. Enter the password you just set"
    log "  4. Select 'Reboot'"
  fi

  # Ensure DKMS is configured to sign modules with this key
  DKMS_CONF="/etc/dkms/framework.conf"
  if [[ -f "$DKMS_CONF" ]]; then
    if ! grep -q "^mok_signing_key=" "$DKMS_CONF" 2>/dev/null; then
      log "Configuring DKMS to auto-sign modules..."
      echo "mok_signing_key=${MOK_KEY}" | run_as_root tee -a "$DKMS_CONF" >/dev/null
      echo "mok_certificate=${MOK_PUB}" | run_as_root tee -a "$DKMS_CONF" >/dev/null
    fi
  fi

  # Re-sign nvidia modules if they exist but aren't signed with enrolled key
  KMOD_SIGN="/usr/lib/linux-kbuild-$(uname -r | cut -d. -f1-2)/scripts/sign-file"
  if [[ ! -x "$KMOD_SIGN" ]]; then
    KMOD_SIGN="$(find /usr/lib/linux-kbuild-*/scripts/sign-file 2>/dev/null | head -1 || true)"
  fi

  if [[ -x "$KMOD_SIGN" ]]; then
    log "Re-signing NVIDIA kernel modules with DKMS key..."
    MOK_KEY_PEM="$(mktemp)"
    openssl x509 -in "$MOK_PUB" -inform DER -out "$MOK_KEY_PEM" -outform PEM 2>/dev/null
    for mod in /lib/modules/"$(uname -r)"/updates/dkms/nvidia*.ko.xz; do
      if [[ -f "$mod" ]]; then
        UNCOMPRESSED="${mod%.xz}"
        xz -dk "$mod" 2>/dev/null || true
        if [[ -f "$UNCOMPRESSED" ]]; then
          run_as_root "$KMOD_SIGN" sha256 "$MOK_KEY" "$MOK_KEY_PEM" "$UNCOMPRESSED" 2>/dev/null || true
          run_as_root xz -f "$UNCOMPRESSED" 2>/dev/null || true
          log "  Signed: $(basename "$mod")"
        fi
      fi
    done
    rm -f "$MOK_KEY_PEM"
  else
    warn "sign-file not found. Modules will be signed by DKMS on next kernel build."
  fi
fi

# -----------------------------------------------------------
# Step 9: Ensure nvidia modules load early (initramfs)
# -----------------------------------------------------------
log "Step 9: Configuring initramfs for NVIDIA modules..."

MODULES_FILE="/etc/initramfs-tools/modules"
NVIDIA_MODULES="nvidia nvidia-modeset nvidia-drm nvidia-uvm"

for mod in $NVIDIA_MODULES; do
  if ! grep -qx "$mod" "$MODULES_FILE" 2>/dev/null; then
    echo "$mod" | run_as_root tee -a "$MODULES_FILE" >/dev/null
  fi
done

log "Rebuilding initramfs (this may take a moment)..."
run_as_root update-initramfs -u

# -----------------------------------------------------------
# Step 10: Verify installation
# -----------------------------------------------------------
log "Step 10: Verifying installation..."

echo ""
log "Driver package installed:"
dpkg -l nvidia-driver 2>/dev/null | grep "^ii" | awk '{print "  " $2 " " $3}'

echo ""
log "Kernel modules available:"
for mod in $NVIDIA_MODULES; do
  if find "/lib/modules/${KERNEL}" -name "${mod}.ko*" 2>/dev/null | grep -q .; then
    echo "  ✓ ${mod}"
  else
    echo "  ✗ ${mod} (MISSING)"
  fi
done

echo ""
log "Nouveau blacklisted:"
if [[ -f "$BLACKLIST_FILE" ]]; then
  echo "  ✓ ${BLACKLIST_FILE}"
else
  echo "  ✗ blacklist file missing"
fi

echo ""
if [[ "$SECUREBOOT_ENABLED" -eq 1 ]]; then
  log "Secure Boot / MOK:"
  echo "  • Secure Boot: ENABLED"
  echo "  • DKMS key: ${MOK_PUB}"
  if echo "$ENROLLED_KEYS" | grep -qi "$MOK_FINGERPRINT" 2>/dev/null; then
    echo "  ✓ Key already enrolled"
  else
    echo "  ⏳ Key pending enrollment (complete at next reboot)"
  fi
fi

# -----------------------------------------------------------
# Done
# -----------------------------------------------------------
echo ""
echo "============================================================"
log "Installation complete!"
echo "============================================================"
echo ""
if [[ "$SECUREBOOT_ENABLED" -eq 1 ]]; then
  log "⚠️  SECURE BOOT REBOOT INSTRUCTIONS:"
  echo ""
  echo "  When the system reboots, a blue 'MOK Manager' screen appears:"
  echo "    1. Select 'Enroll MOK'"
  echo "    2. Select 'Continue'"
  echo "    3. Type the password you entered earlier"
  echo "    4. Select 'Reboot'"
  echo ""
  echo "  If you miss it, re-run: sudo mokutil --import ${MOK_PUB}"
  echo ""
fi
log "After reboot, verify with:"
echo "  nvidia-smi              # Should show NVIDIA GPU + driver version"
echo "  lsmod | grep nvidia     # Should show nvidia modules loaded"
echo "  lsmod | grep nouveau    # Should be empty"
echo ""
log "Then restart Ollama:"
echo "  ollama serve"
echo "  # Ollama will auto-detect CUDA and use full 8 GiB VRAM"
echo ""

read -rp "[nvidia-setup] Reboot now? [y/N] " REPLY
if [[ "${REPLY,,}" == "y" ]]; then
  log "Rebooting..."
  run_as_root reboot
else
  log "Remember to reboot before using the GPU with Ollama."
fi
