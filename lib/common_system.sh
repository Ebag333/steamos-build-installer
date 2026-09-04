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
  mount -t proc proc "$root/proc" \
    || die "Failed to mount proc in $root"
  mount --rbind /sys "$root/sys" \
    || { umount -R "$root/proc" 2>/dev/null; die "Failed to mount sys in $root"; }
  mount --make-rslave "$root/sys" 2>/dev/null || true
  mount --rbind /dev "$root/dev" \
    || { umount -R "$root/sys" "$root/proc" 2>/dev/null; die "Failed to mount dev in $root"; }
  mount --make-rslave "$root/dev" 2>/dev/null || true
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
      warn "Regular unmount failed for $root, trying lazy unmount"
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
  grep -vxF "$mnt" "$MOUNTS_FILE" >"$tmp" 2>/dev/null || true
  if [[ -s "$tmp" ]]; then
    mv -- "$tmp" "$MOUNTS_FILE"
  else
    rm -f "$tmp" "$MOUNTS_FILE"
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

# ---------------------------------------------------------------------------
# SteamOS Read-Only Mode
# ---------------------------------------------------------------------------
# Disable/enable SteamOS read-only filesystem protection.

disable_steamos_readonly() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Disabling SteamOS read-only mode"
    steamos-readonly disable || true
  fi
}

enable_steamos_readonly() {
  if command -v steamos-readonly >/dev/null 2>&1; then
    log "Re-enabling SteamOS read-only mode"
    steamos-readonly enable || true
  fi
}

# ---------------------------------------------------------------------------
# Temporary File Cleanup
# ---------------------------------------------------------------------------
# Remove project-owned temporary files only.
# Run after overlay and bind mounts have been unmounted.

cleanup_temporary_files() {
  local mode="${1:---host}"
  local root="${2:-/}"

  case "$mode" in
    --host)
      rm -rf -- \
        /tmp/steamos-build \
        /dev/shm/steamos-build
      ;;

    --root)
      [[ "$root" != "/" ]] || {
        warn "cleanup_temporary_files: refusing --root with /"
        return 1
      }

      rm -rf -- \
        "$root/tmp/steamos-build" \
        "$root/var/tmp/steamos-build"
      ;;

    *)
      warn "cleanup_temporary_files: unknown mode '$mode'"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Partial Download Cleanup
# ---------------------------------------------------------------------------
# Remove incomplete pacman download fragments.

cleanup_partial_downloads() {
  local root="${1:-/}"
  local pkg_dir="$root/var/cache/pacman/pkg"

  if [[ -d "$pkg_dir" ]]; then
    find "$pkg_dir" -maxdepth 1 -type f \
      \( -name '*.part' -o -name '*.download' \) -delete
  fi
}

# ---------------------------------------------------------------------------
# Journal and Coredump Cleanup
# ---------------------------------------------------------------------------
# Bound journal size and remove coredumps and crash reports.

