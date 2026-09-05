#!/bin/bash
#
# build-nvidia-module.sh — Build nvidia kernel module via DKMS in isolated build root.
# Runs inside the build chroot via INSTALL_CMD.
#
# This script owns the complete build recipe pipeline for nvidia-open-dkms:
#   1. Prerequisite discovery (kernel, NVIDIA source, required packages)
#   2. DKMS registration, build, and install
#   3. Post-build verification (DKMS status, module validity, module list)
#   4. Self-heal bundle creation
#
set -euo pipefail

# ── 0. Detect execution context: chroot vs live ──────────────────────────
# This script can run in two contexts:
#
#   chroot — inside an overlay-chroot build root (INSTALL_CMD).
#            All paths (/usr/src, /var/lib/dkms, …) are chroot-local.
#
#   live   — on a running SteamOS system (direct invocation for on-device
#            module rebuilds).  Paths are the host's real filesystem.
#
# Detection: the chroot launcher (overlay-chroot.sh) sets environment
# variables and mounts overlay filesystems.  We check for several
# indicators that are reliable in overlay-chroot environments.
if [[ -f /.dockerenv ]] \
  || grep -q 'overlay.*overlay' /proc/mounts 2>/dev/null \
  || [[ -n "${MERGED:-}" && -d "${MERGED:-}" ]] \
  || [[ -n "${NEWROOT:-}" && -d "${NEWROOT:-}" ]] \
  || [[ -n "${PARTSET:-}" && -d "${PARTSET:-}" ]]; then
  _NV_CONTEXT="chroot"
else
  _NV_CONTEXT="live"
fi

echo "=== Execution context: $_NV_CONTEXT ==="

# ── 0b. Live-system prerequisite guards ──────────────────────────────────
# On live systems we must validate a stricter set of prerequisites before
# touching the running system's DKMS trees.
if [[ "$_NV_CONTEXT" == "live" ]]; then
  # Root is mandatory — DKMS install and depmod require it.
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: live-system NVIDIA build requires root privileges." >&2
    echo "       Run with: sudo \"$0\"" >&2
    exit 1
  fi

  # The running kernel must have headers installed so we can build against it.
  RUNNING_KVER="$(uname -r)"
  if [[ ! -d "/usr/lib/modules/$RUNNING_KVER" ]]; then
    echo "ERROR: no module directory for running kernel $RUNNING_KVER." >&2
    echo "       Install headers: sudo pacman -S linux-neptune-616-headers" >&2
    exit 1
  fi

  # dkms must be installed.
  if ! command -v dkms &>/dev/null; then
    echo "ERROR: 'dkms' is not installed." >&2
    echo "       Install with: sudo pacman -S dkms" >&2
    exit 1
  fi

  # nvidia-open-dkms sources must be present.
  if ! find /usr/src -maxdepth 1 -type d -name 'nvidia-*' 2>/dev/null | grep -q .; then
    echo "ERROR: no NVIDIA source tree found in /usr/src." >&2
    echo "       Install with: sudo pacman -S nvidia-open-dkms" >&2
    exit 1
  fi

  # Warn the user that loaded nvidia modules will be replaced.
  if lsmod 2>/dev/null | grep -q '^nvidia'; then
    echo "WARNING: nvidia modules are currently loaded." >&2
    echo "         DKMS install will replace them; a reboot may be needed." >&2
  fi
fi

