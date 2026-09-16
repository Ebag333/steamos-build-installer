#!/bin/bash
#
# steamos-build-installer — lib/overlay.sh
# Overlay chroot management: create, mount, configure, unmount.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/overlay.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Globals set by overlay_mount() / _overlay_mount_with_image().
# Use := to only set if unset, so a caller that pre-populates these (e.g.
# setup_clear_stale_state) is not clobbered when the library is sourced.
: "${UPPER:=}"
: "${OVLWORK:=}"
: "${MERGED:=}"

# Create and mount an overlay chroot.
# Args: $1 = lowerdir (base rootfs)
#       $2 = workdir (parent for upper/ovlwork)
#       $3 = merged (mount point)
# Sets: UPPER, OVLWORK, MERGED globals
#
# The caller is responsible for ensuring that a persistent upper layer belongs
# to this lower tree.  _overlay_mount_with_image() does that with a cache key.
overlay_mount() {
  local lowerdir="${1:?overlay_mount: missing lowerdir}"
  local workdir="${2:?overlay_mount: missing workdir}"
  local merged="${3:?overlay_mount: missing merged}"

  UPPER="$workdir/upper"
  OVLWORK="$workdir/ovlwork"
  MERGED="$merged"

  mkdir -p "$UPPER" "$OVLWORK" "$MERGED"

  if mountpoint -q "$MERGED" 2>/dev/null; then
    die "Overlay merge point is already mounted: $MERGED"
  fi

  # workdir is scratch state, not cache state.  After an interrupted/lazy
  # unmount it can contain OverlayFS-internal residue that prevents a clean
  # remount.  It is safe to empty while the overlay is not mounted.
  local _ovl_scratch
  for _ovl_scratch in "$OVLWORK"/*; do
    [[ -e "$_ovl_scratch" ]] || continue
    safe_rmdir "$_ovl_scratch" 2>/dev/null || true
  done

  # OverlayFS requires upperdir and workdir to live on the same filesystem.
  local upper_dev work_dev
  upper_dev="$(stat -c '%d' "$UPPER")"
  work_dev="$(stat -c '%d' "$OVLWORK")"
  [[ "$upper_dev" == "$work_dev" ]] \
    || die "Overlay upperdir and workdir are on different filesystems"

  log "Mounting overlay: lowerdir=$lowerdir upperdir=$UPPER workdir=$OVLWORK merged=$MERGED"

  # This build overlay is intentionally reusable across reconstruction of an
  # otherwise-identical lower tree.  Explicitly disable OverlayFS features
  # that persist lower file handles/origins or otherwise make offline lower
  # changes unsafe.  Do not rely on host kernel/module defaults.
  local overlay_opts
  overlay_opts="index=off,metacopy=off,redirect_dir=nofollow,xino=off,nfs_export=off"
  overlay_opts+=",lowerdir=$lowerdir,upperdir=$UPPER,workdir=$OVLWORK"

  cleanup_mount "$MERGED" "overlay merge" -- -t overlay overlay -o "$overlay_opts"
  mount --make-rprivate "$MERGED" \
    || die "Failed to make overlay mount rprivate: $MERGED"

  # Create mount points INSIDE the overlay so they exist in the merged view.
  mkdir -p "$MERGED/proc" "$MERGED/sys" "$MERGED/dev" "$MERGED/tmp"

  # Mount virtual filesystems for chroot operations.
  cleanup_mount "$MERGED/proc" "chroot proc" -- -t proc proc
  cleanup_mount_readonly_sysfs "$MERGED/sys" "chroot sys" \
    || die "Failed to mount sysfs in chroot"
  log "overlay: sysfs mounted read-only in chroot ($MERGED/sys)"

  # /dev: recursive bind; --make-rslave keeps submounts (pts, shm) in sync.
  cleanup_mount "$MERGED/dev" "chroot dev" -- --rbind /dev
  mount --make-rslave "$MERGED/dev" \
    || die "Failed to set /dev propagation to rslave in chroot"

  # Private shared-memory filesystem — remove inherited bind from rbind, then mount fresh tmpfs
  mkdir -p "$MERGED/dev/shm"
  if mountpoint -q "$MERGED/dev/shm" 2>/dev/null; then
    strict_unmount "$MERGED/dev/shm" "inherited chroot dev/shm" 2>/dev/null || {
      warn "Failed to remove inherited /dev/shm — attempting to continue"
    }
  fi
  cleanup_mount "$MERGED/dev/shm" "chroot dev/shm" -- -t tmpfs tmpfs -o mode=1777,nosuid,nodev

  # Bind-mount host /tmp into the chroot — the overlay mount path doesn't
  # match inside the chroot (host sees /path/to/merged, chroot sees /), so
  # pacman can't resolve mount points for its cachedir space check.
  cleanup_mount "$MERGED/tmp" "chroot tmp" -- --bind /tmp
  mount --make-private "$MERGED/tmp" \
    || die "Failed to make /tmp mount private: $MERGED/tmp"

  # Set up chroot essentials.
  rm -f "$MERGED/etc/resolv.conf"
  cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"
  ln -sf /proc/self/mounts "$MERGED/etc/mtab"

  # Diagnostic: log the chroot /dev mount tree.
  log_debug overlay dev-mount-tree "Chroot /dev mount tree:" mounts "$(findmnt -R "$MERGED/dev" -o TARGET,SOURCE,FSTYPE,PROPAGATION 2>/dev/null || true)" # lint-ignore: strict-mount

  # Sanity check: verify no build mounts leaked into chroot /dev.
  if findmnt -R "$MERGED/dev" -n -o TARGET 2>/dev/null \
    | grep -Fq "$MERGED/dev/shm/steamos-build/"; then
    warn "Build workspace mount tree leaked into chroot /dev:"
    log_debug overlay mount-leak-tree mounts "$(findmnt -R "$MERGED/dev" -o TARGET,SOURCE,FSTYPE,PROPAGATION 2>/dev/null || true)" # lint-ignore: strict-mount
    die "Build workspace mounts leaked into chroot /dev"
  fi

  log "Overlay mounted and ready"
}

# Build the driver in a throwaway overlay on top of the image rootfs, so the
# toolchain/headers never enter the image. The upper layer ($UPPER) is cached
# between runs to speed up reruns.
setup_overlay_chroot() {
  log "Setting up overlay build chroot (build residue stays out of the image)"

  # The overlay upper layer is persistent between runs, so it must only be
  # reused against the same source image/kernel/driver combination.  This is
  # especially important because prepare_writable_rootfs() may reconstruct the
  # Btrfs lower filesystem between runs even when its contents are identical.
  # _overlay_mount_with_image() validates this key BEFORE mounting OverlayFS.
  local source_fp="unknown"
  local root_uuid="unknown"
  local cache_key

  if [[ -n "${FINGERPRINT_FILE:-}" && -f "$FINGERPRINT_FILE" ]]; then
    IFS="" read -r source_fp <"$FINGERPRINT_FILE" || true
    [[ -n "$source_fp" ]] || source_fp="unknown"
  elif [[ -n "${_src_fp:-}" ]]; then
    source_fp="$_src_fp"
  fi

  if [[ -n "${ROOTPART:-}" && -b "$ROOTPART" ]]; then
    root_uuid="$(blkid -s UUID -o value "$ROOTPART" 2>/dev/null || true)"
    [[ -n "$root_uuid" ]] || root_uuid="unknown"
  fi

  printf -v cache_key \
    'source=%s|root_uuid=%s|kernel=%s|kernel_pkg=%s-%s' \
    "$source_fp" "$root_uuid" "$KVER" \
    "${KPKG_NAME:-unknown}" "${KPKG_VERREL:-unknown}"

  # shellcheck disable=SC2153  # WORKDIR is set in lib/backend.sh
  _overlay_mount_with_image "$MNT" "$WORKDIR" "$MERGED" "8G" "$cache_key"

  if [[ $SKIP_SIG -eq 0 ]]; then
    setup_pacman_conf "$MERGED/tmp/pacman-bld.conf" "Required DatabaseOptional"
  else
    warn "pacman signature verification DISABLED for the build"
    setup_pacman_conf "$MERGED/tmp/pacman-bld.conf" "Never"
  fi

  # --fix-keyring: force-initialise with standard Arch Linux keys.  Useful
  # when the frozen image keyring is too old or missing packager keys.
  if [[ $FIX_KEYRING -eq 1 ]]; then
    log "Force-initialising pacman keyring with Arch Linux keys"
    overlay_init_keyring "archlinux holo"
  elif [[ $SKIP_SIG -eq 0 ]]; then
    log "Initialising pacman keyring in chroot"
    overlay_init_keyring
  fi
}

# Validate/invalidate a persistent overlay cache BEFORE OverlayFS is mounted.
# Args: $1 = expected cache key (source image + kernel + driver identity)
#
# The marker lives at the root of the ext4 workspace, outside upperdir, so it
# survives clearing an incompatible upper layer.  Legacy caches without a key
# are cleared once because their lower-tree identity cannot be proven.
_overlay_check_cache() {
  local expected_key="${1:?_overlay_check_cache: missing cache key}"
  local cache_root="${OVL_MNT:-}"
  local marker current_key=""

  [[ -n "$cache_root" && -d "$cache_root" ]] \
    || die "_overlay_check_cache called before overlay workspace was mounted"
  [[ -n "${UPPER:-}" && -n "${OVLWORK:-}" ]] \
    || die "_overlay_check_cache called before upper/work paths were initialized"

  marker="$cache_root/.steamos-build-overlay-cache-key"

  if [[ -f "$marker" ]]; then
    IFS="" read -r current_key <"$marker" || true
    [[ -n "$current_key" ]] || current_key=""
  fi

  # Always start with a fresh upper layer.  The upper acts as a transaction
  # workspace, not a persistent cache — reusing it across builds causes stale
  # feature state (packages, modules, config files from prior options) to leak
  # into the new build.  Downloaded packages are preserved separately on the
  # ext4 workspace via a bind mount in setup_pacman_conf().
  if [[ -n "$current_key" ]]; then
    log "Previous build identity: $current_key"
  fi
  log "Starting fresh overlay upper for this build"
  safe_rmdir "${UPPER:?}"
  safe_rmdir "${OVLWORK:?}"
  mkdir -p "$UPPER" "$OVLWORK"

  printf '%s\n' "$expected_key" >"$marker"
}

# Create/mount an ext4 overlay workspace image and then mount OverlayFS.
# Use this when the host filesystem (e.g. casefold-enabled ext4) cannot safely
# be used as an OverlayFS upperdir.
# Args: $1 = lowerdir (base rootfs)
#       $2 = workdir (parent for image + mount point)
#       $3 = merged (OverlayFS mount point)
#       $4 = image size (default: 8G)
#       $5 = optional persistent-cache identity key
# Sets: OVL_IMG, OVL_MNT, OVL_LOOPDEV, UPPER, OVLWORK, MERGED globals
#
# Cache validation deliberately occurs after the ext4 workspace is mounted but
# BEFORE mount -t overlay.  Deleting/recreating upper/work beneath an already
# mounted overlay leaves the mount referring to different directory objects.
_overlay_mount_with_image() {
  local lowerdir="${1:?_overlay_mount_with_image: missing lowerdir}"
  local workdir="${2:?_overlay_mount_with_image: missing workdir}"
  local merged="${3:?_overlay_mount_with_image: missing merged}"
  local img_size="${4:-8G}"
  local cache_key="${5:-}"

  OVL_IMG="$workdir/overlay-work.img"
  OVL_MNT="$workdir/overlay-mnt"
  MERGED="$merged"

  mkdir -p "$OVL_MNT" "$MERGED"

  if mountpoint -q "$OVL_MNT" 2>/dev/null; then
    die "Overlay workspace is already mounted: $OVL_MNT"
  fi
  if mountpoint -q "$MERGED" 2>/dev/null; then
    die "Overlay merge point is already mounted: $MERGED"
  fi

  if [[ -f "$OVL_IMG" ]]; then
    log "Reusing existing overlay workspace image"
    # Refuse to create another loop on an image that still has attachments.
    # Multiple independent loops for the same backing file can cause corruption.
    local _existing_loops
    _existing_loops="$(losetup -j "$OVL_IMG" 2>/dev/null | cut -d: -f1)"
    if [[ -n "$_existing_loops" ]]; then
      die "_overlay_mount_with_image: overlay-work.img still has loop device(s): $_existing_loops — run cleanup_recover first"
    fi
  else
    log "Creating overlay workspace image ($img_size)"
    truncate -s "$img_size" "$OVL_IMG" \
      || die "Could not create overlay workspace image ($img_size)"
    mkfs.ext4 -q -F "$OVL_IMG" \
      || die "Could not format overlay workspace image"
  fi

  # Allocate the loop device with --nooverlap to prevent creating a second
  # loop on a backing file that already has one.
  OVL_LOOPDEV="$(losetup --find --show --nooverlap "$OVL_IMG")" \
    || die "Could not allocate loop device for overlay workspace"
  cleanup_track_loop "$OVL_LOOPDEV" "$OVL_IMG" "overlay workspace"
  cleanup_mount "$OVL_MNT" "overlay workspace" -- "$OVL_LOOPDEV"
  mount --make-private "$OVL_MNT" \
    || die "Failed to make overlay workspace mount private: $OVL_MNT"

  # Set these before validation so _overlay_check_cache can inspect/clear them.
  UPPER="$OVL_MNT/upper"
  OVLWORK="$OVL_MNT/ovlwork"
  mkdir -p "$UPPER" "$OVLWORK"

  if [[ -n "$cache_key" ]]; then
    _overlay_check_cache "$cache_key"
  else
    # Even without persistent caching, workdir is scratch and must not carry
    # residue from a previous mount.
    local _ovl_scratch
    for _ovl_scratch in "$OVLWORK"/*; do
      [[ -e "$_ovl_scratch" ]] || continue
      safe_rmdir "$_ovl_scratch" 2>/dev/null || true
    done
  fi

  overlay_mount "$lowerdir" "$OVL_MNT" "$merged"
}

# Run a command inside the overlay chroot ($MERGED).
in_chroot() { chroot "$MERGED" /bin/bash -c "$1"; }

# Create a custom pacman config for the overlay chroot.
# Sets PACCONF and PACOPTS globals.  Call after overlay_mount().
# Args: $1 = path to write config (e.g. "$MERGED/tmp/pacman-bld.conf")
#       $2 = optional SigLevel override (default: copy from image's pacman.conf)
setup_pacman_conf() {
  local conf_path="${1:?setup_pacman_conf: missing conf path}"
  local sig_level="${2:-}"

  # Persist downloaded packages on the ext4 workspace so they survive upper
  # layer clears between builds.  The bind mount puts the cache at /tmp/pkgcache
  # inside the chroot — the CacheDir in pacman.conf.
  local overlay_storage="${OVL_MNT:-}"

  # _overlay_mount_with_image() supplies OVL_MNT.
  # Direct overlay_mount() callers such as repatch store upper/work directly
  # beneath the supplied work directory, so derive that directory from UPPER.
  if [[ -z "$overlay_storage" ]]; then
    overlay_storage="$(dirname "${UPPER:?setup_pacman_conf: UPPER is not set}")"
  fi

  mkdir -p "$overlay_storage/pkg-cache" "$MERGED/tmp/pkgcache"

  if ! mountpoint -q "$MERGED/tmp/pkgcache" 2>/dev/null; then
    cleanup_mount "$MERGED/tmp/pkgcache" "pacman cache" -- --bind "$overlay_storage/pkg-cache"
  fi

  # SteamOS stores its pacman db at /usr/lib/holo/pacmandb/, not the default
  # /var/lib/pacman/.  Always read DBPath from the image's config so the
  # generated config inherits it.
  local dbpath arch
  dbpath="$(sed -n 's/^[[:space:]]*DBPath[[:space:]]*=//p' "$MERGED/etc/pacman.conf" 2>/dev/null | head -1 | tr -d ' ')"
  [[ -n "$dbpath" ]] || dbpath="/var/lib/pacman"
  arch="$(sed -n 's/^[[:space:]]*Architecture[[:space:]]*=//p' "$MERGED/etc/pacman.conf" 2>/dev/null | head -1 | tr -d ' ')"
  [[ -n "$arch" ]] || arch="auto"

  # pacman 7+ has download sandboxing that creates temp dirs pacman can't
  # resolve mount points for; disable it on 7+, skip on older.
  local sandbox_opt=""
  local pacman_major
  pacman_major="$(
    chroot "$MERGED" pacman --version 2>/dev/null \
      | sed -n 's/.*Pacman v\([0-9][0-9]*\).*/\1/p' | head -1
  )"
  if [[ "$pacman_major" =~ ^[0-9]+$ ]] && ((pacman_major >= 7)); then
    sandbox_opt="DisableSandbox"
  fi

  if [[ -n "$sig_level" ]]; then
    # Write a config with the requested SigLevel + the image's repo sections.
    {
      printf '[options]\nSigLevel = %s\nDBPath = %s\nArchitecture = %s\nCacheDir = /tmp/pkgcache\n' "$sig_level" "$dbpath" "$arch"
      [[ -n "$sandbox_opt" ]] && printf '%s\n' "$sandbox_opt"
      printf '\n'
      # Append repo sections from the image's config (skip [options]).
      sed -n '/^\[/,$p' "$MERGED/etc/pacman.conf" 2>/dev/null | sed '/^\[options\]/,/^$/d'
    } >"$conf_path"
  else
    # Copy the image's config and append our overrides
    cp "$MERGED/etc/pacman.conf" "$conf_path"
    {
      printf '\n[options]\nCacheDir = /tmp/pkgcache\n'
      [[ -n "$sandbox_opt" ]] && printf '%s\n' "$sandbox_opt"
    } >>"$conf_path"
  fi

  # shellcheck disable=SC2034
  PACCONF="/tmp/$(basename "$conf_path")"
  # shellcheck disable=SC2034
  PACOPTS="--noconfirm --needed"
}

