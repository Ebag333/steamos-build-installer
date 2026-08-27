#!/bin/bash
#
# steamos-nvidia-installer — lib/initramfs.sh
# Single source of truth for initramfs configuration and module management.
# Handles: chroot (build/rebuild), live, verify.
#
# Reads module definitions from configs/initramfs.conf.
# Sourced by the build backend and repatch — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/initramfs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

INITRAMFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INITRAMFS_CONF="$INITRAMFS_DIR/configs/initramfs.conf"

# ---------------------------------------------------------------------------
# Module Registry
# ---------------------------------------------------------------------------
# Load module definitions from initramfs.conf

declare -A _INITRAMFS_GROUP_MODULES=()
declare -A _INITRAMFS_GROUP_DEFAULT=()
declare -A _INITRAMFS_GROUP_DESC=()

_load_initramfs_conf() {
  local group modules default desc

  if [[ ! -r "$INITRAMFS_CONF" ]]; then
    warn "Initramfs config not found: $INITRAMFS_CONF"
    return 1
  fi

  while IFS='|' read -r group modules default desc; do
    [[ "$group" =~ ^#.*$ || -z "$group" ]] && continue

    if [[ -n "${_INITRAMFS_GROUP_MODULES[$group]:-}" ]]; then
      _INITRAMFS_GROUP_MODULES[$group]+=" $modules"
    else
      _INITRAMFS_GROUP_MODULES[$group]="$modules"
    fi
    _INITRAMFS_GROUP_DEFAULT[$group]="$default"
    _INITRAMFS_GROUP_DESC[$group]="$desc"
  done <"$INITRAMFS_CONF"
}

_load_initramfs_conf

# ---------------------------------------------------------------------------
# Module Discovery
# ---------------------------------------------------------------------------

# Get modules for a specific group.
# Args: $1 = group name
# Output: space-separated module list
get_initramfs_group_modules() {
  local group="${1:?get_initramfs_group_modules: missing group name}"
  echo "${_INITRAMFS_GROUP_MODULES[$group]:-}"
}

# Get all modules from all groups (deduplicated).
# Args: $@ = groups to include (empty = all TRUE groups)
# Output: space-separated module list
get_all_initramfs_modules() {
  local -a groups=("$@")
  local all_modules=""

  if [[ ${#groups[@]} -eq 0 ]]; then
    for group in "${!_INITRAMFS_GROUP_MODULES[@]}"; do
      [[ "${_INITRAMFS_GROUP_DEFAULT[$group]:-FALSE}" == "TRUE" ]] || continue
      groups+=("$group")
    done
  fi

  for group in "${groups[@]}"; do
    local mods="${_INITRAMFS_GROUP_MODULES[$group]:-}"
    [[ -n "$mods" ]] && all_modules+=" $mods"
  done

  echo "$all_modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'
}

# Get all modules from all groups regardless of default (deduplicated).
# Args: $@ = groups to include (empty = all groups)
# Output: space-separated module list
get_all_initramfs_modules_force() {
  local -a groups=("$@")
  local all_modules=""

  if [[ ${#groups[@]} -eq 0 ]]; then
    for group in "${!_INITRAMFS_GROUP_MODULES[@]}"; do
      groups+=("$group")
    done
  fi

  for group in "${groups[@]}"; do
    local mods="${_INITRAMFS_GROUP_MODULES[$group]:-}"
    [[ -n "$mods" ]] && all_modules+=" $mods"
  done

  echo "$all_modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'
}

# Get modules from a space-separated list of group names.
# Args: $1 = space-separated group names
# Output: space-separated module list
get_initramfs_modules_by_groups() {
  local group_list="${1:?get_initramfs_modules_by_groups: missing group list}"
  local -a groups
  read -ra groups <<<"$group_list"
  get_all_initramfs_modules "${groups[@]}"
}

# Discover hardware modules via modprobe -R.
# Filters out nouveau.  Returns space-separated list.
# Args: $1 = root path (chroot target), $2 = optional kernel version
discover_auto_modules() {
  local root="${1:?discover_auto_modules: missing root}"
  local kver="${2:-${KVER:-$(uname -r)}}"
  local modules=""

  for dev in /sys/bus/pci/devices/*/modalias; do
    [[ -f "$dev" ]] || continue
    modules+="$(chroot "$root" modprobe -S "$kver" -R "$(cat "$dev")" 2>/dev/null || true)"$'\n'
  done

  echo "$modules" \
    | sort -u \
    | { grep -Ev '^nouveau$' || true; } \
    | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# Module Validation
# ---------------------------------------------------------------------------

# Validate modules against a target kernel.
# Args: $1 = root path, $2 = kernel version, $3 = space-separated modules
# Output: space-separated validated modules
validate_initramfs_modules() {
  local root="${1:?validate_initramfs_modules: missing root}"
  local kver="${2:?validate_initramfs_modules: missing kernel version}"
  local modules="${3:-}"
  local validated=""

  for mod in $modules; do
    if chroot "$root" modinfo -k "$kver" "$mod" >/dev/null 2>&1; then
      validated+=" $mod"
    else
      log "  Skipping $mod (not found in kernel $kver)"
    fi
  done

  echo "${validated# }"
}

# ---------------------------------------------------------------------------
# Initramfs Configuration (Internal)
# ---------------------------------------------------------------------------

# Write initramfs config files without regenerating.
# For offline targets where regeneration happens after boot.
#
# Args: $1 = root path, $2 = kernel version, $3 = space-separated modules
# Returns 0 on success, 1 on failure
_write_initramfs_config() {
  local root="${1:?_write_initramfs_config: missing root}"
  local kver="${2:?_write_initramfs_config: missing kernel version}"
  local modules="${3:-}"

  if [[ -z "$modules" ]]; then
    log "  No modules specified — leaving initramfs unchanged"
    return 0
  fi

  local validated
  validated="$(validate_initramfs_modules "$root" "$kver" "$modules")"

  if [[ -z "$validated" ]]; then
    log "  No valid modules for $kver — leaving initramfs unchanged"
    return 0
  fi

  log "  Writing initramfs config with modules: $validated"

  if [[ -x "$root/usr/bin/dracut" ]]; then
    _write_dracut_config "$root" "$validated"
  elif [[ -x "$root/usr/bin/mkinitcpio" ]]; then
    _write_mkinitcpio_config "$root" "$validated"
  else
    warn "  No initramfs tool found (dracut or mkinitcpio)"
    return 1
  fi
}

# Regenerate initramfs from existing config.
# Args: $1 = root path
# Returns 0 on success, 1 on failure
_regenerate_initramfs() {
  local root="${1:?_regenerate_initramfs: missing root}"

  if [[ -x "$root/usr/bin/dracut" ]]; then
    log "  Regenerating initramfs (dracut)..."
    timeout 300 chroot "$root" dracut -f 2>&1 \
      || {
        warn "dracut failed or timed out"
        return 1
      }
  elif [[ -x "$root/usr/bin/mkinitcpio" ]]; then
    log "  Regenerating initramfs (mkinitcpio)..."
    local mkinitcpio_out
    mkinitcpio_out="$(timeout 300 chroot "$root" mkinitcpio -P 2>&1)" \
      || {
        warn "mkinitcpio failed or timed out: $mkinitcpio_out"
        return 1
      }

    if [[ -n "$mkinitcpio_out" ]]; then
      local mk_warnings
      mk_warnings="$(echo "$mkinitcpio_out" | grep -iE 'warning|missing|Possibly' || true)"
      if [[ -n "$mk_warnings" ]]; then
        log "  mkinitcpio warnings:"
        while IFS="" read -r w; do log "    $w"; done <<<"$mk_warnings"
      fi
    fi
  else
    warn "  No initramfs tool found (dracut or mkinitcpio)"
    return 1
  fi
}

# Full configure: write config + regenerate.
# For chroot/live where regeneration is immediate.
#
# Args: $1 = root path, $2 = kernel version, $3 = space-separated modules
# Returns 0 on success, 1 on failure
_configure_initramfs_modules() {
  local root="${1:?_configure_initramfs_modules: missing root}"
  local kver="${2:?_configure_initramfs_modules: missing kernel version}"
  local modules="${3:-}"

  _write_initramfs_config "$root" "$kver" "$modules" || return 1
  _regenerate_initramfs "$root"
}

# Write dracut config file.
# Args: $1 = root path, $2 = space-separated modules
_write_dracut_config() {
  local root="${1:?_write_dracut_config: missing root}"
  local modules="${2:?_write_dracut_config: missing modules}"

  log "  Using dracut for initramfs"
  mkdir -p "$root/etc/dracut.conf.d"
  cat >"$root/etc/dracut.conf.d/99-steamos-nvidia.conf" <<EOF
# Added by steamos-nvidia-installer
add_drivers+=" $modules "
EOF
  log "  dracut modules: $modules"
}

# Write mkinitcpio config file.
# Args: $1 = root path, $2 = space-separated modules
_write_mkinitcpio_config() {
  local root="${1:?_write_mkinitcpio_config: missing root}"
  local modules="${2:?_write_mkinitcpio_config: missing modules}"

  log "  Using mkinitcpio for initramfs"

  local existing_modules merged_modules
  if [[ -f "$root/etc/mkinitcpio.conf" ]]; then
    existing_modules=$(sed -n 's/^MODULES=(\(.*\))/\1/p' "$root/etc/mkinitcpio.conf")
    log "  Existing modules: ${existing_modules:-<none>}"
    merged_modules=$(echo "$existing_modules $modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
  else
    merged_modules="$modules"
  fi

  mkdir -p "$root/etc/mkinitcpio.conf.d"
  cat >"$root/etc/mkinitcpio.conf.d/99-steamos-nvidia.conf" <<EOF
# Added by steamos-nvidia-installer
MODULES=($merged_modules)
EOF
  log "  MODULES=($merged_modules)"

  if [[ -f "$root/etc/mkinitcpio.conf" ]]; then
    if ! grep -q 'BINARIES=.*bash' "$root/etc/mkinitcpio.conf"; then
      log "  Adding bash to BINARIES in mkinitcpio.conf"
      sed -i 's|^BINARIES=(|BINARIES=(bash |' "$root/etc/mkinitcpio.conf"
    fi
  fi
}

# ---------------------------------------------------------------------------
# High-Level Interface
# ---------------------------------------------------------------------------
# Three paths: chroot, live, verify.

# Write initramfs config without regenerating (for offline targets).
# The config will take effect when the target boots and regenerates its own initramfs.
#
# Args:
#   $1 = root path
#   $2 = kernel version
#   $3 = space-separated module list
write_initramfs_config() {
  local root="${1:?write_initramfs_config: missing root}"
  local kver="${2:?write_initramfs_config: missing kernel version}"
  local modules="${3:?write_initramfs_config: missing modules}"

  _write_initramfs_config "$root" "$kver" "$modules"
}

# Apply initramfs configuration (chroot or live).
#
# Args:
#   $1 = root path
#   $2 = kernel version
#   $3 = (optional) space-separated module list
#        If empty, auto-discovers hardware modules and combines with defaults.
#
# This is the single entry point for all initramfs configuration.
apply_initramfs() {
  local root="${1:?apply_initramfs: missing root}"
  local kver="${2:?apply_initramfs: missing kernel version}"
  local custom_modules="${3:-}"

  local modules
  if [[ -n "$custom_modules" ]]; then
    log "Using custom initramfs modules"
    modules="$custom_modules"
  else
    log "Auto-discovering initramfs modules"
    local auto_modules
    auto_modules="$(discover_auto_modules "$root" "$kver")"
    modules="$(get_all_initramfs_modules) $auto_modules"
    modules="$(echo "$modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')"
  fi

  _configure_initramfs_modules "$root" "$kver" "$modules"
}

# Reconcile initramfs for repatch (self-heal).
# Handles chroot mount setup/teardown.
#
# Args:
#   $1 = root path
#   $2 = kernel version
#   $3 = (optional) space-separated module list
#        If empty, uses defaults from initramfs.conf (stock initramfs — no-op).
reconcile_initramfs() {
  local root="${1:?reconcile_initramfs: missing root}"
  local kver="${2:?reconcile_initramfs: missing kernel version}"
  local custom_modules="${3:-}"

  if [[ -z "$custom_modules" ]]; then
    log "Stock initramfs — not reconfiguring"
    return 0
  fi

  log "Reconciling initramfs for $kver"
  log "  Requested modules: $custom_modules"

  if declare -F mount_chroot_fs >/dev/null 2>&1; then
    mount_chroot_fs "$root"
  fi

  local effective_etc=0
  if declare -F mount_effective_etc >/dev/null 2>&1 \
    && declare -F unmount_effective_etc >/dev/null 2>&1; then
    mount_effective_etc "$root"
    effective_etc=1
  fi

  _reconcile_initramfs_cleanup() {
    set +e
    if ((effective_etc)); then unmount_effective_etc "$root" 2>/dev/null; fi
    umount_chroot_fs_cleanup "$root" 2>/dev/null
  }
  trap _reconcile_initramfs_cleanup ERR

  _configure_initramfs_modules "$root" "$kver" "$custom_modules"
  local rc=$?

  trap - ERR

  if ((effective_etc)); then
    unmount_effective_etc "$root"
  fi
  if declare -F umount_chroot_fs >/dev/null 2>&1; then
    umount_chroot_fs "$root" strict
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
# Check whether initramfs is configured with expected modules.
# Returns 0 if configured and valid, 1 if not.
#
# Args:
#   $1 = root path
#   $2 = (optional) space-separated expected module list
#        If empty, reads modules from the config file.
#   $3 = (optional) kernel version for modinfo validation
#        If empty, skips kernel validation.
#
# Checks:
#   1. Config file exists (dracut or mkinitcpio)
#   2. Expected modules are present in config (if provided)
#   3. Configured modules are valid in target kernel (if kver provided)

verify_initramfs() {
  local root="${1:?verify_initramfs: missing root}"
  local expected_modules="${2:-}"
  local kver="${3:-}"

  # Check for our config files
  local dracut_conf="$root/etc/dracut.conf.d/99-steamos-nvidia.conf"
  local mkinitcpio_conf="$root/etc/mkinitcpio.conf.d/99-steamos-nvidia.conf"
  local config_file=""

  if [[ -f "$dracut_conf" ]]; then
    config_file="$dracut_conf"
  elif [[ -f "$mkinitcpio_conf" ]]; then
    config_file="$mkinitcpio_conf"
  else
    return 1
  fi

  # Read configured modules from the config file
  local configured_modules=""
  if [[ "$config_file" == *"dracut"* ]]; then
    # dracut format: add_drivers+=" mod1 mod2 "
    configured_modules="$(sed -n 's/.*add_drivers+="\(.*\)".*/\1/p' "$config_file" | tr -s ' ')"
  else
    # mkinitcpio format: MODULES=(mod1 mod2)
    configured_modules="$(sed -n 's/^MODULES=(\(.*\))/\1/p' "$config_file" | tr -s ' ')"
  fi

  # Check expected modules are present in config
  if [[ -n "$expected_modules" ]]; then
    for mod in $expected_modules; do
      if [[ " $configured_modules " != *" $mod "* ]]; then
        return 1
      fi
    done
  fi

  # Validate modules against target kernel
  if [[ -n "$kver" && -n "$configured_modules" ]]; then
    local validated
    validated="$(validate_initramfs_modules "$root" "$kver" "$configured_modules")"
    if [[ -z "$validated" ]]; then
      return 1
    fi
  fi

  return 0
}
