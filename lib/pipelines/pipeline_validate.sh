#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_validate.sh
# Validation pipeline definition.
# Validates configuration and system state.
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_validate.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_validate_pipeline() {
  define_pipeline \
    "discover" \
    "validate" \
    "report"

  register_phase "discover" "phase_validate_discover" "Discover context and load config"
  register_phase "validate" "phase_validate_run" "Run validation checks"
  register_phase "report" "phase_validate_report" "Summarize results"
}

# ---------------------------------------------------------------------------
# Validation State
# ---------------------------------------------------------------------------

declare -a _VALIDATE_RESULTS=()
declare _VALIDATE_PASSED=0
declare _VALIDATE_FAILED=0
declare _VALIDATE_SKIPPED=0
declare _VALIDATE_INFO=0
declare _VALIDATE_FOUND=0
declare _VALIDATE_HAS_CONFIG=0

_validate_pass() {
  local item="$1"
  local detail="${2:-}"
  local expected="${3:-}"
  local found="${4:-}"
  _VALIDATE_RESULTS+=("PASS|$item|$detail|$expected|$found")
  ((++_VALIDATE_PASSED))
  [[ "${VALIDATE_OUTPUT_FORMAT:-text}" == "json" ]] || log "  ✓ $item${detail:+ — $detail}"
}

_validate_fail() {
  local item="$1"
  local detail="${2:-}"
  local expected="${3:-}"
  local found="${4:-}"
  _VALIDATE_RESULTS+=("FAIL|$item|$detail|$expected|$found")
  ((++_VALIDATE_FAILED))
  [[ "${VALIDATE_OUTPUT_FORMAT:-text}" == "json" ]] || warn "  ✗ $item${detail:+ — $detail}"
}

_validate_info() {
  local item="$1"
  local detail="${2:-}"
  local expected="${3:-}"
  local found="${4:-}"
  _VALIDATE_RESULTS+=("INFO|$item|$detail|$expected|$found")
  ((++_VALIDATE_INFO))
  [[ "${VALIDATE_OUTPUT_FORMAT:-text}" == "json" ]] || log "  · $item${detail:+ — $detail}"
}

_validate_skip() {
  local item="$1"
  local reason="${2:-}"
  local expected="${3:-}"
  local found="${4:-}"
  _VALIDATE_RESULTS+=("SKIP|$item|$reason|$expected|$found")
  ((++_VALIDATE_SKIPPED))
  [[ "${VALIDATE_OUTPUT_FORMAT:-text}" == "json" ]] || log "  ○ $item${reason:+ — $reason}"
}

# ---------------------------------------------------------------------------
# Phase: Discover
# ---------------------------------------------------------------------------

phase_validate_discover() {
  stage_header "discovery"
  local root="${VALIDATE_ROOT:-/}"

  log "Validation target: $root"

  # Detect if target is a mounted rootfs or live system
  if [[ "$root" == "/" ]]; then
    log "Mode: live system"
    export OPT_MODE="live"
  else
    log "Mode: chroot ($root)"
    export OPT_MODE="chroot"
    export OPT_ROOT="$root"
  fi

  # Load config if explicitly provided.
  # Persisted config is sourced for variable context but does NOT trigger
  # config-aware filtering — only an explicit --config does.
  # Persisted config is only used for live validation (not offline images).
  if [[ -n "${VALIDATE_CONFIG:-}" && -f "${VALIDATE_CONFIG:-}" ]]; then
    log "Loading config: $VALIDATE_CONFIG"
    _VALIDATE_HAS_CONFIG=1
    # shellcheck disable=SC1090
    source "$VALIDATE_CONFIG"
  elif [[ "$OPT_MODE" != "chroot" && -f "/home/.steamos-build/build.conf" ]]; then
    log "Loading persisted config: /home/.steamos-build/build.conf (not filtering — no explicit config)"
    # shellcheck disable=SC1091
    source "/home/.steamos-build/build.conf"
  else
    log "No config found — validating all items"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Phase: Validate
# ---------------------------------------------------------------------------

phase_validate_run() {
  stage_header "validation"
  local root="${OPT_ROOT:-/}"

  log "Running validation checks"
  _validate_all "$root"

  return 0
}

# ---------------------------------------------------------------------------
# Validate All — Single Path
# ---------------------------------------------------------------------------
# Always validates everything from all confs.  Config-awareness is handled
# entirely in the report phase.

_validate_all() {
  local root="$1"

  # System config
  _validate_update_branch "$root"
  _validate_default_session "$root"
  _validate_target_variant "$root"
  _validate_update_mode "$root"
  _validate_rootfs_size "$root"
  _validate_pacman_repos "$root"
  _validate_pacman_repo_setting "$root"
  _validate_base_os_mode "$root"

  # Machine-id integrity (should be empty if source was empty)
  _validate_machine_id "$root"

  # Kernel sync (all kernel-coupled artifacts)
  _validate_kernel_sync "$root"

  # NVIDIA modprobe config
  _validate_nvidia_modprobe "$root"

  # Optimizations (all items from customizations.conf)
  _validate_all_optimizations "$root"

  # Initramfs (all groups from initramfs.conf)
  _validate_all_initramfs "$root"

  # Hardware packages (all entries from hw-packages.conf)
  _validate_all_hw_packages "$root"
}

# ---------------------------------------------------------------------------
# Validation Helpers — System Config
# ---------------------------------------------------------------------------

_validate_update_branch() {
  local root="$1"
  local expected="${UPDATE_BRANCH:-stable}"
  local actual
  actual="$(read_system_config "update-branch" "$root")"

  if verify_system_config "update-branch" "$root" "$expected"; then
    _validate_pass "update-branch" "" "$expected" "$actual"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "update-branch" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  else
    _validate_info "update-branch" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  fi
}

_validate_default_session() {
  local root="$1"
  local expected="${DEFAULT_SESSION:-game}"
  local actual
  actual="$(read_system_config "default-session" "$root")"

  if verify_system_config "default-session" "$root" "$expected"; then
    _validate_pass "default-session" "" "$expected" "$actual"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "default-session" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  else
    _validate_info "default-session" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  fi
}

_validate_target_variant() {
  local root="$1"
  local expected="${TARGET_VARIANT:-steamdeck}"
  local actual
  actual="$(read_system_config "variant" "$root")"

  # Validate variant is a known value
  case "$expected" in
    steamdeck | steamdeck-oobe) ;;
    *)
      _validate_fail "target-variant" "unknown variant: $expected" "" "$expected"
      return
      ;;
  esac

  if verify_system_config "variant" "$root" "$expected"; then
    _validate_pass "target-variant" "" "$expected" "$actual"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "target-variant" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  else
    _validate_info "target-variant" "expected $expected, got ${actual:-<unknown>}" "$expected" "$actual"
  fi
}