# Mount the effective /etc overlay on $root/etc so that subsequent reads and
# edits see the same merged view SteamOS uses at runtime (lower rootfs /etc +
# upper from var partition).  The lower /etc is bind-mounted to a separate path
# first — OverlayFS requires lowerdir, upperdir, workdir, and the merged
# mountpoint to be distinct directories.
#
# Teardown order matters: unmount the overlay, then the lower bind, then var.
# If a die() fires between mount and unmount, setup_clear_stale_state() cleans
# up the stale mounts via the same WORKDIR-based paths.
#
# Args: $1 = root path (e.g. $MNT)
# Sets: _EFFECTIVE_ETC_MOUNTED=1 if overlay was mounted
mount_effective_etc() {
  local root="${1:?mount_effective_etc: missing root}"
  _EFFECTIVE_ETC_MOUNTED=0

  [[ -d "$root/etc" ]] \
    || die "Target root has no /etc directory: $root/etc"

  [[ -n "${VARPART:-}" && -b "$VARPART" ]] || {
    log "  No var partition; effective /etc overlay unavailable"
    return 0
  }

  local lower="$WORKDIR/effective-etc-lower"
  local varmnt="$WORKDIR/effective-etc-var"
  mkdir -p "$lower" "$varmnt"

  # These paths are project-owned.  Refuse to stack new mounts on stale state.
  if mountpoint -q "$root/etc" 2>/dev/null; then
    die "Refusing to mount effective /etc: $root/etc is already a mountpoint"
  fi
  strict_unmount "$lower" "stale effective /etc lower bind" \
    || die "Failed to unmount stale effective /etc lower bind: $lower"
  strict_unmount "$varmnt" "stale effective /etc var mount" \
    || die "Failed to unmount stale effective /etc var mount: $varmnt"

  # The upper/work paths do not exist in the host-side mountpoint until VARPART
  # is mounted here.  Mount var first, then inspect the real SteamOS overlay.
  log "  Mounting $VARPART to expose the runtime /etc upper/work"
  cleanup_mount "$varmnt" "effective etc var" -- -o rw "$VARPART"

  local ovl="$varmnt/lib/overlays/etc"
  local upper="$ovl/upper"
  local work="$ovl/work"

  if [[ ! -d "$upper" && ! -d "$work" ]]; then
    log "  No /etc overlay on var partition; using lower-only /etc"
    strict_unmount "$varmnt" "var after effective /etc overlay check" \
      || die "Failed to unmount var after effective /etc overlay check"
    return 0
  fi

  if [[ ! -d "$upper" || ! -d "$work" ]]; then
    local upper_state="missing" work_state="missing"
    [[ -d "$upper" ]] && upper_state="present"
    [[ -d "$work" ]] && work_state="present"
    strict_unmount "$varmnt" "var after incomplete effective /etc overlay check" \
      || die "Failed to unmount var after incomplete effective /etc overlay check"
    die "Incomplete SteamOS /etc overlay state (upper=$upper_state, work=$work_state)"
  fi

  log "  Binding lower /etc: $root/etc → $lower"
  if ! cleanup_mount "$lower" "effective etc lower bind" -- --bind "$root/etc" "$lower"; then
    strict_unmount "$varmnt" "var after failed lower /etc bind" || true
    die "Failed to bind lower /etc"
  fi

  log "  Mounting effective /etc overlay"
  if ! cleanup_mount "$root/etc" "effective etc overlay" -- -t overlay overlay \
    -o "lowerdir=$lower,upperdir=$upper,workdir=$work"; then
    strict_unmount "$lower" "lower /etc bind after failed effective overlay mount" || true
    strict_unmount "$varmnt" "var after failed effective /etc overlay mount" || true
    die "Failed to mount effective /etc overlay"
  fi

  _EFFECTIVE_ETC_MOUNTED=1
  log "  Effective /etc overlay mounted on $root/etc"
  log_debug overlay etc-overlay-mounted mounts "$(findmnt -T "$root/etc" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true)"
}

