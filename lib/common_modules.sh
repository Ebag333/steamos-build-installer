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

  if (( failed )); then
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

  (( ${#BUILT_MODULE_FILES[@]} > 0 )) || return 0

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

# Discover hardware modules via modprobe -R.
# Filters out nouveau.  Returns space-separated list.
# Args: $1 = root path (chroot target), $2 = optional kernel version
discover_auto_modules() {
  local root="${1:?discover_auto_modules: missing root}"
  local kver="${2:-${KVER:?discover_auto_modules: KVER is not set}}"
  local modules=""

  for dev in /sys/bus/pci/devices/*/modalias; do
    [[ -f "$dev" ]] || continue
    modules+="$(chroot "$root" modprobe -S "$kver" -R "$(cat "$dev")" 2>/dev/null)"$'\n'
  done

  echo "$modules" \
    | sort -u \
    | { grep -Ev '^nouveau$' || true; } \
    | tr '\n' ' '
}

# Configure initramfs (dracut or mkinitcpio) with nvidia + auto-discovered modules.
# Args: $1 = root path, $2 = space-separated auto-discovered modules
#       $3 = (optional) "egpu" to exclude nvidia from initramfs (deprecated)
#       $4 = (optional) space-separated user-selected module list; overrides $2
#       $5 = (optional) kernel version; defaults to global KVER
configure_initramfs() {
  local root="${1:?configure_initramfs: missing root}"
  local auto_modules="${2:-}"
  # shellcheck disable=SC2034
  local mode="${3:-}"
  local user_modules="${4:-}"
  local kver="${5:-${KVER:?configure_initramfs: KVER is not set}}"

  local all_modules
  # If user provided a specific module list, use it instead of auto-discovery.
  if [[ -n "$user_modules" ]]; then
    log "  Using user-selected initramfs modules"
    all_modules="$user_modules"
  else
    all_modules="nvidia nvidia_modeset nvidia_drm nvidia_uvm $auto_modules"
  fi

  # Deduplicate (grep returns 1 when filtering empties from an empty list — don't let pipefail kill us)
  all_modules=$(echo "$all_modules" | tr ' ' '\n' | sort -u | { grep -v '^$' || true; } | tr '\n' ' ')

  # Validate every module against the target kernel.  Modules discovered on the
  # build host may not exist in the image's kernel version.
  local validated=""
  local _mod
  for _mod in $all_modules; do
    if chroot "$root" modinfo -k "$kver" "$_mod" >/dev/null 2>&1; then
      validated+="$_mod "
    else
      log "  Skipping $_mod (not found in target kernel $kver)"
    fi
  done
  validated="${validated% }"

  # Always replace the requested set with the validated set.  If every
  # requested module is invalid, all_modules must become empty rather than
  # silently falling back to the original unvalidated list.
  all_modules="$validated"

  # An explicit selection whose members are all invalid should leave the
  # existing initramfs untouched.  This preserves repatch's previous behavior
  # and avoids an unnecessary regeneration that cannot add anything useful.
  if [[ -n "$user_modules" && -z "$all_modules" ]]; then
    log "  No requested modules are valid for $kver — leaving initramfs unchanged"
    return 0
  fi

  log "  Checking initramfs tools..."
  if [[ -x "$root/usr/bin/dracut" ]]; then
    log "  Using dracut for initramfs"
    cat > "$root/etc/dracut.conf.d/99-steamos-nvidia.conf" <<EOF
# Added by steamos-nvidia-installer
add_drivers+=" $all_modules "
EOF
    log "  dracut modules: $all_modules"
    log "  Regenerating initramfs (this may take a while)..."
    timeout 300 chroot "$root" dracut -f 2>&1 \
      || die "dracut failed or timed out"
  elif [[ -x "$root/usr/bin/mkinitcpio" ]]; then
    log "  Using mkinitcpio for initramfs"
    if [[ -n "$all_modules" ]]; then
      local existing_modules merged_modules
      existing_modules=$(sed -n 's/^MODULES=(\(.*\))/\1/p' "$root/etc/mkinitcpio.conf")
      log "  Existing modules: ${existing_modules:-<none>}"
      merged_modules=$(echo "$existing_modules $all_modules" | tr ' ' '\n' | sort -u | { grep -v '^$' || true; } | tr '\n' ' ')
      sed -i "s|^MODULES=(.*)|MODULES=($merged_modules)|" "$root/etc/mkinitcpio.conf"
      log "  MODULES=($merged_modules)"
    fi
    # Ensure bash is in BINARIES — mount.steamos requires it and SteamOS's
    # default mkinitcpio.conf does not include it.
    if [[ -f "$root/etc/mkinitcpio.conf" ]]; then
      if ! grep -q 'BINARIES=.*bash' "$root/etc/mkinitcpio.conf"; then
        log "  Adding bash to BINARIES in mkinitcpio.conf"
        sed -i 's|^BINARIES=(|BINARIES=(bash |' "$root/etc/mkinitcpio.conf"
      fi
    fi
    log "  Regenerating initramfs (this may take a while)..."
    local mkinitcpio_out
    mkinitcpio_out="$(timeout 300 chroot "$root" mkinitcpio -P 2>&1)" \
      || die "mkinitcpio failed or timed out: $mkinitcpio_out"
    # Log warnings even on success — missing firmware/scripts are informational.
    if [[ -n "$mkinitcpio_out" ]]; then
      local mk_warnings
      mk_warnings="$(echo "$mkinitcpio_out" | grep -iE 'warning|missing|Possibly' || true)"
      if [[ -n "$mk_warnings" ]]; then
        log "  mkinitcpio warnings:"
        while IFS= read -r w; do log "    $w"; done <<< "$mk_warnings"
      fi
    fi
    # Verify critical components landed in the generated initramfs.
    # lsinitcpio lists cpio archive contents — try host first, fall back to chroot.
    # Path differs: host uses $root/boot/..., chroot uses /boot/...
    local _use_chroot=0
    if ! command -v lsinitcpio >/dev/null 2>&1; then
      if [[ -x "$root/usr/bin/lsinitcpio" ]]; then
        _use_chroot=1
      else
        log "  lsinitcpio not available — skipping initramfs verification"
        return 0
      fi
    fi

    local initramfs_img
    for initramfs_img in "$root"/boot/initramfs-*.img; do
      [[ -f "$initramfs_img" ]] || continue
      local img_name
      img_name="$(basename "$initramfs_img")"
      local contents
      if [[ $_use_chroot -eq 1 ]]; then
        contents="$(chroot "$root" lsinitcpio "/boot/$img_name" 2>/dev/null)" || continue
      else
        contents="$(lsinitcpio "$initramfs_img" 2>/dev/null)" || continue
      fi

      # Check bash availability.
      local bash_found=0
      if echo "$contents" | grep -qE '(^|/)bash$'; then
        bash_found=1
        log "  $img_name: bash present"
      fi
      # Check if /bin is a symlink (usr-merged) — if /bin/bash isn't listed
      # but /usr/bin/bash is, the shebang may still resolve via symlink.
      if [[ $bash_found -eq 0 ]]; then
        if echo "$contents" | grep -qE '^usr/bin/bash$'; then
          log "  $img_name: /usr/bin/bash present (usr-merged)"
          bash_found=1
        fi
      fi
      # Check /bin -> usr/bin symlink in the initramfs.
      if echo "$contents" | grep -qE '^bin -> usr/bin$'; then
        log "  $img_name: /bin -> usr/bin symlink present"
      else
        # Some lsinitcpio versions don't list symlinks explicitly.
        # If both /bin/bash and /usr/bin/bash are absent, that's the problem.
        if [[ $bash_found -eq 0 ]]; then
          warn "  $img_name: /bin symlink NOT detected and bash missing entirely"
        fi
      fi

      # Check mount.steamos and its interpreter.
      if echo "$contents" | grep -qE '(^|/)mount\.steamos$'; then
        log "  $img_name: mount.steamos present (requires /bin/bash per mkinitcpio)"

        if [[ $bash_found -eq 0 ]]; then
          die "  $img_name: bash NOT in initramfs — mount.steamos requires /bin/bash. Build aborted."
        fi
      fi

      # Check mkinitcpio config for bash in BINARIES.
      if [[ -f "$root/etc/mkinitcpio.conf" ]]; then
        if grep -q 'BINARIES=.*bash' "$root/etc/mkinitcpio.conf"; then
          log "  mkinitcpio.conf: bash in BINARIES"
        else
          warn "  mkinitcpio.conf: bash NOT in BINARIES array"
        fi
      fi
    done
  else
    warn "No initramfs tool found (neither dracut nor mkinitcpio)"
  fi
}

# Reconcile explicitly persisted initramfs module selections for a target
# rootfs.  An empty selection means "leave the stock initramfs alone".
#
# This owns chroot mount setup/teardown and, when rootfs-etc.sh is available,
# temporarily exposes SteamOS's effective /etc overlay before regeneration.
# repatch can use the same helper without depending on rootfs-etc.sh; in that
# environment it preserves the existing lower-/etc behavior.
#
# Args:
#   $1 = target root
#   $2 = kernel version
#   $3 = space-separated explicit module list
reconcile_initramfs() {
  local root="${1:?reconcile_initramfs: missing root}"
  local kver="${2:?reconcile_initramfs: missing kernel version}"
  local user_modules="${3:-}"
  local effective_etc=0

  if [[ -z "$user_modules" ]]; then
    log "Stock initramfs — not reconfiguring"
    return 0
  fi

  log "Reconciling initramfs for $kver"
  log "  Requested modules: $user_modules"

  mount_chroot_fs "$root"

  # Initial image builds source rootfs-etc.sh and therefore reconcile the
  # runtime-effective /etc.  The on-device repatch bundle currently does not
  # require that helper, so keep this capability optional.
  if declare -F mount_effective_etc >/dev/null 2>&1 \
     && declare -F unmount_effective_etc >/dev/null 2>&1; then
    mount_effective_etc "$root"
    effective_etc=1
  fi

  # ERR trap ensures teardown runs even if configure_initramfs calls die().
  # Uses the permissive cleanup variant (lazy-unmount fallback, never dies)
  # so the trap itself cannot fail while we are already handling an error.
  _reconcile_initramfs_cleanup() {
    set +e
    if (( effective_etc )); then unmount_effective_etc "$root" 2>/dev/null; fi
    umount_chroot_fs_cleanup "$root" 2>/dev/null
  }
  trap _reconcile_initramfs_cleanup ERR

  configure_initramfs "$root" "" "" "$user_modules" "$kver"

  trap - ERR

  if (( effective_etc )); then
    unmount_effective_etc "$root"
  fi

  umount_chroot_fs "$root" strict
}

