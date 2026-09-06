#!/bin/bash
#
# steamos-build-installer — lib/common_system.sh
# System helpers: chroot filesystem mounting, depmod, ldconfig, nvidia services.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common_system.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

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
    journalctl --vacuum-size=50M 2>/dev/null \
      || warn "Journal cleanup failed"
  else
    journalctl --root="$root" --vacuum-size=50M 2>/dev/null \
      || warn "Target journal cleanup failed"
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

  local module kernel arch ko_dir arch_dir
  while IFS= read -r -d '' arch_dir; do
    # DKMS layout: /var/lib/dkms/<module>/<kernel-version>/<arch>/
    # arch_dir is the <arch> directory (depth 3 from dkms_dir)
    kernel="$(basename "$(dirname "$arch_dir")")"
    module="$(basename "$(dirname "$(dirname "$arch_dir")")")"
    arch="$(basename "$arch_dir")"

    [[ -n "$module" && -n "$kernel" && -n "$arch" ]] || continue

    # Verify installed .ko exists before cleaning scratch
    ko_dir="$root/usr/lib/modules/$kernel"
    if [[ -d "$ko_dir" ]] && find "$ko_dir" -name "${module//-/_}.ko*" -print -quit | grep -q .; then
      rm -rf -- "$arch_dir/module" 2>/dev/null || true
      rm -rf -- "$arch_dir/log" 2>/dev/null || true
    fi
  done < <(find "$dkms_dir" -mindepth 3 -maxdepth 3 -type d -print0 2>/dev/null)
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
    live | repatch | image-finalize) ;;
    *)
      warn "cleanup_disk_space: unknown policy '$policy' (use live, repatch, or image-finalize)"
      return 1
      ;;
  esac

  log "Cleaning disk space under $root (policy: $policy)"

  before_kb="$(df -Pk "$root" | awk 'NR == 2 { print $4 }')"

  # --- All policies ---

  if [[ "$root" == "/" ]]; then
    pacman_clean_cache --host \
      || warn "Pacman cache cleanup failed"
  else
    pacman_clean_cache --chroot "$root" \
      || warn "Target pacman cache cleanup failed"
  fi

  cleanup_temporary_files --host \
    || warn "Temporary-file cleanup failed"

  if [[ "$root" != "/" ]]; then
    cleanup_temporary_files --root "$root" \
      || warn "Target temporary-file cleanup failed"
  fi

  cleanup_partial_downloads "$root" \
    || warn "Partial download cleanup failed"

  cleanup_diagnostics "$root" \
    || warn "Diagnostics cleanup failed"

  # --- repatch + image-finalize ---

  if [[ "$policy" == "repatch" || "$policy" == "image-finalize" ]]; then
    cleanup_build_artifacts "$root" \
      || warn "Build artifact cleanup failed"

    cleanup_dkms_scratch "$root" \
      || warn "DKMS scratch cleanup failed"
  fi

  # --- image-finalize only ---

  if [[ "$policy" == "image-finalize" ]]; then
    cleanup_image_finalize "$root" \
      || warn "Image finalization cleanup failed"
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
  local passwd_status
  if ! passwd_status=$(passwd -S deck 2>/dev/null); then
    log "Warning: could not query password status for 'deck'"
  elif echo "$passwd_status" | awk '$2 == "P" { exit 0 } { exit 1 }'; then
    log "User 'deck' already has a password set"
    return 0
  fi
  log "Setting user password"
  echo ""
  echo "Enter a new password for the 'deck' user:"
  passwd deck
}
