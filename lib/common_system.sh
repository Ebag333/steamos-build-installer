#!/bin/bash
#
# steamos-build-installer — lib/common_system.sh
# System helpers: chroot filesystem mounting, depmod, ldconfig, nvidia services.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common_system.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Mount proc/sys/dev into a chroot directory.
# Args: $1 = root path (e.g. $MNT, $MERGED, $NEWROOT)
mount_chroot_fs() {
  local root="${1:?mount_chroot_fs: missing root}"
  log "Mounting chroot filesystems in $root"
  mkdir -p "$root/proc" "$root/sys" "$root/dev"
  mount -t proc proc "$root/proc"
  mount --rbind /sys "$root/sys"
  mount --make-rslave "$root/sys"
  mount --rbind /dev "$root/dev"
  mount --make-rslave "$root/dev"
  log "  chroot mounts ready: proc sys dev"
}

# Unmount proc/sys/dev from a chroot directory.
# Args: $1 = root path, $2 = mode (optional: "strict" to die on failure, default: permissive)
umount_chroot_fs() {
  local root="${1:?umount_chroot_fs: missing root}"
  local mode="${2:-}"

  # Collect only the children that are actually mounted — avoids spurious
  # warnings when cleanup runs before mount_chroot_fs was called.
  local -a targets=()
  local child
  for child in proc sys dev; do
    mountpoint -q "$root/$child" 2>/dev/null && targets+=("$root/$child")
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    log "Unmounting chroot filesystems in $root (nothing mounted)"
    return 0
  fi

  log "Unmounting chroot filesystems in $root"
  if ! umount -R "${targets[@]}" 2>/dev/null; then
    if [[ "$mode" == "strict" ]]; then
      warn "Failed to unmount chroot filesystems in $root"
      warn "  Active mounts:"
      findmnt --target "$root" -o SOURCE,TARGET,OPTIONS 2>/dev/null | while IFS="" read -r line; do
        warn "    $line"
      done
      die "Could not cleanly unmount chroot in $root"
    else
      warn "Strict unmount failed for $root, trying lazy unmount"
      umount -Rl "${targets[@]}" 2>/dev/null || true
    fi
  fi
  log "  chroot mounts removed"
}

# Run depmod + ldconfig in a chroot.
# Args: $1 = root path, $2 = kernel version
run_depmod_ldconfig() {
  local root="${1:?run_depmod_ldconfig: missing root}"
  local kver="${2:?run_depmod_ldconfig: missing kver}"
  chroot "$root" depmod "$kver"
  chroot "$root" ldconfig
}

# Enable nvidia power management services in a chroot.
# Creates enable symlinks directly rather than relying on systemctl inside a
# chroot (no running systemd daemon means systemctl enable is unreliable).
# Args: $1 = root path
enable_nvidia_power_services() {
  local root="${1:?enable_nvidia_power_services: missing root}"
  local wants_dir="$root/etc/systemd/system/multi-user.target.wants"
  local svc enabled=0

  for svc in nvidia-suspend nvidia-resume nvidia-hibernate; do
    if [[ -f "$root/usr/lib/systemd/system/${svc}.service" ]]; then
      mkdir -p "$wants_dir"
      ln -sf "/usr/lib/systemd/system/${svc}.service" \
        "$wants_dir/${svc}.service"
      ((enabled++)) || true
    fi
  done

  if ((enabled == 0)); then
    warn "No nvidia power services found in image — nothing to enable"
  else
    log "Enabled $enabled nvidia power service(s)"
  fi
}

# Backup steamos-update and install the self-heal wrapper.
# Args: $1 = root path
backup_original_updater() {
  local root="${1:?backup_original_updater: missing root}"
  if [[ ! -f "$root/usr/bin/steamos-update.orig" ]]; then
    mv "$root/usr/bin/steamos-update" "$root/usr/bin/steamos-update.orig"
  fi
}

# Unmount a path if it is a mountpoint.  No-op when not mounted.
# Args: $1 = path, $2 = label (used in error message)
ensure_unmounted() {
  local path="${1:?ensure_unmounted: missing path}"
  local label="${2:-$path}"
  if mountpoint -q "$path" 2>/dev/null; then
    strict_unmount "$path" "$label" || die "Could not clean stale $label"
  fi
}

# ── Persistent mount tracking ─────────────────────────────────────────────────
# A plain-text file ($MOUNTS_FILE, typically $WORKDIR/mounts) records every
# mountpoint we create.  If the process is killed before cleanup runs, the next
# build reads this file and tears down the leftovers in reverse order.
#
# Callers set MOUNTS_FILE before using these helpers.  All functions are no-ops
# when MOUNTS_FILE is unset or the file does not exist.