# Unmount the effective /etc overlay.  Safe to call unconditionally — no-ops if
# the overlay was never mounted.  Teardown order: overlay, lower bind, var.
# Args: $1 = root path
unmount_effective_etc() {
  local root="${1:?unmount_effective_etc: missing root}"

  [[ "${_EFFECTIVE_ETC_MOUNTED:-0}" == 1 ]] || return 0

  strict_unmount "$root/etc" "effective /etc overlay" \
    || die "Failed to unmount effective /etc overlay from $root/etc"

  strict_unmount "$WORKDIR/effective-etc-lower" "effective /etc lower bind" \
    || die "Failed to unmount lower /etc bind"

  strict_unmount "$WORKDIR/effective-etc-var" "effective /etc var mount" \
    || die "Failed to unmount var for effective /etc"

  rmdir "$WORKDIR/effective-etc-lower" \
    "$WORKDIR/effective-etc-var" 2>/dev/null || true

  _EFFECTIVE_ETC_MOUNTED=0
  log "  Effective /etc overlay unmounted cleanly"
}

# Remove stale overlayfs *state* from a rootfs tree.  Do not remove fstab or
# systemd mount definitions here: those are configuration, not cache/state.
#
# NOTE: SteamOS mounts a separate /var during boot.  The runtime /etc overlay
# upper/work directories therefore normally live on VARPART and are handled by
# snapshot_runtime_etc() / restore_runtime_etc().  This helper only removes any
# hidden copy that exists inside the rootfs itself.
# Args: $1 = root path (must be mounted rw)
clean_overlay_state() {
  local root="${1:?clean_overlay_state: missing root}"

  if [[ -d "$root/var/lib/overlays" ]]; then
    log "  Removing hidden rootfs overlay state: $root/var/lib/overlays"
    safe_rmdir "$root/var/lib/overlays" \
      || die "Failed to remove stale overlay state from $root"
  else
    log "  No hidden rootfs overlay state found in $root"
  fi
}