cleanup_diagnostics() {
  local root="${1:-/}"

  if [[ "$root" == "/" ]]; then
    journalctl --vacuum-size=50M 2>/dev/null ||
      warn "Journal cleanup failed"
  else
    journalctl --root="$root" --vacuum-size=50M 2>/dev/null ||
      warn "Target journal cleanup failed"
  fi

  rm -f -- "$root"/var/lib/systemd/coredump/* 2>/dev/null || true
  rm -f -- "$root"/var/crash/* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Build Artifact Cleanup
# ---------------------------------------------------------------------------
# Remove installer build artifacts, makepkg working directories,
# and build-user caches. Safe for repatch and image-finalize.

cleanup_build_artifacts() {
  local root="${1:-/}"

  # makepkg working directories
  rm -rf -- "$root/tmp/makepkg-"* 2>/dev/null || true
  rm -rf -- "$root/var/tmp/makepkg-"* 2>/dev/null || true

  # Root cache (build-user cache cleaned only if populated during build)
  rm -rf -- "$root/root/.cache" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# DKMS Scratch Cleanup
# ---------------------------------------------------------------------------
# Remove completed DKMS build logs and compiled module scratch,
# but only after verifying the final .ko files exist under
# /usr/lib/modules/<kernel>. Preserves source and registration state.

cleanup_dkms_scratch() {
  local root="${1:-/}"
  local dkms_dir="$root/var/lib/dkms"

  [[ -d "$dkms_dir" ]] || return 0

  local module version kernel arch ko_dir
  while IFS= read -r -d '' module_dir; do
    module="$(basename "$(dirname "$(dirname "$module_dir")")")"
    version="$(basename "$(dirname "$module_dir")")"
    kernel="$(basename "$module_dir")"
    local -a _arch_candidates=("$module_dir"/*)
    arch="$(basename "${_arch_candidates[0]}" 2>/dev/null)"

    [[ -n "$arch" ]] || continue

    # Verify installed .ko exists before cleaning scratch
    ko_dir="$root/usr/lib/modules/$kernel"
    if [[ -d "$ko_dir" ]] && find "$ko_dir" -name "${module//-/_}.ko*" -print -quit | grep -q .; then
      rm -rf -- "$module_dir/$arch/module" 2>/dev/null || true
      rm -rf -- "$module_dir/$arch/log" 2>/dev/null || true
    fi
  done < <(find "$dkms_dir" -mindepth 4 -maxdepth 4 -type d -print0 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Image Finalization Cleanup
# ---------------------------------------------------------------------------
# Aggressive cleanup for finalized build images only.
# Removes sync databases and external build intermediates.

cleanup_image_finalize() {
  local root="${1:-/}"

  # Pacman sync databases (will be recreated by pacman -Sy)
  rm -f -- "$root"/var/lib/pacman/sync/* 2>/dev/null || true

  # External build intermediates (recovery images, overlay work dirs, etc.)
  # These live outside $root and are safe to remove after image is finalized.
  rm -rf -- /tmp/steamos-recovery-* 2>/dev/null || true
  rm -rf -- /tmp/steamos-overlay-* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Disk Cleanup
# ---------------------------------------------------------------------------
# Clean target-owned caches, temporary files, and diagnostics.
#
# Policies:
#   live            Project temp files, partial downloads, bounded journal
#   repatch         Same, plus build artifacts and verified DKMS scratch
#   image-finalize  Same, plus sync databases and external intermediates

cleanup_disk_space() {
  local root="${1:-/}"
  local policy="${2:-live}"
  local before_kb after_kb freed_kb

  if [[ "$root" != "/" ]]; then
    if [[ ! -d "$root" || ! -e "$root/etc/os-release" ]]; then
      warn "cleanup_disk_space: invalid target root: $root"
      return 1
    fi
  fi

  case "$policy" in
    live|repatch|image-finalize) ;;
    *)
      warn "cleanup_disk_space: unknown policy '$policy' (use live, repatch, or image-finalize)"
      return 1
      ;;
  esac

  log "Cleaning disk space under $root (policy: $policy)"

  before_kb="$(df -Pk "$root" | awk 'NR == 2 { print $4 }')"

  # --- All policies ---

  if [[ "$root" == "/" ]]; then
    pacman_clean_cache --host ||
      warn "Pacman cache cleanup failed"
  else
    pacman_clean_cache --chroot "$root" ||
      warn "Target pacman cache cleanup failed"
  fi

  cleanup_temporary_files --host ||
    warn "Temporary-file cleanup failed"

  if [[ "$root" != "/" ]]; then
    cleanup_temporary_files --root "$root" ||
      warn "Target temporary-file cleanup failed"
  fi

  cleanup_partial_downloads "$root" ||
    warn "Partial download cleanup failed"

  cleanup_diagnostics "$root" ||
    warn "Diagnostics cleanup failed"

  # --- repatch + image-finalize ---

  if [[ "$policy" == "repatch" || "$policy" == "image-finalize" ]]; then
    cleanup_build_artifacts "$root" ||
      warn "Build artifact cleanup failed"

    cleanup_dkms_scratch "$root" ||
      warn "DKMS scratch cleanup failed"
  fi

  # --- image-finalize only ---

  if [[ "$policy" == "image-finalize" ]]; then
    cleanup_image_finalize "$root" ||
      warn "Image finalization cleanup failed"
  fi

  after_kb="$(df -Pk "$root" | awk 'NR == 2 { print $4 }')"
  freed_kb=$((after_kb - before_kb))
  ((freed_kb < 0)) && freed_kb=0

  log "Cleanup complete — freed $((freed_kb / 1024)) MiB; $((after_kb / 1024)) MiB available on target filesystem"
}

# ---------------------------------------------------------------------------
# User Password
# ---------------------------------------------------------------------------
# Set user password (interactive).

set_user_password() {
  if passwd -S deck 2>/dev/null | grep -q "P"; then
    log "User 'deck' already has a password set"
    return 0
  fi
  log "Setting user password"
  echo ""
  echo "Enter a new password for the 'deck' user:"
  passwd deck
}