# ── 1. Bootstrap: source pacman helpers if available ─────────────────────
# The helpers live at a predictable in-chroot path once the build image is
# prepared.  Source them so this script can use the shared pacman_*()
# wrappers instead of raw pacman calls.
#
# NOTE: Because we are already inside the chroot (not on the host),
# _pacman_exec with context "host" correctly means "run in the
# current root filesystem" — which is the chroot's root.
_STEAMOS_LIB="/usr/lib/steamos-build/lib"
if [[ -r "$_STEAMOS_LIB/pacman-helpers.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_STEAMOS_LIB/pacman-helpers.sh" # lint-ignore: single-source
fi

# ── 1. Discover kernel version ──────────────────────────────────────────
# In chroot mode, derive from the installed linux-neptune-616 headers
# symlink — not by picking the "latest" directory (which breaks if
# old+new trees coexist).
#
# On live systems, prefer the running kernel to guarantee ABI match.
# If the symlink exists, fall back to it; otherwise use uname -r.
if [[ "$_NV_CONTEXT" == "live" ]]; then
  KVER="$(uname -r)"
  # Prefer the symlink if it exists; verify it resolves to the running kernel.
  if [[ -L /usr/src/linux-neptune-616 ]]; then
    _LINK_TARGET="$(readlink -f /usr/src/linux-neptune-616)"
    _LINK_KVER="$(basename "$(dirname "$_LINK_TARGET")")"
    if [[ "$_LINK_KVER" != "$KVER" ]]; then
      echo "WARNING: linux-neptune-616 symlink points to $_LINK_KVER," >&2
      echo "         but running kernel is $KVER — using running kernel." >&2
    fi
  fi
  KBUILD="/usr/lib/modules/$KVER/build"
else
  KBUILD="$(readlink -f /usr/src/linux-neptune-616)"
  [[ -f "$KBUILD/Makefile" ]] || {
    echo "ERROR: invalid linux-neptune-616 build tree: $KBUILD" >&2
    exit 1
  }
  KVER="$(basename "$(dirname "$KBUILD")")"
fi

# Verify kernel headers/build directory is usable
[[ -d "/usr/lib/modules/$KVER/build" ]] || {
  echo "ERROR: kernel headers/build tree missing for $KVER" >&2
  exit 1
}

# ── 2. Discover NVIDIA version from source tree ─────────────────────────
# Require exactly one NVIDIA source tree — ambiguity is an error.
mapfile -t NV_SOURCES < <(
  find /usr/src \
    -mindepth 1 -maxdepth 1 \
    -type d \
    -name 'nvidia-*' \
    -print \
    | sort -V
)

if ((${#NV_SOURCES[@]} != 1)); then
  printf 'ERROR: expected exactly one NVIDIA source tree, found %d:\n' "${#NV_SOURCES[@]}" >&2
  if ((${#NV_SOURCES[@]} > 0)); then
    printf '  %s\n' "${NV_SOURCES[@]}" >&2
  fi
  exit 1
fi

NV_SRC="${NV_SOURCES[0]}"
NVVER="${NV_SRC##*/nvidia-}"
if [[ ! "$NVVER" =~ ^[0-9]+(\.[0-9]+)* ]]; then
  echo "ERROR: could not parse NVIDIA version from $NV_SRC (got '$NVVER')" >&2
  exit 1
fi

INSTALL_DIR="/usr/lib/modules/$KVER/updates/dkms"

# Explicitly pin DKMS trees for deterministic builds.
# Eliminates /etc/dkms/framework.conf from the equation.
DKMS_ARGS=(
  --dkmstree /var/lib/dkms
  --sourcetree /usr/src
  --installtree /usr/lib/modules
)

echo "=== NVIDIA DKMS module build ==="
echo "  NVIDIA source: $NV_SRC"
echo "  NVIDIA version: $NVVER"
echo "  Kernel:         $KVER"
echo "  KBUILD:         $KBUILD"

# ── 3. Check prerequisites ──────────────────────────────────────────────
# Use pacman helpers if available; fall back to raw pacman -Q if not.
# In chroot mode the helpers run with context "host" (the chroot's root).
# In live mode the helpers run against the real host filesystem.
_required_pkgs=(nvidia-open-dkms dkms linux-neptune-616-headers)
if [[ "$(type -t _pacman_exec 2>/dev/null)" == "function" ]]; then
  for _pkg in "${_required_pkgs[@]}"; do
    if ! _pacman_exec "host" "pacman -Q $_pkg" &>/dev/null; then
      echo "ERROR: required package '$_pkg' is not installed" >&2
      [[ "$_NV_CONTEXT" == "live" ]] \
        && echo "       Install with: sudo pacman -S $_pkg" >&2
      exit 1
    fi
  done
else
  # Fallback: helpers not sourced — use raw pacman
  for _pkg in "${_required_pkgs[@]}"; do
    if ! pacman -Q "$_pkg" &>/dev/null; then
      echo "ERROR: required package '$_pkg' is not installed" >&2
      [[ "$_NV_CONTEXT" == "live" ]] \
        && echo "       Install with: sudo pacman -S $_pkg" >&2
      exit 1
    fi
  done
fi

# ── 4. Register with DKMS if not already registered ─────────────────────
echo
echo "--- DKMS status before build ---"
dkms status "${DKMS_ARGS[@]}" || true

if ! dkms status "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER" 2>/dev/null \
  | grep -q "^nvidia/$NVVER"; then
  echo "Registering nvidia/$NVVER with DKMS"
  dkms add "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER"
fi

# ── 5. Build ────────────────────────────────────────────────────────────
echo
echo "Building nvidia/$NVVER for $KVER"
if ! dkms build "${DKMS_ARGS[@]}" --kernelsourcedir "$KBUILD" -m nvidia -v "$NVVER" -k "$KVER"; then
  echo "ERROR: DKMS build failed" >&2
  echo "--- make.log ---" >&2
  find /var/lib/dkms/nvidia -type f -name make.log -exec tail -n 100 {} \; 2>&1 || true
  exit 1
fi

# ── 6. Install ──────────────────────────────────────────────────────────
echo
echo "Installing nvidia/$NVVER for $KVER"
if ! dkms install "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER" -k "$KVER"; then
  echo "ERROR: DKMS install failed" >&2
  exit 1
fi

# Update module dependency database so the kernel can resolve symbols
if ! depmod "$KVER"; then
  echo "ERROR: depmod $KVER failed" >&2
  exit 1
fi

# ── 6b. Live-system: unload old modules if needed ────────────────────────
# On a live system the old nvidia modules may be loaded.  We cannot unload
# them while Xorg / Wayland are using them, but we can at least note the
# situation and run a dependency check so the next boot picks up the new
# modules.
if [[ "$_NV_CONTEXT" == "live" ]]; then
  if lsmod 2>/dev/null | grep -q '^nvidia '; then
    echo "  Live: nvidia modules are loaded — attempting soft unload"
    # Best-effort: try to unload user-space-dependent modules first.
    # If they are still in use, skip and rely on reboot.
    for mod in nvidia-uvm nvidia-drm nvidia-modeset nvidia; do
      modprobe -r "$mod" 2>/dev/null || true
    done
    # If nvidia is still loaded, warn and continue — reboot will apply.
    if lsmod 2>/dev/null | grep -q '^nvidia '; then
      echo "  WARNING: nvidia module still in use — a reboot is required to" >&2
      echo "           activate the newly built modules." >&2
    else
      echo "  Live: old nvidia modules unloaded successfully"
    fi
  fi
  # Verify modprobe can resolve the newly installed modules.
  if command -v modprobe &>/dev/null; then
    if modprobe --show-depends nvidia 2>/dev/null; then
      echo "  Live: modprobe dependency check passed"
    else
      echo "  WARNING: modprobe --show-depends nvidia failed — module paths may need update" >&2
    fi
  fi
fi

# ── 7. Verify ───────────────────────────────────────────────────────────
echo
echo "--- DKMS status after build ---"
dkms status "${DKMS_ARGS[@]}" || true

echo
echo "--- Built modules ---"
find "/usr/lib/modules/$KVER" -type f -name 'nvidia*.ko*' -print 2>/dev/null || true

# Verify the core nvidia.ko was produced
if ! compgen -G "$INSTALL_DIR/nvidia.ko*" >/dev/null; then
  echo "ERROR: nvidia.ko not found after DKMS build" >&2
  exit 1
fi

# Validate each expected module: existence, modinfo, and vermagic match
for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
  ko_path="$(compgen -G "$INSTALL_DIR/$mod.ko*" 2>/dev/null | head -1)"
  if [[ -z "$ko_path" ]]; then
    echo "ERROR: $mod.ko not found in $INSTALL_DIR" >&2
    exit 1
  fi
  if ! modinfo "$ko_path" >/dev/null 2>&1; then
    echo "ERROR: $mod.ko is not a valid kernel module" >&2
    exit 1
  fi
  vermagic="$(modinfo -F vermagic "$ko_path" 2>/dev/null | head -1)"
  if [[ "$vermagic" != "$KVER "* ]]; then
    echo "ERROR: $mod.ko vermagic '$vermagic' != $KVER" >&2
    exit 1
  fi
  echo "  OK $mod.ko (vermagic: $vermagic)"
done

echo
echo "  OK nvidia module built successfully"

# ── 8. Bundle modules for self-heal ─────────────────────────────────────
# In chroot mode, paths are relative to the chroot root (/).
# On live systems, the bundle path is the real /home.
BUNDLE_DIR="/home/.steamos-build/bundles/nvidia-open-dkms"
echo "  Bundling modules for self-heal"
if ! mkdir -p "$BUNDLE_DIR"; then
  echo "ERROR: failed to create bundle directory $BUNDLE_DIR" >&2
  exit 1
fi
cp -a "$INSTALL_DIR"/nvidia*.ko* "$BUNDLE_DIR/" || {
  echo "ERROR: failed to create NVIDIA self-heal bundle at $BUNDLE_DIR" >&2
  exit 1
}

for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
  compgen -G "$BUNDLE_DIR/$mod.ko*" >/dev/null || {
    echo "ERROR: bundle missing $mod in $BUNDLE_DIR" >&2
    exit 1
  }
done

echo "  Bundle created at $BUNDLE_DIR"

# ── 9. Install modprobe configuration ──────────────────────────────────
# Blacklist nouveau and enable nvidia-drm KMS so the open kernel modules
# work correctly on the next boot.
_NVIDIA_CONF="/etc/modprobe.d/99-nvidia-patch.conf"
if [[ ! -s "$_NVIDIA_CONF" ]]; then
  echo "Installing nvidia modprobe config"
  mkdir -p /etc/modprobe.d
  cat >"$_NVIDIA_CONF" <<'MODPROBE_EOF'
# Added by steamos-build-installer
blacklist nouveau
options nouveau modeset=0

# Explicit although enabled by default on current NVIDIA drivers
options nvidia_drm modeset=1 fbdev=1
MODPROBE_EOF
fi

if [[ -s "$_NVIDIA_CONF" ]]; then
  echo "  OK modprobe config installed at $_NVIDIA_CONF"
else
  echo "ERROR: failed to install modprobe config at $_NVIDIA_CONF" >&2
  exit 1
fi

echo "=== NVIDIA DKMS module build complete ==="