# Initialize pacman keyring in the overlay chroot.
# Call after setup_pacman_conf() and overlay_mount().
# Args: $1 = (optional) space-separated extra keyrings to populate
overlay_init_keyring() {
  local extra_keyrings="${1:-}"

  # Guard: MERGED must be set and point to a mounted chroot
  : "${MERGED:?overlay_init_keyring: MERGED is not set}"
  mountpoint -q "$MERGED" || die "overlay_init_keyring: MERGED ($MERGED) is not a mountpoint"

  safe_rmdir "$MERGED/etc/pacman.d/gnupg" 2>/dev/null || true
  # lint-ignore: silenced-stdout — stdout intentionally suppressed; stderr preserved for diagnostics
  in_chroot "pacman-key --init >/dev/null" || die "pacman-key --init failed"

  if [[ -n "$extra_keyrings" ]]; then
    # lint-ignore: silenced-stdout — stdout intentionally suppressed; stderr preserved for diagnostics
    in_chroot "pacman-key --populate $extra_keyrings >/dev/null" || die "pacman-key --populate failed"
  else
    # lint-ignore: silenced-stdout — stdout intentionally suppressed; stderr preserved for diagnostics
    in_chroot "pacman-key --populate >/dev/null" || die "pacman-key --populate failed"
  fi

  # Diagnostic: log keyring state after bootstrap
  if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
    log "Keyring bootstrap diagnostics:"
    in_chroot "pacman -Q archlinux-keyring 2>/dev/null || echo 'archlinux-keyring: NOT INSTALLED'" || true
    in_chroot "pacman-key --list-keys 2>/dev/null | head -20" || true
  fi
}