_validate_update_mode() {
  local root="$1"
  local expected="${UPDATE_MODE:-selfheal}"

  # Validate mode is a known value
  case "$expected" in
    selfheal | hold | stock) ;;
    *)
      _validate_fail "update-mode" "unknown mode: $expected" "" "$expected"
      return
      ;;
  esac

  # Check for mode-specific indicators
  local indicators_ok=1
  local detail=""

  case "$expected" in
    selfheal)
      # selfheal: steamos-update wrapper should exist
      if [[ -f "$root/usr/bin/steamos-update" ]]; then
        if grep -q "self-healing" "$root/usr/bin/steamos-update" 2>/dev/null; then
          detail="wrapper installed"
        else
          indicators_ok=0
          detail="wrapper missing self-healing marker"
        fi
      else
        indicators_ok=0
        detail="steamos-update wrapper not found"
      fi
      ;;
    hold)
      # hold: atomupd should be masked
      local atomupd="$root/etc/systemd/system/atomupd.service"
      if [[ -L "$atomupd" ]] && [[ "$(readlink "$atomupd")" == "/dev/null" ]]; then
        detail="atomupd masked"
      else
        indicators_ok=0
        detail="atomupd not masked"
      fi
      ;;
    stock)
      # stock: no special indicators to check
      detail="no special handling"
      ;;
  esac

  if [[ "$indicators_ok" -eq 1 ]]; then
    _validate_pass "update-mode" "$detail" "$expected" "$expected"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "update-mode" "$expected: $detail" "$expected" "$detail"
  else
    _validate_info "update-mode" "$expected: $detail" "$expected" "$detail"
  fi
}

_validate_machine_id() {
  local root="$1"
  local machine_id="$root/etc/machine-id"

  if [[ ! -f "$machine_id" ]]; then
    _validate_info "machine-id" "/etc/machine-id not found"
    return
  fi

  local content
  content="$(cat "$machine_id" 2>/dev/null)"

  # A valid machine ID is 32 hex characters
  # Empty or all-zero is expected for recovery images (Valve's uninitialized state)
  if [[ -z "$content" || "$content" =~ ^[0]+$ ]]; then
    _validate_pass "machine-id" "" "empty" "empty"
  elif [[ "$content" =~ ^[0-9a-fA-F]{32}$ ]]; then
    # Valid machine ID present — this is fine for live systems
    _validate_pass "machine-id" "" "valid" "valid"
  else
    _validate_fail "machine-id" "invalid format: $content" "empty or 32 hex chars" "$content"
  fi
}

_validate_pacman_repos() {
  local root="$1"
  local conf="$root/etc/pacman.conf"

  if [[ ! -f "$conf" ]]; then
    _validate_info "pacman-repos" "/etc/pacman.conf not found"
    return
  fi

  local -a repos=()
  local line
  while IFS= read -r line; do
    case "$line" in
      \[*\])
        line="${line#\[}"
        line="${line%\]}"
        [[ "$line" == "options" ]] && continue
        repos+=("$line")
        ;;
    esac
  done <"$conf"

  if [[ ${#repos[@]} -eq 0 ]]; then
    _validate_info "pacman-repos" "no repo sections found"
    return
  fi

  _validate_info "pacman-repos" "${repos[*]}"
}

_validate_pacman_repo_setting() {
  local expected="${PACMAN_REPO:-valve}"
  _validate_info "pacman-repo-setting" "$expected"
}

_validate_base_os_mode() {
  local expected="${BASE_OS_MODE:-additive}"

  case "$expected" in
    additive | upgrade)
      _validate_pass \
        "base-os-mode" \
        "" \
        "$expected" \
        "$expected"
      ;;
    *)
      _validate_fail \
        "base-os-mode" \
        "unknown mode: $expected" \
        "" \
        "$expected"
      ;;
  esac
}

