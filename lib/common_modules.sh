#!/bin/bash
#
# steamos-nvidia-installer — lib/common_modules.sh
# Module helpers: kernel discovery, module verification, and initramfs reconciliation.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common_modules.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Discover the neptune kernel version in a rootfs.
# Sets KVER global.  Dies if not found.
# Args: $1 = root path (e.g. $MNT, $NEWROOT)
discover_neptune_kver() {
  local root="${1:?discover_neptune_kver: missing root}"
  KVER=""
  for d in "$root/usr/lib/modules/"*neptune*; do
    [[ -d "$d" ]] && KVER="$(basename "$d")" && break
  done
  [[ -n "$KVER" ]] || die "No neptune kernel found in $root"
}

# Check if nvidia.ko exists in a rootfs.
# Args: $1 = root path, $2 = kernel version
nvidia_module_exists() {
  local root="${1:?nvidia_module_exists: missing root}"
  local kver="${2:?nvidia_module_exists: missing kver}"
  compgen -G "$root/usr/lib/modules/$kver/updates/dkms/nvidia.ko*" >/dev/null
}

# Kernel modules explicitly built by this run.
#
# Entries are paths relative to /usr/lib/modules/$KVER, for example:
#   updates/logitech/hid-logitech-dj.ko
#
# Module builders register their outputs as they create them.  Consumers can
# then verify the same set before payload copy and again after installation
# without knowing which subsystem produced each module.
declare -ag BUILT_MODULE_FILES=()

register_built_module() {
  local module="${1:?register_built_module: missing module path}"
  local existing

  # Keep one canonical relative form.
  module="${module#/}"
  if [[ -n "${KVER:-}" ]]; then
    local _kver_prefix="usr/lib/modules/$KVER/"
    module="${module#"$_kver_prefix"}"
  fi

  [[ "$module" != usr/lib/modules/* ]] \
    || die "register_built_module: path belongs to a different/unknown kernel: $module"

  for existing in "${BUILT_MODULE_FILES[@]}"; do
    [[ "$existing" == "$module" ]] && return 0
  done

  BUILT_MODULE_FILES+=("$module")
}

# Resolve a registered .ko path, accepting the compression formats normally
# used for installed kernel modules.
_resolve_module_file() {
  local base="${1:?_resolve_module_file: missing path}"
  local candidate

  for candidate in "$base" "$base.zst" "$base.xz" "$base.gz"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

# Verify an explicit set of module paths in a rootfs.
# Args:
#   $1 = root path
#   $2 = kernel version
#   $3 = "die" or "warn"
#   $4... = paths relative to /usr/lib/modules/$2
_verify_module_files() {
  local root="${1:?_verify_module_files: missing root}"
  local kver="${2:?_verify_module_files: missing kver}"
  local on_fail="${3:-warn}"
  shift 3

  local module base actual vermagic
  local failed=0

  for module in "$@"; do
    base="$root/usr/lib/modules/$kver/$module"
    actual="$(_resolve_module_file "$base" 2>/dev/null || true)"

    if [[ -z "$actual" ]]; then
      warn "Kernel module not found: $base"
      failed=1
      continue
    fi

    # Use the file directly rather than the module name, so this does not
    # depend on depmod having regenerated modules.dep yet.
    vermagic="$(modinfo -F vermagic "$actual" 2>/dev/null || true)"
    if [[ -z "$vermagic" ]]; then
      warn "Could not read module metadata: $actual"
      failed=1
      continue
    fi

    if [[ "$vermagic" != "$kver" && "$vermagic" != "$kver "* ]]; then
      warn "Kernel module has wrong vermagic: $actual"
      warn "  expected: $kver"
      warn "  actual:   $vermagic"
      failed=1
      continue
    fi

    log "  ✓ ${module##*/}"
  done

  if ((failed)); then
    if [[ "$on_fail" == "die" ]]; then
      die "One or more kernel modules failed verification for $kver"
    fi
    return 1
  fi

  return 0
}

# Verify every module registered by this build.
# Args: $1 = root path, $2 = kernel version, $3 = (optional) "die" to abort
verify_built_modules() {
  local root="${1:?verify_built_modules: missing root}"
  local kver="${2:?verify_built_modules: missing kver}"
  local on_fail="${3:-warn}"

  ((${#BUILT_MODULE_FILES[@]} > 0)) || return 0

  log "Verifying ${#BUILT_MODULE_FILES[@]} built kernel module(s) for $kver"
  _verify_module_files \
    "$root" "$kver" "$on_fail" \
    "${BUILT_MODULE_FILES[@]}"
}

# Compatibility helper for existing repatch/install code.  New module builders
# should register their outputs with register_built_module() and use
# verify_built_modules() instead.
verify_hid_modules() {
  local root="${1:?verify_hid_modules: missing root}"
  local kver="${2:?verify_hid_modules: missing kver}"
  local on_fail="${3:-warn}"

  local -a hid_modules=(
    "updates/logitech/hid-logitech-dj.ko"
    "updates/logitech/hid-logitech-hidpp.ko"
  )

  _verify_module_files "$root" "$kver" "$on_fail" "${hid_modules[@]}"
}