# Append a mountpoint to the tracking file.  Idempotent — duplicates are
# silently skipped.
# Args: $1 = mountpoint path
track_mount() {
  local mnt="${1:?track_mount: missing mountpoint}"
  [[ -n "${MOUNTS_FILE:-}" ]] || return 0
  mkdir -p "$(dirname "$MOUNTS_FILE")"
  if [[ ! -f "$MOUNTS_FILE" ]] || ! grep -qxF "$mnt" "$MOUNTS_FILE" 2>/dev/null; then
    printf '%s\n' "$mnt" >>"$MOUNTS_FILE"
  fi
}

# Remove a mountpoint from the tracking file, but ONLY after verifying the
# mount is actually gone.  No-op if the entry does not exist or the path is
# still mounted.
# Args: $1 = mountpoint path
untrack_mount() {
  local mnt="${1:?untrack_mount: missing mountpoint}"
  [[ -n "${MOUNTS_FILE:-}" && -f "$MOUNTS_FILE" ]] || return 0

  # Safety: refuse to untrack if the mount is still alive.
  if mountpoint -q "$mnt" 2>/dev/null; then
    warn "untrack_mount: $mnt is still mounted — refusing to remove from tracking"
    return 1
  fi

  local tmp="${MOUNTS_FILE}.untrack.$$"
  if grep -vxF "$mnt" "$MOUNTS_FILE" >"$tmp" 2>/dev/null; then
    mv -- "$tmp" "$MOUNTS_FILE"
  else
    rm -f "$tmp"
  fi
}

# Read the tracking file and tear down every listed mount in reverse order.
# Entries for mounts that are already gone are silently removed.  Entries whose
# unmount fails are left in place for the next attempt.
# Args: none (uses $MOUNTS_FILE)
cleanup_tracked_mounts() {
  [[ -n "${MOUNTS_FILE:-}" && -f "$MOUNTS_FILE" ]] || return 0

  log "Cleaning up tracked mounts from $MOUNTS_FILE"

  # Read into an array so we can process in reverse (LIFO).
  local -a mounts=()
  local line
  while IFS="" read -r line; do
    [[ -n "$line" ]] && mounts+=("$line")
  done <"$MOUNTS_FILE"

  if [[ ${#mounts[@]} -eq 0 ]]; then
    rm -f "$MOUNTS_FILE"
    return 0
  fi

  local rc=0
  local i
  for ((i = ${#mounts[@]} - 1; i >= 0; i--)); do
    local m="${mounts[$i]}"

    if ! mountpoint -q "$m" 2>/dev/null; then
      # Already gone — just clean the entry.
      untrack_mount "$m" 2>/dev/null || true
      continue
    fi

    if strict_unmount "$m" "tracked mount"; then
      untrack_mount "$m" 2>/dev/null || true
    else
      warn "cleanup_tracked_mounts: could not unmount $m"
      rc=1
    fi
  done

  # If everything was cleaned up, remove the file.
  if ((rc == 0)) && [[ -f "$MOUNTS_FILE" ]]; then
    local remaining
    remaining="$(wc -l <"$MOUNTS_FILE" 2>/dev/null || echo 1)"
    if [[ "$remaining" -eq 0 ]] 2>/dev/null; then
      rm -f "$MOUNTS_FILE"
    fi
  fi

  return "$rc"
}

# Log entry count and human-readable size of a directory tree.
# Args: $1 = directory path
count_dir_entries() {
  local dir="${1:?count_dir_entries: missing dir}" count bytes
  count="$(find "$dir" -mindepth 1 -printf '.' 2>/dev/null | wc -c)"
  bytes="$(du -sh "$dir" 2>/dev/null | awk '{print $1}')"
  log "  ${count:-0} entries, ${bytes:-unknown} on disk"
}

# Rsync with ownership/permissions/xattrs, then verify with a dry-run diff.
# Dies if the copy or verification fails.  Optional trailing args are mount
# paths to unmount (in order) before dying on failure.
# Args: $1 = source (trailing slash), $2 = destination (trailing slash)
#       $3 = label for error messages
#       $4… = mount paths to unmount on failure (optional)
rsync_verified() {
  local src="${1:?}" dst="${2:?}" label="${3:-rsync}"
  shift 3

  rsync -aHAX --numeric-ids "$src" "$dst" || {
    local m
    for m in "$@"; do strict_unmount "$m" "$label cleanup" || true; done
    die "Failed to $label"
  }

  local _diff
  _diff="$(
    rsync -aHAXcn --numeric-ids --delete --itemize-changes "$src" "$dst"
  )" || {
    local m
    for m in "$@"; do strict_unmount "$m" "$label cleanup" || true; done
    die "Failed to verify $label"
  }

  if [[ -n "$_diff" ]]; then
    warn "$label verification — content differs:"
    printf '%s\n' "$_diff" >&2
    local m
    for m in "$@"; do strict_unmount "$m" "$label cleanup" || true; done
    die "$label verification failed"
  fi
}
