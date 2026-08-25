#!/bin/bash
#
# steamos-nvidia-installer — lib/overlay.sh
# Overlay chroot management: create, mount, configure, unmount.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/overlay.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Globals set by overlay_mount() / overlay_mount_with_image()
UPPER=""
OVLWORK=""
MERGED=""

# Create and mount an overlay chroot.
# Args: $1 = lowerdir (base rootfs)
#       $2 = workdir (parent for upper/ovlwork)
#       $3 = merged (mount point)
# Sets: UPPER, OVLWORK, MERGED globals
#
# The caller is responsible for ensuring that a persistent upper layer belongs
# to this lower tree.  overlay_mount_with_image() does that with a cache key.
overlay_mount() {
  local lowerdir="${1:?overlay_mount: missing lowerdir}"
  local workdir="${2:?overlay_mount: missing workdir}"
  local merged="${3:?overlay_mount: missing merged}"

  UPPER="$workdir/upper"
  OVLWORK="$workdir/ovlwork"
  MERGED="$merged"

  mkdir -p "$UPPER" "$OVLWORK" "$MERGED"
  mkdir -p "$MERGED/proc" "$MERGED/sys" "$MERGED/dev" "$MERGED/tmp"

  if mountpoint -q "$MERGED" 2>/dev/null; then
    die "Overlay merge point is already mounted: $MERGED"
  fi

  # workdir is scratch state, not cache state.  After an interrupted/lazy
  # unmount it can contain OverlayFS-internal residue that prevents a clean
  # remount.  It is safe to empty while the overlay is not mounted.
  find "$OVLWORK" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true

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

  mount -t overlay overlay -o "$overlay_opts" "$MERGED"
  mount --make-rprivate "$MERGED"

  # Mount virtual filesystems for chroot operations.
  mount -t proc proc "$MERGED/proc"
  mount --rbind /sys "$MERGED/sys"
  mount --make-rslave "$MERGED/sys"

  # /dev: non-recursive bind to avoid cloning /dev/shm/nvidia-build mounts.
  mount --bind /dev "$MERGED/dev"
  mount --make-private "$MERGED/dev"

  # Pseudoterminals.
  mkdir -p "$MERGED/dev/pts"
  mount --bind /dev/pts "$MERGED/dev/pts"
  mount --make-private "$MERGED/dev/pts"

  # Private shared-memory filesystem — pacman/GnuPG use /dev/shm,
  # but the chroot must NOT see /dev/shm/nvidia-build (our build mounts).
  mkdir -p "$MERGED/dev/shm"
  mount -t tmpfs tmpfs "$MERGED/dev/shm" -o mode=1777,nosuid,nodev

  # Bind-mount host /tmp into the chroot — the overlay mount path doesn't
  # match inside the chroot (host sees /path/to/merged, chroot sees /), so
  # pacman can't resolve mount points for its cachedir space check.
  mount --bind /tmp "$MERGED/tmp"
  mount --make-private "$MERGED/tmp"

  # Set up chroot essentials.
  rm -f "$MERGED/etc/resolv.conf"
  cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"
  ln -sf /proc/self/mounts "$MERGED/etc/mtab"

  # Diagnostic: log the chroot /dev mount tree.
  log "Chroot /dev mount tree:"
  findmnt -R "$MERGED/dev" -o TARGET,SOURCE,FSTYPE,PROPAGATION >&2 2>/dev/null || true

  # Sanity check: verify no build mounts leaked into chroot /dev.
  if findmnt -R "$MERGED/dev" -n -o TARGET 2>/dev/null \
    | grep -Fq "$MERGED/dev/shm/nvidia-build/"; then
    warn "Build workspace mount tree leaked into chroot /dev:"
    findmnt -R "$MERGED/dev" -o TARGET,SOURCE,FSTYPE,PROPAGATION >&2 2>/dev/null || true
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
  # overlay_mount_with_image() validates this key BEFORE mounting OverlayFS.
  local source_fp="unknown"
  local root_uuid="unknown"
  local cache_key

  if [[ -n "${FINGERPRINT_FILE:-}" && -f "$FINGERPRINT_FILE" ]]; then
    IFS= read -r source_fp <"$FINGERPRINT_FILE" || source_fp="unknown"
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

  overlay_mount_with_image "$MNT" "$WORKDIR" "$MERGED" "8G" "$cache_key"

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
overlay_check_cache() {
  local expected_key="${1:?overlay_check_cache: missing cache key}"
  local cache_root="${OVL_MNT:-}"
  local marker current_key=""

  [[ -n "$cache_root" && -d "$cache_root" ]] \
    || die "overlay_check_cache called before overlay workspace was mounted"
  [[ -n "${UPPER:-}" && -n "${OVLWORK:-}" ]] \
    || die "overlay_check_cache called before upper/work paths were initialized"

  marker="$cache_root/.steamos-nvidia-overlay-cache-key"

  if [[ -f "$marker" ]]; then
    IFS= read -r current_key <"$marker" || current_key=""
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
  rm -rf "${UPPER:?}" "${OVLWORK:?}"
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
overlay_mount_with_image() {
  local lowerdir="${1:?overlay_mount_with_image: missing lowerdir}"
  local workdir="${2:?overlay_mount_with_image: missing workdir}"
  local merged="${3:?overlay_mount_with_image: missing merged}"
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
      warn "overlay_mount_with_image: overlay-work.img still has loop device(s): $_existing_loops"
      warn "Attempting to detach stale loops before proceeding"
      while IFS= read -r _stale; do
        [[ -n "$_stale" ]] || continue
        findmnt -rn -o TARGET,SOURCE 2>/dev/null \
          | awk -v l="$_stale" '$2 ~ "^"l {print $1}' \
          | tac | while read -r _m; do
          [[ -n "$_m" ]] || continue
          umount -R "$_m" \
            || die "Could not cleanly unmount stale overlay workspace: $_m"
        done
        losetup -d "$_stale" 2>/dev/null || true
      done <<<"$_existing_loops"
      udevadm settle --timeout=5 2>/dev/null || true
      _existing_loops="$(losetup -j "$OVL_IMG" 2>/dev/null | cut -d: -f1)"
      if [[ -n "$_existing_loops" ]]; then
        die "overlay_mount_with_image: could not detach stale loops for overlay-work.img: $_existing_loops"
      fi
    fi
  else
    log "Creating overlay workspace image ($img_size)"
    truncate -s "$img_size" "$OVL_IMG"
    mkfs.ext4 -q -F "$OVL_IMG"
  fi

  # Allocate the loop device with --nooverlap to prevent creating a second
  # loop on a backing file that already has one.
  OVL_LOOPDEV="$(losetup --find --show --nooverlap "$OVL_IMG")" \
    || die "Could not allocate loop device for overlay workspace"
  mount "$OVL_LOOPDEV" "$OVL_MNT" \
    || die "Could not mount overlay workspace image"
  mount --make-private "$OVL_MNT"

  # Set these before validation so overlay_check_cache can inspect/clear them.
  UPPER="$OVL_MNT/upper"
  OVLWORK="$OVL_MNT/ovlwork"
  mkdir -p "$UPPER" "$OVLWORK"

  if [[ -n "$cache_key" ]]; then
    overlay_check_cache "$cache_key"
  else
    # Even without persistent caching, workdir is scratch and must not carry
    # residue from a previous mount.
    find "$OVLWORK" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
  fi

  overlay_mount "$lowerdir" "$OVL_MNT" "$merged"
}

# Run a command inside the overlay chroot ($MERGED).
in_chroot() { chroot "$MERGED" /bin/bash -c "$*"; }

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

  # overlay_mount_with_image() supplies OVL_MNT.
  # Direct overlay_mount() callers such as repatch store upper/work directly
  # beneath the supplied work directory, so derive that directory from UPPER.
  if [[ -z "$overlay_storage" ]]; then
    overlay_storage="$(dirname "${UPPER:?setup_pacman_conf: UPPER is not set}")"
  fi

  mkdir -p "$overlay_storage/pkg-cache" "$MERGED/tmp/pkgcache"

  if ! mountpoint -q "$MERGED/tmp/pkgcache" 2>/dev/null; then
    mount --bind "$overlay_storage/pkg-cache" "$MERGED/tmp/pkgcache" \
      || die "Failed to bind-mount persistent pacman cache"
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
  ensure_unmounted "$lower" "stale effective /etc lower bind"
  ensure_unmounted "$varmnt" "stale effective /etc var mount"

  # The upper/work paths do not exist in the host-side mountpoint until VARPART
  # is mounted here.  Mount var first, then inspect the real SteamOS overlay.
  log "  Mounting $VARPART to expose the runtime /etc upper/work"
  mount -o rw "$VARPART" "$varmnt" \
    || die "Failed to mount var for effective /etc"

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
  if ! mount --bind "$root/etc" "$lower"; then
    strict_unmount "$varmnt" "var after failed lower /etc bind" || true
    die "Failed to bind lower /etc"
  fi

  log "  Mounting effective /etc overlay"
  if ! mount -t overlay overlay \
    -o "lowerdir=$lower,upperdir=$upper,workdir=$work" \
    "$root/etc"; then
    strict_unmount "$lower" "lower /etc bind after failed effective overlay mount" || true
    strict_unmount "$varmnt" "var after failed effective /etc overlay mount" || true
    die "Failed to mount effective /etc overlay"
  fi

  _EFFECTIVE_ETC_MOUNTED=1
  log "  Effective /etc overlay mounted on $root/etc"
  findmnt -T "$root/etc" -o TARGET,SOURCE,FSTYPE,OPTIONS >&2 || true
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
    rm -rf "$root/var/lib/overlays" \
      || die "Failed to remove stale overlay state from $root"
  else
    log "  No hidden rootfs overlay state found in $root"
  fi
}

# Clean up stale state from interrupted previous runs: unmount anything backed
# by our output image, detach loop devices, and remove leftover data that
# wastes disk space.  Idempotent — safe to call every run.
setup_clear_stale_state() {
  log "Checking for stale build state"

  # Give overlay_cleanup the canonical paths even though this is running
  # before overlay_mount_with_image().
  OVL_IMG="$WORKDIR/overlay-work.img"
  OVL_MNT="$WORKDIR/overlay-mnt"
  # shellcheck disable=SC2034
  OVL_LOOPDEV=""

  # ============================================================
  # 1. Overlay/chroot FIRST.
  #
  # MERGED references:
  #   - MNT as lowerdir
  #   - OVL_MNT as upper/work storage
  #
  # Therefore neither of those may be torn down first.
  # ============================================================
  if ! overlay_cleanup; then
    die "Could not safely clean stale overlay state. Refusing to touch its backing filesystems."
  fi

  if [[ -n "${MERGED:-}" ]] && mountpoint -q "$MERGED" 2>/dev/null; then
    die "Stale OverlayFS remains mounted at $MERGED"
  fi

  if mountpoint -q "$OVL_MNT" 2>/dev/null; then
    die "Stale overlay workspace remains mounted at $OVL_MNT"
  fi

  local remaining_overlay_loops
  remaining_overlay_loops="$(loops_for_file "$OVL_IMG")"

  if [[ -n "$remaining_overlay_loops" ]]; then
    warn "Overlay workspace still has loop attachments:"
    while IFS= read -r dev; do
      [[ -n "$dev" ]] && warn "  $dev"
    done <<<"$remaining_overlay_loops"

    die "Could not safely recover the previous overlay workspace; reboot may be required"
  fi

  # ============================================================
  # 1b. Effective /etc overlay used by the build chroot.
  #
  # Never construct /etc from an empty MNT: that could target the host's /etc.
  # Teardown order is overlay -> lower bind -> var backing mount.
  # ============================================================
  local _etc_lower="$WORKDIR/effective-etc-lower"
  local _etc_var="$WORKDIR/effective-etc-var"

  if [[ -n "${MNT:-}" ]]; then
    local _etc_merged="$MNT/etc"
    if mountpoint -q "$_etc_merged" 2>/dev/null; then
      warn "Cleaning stale effective /etc overlay at $_etc_merged"
      ensure_unmounted "$_etc_merged" "stale effective /etc overlay"
    fi
  fi

  ensure_unmounted "$_etc_lower" "stale effective /etc lower bind"
  ensure_unmounted "$_etc_var" "stale effective /etc var mount"

  rmdir "$_etc_lower" "$_etc_var" 2>/dev/null || true
  _EFFECTIVE_ETC_MOUNTED=0

  # ============================================================
  # 1c. Rootfs reconstruction / snapshot temporary mounts.
  #
  # etc-merged is itself an OverlayFS and must be removed before either of its
  # lower/upper backing mounts.  Everything here must be gone before the main
  # image loop device is detached.
  # ============================================================
  local _tmp_etc_merged="$WORKDIR/etc-merged"
  local _tmp_mount

  if mountpoint -q "$_tmp_etc_merged" 2>/dev/null; then
    warn "Cleaning stale rootfs /etc reconstruction overlay at $_tmp_etc_merged"
    ensure_unmounted "$_tmp_etc_merged" "stale rootfs /etc reconstruction overlay"
  fi

  for _tmp_mount in \
    "$WORKDIR/etc-new-root" \
    "$WORKDIR/etc-var-mnt" \
    "$WORKDIR/rootfs-ro-source" \
    "$WORKDIR/rootfs-native-rw" \
    "$WORKDIR/rootfs-resize" \
    "$WORKDIR/rootfs-grow" \
    "$WORKDIR/rootfs-post-rebuild-diag" \
    "$WORKDIR/ovl-clean-mnt"; do
    if mountpoint -q "$_tmp_mount" 2>/dev/null; then
      warn "Cleaning stale rootfs helper mount: $_tmp_mount"
      ensure_unmounted "$_tmp_mount" "stale rootfs helper mount"
    fi
  done

  # mount -o loop may have left an explicit loop attachment for the temporary
  # reconstructed filesystem if a prior run died before unmount.
  local _root_tmp="$WORKDIR/rootfs-writable.img"
  local _root_tmp_loops
  _root_tmp_loops="$(loops_for_file "$_root_tmp")"
  if [[ -n "$_root_tmp_loops" ]]; then
    warn "Cleaning stale temporary rootfs loop attachments"
    while IFS= read -r dev; do
      [[ -n "$dev" ]] || continue
      warn "  $dev"
      strict_detach_loop "$dev" \
        || die "Could not safely detach temporary rootfs loop $dev"
    done <<<"$_root_tmp_loops"
  fi

  # ============================================================
  # 2. Main image partitions SECOND.
  # ============================================================
  local dev m
  local image_loops

  image_loops="$(loops_for_file "$OUT")"

  while IFS= read -r dev; do
    [[ -n "$dev" ]] || continue

    warn "Cleaning stale image loop: $dev"

    while IFS= read -r m; do
      [[ -n "$m" ]] || continue

      if ! strict_unmount "$m" "stale image filesystem"; then
        die "Could not safely unmount $m from $dev"
      fi
    done < <(mounts_for_loop "$dev")

    if ! strict_detach_loop "$dev"; then
      die "Could not safely detach stale image loop $dev"
    fi
  done <<<"$image_loops"

  image_loops="$(loops_for_file "$OUT")"
  if [[ -n "$image_loops" ]]; then
    die "Stale loop device still references $OUT; refusing to delete the backing image"
  fi

  # ============================================================
  # 3. Explicit project mountpoints.
  # ============================================================
  for m in "$HOMEMNT" "$EFIMNT" "$MNT"; do
    [[ -n "$m" ]] || continue

    if mountpoint -q "$m" 2>/dev/null; then
      warn "Unexpected stale project mount: $m"
      ensure_unmounted "$m" "project filesystem"
    fi
  done

  # ============================================================
  # 4. NOW it is safe to delete an incomplete working image.
  # ============================================================
  if [[ -f "$OUT" && ! -f "${OUT}.src-fingerprint" ]]; then
    warn "Removing incomplete output from previous failed run"
    rm -f "$OUT"
  fi

  if [[ ! -f "$OUT" && -f "${OUT}.src-fingerprint" ]]; then
    rm -f "${OUT}.src-fingerprint"
  fi

  # ============================================================
  # 5. Remove host-side scratch residue only after proving it is unmounted.
  # ============================================================
  for m in "$MERGED" "$UPPER" "$OVLWORK"; do
    [[ -n "$m" && -e "$m" ]] || continue

    if mountpoint -q "$m" 2>/dev/null; then
      die "Refusing to remove mounted stale directory: $m"
    fi

    rm -rf "$m"
  done

  log "Stale build state is clean"
}

# Initialize pacman keyring in the overlay chroot.
# Call after setup_pacman_conf() and overlay_mount().
# Args: $1 = (optional) space-separated extra keyrings to populate
overlay_init_keyring() {
  local extra_keyrings="${1:-}"

  rm -rf "$MERGED/etc/pacman.d/gnupg"
  in_chroot "pacman-key --init" || die "pacman-key --init failed"

  if [[ -n "$extra_keyrings" ]]; then
    in_chroot "pacman-key --populate $extra_keyrings" || die "pacman-key --populate failed"
  else
    in_chroot "pacman-key --populate" || die "pacman-key --populate failed"
  fi

  # Diagnostic: log keyring state after bootstrap
  if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
    log "Keyring bootstrap diagnostics:"
    in_chroot "pacman -Q archlinux-keyring 2>/dev/null || echo 'archlinux-keyring: NOT INSTALLED'" || true
    in_chroot "pacman-key --list-keys 2>/dev/null | head -20" || true
  fi
}

# Tear down the overlay hierarchy.
#
# Required order:
#
#   chroot bind mounts
#        ↓
#   MERGED OverlayFS
#        ↓
#   OVL_MNT ext4 filesystem
#        ↓
#   ext4 superblock disappears
#        ↓
#   overlay loop device
#
# Never lazy-unmount MERGED or OVL_MNT. A lazy unmount can hide the mount from
# userspace while leaving the ext4 filesystem referenced in the kernel.
overlay_cleanup() {
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  local rc=0
  local m
  local loops=""

  # Allow this to work during startup recovery before overlay_mount_with_image()
  # has populated these globals.
  : "${OVL_IMG:=${WORKDIR:+$WORKDIR/overlay-work.img}}"
  : "${OVL_MNT:=${WORKDIR:+$WORKDIR/overlay-mnt}}"

  # ------------------------------------------------------------
  # 1. Kill known chroot daemons before touching mount topology.
  # ------------------------------------------------------------
  if [[ -n "${MERGED:-}" &&
    -d "$MERGED/etc/pacman.d/gnupg" ]]; then
    gpgconf \
      --homedir "$MERGED/etc/pacman.d/gnupg" \
      --kill gpg-agent \
      >/dev/null 2>&1 || true
  fi

  # ------------------------------------------------------------
  # 2. Remove mounts INSIDE the OverlayFS.
  #
  # /dev children (pts, shm) must be unmounted before /dev itself.
  # ------------------------------------------------------------
  if [[ -n "${MERGED:-}" ]]; then
    for m in \
      "$MERGED/tmp/pkgcache" \
      "$MERGED/dev/pts" \
      "$MERGED/dev/shm" \
      "$MERGED/dev" \
      "$MERGED/sys" \
      "$MERGED/proc" \
      "$MERGED/tmp"; do
      [[ -e "$m" ]] || continue

      if mountpoint -q "$m" 2>/dev/null; then
        if ! strict_unmount "$m" "chroot child"; then
          rc=1
        fi
      fi
    done
  fi

  if ((rc != 0)); then
    warn "overlay_cleanup: chroot child mounts remain; refusing to tear down OverlayFS"
    [[ "$_had_e" -eq 1 ]] && set -e
    return 1
  fi

  # ------------------------------------------------------------
  # 3. Remove MERGED itself.
  # ------------------------------------------------------------
  if [[ -n "${MERGED:-}" ]] \
    && mountpoint -q "$MERGED" 2>/dev/null; then
    echo "=== PRE-MERGED-UNMOUNT ==="
    findmnt -R "$MERGED" 2>/dev/null || true
    fuser -vm "$MERGED" 2>/dev/null || true
    grep -F "$MERGED" /proc/self/mountinfo 2>/dev/null || true
    if [[ -n "${OVL_LOOPDEV:-}" ]]; then
      findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true
      [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
        && echo "${OVL_LOOPDEV##/dev/} ext4 still alive before MERGED unmount"
    fi

    echo "=== UNMOUNT MERGED ==="
    local umount_merged_rc=0
    umount -v "$MERGED" 2>&1 || umount_merged_rc=$?
    echo "umount MERGED rc=$umount_merged_rc"

    echo "=== AFTER MERGED ==="
    findmnt -R "$MERGED" 2>/dev/null || true
    if [[ -n "${OVL_LOOPDEV:-}" ]]; then
      findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true
      [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
        && echo "${OVL_LOOPDEV##/dev/} ext4 still alive after MERGED unmount"
    fi

    if ((umount_merged_rc != 0)); then
      warn "overlay_cleanup: refusing to unmount overlay workspace while MERGED exists"
      [[ "$_had_e" -eq 1 ]] && set -e
      return 1
    fi
  fi

  # Explicit invariant.
  if [[ -n "${MERGED:-}" ]] \
    && mountpoint -q "$MERGED" 2>/dev/null; then
    warn "overlay_cleanup: MERGED is unexpectedly still mounted"
    [[ "$_had_e" -eq 1 ]] && set -e
    return 1
  fi

  # ------------------------------------------------------------
  # 4. Now — and only now — unmount the ext4 overlay workspace.
  # ------------------------------------------------------------
  if [[ -n "${OVL_MNT:-}" ]] \
    && mountpoint -q "$OVL_MNT" 2>/dev/null; then
    echo "=== PRE-OVL_MNT-UNMOUNT ==="
    findmnt -R "$OVL_MNT" 2>/dev/null || true
    fuser -vm "$OVL_MNT" 2>/dev/null || true
    grep -F "$OVL_MNT" /proc/self/mountinfo 2>/dev/null || true
    if [[ -n "${OVL_LOOPDEV:-}" ]]; then
      findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true
      [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
        && echo "${OVL_LOOPDEV##/dev/} ext4 still alive before OVL_MNT unmount"
    fi

    echo "=== UNMOUNT OVL_MNT ==="
    local umount_ovl_rc=0
    umount -v "$OVL_MNT" 2>&1 || umount_ovl_rc=$?
    echo "umount OVL_MNT rc=$umount_ovl_rc"

    echo "=== AFTER OVL_MNT ==="
    findmnt -R "$OVL_MNT" 2>/dev/null || true
    if [[ -n "${OVL_LOOPDEV:-}" ]]; then
      findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true
      [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
        && echo "${OVL_LOOPDEV##/dev/} ext4 still alive after OVL_MNT unmount"
    fi

    if ((umount_ovl_rc != 0)); then
      warn "overlay_cleanup: overlay workspace could not be cleanly unmounted"
      [[ "$_had_e" -eq 1 ]] && set -e
      return 1
    fi
  fi

  # ------------------------------------------------------------
  # 5. Find every loop associated with overlay-work.img.
  # ------------------------------------------------------------
  if [[ -n "${OVL_IMG:-}" ]]; then
    loops="$(loops_for_file "$OVL_IMG")"
  fi

  # Include the loop we explicitly allocated even if losetup's backing-file
  # presentation is unusual.
  if [[ -n "${OVL_LOOPDEV:-}" ]] \
    && losetup "$OVL_LOOPDEV" >/dev/null 2>&1 \
    && ! grep -qxF "$OVL_LOOPDEV" <<<"$loops"; then
    loops="${loops:+$loops$'\n'}$OVL_LOOPDEV"
  fi

  # ------------------------------------------------------------
  # 6. The ext4 filesystem must be completely gone BEFORE detach.
  # ------------------------------------------------------------
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue

    if ! wait_ext4_gone "$m"; then
      warn "overlay_cleanup: $m still owns a live ext4 superblock"
      warn "overlay_cleanup: refusing losetup -d; reboot may be required"
      [[ "$_had_e" -eq 1 ]] && set -e
      return 1
    fi
  done <<<"$loops"

  # ------------------------------------------------------------
  # 7. Detach loops and verify.
  # ------------------------------------------------------------
  while IFS= read -r m; do
    [[ -n "$m" ]] || continue

    if ! strict_detach_loop "$m"; then
      rc=1
    fi
  done <<<"$loops"

  if [[ -n "${OVL_IMG:-}" ]]; then
    local remaining
    remaining="$(loops_for_file "$OVL_IMG")"

    if [[ -n "$remaining" ]]; then
      warn "overlay_cleanup: loop device(s) still attached to $OVL_IMG:"
      while IFS= read -r m; do
        [[ -n "$m" ]] && warn "  $m"
      done <<<"$remaining"
      rc=1
    fi
  fi

  if ((rc == 0)); then
    OVL_LOOPDEV=""
  fi

  [[ "$_had_e" -eq 1 ]] && set -e
  return "$rc"
}
