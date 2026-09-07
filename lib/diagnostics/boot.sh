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
    out="$(steamos-bootconf this-image 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
      log "  steamos-bootconf this-image: $out"
    else
      warn "steamos-bootconf this-image failed (rc=$rc): $out"
    fi

    out="$(steamos-bootconf list-images 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
      while IFS="" read -r path; do
        log "  steamos-bootconf list-images: $path"
      done <<<"$out"
    else
      warn "steamos-bootconf list-images failed (rc=$rc): $out"
    fi

    out="$(steamos-bootconf selected-image 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then
      log "  steamos-bootconf selected-image: $out"
    else
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

  if ! command -v steamos-bootconf >/dev/null 2>&1; then
    warn "steamos-bootconf not found — cannot diagnose boot state"
    return 0
  fi

  log "SteamOS boot state:"

  for slot in A B; do
    out="$(steamos-bootconf --image "$slot" config \
      --get boot-attempts \
      --get boot-requested-at \
      --get image-invalid \
      --get comment 2>&1)" && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then

      log "  [$slot]"
      while IFS="" read -r line; do
        log "    $line"
      done <<<"$out"
    else
      warn "Could not read boot state for $slot (rc=$rc): $out"
    fi
  done
}
