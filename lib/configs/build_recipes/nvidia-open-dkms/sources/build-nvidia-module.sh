#!/bin/bash
#
# build-nvidia-module.sh — Build nvidia kernel module via DKMS in isolated build root.
# Runs inside the build chroot via INSTALL_CMD.
#
set -euo pipefail

# ── Discover kernel version ──────────────────────────────────────────────
# Derive from the installed linux-neptune-616 headers symlink, not by
# picking the "latest" directory (which breaks if old+new trees coexist).
KBUILD="$(readlink -f /usr/src/linux-neptune-616)"
[[ -f "$KBUILD/Makefile" ]] || {
  echo "ERROR: invalid linux-neptune-616 build tree: $KBUILD" >&2
  exit 1
}
KVER="$(basename "$(dirname "$KBUILD")")"

# ── Discover NVIDIA version from source tree ─────────────────────────────
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
  printf '  %s\n' "${NV_SOURCES[@]}" >&2
  exit 1
fi

NV_SRC="${NV_SOURCES[0]}"
NVVER="${NV_SRC##*/nvidia-}"

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

# ── Check prerequisites ──────────────────────────────────────────────────
if ! pacman -Q nvidia-open-dkms &>/dev/null; then
  echo "ERROR: nvidia-open-dkms not installed" >&2
  exit 1
fi

if ! pacman -Q dkms &>/dev/null; then
  echo "ERROR: dkms not installed" >&2
  exit 1
fi

# ── Register with DKMS if not already registered ─────────────────────────
echo
echo "--- DKMS status before build ---"
dkms status "${DKMS_ARGS[@]}" || true

if ! dkms status "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER" 2>/dev/null \
  | grep -q "^nvidia/$NVVER"; then
  echo "Registering nvidia/$NVVER with DKMS"
  dkms add "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER"
fi

# ── Build ────────────────────────────────────────────────────────────────
echo
echo "Building nvidia/$NVVER for $KVER"
if ! dkms build "${DKMS_ARGS[@]}" --kernelsourcedir "$KBUILD" -m nvidia -v "$NVVER" -k "$KVER"; then
  echo "ERROR: DKMS build failed" >&2
  echo "--- make.log ---"
  find /var/lib/dkms/nvidia -type f -name make.log -exec tail -n 100 {} \; 2>/dev/null || true
  exit 1
fi

# ── Install ──────────────────────────────────────────────────────────────
echo
echo "Installing nvidia/$NVVER for $KVER"
if ! dkms install "${DKMS_ARGS[@]}" -m nvidia -v "$NVVER" -k "$KVER"; then
  echo "ERROR: DKMS install failed" >&2
  exit 1
fi

# ── Verify ───────────────────────────────────────────────────────────────
echo
echo "--- DKMS status after build ---"
dkms status "${DKMS_ARGS[@]}"

echo
echo "--- Built modules ---"
find "/usr/lib/modules/$KVER" -type f -name 'nvidia*.ko*' -print 2>/dev/null || true

if ! compgen -G "$INSTALL_DIR/nvidia.ko*" >/dev/null; then
  echo "ERROR: nvidia.ko not found after DKMS build" >&2
  exit 1
fi

echo
echo "  OK nvidia module built successfully"

# ── Bundle modules for self-heal ─────────────────────────────────────────
BUNDLE_DIR="/home/.steamos-build/bundles/nvidia-open-dkms"
echo "  Bundling modules for self-heal"
mkdir -p "$BUNDLE_DIR"
cp -a "$INSTALL_DIR"/nvidia*.ko* "$BUNDLE_DIR/" || {
  echo "ERROR: failed to create NVIDIA self-heal bundle" >&2
  exit 1
}

for mod in nvidia nvidia-modeset nvidia-drm nvidia-uvm; do
  compgen -G "$BUNDLE_DIR/$mod.ko*" >/dev/null || {
    echo "ERROR: bundle missing $mod" >&2
    exit 1
  }
done

echo "=== NVIDIA DKMS module build complete ==="