_validate_rootfs_size() {
  local root="$1"
  local expected_mib="${ROOTFS_SIZE:-}"

  # Find the underlying block device from the mount point
  local part_bytes=0
  local fs_bytes=0

  # Try to get partition size from the block device backing the mount
  local backing_dev=""
  if mountpoint -q "$root" 2>/dev/null; then
    backing_dev="$(findmnt -n -o SOURCE "$root" 2>/dev/null)" || true
  fi

  # If we found a block device, get its size
  if [[ -n "$backing_dev" && -b "$backing_dev" ]]; then
    part_bytes="$(blockdev --getsize64 "$backing_dev" 2>/dev/null)" || part_bytes=0
  fi

  # Try to get filesystem size from btrfs
  if btrfs filesystem show "$root" >/dev/null 2>&1; then
    fs_bytes="$(btrfs filesystem usage -b "$root" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+')" || fs_bytes=0
  fi

  local part_mib=$((part_bytes / 1024 / 1024))
  local fs_mib=$((fs_bytes / 1024 / 1024))

  # If no ROOTFS_SIZE set, just report what we found
  if [[ -z "$expected_mib" ]]; then
    if [[ "$part_bytes" -gt 0 ]]; then
      _validate_pass "rootfs-size-partition" "" "" "${part_mib} MiB"
      _validate_pass "rootfs-size-filesystem" "" "" "${fs_mib} MiB"
    elif [[ "$fs_bytes" -gt 0 ]]; then
      _validate_pass "rootfs-size-filesystem" "" "" "${fs_mib} MiB"
    else
      _validate_info "rootfs-size-partition" "could not determine size"
      _validate_info "rootfs-size-filesystem" "could not determine size"
    fi
    return 0
  fi

  [[ "$expected_mib" =~ ^[0-9]+$ ]] || {
    _validate_fail "rootfs-size-partition" "invalid value: $expected_mib" "$expected_mib"
    _validate_fail "rootfs-size-filesystem" "invalid value: $expected_mib" "$expected_mib"
    return 0
  }

  local expected_bytes=$((expected_mib * 1024 * 1024))

  # ── Partition size ────────────────────────────────────────────────────
  if [[ "$part_bytes" -gt 0 ]]; then
    if [[ "$part_bytes" -ge "$expected_bytes" ]]; then
      _validate_pass "rootfs-size-partition" "" "${expected_mib} MiB" "${part_mib} MiB"
    else
      if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
        _validate_fail "rootfs-size-partition" "expected >= ${expected_mib} MiB, got ${part_mib} MiB" "${expected_mib} MiB" "${part_mib} MiB"
      else
        _validate_info "rootfs-size-partition" "expected >= ${expected_mib} MiB, got ${part_mib} MiB" "${expected_mib} MiB" "${part_mib} MiB"
      fi
    fi
  else
    _validate_skip "rootfs-size-partition" "cannot determine partition size"
  fi

  # ── Filesystem size ───────────────────────────────────────────────────
  if [[ "$fs_bytes" -gt 0 ]]; then
    if [[ "$part_bytes" -gt 0 && "$fs_bytes" -eq "$part_bytes" ]]; then
      _validate_pass "rootfs-size-filesystem" "" "${expected_mib} MiB" "${fs_mib} MiB"
    elif [[ "$fs_bytes" -ge "$expected_bytes" ]]; then
      _validate_pass "rootfs-size-filesystem" "" "${expected_mib} MiB" "${fs_mib} MiB"
    else
      if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
        _validate_fail "rootfs-size-filesystem" "expected >= ${expected_mib} MiB, got ${fs_mib} MiB" "${expected_mib} MiB" "${fs_mib} MiB"
      else
        _validate_info "rootfs-size-filesystem" "expected >= ${expected_mib} MiB, got ${fs_mib} MiB" "${expected_mib} MiB" "${fs_mib} MiB"
      fi
    fi
  else
    _validate_skip "rootfs-size-filesystem" "cannot determine filesystem size"
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Optimizations
# ---------------------------------------------------------------------------

_validate_optimization() {
  local item="$1"
  local root="$2"
  local rc

  verify_optimization_for_item "$item" "$OPT_MODE" "$root" 2>/dev/null
  rc=$?
  if [[ $rc -eq 0 ]]; then
    _validate_pass "$item"
  elif [[ $rc -eq 2 ]]; then
    _validate_skip "$item" "verify not supported"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "$item"
  else
    _validate_info "$item"
  fi
}

_validate_all_optimizations() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/customizations.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "optimizations" "customizations.conf not found"
    return
  fi

  local module item default
  while IFS='|' read -r module item default _; do
    [[ "$module" =~ ^#.*$ || -z "$module" ]] && continue
    _validate_optimization "$item" "$root"
  done <"$conf"
}

# ---------------------------------------------------------------------------
# Validation Helpers — Initramfs
# ---------------------------------------------------------------------------

_validate_all_initramfs() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/initramfs.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "initramfs" "initramfs.conf not found"
    return
  fi

  local group modules default
  while IFS='|' read -r group modules default _; do
    [[ "$group" =~ ^#.*$ || -z "$group" ]] && continue
    _validate_initramfs_group "$group" "$modules" "$root"
  done <"$conf"
}

_validate_initramfs_group() {
  local group="$1"
  local modules="$2"
  local root="$3"

  # Use first module name to make item identifier unique
  local first_module
  first_module="$(echo "$modules" | awk '{print $1}')"
  local item_id="initramfs/$group/$first_module"

  if verify_initramfs "$root" "$modules"; then
    _validate_pass "$item_id" "" "" "$modules"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "$item_id" "modules missing" "" "$modules"
  else
    _validate_info "$item_id" "modules missing" "" "$modules"
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Kernel Sync
# ---------------------------------------------------------------------------
# Verifies all kernel-coupled artifacts are in sync with the installed kernel.
# Treats the kernel package as the anchor and checks: vmlinuz, modules tree,
# headers/build tree, initramfs, and DKMS modules.

_validate_kernel_sync() {
  local root="$1"

  # Helper: run a command in the target (chroot for offline, direct for live)
  _ksync_run() {
    if [[ "$root" == "/" ]]; then
      /bin/bash -c "$*" 2>/dev/null
    else
      chroot "$root" /bin/bash -c "$*" 2>/dev/null
    fi
  }

  # ── 1. Discover kernel package ──────────────────────────────────────────
  local kpkg=""
  kpkg="$(_ksync_run "pacman -Qq | grep -E '^linux-neptune-[0-9]+$' | head -1")"

  if [[ -z "$kpkg" ]]; then
    _validate_fail "kernel/package" "no linux-neptune-* package found"
    return
  fi

  local kpkg_ver
  kpkg_ver="$(_ksync_run "pacman -Q $kpkg" | awk '{print $2}')"
  _validate_pass "kernel/package" "" "$kpkg" "$kpkg_ver"

  # ── 2. Derive kernel release string from package-owned modules tree ────
  local kver=""
  kver="$(
    _ksync_run "pacman -Ql '$kpkg'" \
      | sed -nE 's#^[^ ]+ /usr/lib/modules/([^/]+)/.*#\1#p' \
      | sort -u \
      | head -n1
  )"

  if [[ -z "$kver" ]]; then
    _validate_fail "kernel/release" "no /usr/lib/modules/* entry owned by $kpkg"
    return
  fi

  _validate_pass "kernel/release" "" "$kpkg" "$kver"

  # ── 2b. Running kernel (live systems only) ─────────────────────────────
  if [[ "$root" == "/" ]]; then
    local running_kver
    running_kver="$(uname -r)"

    if [[ "$running_kver" == "$kver" ]]; then
      _validate_pass "kernel/running" "" "$kver" "$running_kver"
    else
      _validate_info "kernel/running" "running $running_kver, installed $kver — reboot required" "$kver" "$running_kver"
    fi
  fi

  # ── 3. vmlinuz ─────────────────────────────────────────────────────────
  local vmlinuz="$root/boot/vmlinuz-$kpkg"
  if [[ -f "$vmlinuz" ]]; then
    local vmlinuz_ver=""
    # Try file first — bzImage frequently exposes its release this way
    if command -v file &>/dev/null; then
      vmlinuz_ver="$(file "$vmlinuz" 2>/dev/null | grep -oP 'Linux kernel x86 boot executable.*version \K[^ ,]+')"
    fi
    # Fallback to strings
    if [[ -z "$vmlinuz_ver" ]] && command -v strings &>/dev/null; then
      vmlinuz_ver="$(strings "$vmlinuz" 2>/dev/null | grep -m1 'Linux version' | awk '{print $3}')"
    fi

    if [[ -n "$vmlinuz_ver" ]]; then
      if [[ "$vmlinuz_ver" == "$kver" ]]; then
        _validate_pass "kernel/vmlinuz" "" "$kver" "$vmlinuz_ver"
      else
        _validate_fail "kernel/vmlinuz" "image reports $vmlinuz_ver, expected $kver" "$kver" "$vmlinuz_ver"
      fi
    else
      _validate_info "kernel/vmlinuz" "present; release could not be extracted"
    fi
  else
    _validate_fail "kernel/vmlinuz" "/boot/vmlinuz-$kpkg missing"
  fi

  # ── 4. Modules tree ────────────────────────────────────────────────────
  local moddir="$root/usr/lib/modules/$kver"
  if [[ -d "$moddir" ]]; then
    local mod_count
    mod_count="$(find "$moddir" -name '*.ko*' -type f 2>/dev/null | wc -l)"
    _validate_pass "kernel/modules-tree" "" "" "$mod_count modules"
  else
    _validate_fail "kernel/modules-tree" "/usr/lib/modules/$kver missing"
  fi

  # ── 5. Headers/build tree ──────────────────────────────────────────────
  local hpkg="${kpkg}-headers"
  local hpkg_ver=""
  hpkg_ver="$(_ksync_run "pacman -Q '$hpkg'" | awk '{print $2}')"

  if [[ -n "$hpkg_ver" ]]; then
    _validate_pass "kernel/headers-package" "" "$hpkg" "$hpkg_ver"
  else
    _validate_info "kernel/headers-package" "$hpkg not installed"
  fi

  # Check build tree via chroot to avoid host symlink resolution on offline images
  if _ksync_run "test -f '/usr/lib/modules/$kver/build/Makefile'"; then
    _validate_pass "kernel/headers" "" "" "build tree present"
  else
    _validate_info "kernel/headers" "build tree missing"
  fi

  # ── 6. Initramfs ───────────────────────────────────────────────────────
  local image
  for image in \
    "$root/boot/initramfs-$kpkg.img" \
    "$root/boot/initramfs-$kpkg-fallback.img"; do

    local label
    label="$(basename "$image" .img)"
    label="${label#initramfs-}"

    if [[ ! -f "$image" ]]; then
      if [[ "$label" == *-fallback ]]; then
        _validate_info "kernel/initramfs/$label" "missing (optional)"
      else
        _validate_fail "kernel/initramfs/$label" "missing"
      fi
      continue
    fi

    if ! command -v lsinitcpio &>/dev/null; then
      _validate_info "kernel/initramfs/$label" "present; lsinitcpio not available to inspect"
      continue
    fi

    local init_kvers
    init_kvers="$(
      lsinitcpio "$image" 2>/dev/null \
        | sed -nE 's#.*usr/lib/modules/([^/]+)/.*#\1#p' \
        | sort -u
    )"

    if [[ -z "$init_kvers" ]]; then
      _validate_info "kernel/initramfs/$label" "present; no modules release detected"
    elif grep -Fq "$kver" <<<"$init_kvers"; then
      local init_mod_count
      init_mod_count="$(lsinitcpio "$image" 2>/dev/null | grep -c '\.ko' || echo 0)"
      _validate_pass "kernel/initramfs/$label" "$init_mod_count modules" "$kver" "$kver"
    else
      _validate_fail "kernel/initramfs/$label" "contains modules for $init_kvers, expected $kver" "$kver" "$init_kvers"
    fi
  done

  # ── 7. DKMS / NVIDIA vermagic ──────────────────────────────────────────
  local nvidia_ko=""
  nvidia_ko="$(find "$moddir/updates/dkms" -name 'nvidia.ko*' -type f 2>/dev/null | head -1)"

  if [[ -n "$nvidia_ko" ]]; then
    local vermagic=""
    if command -v modinfo &>/dev/null; then
      vermagic="$(modinfo -F vermagic "$nvidia_ko" 2>/dev/null | head -1)"
    fi
    if [[ -z "$vermagic" ]]; then
      # Fallback: read vermagic from the .ko itself via strings
      vermagic="$(strings "$nvidia_ko" 2>/dev/null | grep -m1 '^vermagic=' | sed 's/^vermagic=//')"
    fi

    if [[ "$vermagic" == "$kver "* || "$vermagic" == "$kver" ]]; then
      _validate_pass "kernel/nvidia-vermagic" "" "$kver" "$vermagic"
    elif [[ -n "$vermagic" ]]; then
      _validate_fail "kernel/nvidia-vermagic" "vermagic '$vermagic' does not match $kver" "$kver" "$vermagic"
    else
      _validate_info "kernel/nvidia-vermagic" "could not read vermagic from $nvidia_ko"
    fi
  else
    _validate_info "kernel/nvidia-vermagic" "no nvidia.ko in updates/dkms"
  fi

  # ── 8. Boot artifacts (GRUB/EFI) ──────────────────────────────────────
  local grub_cfg=""
  for grub_cfg in \
    "$root/efi/EFI/SteamOS/grub.cfg" \
    "$root/efi/EFI/steamos/grub.cfg" \
    "/efi/EFI/SteamOS/grub.cfg" \
    "/efi/EFI/steamos/grub.cfg"; do
    [[ -f "$grub_cfg" ]] && break
    grub_cfg=""
  done

  if [[ -z "$grub_cfg" ]]; then
    _validate_info "kernel/boot-cfg" "grub.cfg not found (EFI may not be mounted)"
    return
  fi

  # Extract vmlinuz path from steamenv_boot linux lines
  local boot_vmlinuz
  boot_vmlinuz="$(grep -oP 'steamenv_boot\s+linux\s+\K/boot/vmlinuz[^ ]*' "$grub_cfg" 2>/dev/null | head -1)"

  if [[ -n "$boot_vmlinuz" ]]; then
    local boot_vmlinuz_name
    boot_vmlinuz_name="$(basename "$boot_vmlinuz")"
    if [[ "$boot_vmlinuz_name" == "vmlinuz-$kpkg" ]]; then
      _validate_pass "kernel/boot-vmlinuz" "" "vmlinuz-$kpkg" "$boot_vmlinuz_name"
    else
      _validate_fail "kernel/boot-vmlinuz" "points to $boot_vmlinuz_name, expected vmlinuz-$kpkg" "vmlinuz-$kpkg" "$boot_vmlinuz_name"
    fi
  else
    _validate_info "kernel/boot-vmlinuz" "no steamenv_boot linux line found in grub.cfg"
  fi

  # Extract initramfs path from initrd lines (plain initrd, not steamenv_boot)
  local boot_initramfs
  boot_initramfs="$(grep -oP '^\s*initrd\s+\K.*initramfs[^ ]*' "$grub_cfg" 2>/dev/null | head -1)"

  if [[ -n "$boot_initramfs" ]]; then
    local boot_initramfs_name
    boot_initramfs_name="$(basename "$boot_initramfs")"
    if [[ "$boot_initramfs_name" == "initramfs-$kpkg.img" ]]; then
      _validate_pass "kernel/boot-initramfs" "" "initramfs-$kpkg.img" "$boot_initramfs_name"
    else
      _validate_fail "kernel/boot-initramfs" "points to $boot_initramfs_name, expected initramfs-$kpkg.img" "initramfs-$kpkg.img" "$boot_initramfs_name"
    fi
  else
    _validate_info "kernel/boot-initramfs" "no initrd line found in grub.cfg"
  fi
}

# ── 9. NVIDIA modprobe config ─────────────────────────────────────────
_validate_nvidia_modprobe() {
  local root="$1"
  local modprobe_conf="$root/etc/modprobe.d/99-nvidia-patch.conf"

  if nvidia_is_selected; then
    # NVIDIA selected — config must exist with correct content
    if [[ -f "$modprobe_conf" ]]; then
      if grep -q 'blacklist nouveau' "$modprobe_conf"; then
        _validate_pass "nvidia/modprobe-config" "" "present" "present"
      else
        _validate_fail "nvidia/modprobe-config" "exists but missing 'blacklist nouveau'" "blacklist nouveau" "missing"
      fi
    else
      _validate_fail "nvidia/modprobe-config" "NVIDIA selected but modprobe config missing" "present" "missing"
    fi
  else
    # NVIDIA not selected — config should not be installer-added
    if [[ -f "$modprobe_conf" ]]; then
      if grep -q 'steamos-build-installer' "$modprobe_conf"; then
        _validate_fail "nvidia/modprobe-config" "NVIDIA not selected but installer-added modprobe config exists" "absent" "present"
      else
        _validate_info "nvidia/modprobe-config" "modprobe config exists (not installer-added)"
      fi
    else
      _validate_pass "nvidia/modprobe-config" "" "absent" "absent"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Validation Helpers — Hardware Packages
# ---------------------------------------------------------------------------

_validate_all_hw_packages() {
  local root="$1"
  local conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"

  if [[ ! -r "$conf" ]]; then
    _validate_skip "hw-packages" "hw-packages.conf not found"
    return
  fi

  local type group pkg version default desc recipe
  # shellcheck disable=SC2034 # version, default, desc consumed by read
  while IFS='|' read -r type group pkg version default desc recipe; do
    [[ "$type" =~ ^#.*$ || -z "$type" ]] && continue
    case "$type" in
      pacman)
        _validate_hw_package "$group" "$pkg" "$root"
        ;;
      build-recipe)
        _validate_kernel_module "$group" "$pkg" "$recipe" "$root"
        ;;
      flatpak)
        _validate_flatpak_item "$group" "$pkg" "$recipe" "$root"
        ;;
    esac
  done <"$conf"
}

_query_installed_version() {
  local pkg="${1%%=*}"
  local root="${2:-/}"

  if [[ "$root" == "/" ]]; then
    pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
  else
    pacman -Q --dbpath "$root/usr/lib/holo/pacmandb" "$pkg" 2>/dev/null | awk '{print $2}'
  fi
}

_validate_hw_package() {
  local group="$1"
  local pkg="$2"
  local root="${3:-/}"
  local ver
  ver="$(_query_installed_version "$pkg" "$root")"

  if [[ -n "$ver" ]]; then
    _validate_pass "hw/$group/$pkg" "" "$pkg" "$ver"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "hw/$group/$pkg" "not installed"
  else
    _validate_info "hw/$group/$pkg" "not installed"
  fi
}

_validate_kernel_module() {
  local group="$1"
  local name="$2"
  local recipe="$3"
  local root="${4:-/}"
  local ver
  ver="$(_query_installed_version "$name" "$root")"

  if [[ -n "$ver" ]]; then
    _validate_pass "build/$group/$name" "" "$name" "$ver"
  elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    _validate_fail "build/$group/$name" "not installed"
  else
    _validate_info "build/$group/$name" "not installed"
  fi
}

_validate_flatpak_item() {
  local group="$1"
  local name="$2"
  local recipe_name="$3"
  local root="$4"

  if [[ -z "$recipe_name" ]]; then
    _validate_fail "flatpak/$group/$name" "no recipe"
    return
  fi

  local recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe_name"
  if [[ ! -d "$recipe_dir" ]]; then
    _validate_fail "flatpak/$group/$name" "recipe directory missing"
    return
  fi

  local app_id
  app_id="$(sed -n 's/^FLATPAK_APP_ID=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"')"
  if [[ -z "$app_id" ]]; then
    _validate_fail "flatpak/$group/$name" "no FLATPAK_APP_ID in recipe"
    return
  fi

  if [[ "$OPT_MODE" == "live" ]]; then
    if flatpak info "$app_id" &>/dev/null; then
      _validate_pass "flatpak/$group/$name" "" "$app_id" "installed"
    elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      _validate_fail "flatpak/$group/$name" "$app_id not installed" "$app_id" "not installed"
    else
      _validate_info "flatpak/$group/$name" "$app_id not installed" "$app_id" "not installed"
    fi
  else
    local staged="$root/usr/share/steamos-build/flatpaks"
    if [[ -d "$staged" && -n "$(ls "$staged"/*.flatpak 2>/dev/null)" ]]; then
      _validate_pass "flatpak/$name" "" "" "staged"
    elif [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      _validate_fail "flatpak/$name" "no staged flatpak bundles in $staged"
    else
      _validate_info "flatpak/$name" "no staged flatpak bundles in $staged"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Config Selection Check
# ---------------------------------------------------------------------------
# Returns 0 if the item is "selected" in the loaded config, 1 if not.
# Used by the report phase to filter results when a config was provided.

_validate_is_selected() {
  local item="$1"

  # System config items are always selected
  case "$item" in
    update-branch* | default-session* | target-variant* | update-mode* | pacman-repo* | base-os-mode* | rootfs-size* | machine-id*) return 0 ;;
    kernel/*) return 0 ;;
    nvidia/*) return 0 ;;
  esac

  # Optimization items
  if [[ -n "${_OPT_ITEM_TO_MODULE["$item"]:-}" ]]; then
    # "always" items are unconditionally selected
    if [[ "${_OPT_ITEM_DEFAULT["$item"]:-}" == "always" ]]; then
      return 0
    fi
    # Check GAMING_ITEMS
    if [[ -n "${GAMING_ITEMS:-}" && " $GAMING_ITEMS " == *" $item "* ]]; then
      return 0
    fi
    return 1
  fi

  # Initramfs groups — check if the group's modules are in INITRAMFS_MODULES
  if [[ "$item" == initramfs/* ]]; then
    local group="${item#initramfs/}"
    group="${group%% (*}"
    if [[ -z "${INITRAMFS_MODULES:-}" ]]; then
      return 1
    fi
    # Look up modules for this group from initramfs.conf
    local conf="$SCRIPT_DIR/lib/configs/initramfs.conf"
    if [[ -r "$conf" ]]; then
      local g m d
      while IFS='|' read -r g m d _; do
        [[ "$g" =~ ^#.*$ || -z "$g" ]] && continue
        if [[ "$g" == "$group" ]]; then
          # Check if all modules in this group are in INITRAMFS_MODULES
          local mod
          for mod in $m; do
            if [[ " $INITRAMFS_MODULES " != *" $mod "* ]]; then
              return 1
            fi
          done
          return 0
        fi
      done <"$conf"
    fi
    return 1
  fi

  # Hardware packages — check HW_SUPPORT_ITEMS
  if [[ "$item" == hw/* ]]; then
    local pkg="${item#hw/}"
    pkg="${pkg#*/}"
    if [[ -n "${HW_SUPPORT_ITEMS:-}" && " $HW_SUPPORT_ITEMS " == *" $pkg "* ]]; then
      return 0
    fi
    return 1
  fi

  # Build items — check default from hw-packages.conf
  if [[ "$item" == build/* || "$item" == flatpak/* ]]; then
    local name="${item#*/}"
    name="${name% (*}"
    local conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"
    if [[ -r "$conf" ]]; then
      local t g n d
      while IFS='|' read -r t g n _ d _; do
        [[ "$t" =~ ^#.*$ || -z "$t" ]] && continue
        if [[ "$n" == "$name" && "$d" == "TRUE" ]]; then
          return 0
        fi
      done <"$conf"
    fi
    return 1
  fi

  # Unknown items — treat as not selected
  return 1
}

# ---------------------------------------------------------------------------
# Phase: Report
# ---------------------------------------------------------------------------

phase_validate_report() {
  stage_header "report"
  # If a config was loaded, cross-reference results against config selections.
  # Items not selected in the config are overridden to SKIP.
  if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
    local filtered=()
    local entry status item detail expected found
    local repassed=0 refailed=0 reskipped=0 reinfo=0 refound=0

    for entry in "${_VALIDATE_RESULTS[@]}"; do
      IFS='|' read -r status item detail expected found <<<"$entry"

      if _validate_is_selected "$item"; then
        # Selected — keep the real result
        filtered+=("$entry")
        case "$status" in
          PASS) ((++repassed)) ;;
          FAIL) ((++refailed)) ;;
          INFO) ((++reinfo)) ;;
          SKIP) ((++reskipped)) ;;
        esac
      elif [[ "$status" == "PASS" ]]; then
        # Not selected but present — mark as found
        filtered+=("FOUND|$item|present (not selected in config)|$expected|$found")
        ((++refound))
      else
        # Not selected and absent — skip
        filtered+=("SKIP|$item|not selected in config||")
        ((++reskipped))
      fi
    done

    # Replace results with filtered set
    _VALIDATE_RESULTS=("${filtered[@]}")
    _VALIDATE_PASSED=$repassed
    _VALIDATE_FAILED=$refailed
    _VALIDATE_SKIPPED=$reskipped
    _VALIDATE_INFO=$reinfo
    _VALIDATE_FOUND=$refound
  fi

  local total=$((_VALIDATE_PASSED + _VALIDATE_FAILED + _VALIDATE_SKIPPED + _VALIDATE_INFO + _VALIDATE_FOUND))

  # If --output was specified, write JSON to file
  if [[ -n "${VALIDATE_OUTPUT_FILE:-}" ]]; then
    _validate_report_json >"$VALIDATE_OUTPUT_FILE"
    log "JSON report written to: $VALIDATE_OUTPUT_FILE"
  fi

  # Summary output (always shown)
  echo ""
  echo "Validation:"
  printf "  total:   %d\n" "$total"
  printf "  passed:  %d\n" "$_VALIDATE_PASSED"
  printf "  failed:  %d\n" "$_VALIDATE_FAILED"
  printf "  skipped: %d\n" "$_VALIDATE_SKIPPED"
  printf "  info:    %d\n" "$_VALIDATE_INFO"
  printf "  found:   %d\n" "$_VALIDATE_FOUND"
  if [[ -n "${VALIDATE_OUTPUT_FILE:-}" ]]; then
    echo "JSON report: $VALIDATE_OUTPUT_FILE"
  fi

  # Show failed entries individually
  if ((_VALIDATE_FAILED > 0)); then
    echo ""
    echo "Failed items:"
    local entry status item detail expected found
    for entry in "${_VALIDATE_RESULTS[@]}"; do
      IFS='|' read -r status item detail expected found <<<"$entry"
      [[ "$status" == "FAIL" ]] && echo "  ✗ $item${detail:+ — $detail}"
    done
  fi

  # Full text report only in text mode (not JSON mode)
  local output_format="${VALIDATE_OUTPUT_FORMAT:-text}"
  if [[ "$output_format" != "json" ]]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      echo "  VALIDATION REPORT"
    else
      echo "  SYSTEM STATE REPORT"
    fi
    echo "═══════════════════════════════════════════════════════════"

    local section=""
    for entry in "${_VALIDATE_RESULTS[@]}"; do
      IFS='|' read -r status item detail expected found <<<"$entry"

      # Determine section from item prefix
      local new_section=""
      case "$item" in
        update-branch* | default-session* | target-variant* | update-mode* | pacman-repo* | rootfs-size* | machine-id*) new_section="System Config" ;;
        kernel/*) new_section="Kernel" ;;
        nvidia/*) new_section="NVIDIA" ;;
        initramfs/*) new_section="Initramfs" ;;
        hw/*) new_section="Hardware Packages" ;;
        build/* | flatpak/*) new_section="Build Items" ;;
        *) new_section="Customizations" ;;
      esac

      # Print section header on transition
      if [[ "$new_section" != "$section" ]]; then
        section="$new_section"
        echo ""
        echo "  $section"
        echo "  ────────────────────────────────────────────────"
      fi

      # Strip prefix for cleaner display
      local display="$item"
      case "$item" in
        initramfs/*) display="${item#initramfs/}" ;;
        kernel/*) display="${item#kernel/}" ;;
        hw/*) display="${item#hw/}" ;;
        build/*) display="${item#build/}" ;;
        flatpak/*) display="${item#flatpak/}" ;;
      esac

      case "$status" in
        PASS) echo "    ✓ $display" ;;
        FAIL) echo "    ✗ $display${detail:+ — $detail}" ;;
        INFO) echo "    · $display${detail:+ — $detail}" ;;
        SKIP) echo "    ○ $display${detail:+ — $detail}" ;;
        FOUND) echo "    ◆ $display${detail:+ — $detail}" ;;
      esac
    done

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    if [[ "$_VALIDATE_HAS_CONFIG" -eq 1 ]]; then
      printf "  Total: %d  Passed: %d  Failed: %d  Skipped: %d  Found: %d\n" \
        "$total" "$_VALIDATE_PASSED" "$_VALIDATE_FAILED" "$_VALIDATE_SKIPPED" "$_VALIDATE_FOUND"
    else
      printf "  Total: %d  Present: %d  Absent: %d  Skipped: %d\n" \
        "$total" "$_VALIDATE_PASSED" "$_VALIDATE_INFO" "$_VALIDATE_SKIPPED"
    fi
    echo "═══════════════════════════════════════════════════════════"
    echo ""
  fi

  return 0
}

# ---------------------------------------------------------------------------
# JSON Output
# ---------------------------------------------------------------------------
# Outputs validation results as JSON for machine ingestion.

# Escape a string for safe inclusion in a JSON string value.
# Handles all JSON-required escapes: control chars (U+0000–U+001F),
# backslash, and double-quote.
_json_escape() {
  local s="$1"
  # Backslash must be first to avoid double-escaping
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  # Control characters that have short escape sequences
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  # Remaining control characters (U+0000–U+001F) as \u00XX
  local i c
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    # Check if character is a control character (ASCII < 0x20) that we
    # haven't already escaped. printf %d gives the decimal codepoint.
    local ord
    printf -v ord '%d' "'$c" 2>/dev/null || ord=0
    if (( ord >= 0 && ord < 32 )); then
      s="${s:0:$i}$(printf '\\u%04x' "$ord")${s:$((i+1))}"
      # skip past the 6-char escape we just inserted
      (( i += 5 ))
    fi
  done
  printf '%s' "$s"
}

_validate_report_json() {
  local total=$((_VALIDATE_PASSED + _VALIDATE_FAILED + _VALIDATE_SKIPPED + _VALIDATE_INFO + _VALIDATE_FOUND))

  echo "{"
  echo "  \"has_config\": $([ "$_VALIDATE_HAS_CONFIG" -eq 1 ] && echo true || echo false),"
  echo "  \"summary\": {"
  echo "    \"total\": $total,"
  echo "    \"passed\": $_VALIDATE_PASSED,"
  echo "    \"failed\": $_VALIDATE_FAILED,"
  echo "    \"skipped\": $_VALIDATE_SKIPPED,"
  echo "    \"info\": $_VALIDATE_INFO,"
  echo "    \"found\": $_VALIDATE_FOUND"
  echo "  },"
  echo "  \"results\": ["

  local first=1
  local entry status item detail expected found section
  for entry in "${_VALIDATE_RESULTS[@]}"; do
    IFS='|' read -r status item detail expected found <<<"$entry"

    # Determine section
    case "$item" in
      update-branch* | default-session* | target-variant* | update-mode* | pacman-repo* | rootfs-size* | machine-id*) section="system-config" ;;
      kernel/*) section="kernel" ;;
      nvidia/*) section="nvidia" ;;
      initramfs/*) section="initramfs" ;;
      hw/*) section="hardware-packages" ;;
      build/* | flatpak/*) section="build-items" ;;
      *) section="customizations" ;;
    esac

    # Strip prefix for display
    local display="$item"
    case "$item" in
      initramfs/*) display="${item#initramfs/}" ;;
      kernel/*) display="${item#kernel/}" ;;
      hw/*) display="${item#hw/}" ;;
      build/*) display="${item#build/}" ;;
      flatpak/*) display="${item#flatpak/}" ;;
    esac

    # JSON escape detail, expected, found
    local detail_escaped
    detail_escaped="$(_json_escape "$detail")"
    local expected_escaped
    expected_escaped="$(_json_escape "$expected")"
    local found_escaped
    found_escaped="$(_json_escape "$found")"

    # Also escape item, display, section, status for safety
    local item_escaped
    item_escaped="$(_json_escape "$item")"
    local display_escaped
    display_escaped="$(_json_escape "$display")"
    local section_escaped
    section_escaped="$(_json_escape "$section")"
    local status_escaped
    status_escaped="$(_json_escape "$status")"

    [[ "$first" -eq 0 ]] && echo ","
    first=0

    printf '    {"status": "%s", "item": "%s", "display": "%s", "detail": "%s", "expected": "%s", "found": "%s", "section": "%s"}' \
      "$status_escaped" "$item_escaped" "$display_escaped" "$detail_escaped" "$expected_escaped" "$found_escaped" "$section_escaped"
  done

  echo ""
  echo "  ]"
  echo "}"
}
