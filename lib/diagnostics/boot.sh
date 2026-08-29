#!/bin/bash
#
# steamos-build-installer — lib/diagnostics/boot.sh
# Boot and partition diagnostics for SteamOS A/B slot system.
# Provides functions to diagnose boot layout and state.
#
# Sourced by repatch.sh and pipeline scripts — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/diagnostics/boot.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Boot Layout Diagnostics
# ---------------------------------------------------------------------------

# Diagnose boot partition layout and partsets.
# Args: $1 = partset (optional, defaults to current)
diagnose_boot_layout() {
  local partset="${1:-${PARTSET:-unknown}}"
  local slot kind path resolved mnt info out rc

  log "Boot/partset diagnostics:"
  log "  requested partset: $partset"
  log "  kernel cmdline: $(cat /proc/cmdline 2>/dev/null || echo '<unavailable>')"

  # Check partset symlinks
  for slot in A B self other; do
    for kind in rootfs efi var; do
      path="/dev/disk/by-partsets/$slot/$kind"
      if [[ -e "$path" || -L "$path" ]]; then
        resolved="$(readlink -f "$path" 2>/dev/null || true)"
        log "  $slot/$kind -> ${resolved:-<unresolved>}"
      else
        log "  $slot/$kind -> <missing>"
      fi
    done
  done

  # Check EFI mounts
  for mnt in /efi /esp; do
    if mountpoint -q "$mnt" 2>/dev/null; then
      info="$(findmnt -rn -o SOURCE,FSTYPE,OPTIONS,TARGET "$mnt" 2>/dev/null || true)"
      log "  mount $mnt: ${info:-<unknown>}"
    else
      log "  mount $mnt: <not mounted>"
    fi

    # Check partsets directory
    if [[ -d "$mnt/SteamOS/partsets" ]]; then
      log "  $mnt/SteamOS/partsets:"
      while IFS="" read -r out; do
        log "    $out"
      done < <(ls -la "$mnt/SteamOS/partsets" 2>&1)
    else
      log "  $mnt/SteamOS/partsets: <missing>"
    fi

    # Check conf directory
    if [[ -d "$mnt/SteamOS/conf" ]]; then
      log "  $mnt/SteamOS/conf:"
      while IFS="" read -r out; do
        log "    $out"
      done < <(ls -la "$mnt/SteamOS/conf" 2>&1)
    else
      log "  $mnt/SteamOS/conf: <missing>"
    fi
  done

  # Check steamos-bootconf
  if command -v steamos-bootconf >/dev/null 2>&1; then
    if out="$(steamos-bootconf this-image 2>&1)"; then
      log "  steamos-bootconf this-image: $out"
    else
      rc=$?
      warn "steamos-bootconf this-image failed (rc=$rc): $out"
    fi

    if out="$(steamos-bootconf list-images 2>&1)"; then
      while IFS="" read -r path; do
        log "  steamos-bootconf list-images: $path"
      done <<<"$out"
    else
      rc=$?
      warn "steamos-bootconf list-images failed (rc=$rc): $out"
    fi

    if out="$(steamos-bootconf selected-image 2>&1)"; then
      log "  steamos-bootconf selected-image: $out"
    else
      rc=$?
      warn "steamos-bootconf selected-image failed (rc=$rc): $out"
    fi
  else
    warn "steamos-bootconf not found"
  fi
}

# ---------------------------------------------------------------------------
# Boot State Diagnostics
# ---------------------------------------------------------------------------

# Diagnose SteamOS boot state for A/B slots.
diagnose_boot_state() {
  local slot out rc line

  log "SteamOS boot state:"

  for slot in A B; do
    if out="$(steamos-bootconf --image "$slot" config \
      --get boot-attempts \
      --get boot-requested-at \
      --get image-invalid \
      --get comment 2>&1)"; then

      log "  [$slot]"
      while IFS="" read -r line; do
        log "    $line"
      done <<<"$out"
    else
      rc=$?
      warn "Could not read boot state for $slot (rc=$rc): $out"
    fi
  done
}

# ---------------------------------------------------------------------------
# Rootfs Diagnostics
# ---------------------------------------------------------------------------

# Diagnose rootfs writability and filesystem state.
# Args: $1 = root path
diagnose_rootfs_state() {
  local root="${1:-/}"
  local vfs_opts btrfs_ro

  log "Rootfs state diagnostics:"
  log "  root: $root"

  # VFS mount options
  vfs_opts="$(findmnt -no OPTIONS "$root" 2>/dev/null || true)"
  log "  VFS options: ${vfs_opts:-<unknown>}"

  # Btrfs read-only property
  if btrfs filesystem show "$root" >/dev/null 2>&1; then
    btrfs_ro="$(btrfs property get -ts "$root" ro 2>/dev/null | awk -F= '/^ro=/{print $2}' || true)"
    log "  Btrfs ro: ${btrfs_ro:-<unknown>}"

    # Partition vs filesystem size
    local part_bytes fs_bytes
    part_bytes="$(blockdev --getsize64 "$(findmnt -rn -o SOURCE "$root" | head -1)" 2>/dev/null || echo 0)"
    fs_bytes="$(btrfs filesystem usage -b "$root" 2>/dev/null | grep -oP '^\s+Device size:\s+\K[0-9]+' || echo 0)"
    log "  Partition size: $part_bytes bytes"
    log "  Filesystem size: $fs_bytes bytes"
  else
    log "  Filesystem: not btrfs"
  fi

  # Write test
  if touch "$root/.rw-test" 2>/dev/null; then
    rm -f "$root/.rw-test"
    log "  Write test: OK"
  else
    log "  Write test: FAILED"
  fi
}

# ---------------------------------------------------------------------------
# Kernel Diagnostics
# ---------------------------------------------------------------------------

# Diagnose kernel and module state.
# Args: $1 = root path, $2 = kernel version (optional)
diagnose_kernel_state() {
  local root="${1:-/}"
  local kver="${2:-$(uname -r)}"

  log "Kernel state diagnostics:"
  log "  kernel: $kver"

  # Check kernel package
  local kpkg_dir
  kpkg_dir="$(find "$root/usr/lib/holo/pacmandb/local" -maxdepth 1 -name 'linux-neptune-*' -type d 2>/dev/null | head -1 || true)"
  if [[ -n "$kpkg_dir" ]]; then
    log "  kernel package: $(basename "$kpkg_dir")"
  else
    log "  kernel package: <not found>"
  fi

  # Check headers
  if [[ -d "$root/usr/lib/modules/$kver/build" ]]; then
    log "  headers: installed"
  else
    log "  headers: missing"
  fi

  # Check NVIDIA modules
  local mod
  for mod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    local mod_path
    mod_path="$(chroot "$root" modinfo -k "$kver" -n "$mod" 2>/dev/null || true)"
    if [[ -n "$mod_path" ]]; then
      log "  $mod: $mod_path"
    else
      log "  $mod: <not found>"
    fi
  done
}

# ---------------------------------------------------------------------------
# Combined Diagnostics
# ---------------------------------------------------------------------------

# Run all diagnostics.
# Args: $1 = root path (optional), $2 = partset (optional)
run_all_diagnostics() {
  local root="${1:-/}"
  local partset="${2:-${PARTSET:-unknown}}"

  diagnose_boot_layout "$partset"
  diagnose_boot_state
  diagnose_rootfs_state "$root"
  diagnose_kernel_state "$root"
}
