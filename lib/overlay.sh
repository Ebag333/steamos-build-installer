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

# Clean up stale state from interrupted previous runs: unmount anything backed
# by our output image, detach loop devices, and remove leftover data that
# wastes disk space.  Idempotent — safe to call every run.
setup_clear_stale_state() {
  log "Checking for stale build state"

  # Clean up any mounts tracked by a previous (possibly killed) run.
  local _stale_rc=0
  if ! cleanup_unmount_registered; then
    warn "setup_clear_stale_state: tracked mount cleanup failed"
    _stale_rc=1
  fi

  # Give overlay_cleanup the canonical paths even though this is running
  # before _overlay_mount_with_image().
  OVL_IMG="$WORKDIR/overlay-work.img"
  OVL_MNT="$WORKDIR/overlay-mnt"
  # shellcheck disable=SC2034
  OVL_LOOPDEV=""

  # ============================================================
  # 0. Kill workspace-owned processes in old namespaces
  # ============================================================
  # Previous builds may have left gpg-agent processes alive in old mount
  # namespaces. These hold mounts and loops open that are invisible in our
  # namespace. We must identify, verify, and terminate them.
  # _stale_rc is used by namespace cleanup and effective /etc overlay
  # teardown below. It is initialized above and propagated through all
  # cleanup phases.

  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    log "Checking for workspace-owned processes in old namespaces"
    local _our_mnt_ns
    _our_mnt_ns="$(readlink /proc/self/ns/mnt 2>/dev/null)" || _our_mnt_ns=""

    # Find all processes whose root is inside our workspace
    local _stale_pids
    _stale_pids="$(pgrep -x gpg-agent 2>/dev/null || true)"
    # Also check for other known workspace processes
    _stale_pids+=" $(pgrep -x 'pacman' 2>/dev/null || true)"
    _stale_pids="$(echo "$_stale_pids" | tr ' ' '\n' | sort -u | tr '\n' ' ')"

    # Store start times per PID so the force-kill loop can compare against
    # the original value (not a freshly-read one that would always match).
    local -A _pid_start_times=()

    local _pid
    for _pid in $_stale_pids; do
      [[ "$_pid" =~ ^[0-9]+$ ]] || continue

      # Verify workspace ownership via /proc/$pid/root
      local _pid_root
      _pid_root="$(readlink "/proc/$_pid/root" 2>/dev/null)" || _pid_root=""
      [[ -n "$_pid_root" ]] || continue

      case "$_pid_root" in
        "$WORKDIR"|"$WORKDIR"/*) ;;
        *) continue ;; # Not a workspace process
      esac

      # Verify process start time to avoid killing a recycled PID
      local _pid_start
      _pid_start="$(awk '{print $22}' "/proc/$_pid/stat" 2>/dev/null)" || _pid_start=""
      if [[ -z "$_pid_start" ]]; then
        debug "setup_clear_stale_state: could not read start time for PID $_pid — skipping"
        continue
      fi
      local _uptime
      _uptime="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)" || _uptime=0
      local _clk_tck
      _clk_tck="$(getconf CLK_TCK 2>/dev/null)" || _clk_tck=100
      local _pid_start_sec=0
      if [[ -n "$_pid_start" && $_clk_tck -gt 0 ]]; then
        _pid_start_sec=$(( _pid_start / _clk_tck ))
      fi
      local _pid_age=$(( _uptime - _pid_start_sec ))
      if [[ $_pid_age -lt 60 ]]; then
        debug "setup_clear_stale_state: PID $_pid started ${_pid_age}s ago — too recent, skipping"
        continue
      fi

      # Preserve this PID's start time for the force-kill identity check.
      _pid_start_times[$_pid]="$_pid_start"

      # Get the process's mount namespace
      local _pid_mnt_ns
      _pid_mnt_ns="$(readlink "/proc/$_pid/ns/mnt" 2>/dev/null)" || _pid_mnt_ns=""

      # Get process info for logging
      local _pid_cmd
      _pid_cmd="$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)" || _pid_cmd=""

      log "setup_clear_stale_state: found workspace process PID $_pid ($_pid_cmd)"
      log "  root=$_pid_root ns=$_pid_mnt_ns"

      # Check if this process is in a different mount namespace
      if [[ -n "$_our_mnt_ns" && -n "$_pid_mnt_ns" && "$_pid_mnt_ns" != "$_our_mnt_ns" ]]; then
        log "  Process is in a different mount namespace — entering for cleanup"

        # Revalidate PID identity before entering its namespace
        local _pre_ns_start
        _pre_ns_start="$(awk '{print $22}' "/proc/$_pid/stat" 2>/dev/null)" || _pre_ns_start=""
        if [[ -z "$_pre_ns_start" ]]; then
          warn "setup_clear_stale_state: PID $_pid disappeared before namespace entry"
          continue
        fi
        if [[ "$_pre_ns_start" != "${_pid_start_times[$_pid]:-}" ]]; then
          warn "setup_clear_stale_state: PID $_pid recycled before namespace entry (start time mismatch)"
          continue
        fi

        # Enter the old namespace and clean up mounts there
        # Use nsenter --mount to enter the old namespace
        local _ns_cleanup_rc=0
        nsenter --mount="/proc/$_pid/ns/mnt" -- \
          /bin/sh -c '
            workspace="$1"
            _ns_mnt_file=$(mktemp) || { echo "WARN: mktemp failed" >&2; exit 1; }
            if findmnt -rno TARGET --submounts > "$_ns_mnt_file" 2>/dev/null; then
              sort -r < "$_ns_mnt_file" > "$_ns_mnt_file.sorted"
              mv "$_ns_mnt_file.sorted" "$_ns_mnt_file"
            else
              echo "WARN: findmnt failed in namespace" >&2
              rm -f "$_ns_mnt_file"
              exit 1
            fi
            _ns_fail=0
            while IFS= read -r m; do
              [ -n "$m" ] || continue
              case "$m" in
                "$workspace"|"$workspace"/*)
                  if ! umount -l "$m" 2>/dev/null; then
                    echo "WARN: namespace unmount failed for $m" >&2
                    _ns_fail=1
                  fi
                  ;;
              esac
            done < "$_ns_mnt_file"
            rm -f "$_ns_mnt_file"
            exit "$_ns_fail"
          ' _ "$WORKDIR" 2>/dev/null || _ns_cleanup_rc=1

        if [[ $_ns_cleanup_rc -ne 0 ]]; then
          warn "setup_clear_stale_state: namespace cleanup for PID $_pid had errors — some mounts may be stuck"
          _stale_rc=1
        fi
      fi

      # Revalidate PID identity before signaling — compare current
      # start time against the value captured during initial discovery.
      if [[ -z "${_pid_start_times[$_pid]:-}" ]]; then
        debug "setup_clear_stale_state: PID $_pid has no preserved start time — skipping SIGTERM"
        continue
      fi
      local _recheck_start
      _recheck_start="$(awk '{print $22}' "/proc/$_pid/stat" 2>/dev/null)" || _recheck_start=""
      if [[ -z "$_recheck_start" ]]; then
        debug "setup_clear_stale_state: PID $_pid disappeared before SIGTERM"
        continue
      fi
      if [[ "$_recheck_start" != "${_pid_start_times[$_pid]}" ]]; then
        debug "setup_clear_stale_state: PID $_pid recycled — skipping"
        continue
      fi

      # Gracefully terminate the process
      log "  Sending SIGTERM to PID $_pid"
      kill "$_pid" 2>/dev/null || true
    done

    # Wait for processes to exit
    local _wait_count=0
    while ((_wait_count < 30)); do
      local _any_alive=0
      for _pid in $_stale_pids; do
        [[ "$_pid" =~ ^[0-9]+$ ]] || continue
        if kill -0 "$_pid" 2>/dev/null; then
          local _pid_root
          _pid_root="$(readlink "/proc/$_pid/root" 2>/dev/null)" || _pid_root=""
          case "$_pid_root" in
            "$WORKDIR"|"$WORKDIR"/*)
              _any_alive=1
              break
              ;;
          esac
        fi
      done
      if ((_any_alive == 0)); then
        break
      fi
      sleep 0.2
      ((_wait_count++)) || true
    done

    # Force kill any remaining workspace processes
    for _pid in $_stale_pids; do
      [[ "$_pid" =~ ^[0-9]+$ ]] || continue
      # Skip PIDs that were not eligible for termination (e.g., too young)
      if [[ -z "${_pid_start_times[$_pid]:-}" ]]; then
        debug "setup_clear_stale_state: skipping PID $_pid (no preserved start time — was too young)"
        continue
      fi
      if kill -0 "$_pid" 2>/dev/null; then
        local _pid_root
        _pid_root="$(readlink "/proc/$_pid/root" 2>/dev/null)" || _pid_root=""
        case "$_pid_root" in
          "$WORKDIR"|"$WORKDIR"/*)
            # Revalidate PID identity before force kill — compare current
            # start time against the value captured during initial discovery.
            local _recheck_start
            _recheck_start="$(awk '{print $22}' "/proc/$_pid/stat" 2>/dev/null)" || _recheck_start=""
            if [[ -z "$_recheck_start" ]]; then
              debug "setup_clear_stale_state: PID $_pid disappeared before SIGKILL"
              continue
            fi
            if [[ "$_recheck_start" != "${_pid_start_times[$_pid]}" ]]; then
              debug "setup_clear_stale_state: PID $_pid recycled — skipping force kill"
              continue
            fi
            warn "setup_clear_stale_state: SIGKILL to workspace process PID $_pid"
            kill -9 "$_pid" 2>/dev/null || true
            ;;
        esac
      fi
    done

    # Brief wait for kernel to release resources after SIGKILL
    sleep 1
  fi

  # ============================================================
  # 1. Overlay/chroot SECOND.
  #
  # MERGED references:
  #   - MNT as lowerdir
  #   - OVL_MNT as upper/work storage
  #
  # Therefore neither of those may be torn down first.
  # ============================================================
  local _cleanup_rc=0
  overlay_cleanup || _cleanup_rc=$?
  if ((_cleanup_rc != 0)); then
    die "Could not safely clean stale overlay state. Refusing to touch its backing filesystems."
  fi

  if [[ -n "${MERGED:-}" ]] && mountpoint -q "$MERGED" 2>/dev/null; then
    die "Stale OverlayFS remains mounted at $MERGED"
  fi

  if mountpoint -q "$OVL_MNT" 2>/dev/null; then
    die "Stale overlay workspace remains mounted at $OVL_MNT"
  fi

  local remaining_overlay_loops _remaining_rc=0
  remaining_overlay_loops="$(loops_for_file "$OVL_IMG")" || _remaining_rc=$?

  if [[ $_remaining_rc -ne 0 ]]; then
    warn "Could not determine loop state for $OVL_IMG (rc=$_remaining_rc) — treating as still present"
    die "Could not safely recover the previous overlay workspace; reboot may be required"
  fi

  if [[ -n "$remaining_overlay_loops" ]]; then
    local all_autoclear=1
    while IFS="" read -r dev; do
      [[ -n "$dev" ]] || continue
      local ac
      ac="$(losetup -l -O AUTOCLEAR "$dev" 2>/dev/null | tail -1 | tr -d ' ')"
      if [[ "$ac" == "1" ]]; then
        log "setup_clear_stale_state: $dev still attached but AUTOCLEAR=1 — kernel will auto-detach"
      else
        warn "setup_clear_stale_state: $dev still attached without AUTOCLEAR"
        all_autoclear=0
      fi
    done <<<"$remaining_overlay_loops"

    if ((all_autoclear == 0)); then
      die "Could not safely recover the previous overlay workspace; reboot may be required"
    fi

    if ((all_autoclear == 1)); then
      # Wait for AUTOCLEAR loops to actually detach (up to 5 seconds)
      local _waited=0
      local _still_present=1
      while ((_waited < 50)); do
        local _check_loops _check_rc=0
        _check_loops="$(loops_for_file "$OVL_IMG")" || _check_rc=$?
        if [[ $_check_rc -ne 0 ]]; then
          warn "Could not query loop state for $OVL_IMG (rc=$_check_rc) — continuing to wait"
        elif [[ -z "$_check_loops" ]]; then
          _still_present=0
          break
        fi
        sleep 0.1
        ((_waited++)) || true
      done
      if ((_still_present)); then
        warn "setup_clear_stale_state: AUTOCLEAR=1 loops still present after 5s — forcing detach"
        while IFS="" read -r dev; do
          [[ -n "$dev" ]] || continue
          local _detach_rc=0
          strict_detach_loop "$dev" 2>/dev/null || _detach_rc=$?
          if ((_detach_rc != 0)); then
            warn "setup_clear_stale_state: loop detach failed for $dev (rc=$_detach_rc)"
          fi
        done <<<"$_check_loops"
      fi
    fi
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
      if ! strict_unmount "$_etc_merged" "stale effective /etc overlay"; then
        warn "Failed to unmount stale mount: $_etc_merged"
        _stale_rc=1
      fi
    fi
  fi

  if ! strict_unmount "$_etc_lower" "stale effective /etc lower bind"; then
    warn "Failed to unmount stale mount: $_etc_lower"
    _stale_rc=1
  fi
  if ! strict_unmount "$_etc_var" "stale effective /etc var mount"; then
    warn "Failed to unmount stale mount: $_etc_var"
    _stale_rc=1
  fi

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
    if ! strict_unmount "$_tmp_etc_merged" "stale rootfs /etc reconstruction overlay"; then
      warn "Failed to unmount stale mount: $_tmp_etc_merged"
      _stale_rc=1
    fi
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
      if ! strict_unmount "$_tmp_mount" "stale rootfs helper mount"; then
        warn "Failed to unmount stale mount: $_tmp_mount"
        _stale_rc=1
      fi
    fi
  done

  if ((_stale_rc)); then
    warn "Stale cleanup: mount failures detected — preserving workspace"
    return 1
  fi

  # mount -o loop may have left an explicit loop attachment for the temporary
  # reconstructed filesystem if a prior run died before unmount.
  local _root_tmp="$WORKDIR/rootfs-writable.img"
  local _root_tmp_loops _root_tmp_rc=0
  _root_tmp_loops="$(loops_for_file "$_root_tmp")" || _root_tmp_rc=$?
  if [[ $_root_tmp_rc -ne 0 ]]; then
    warn "setup_clear_stale_state: could not determine loop state for $_root_tmp (rc=$_root_tmp_rc)"
    return 1
  fi
  if [[ -n "$_root_tmp_loops" ]]; then
    warn "Cleaning stale temporary rootfs loop attachments"
    while IFS="" read -r dev; do
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
  local image_loops _image_loops_init_rc=0

  image_loops="$(loops_for_file "$OUT")" || _image_loops_init_rc=$?
  if [[ $_image_loops_init_rc -ne 0 ]]; then
    warn "setup_clear_stale_state: could not determine loop state for $OUT (rc=$_image_loops_init_rc)"
    return 1
  fi

  while IFS="" read -r dev; do
    [[ -n "$dev" ]] || continue

    warn "Cleaning stale image loop: $dev"

    local _loop_mounts _inv_rc=0
    _loop_mounts="$(mounts_for_loop "$dev")" || _inv_rc=$?
    if ((_inv_rc != 0)); then
      die "Could not inventory mounts for $dev"
    fi
    while IFS="" read -r m; do
      [[ -n "$m" ]] || continue

      if ! strict_unmount "$m" "stale image filesystem"; then
        die "Could not safely unmount $m from $dev"
      fi
    done <<<"$_loop_mounts"

    if ! strict_detach_loop "$dev"; then
      die "Could not safely detach stale image loop $dev"
    fi

    # Wait for the loop to be released (jbd2 may be flushing metadata).
    # Do NOT signal jbd2 — it is a kernel thread, not a build-owned process.
    local _wait_i
    for _wait_i in $(seq 1 50); do
      losetup "$dev" >/dev/null 2>&1 || break # lint-ignore: strict-mount
      sleep 0.2
    done
  done <<<"$image_loops"

  local _image_loops_rc=0
  image_loops="$(loops_for_file "$OUT")" || _image_loops_rc=$?
  if [[ $_image_loops_rc -ne 0 ]]; then
    warn "Could not determine loop state for $OUT (rc=$_image_loops_rc) — refusing to delete"
    return 1
  fi
  if [[ -n "$image_loops" ]]; then
    # Check if all remaining loops are AUTOCLEAR=1 (kernel will clean up)
    local _all_ac=1
    while IFS="" read -r m; do
      [[ -n "$m" ]] || continue
      local _ac
      _ac="$(losetup -l -O AUTOCLEAR "$m" 2>/dev/null | tail -1 | tr -d ' ')"
      [[ "$_ac" == "1" ]] || _all_ac=0
    done <<<"$image_loops"
    if ((_all_ac == 1)); then
      log "Stale image loops still visible but all AUTOCLEAR=1 — kernel will auto-detach"
      # Re-check after forced detach attempt to ensure kernel has cleaned up
      local _remaining_loops _remaining_rc=0
      _remaining_loops="$(loops_for_file "$OUT")" || _remaining_rc=$?
      if [[ $_remaining_rc -ne 0 ]]; then
        warn "Could not re-check loop state for $OUT (rc=$_remaining_rc) — refusing to delete"
        return 1
      fi
      if [[ -n "$_remaining_loops" ]]; then
        warn "setup_clear_stale_state: loops still reference $OUT after detach attempt"
        warn "setup_clear_stale_state: refusing to delete image while loops are active"
        while IFS= read -r _loop; do
          warn "  $_loop"
        done <<<"$_remaining_loops"
        return 1
      fi
    else
      die "Stale loop device still references $OUT; refusing to delete the backing image"
    fi
  fi

  # ============================================================
  # 3. Explicit project mountpoints.
  # ============================================================
  local _stale_rc=0
  for m in "$HOMEMNT" "$EFIMNT" "$MNT"; do
    [[ -n "$m" ]] || continue

    if mountpoint -q "$m" 2>/dev/null; then
      warn "Unexpected stale project mount: $m"
      if ! strict_unmount "$m" "project filesystem"; then
        warn "Failed to unmount project filesystem: $m"
        _stale_rc=1
      fi
    fi
  done

  # ============================================================
  # 4. NOW it is safe to delete an incomplete working image.
  # ============================================================
  if ((_stale_rc != 0)); then
    warn "setup_clear_stale_state: project unmount failures — refusing to delete $OUT"
    return 1
  fi

  if [[ -f "$OUT" ]]; then
    warn "Removing incomplete output from previous failed run"
    rm -f "$OUT" "${OUT}.src-fingerprint"
  fi

  if [[ ! -f "$OUT" && -f "${OUT}.src-fingerprint" ]]; then
    rm -f "${OUT}.src-fingerprint"
  fi

  # ============================================================
  # 5. Remove host-side scratch residue only after proving it is unmounted.
  # ============================================================
  for m in "$MERGED" "$UPPER" "$OVLWORK"; do
    [[ -n "$m" && -e "$m" ]] || continue
    if ! safe_rmdir "$m"; then
      die "Refusing to remove stale directory with active mounts: $m"
    fi
  done

  # ============================================================
  # 6. Clean up stale build root overlays from previous runs.
  # ============================================================
  if ! _cleanup_stale_build_roots; then
    warn "setup_clear_stale_state: stale build root cleanup had failures"
    _stale_rc=1
  fi

  if ! _cleanup_stale_build_loops; then
    warn "setup_clear_stale_state: stale build loop cleanup failed"
    _stale_rc=1
  fi

  if ((_stale_rc)); then
    warn "setup_clear_stale_state: stale state recovery had errors"
    return 1
  fi

  # Final verification: check if any stale loops remain
  local _final_loops=0
  if [[ -n "${OVL_IMG:-}" ]]; then
    local _final_check _final_rc=0
    _final_check="$(loops_for_file "$OVL_IMG")" || _final_rc=$?
    if [[ $_final_rc -ne 0 ]]; then
      warn "Could not verify loop state for $OVL_IMG (rc=$_final_rc)"
      _final_loops=1
    else
      [[ -z "$_final_check" ]] || _final_loops=1
    fi
  fi
  if [[ -n "${OUT:-}" ]]; then
    local _final_check _final_rc=0
    _final_check="$(loops_for_file "$OUT")" || _final_rc=$?
    if [[ $_final_rc -ne 0 ]]; then
      warn "Could not verify loop state for $OUT (rc=$_final_rc)"
      _final_loops=1
    else
      [[ -z "$_final_check" ]] || _final_loops=1
    fi
  fi

  if ((_final_loops)); then
    die "Stale workspace loops remain after recovery — refusing to start new build"
  fi

  log "Stale build state is clean"
}

# Clean up stale build root overlays from previous runs.
# Build roots live at $WORKDIR/build-roots/*/overlay-work.img.
# Called from setup_clear_stale_state().
_cleanup_stale_build_roots() {
  local build_roots_dir="$WORKDIR/build-roots"
  [[ -d "$build_roots_dir" ]] || return 0

  local _func_rc=0

  local stale_img
  for stale_img in "$build_roots_dir"/*/overlay-work.img; do
    [[ -f "$stale_img" ]] || continue

    local stale_dir="${stale_img%/overlay-work.img}"
    local stale_loops _stale_rc=0
    stale_loops="$(loops_for_file "$stale_img")" || _stale_rc=$?

    if [[ $_stale_rc -ne 0 ]]; then
      warn "Could not determine loop state for $stale_img (rc=$_stale_rc) — refusing to remove $stale_dir"
      continue
    fi

    if [[ -z "$stale_loops" ]]; then
      # No loop attached — just remove the directory
      log "  Removing orphaned build root: $stale_dir"
      if ! safe_rmdir "$stale_dir"; then
        die "Refusing to remove stale build root with active mounts: $stale_dir"
      fi
      continue
    fi

    warn "Cleaning stale build root: $stale_dir"

    local merged="$stale_dir/merged"

    # Unmount anything backed by these loops
    while IFS="" read -r loop; do
      [[ -n "$loop" ]] || continue

      local m _loop_mounts _inv_rc=0
      _loop_mounts="$(mounts_for_loop "$loop")" || _inv_rc=$?
      if ((_inv_rc != 0)); then
        die "Could not inventory mounts for $loop"
      fi
      while IFS="" read -r m; do
        [[ -n "$m" ]] || continue
        if mountpoint -q "$m" 2>/dev/null; then
          warn "  Unmounting stale build root mount: $m"
          if ! strict_unmount "$m" "stale build root mount"; then
            warn "  Failed to unmount stale build root mount: $m"
            _func_rc=1
          fi
        fi
      done <<<"$_loop_mounts"

      # Also try unmounting known paths inside the build root
      for m in "$merged/dev/shm" "$merged/dev" "$merged/sys" "$merged/proc" "$merged/tmp" "$merged"; do
        [[ -e "$m" ]] || continue
        if mountpoint -q "$m" 2>/dev/null; then
          warn "  Unmounting stale build root path: $m"
          if ! strict_unmount "$m" "stale build root mount"; then
            warn "  Failed to unmount stale build root path: $m"
            _func_rc=1
          fi
        fi
      done

      local ovl_mnt="$stale_dir/overlay-mnt"
      if [[ -e "$ovl_mnt" ]] && mountpoint -q "$ovl_mnt" 2>/dev/null; then
        warn "  Unmounting stale build root workspace: $ovl_mnt"
        if ! strict_unmount "$ovl_mnt" "stale build root workspace"; then
          warn "  Failed to unmount stale build root workspace: $ovl_mnt"
          _func_rc=1
        fi
      fi

      # Wait for ext4 release and detach
      if wait_ext4_gone "$loop"; then
        if ! strict_detach_loop "$loop"; then
          warn "  Could not detach $loop"
          _func_rc=1
        fi
      else
        warn "  $loop ext4 superblock still alive; attempting detach anyway"
        if ! strict_detach_loop "$loop"; then
          warn "  Could not detach $loop despite live superblock"
          _func_rc=1
        fi
      fi
    done <<<"$stale_loops"

    # Remove directory if no loops remain
    local _post_detach_rc=0
    stale_loops="$(loops_for_file "$stale_img")" || _post_detach_rc=$?
    if [[ $_post_detach_rc -ne 0 ]]; then
      warn "Could not re-check loop state for $stale_img (rc=$_post_detach_rc) — refusing to remove $stale_dir"
    elif [[ -z "$stale_loops" ]]; then
      if ! safe_rmdir "$stale_dir"; then
        die "Refusing to remove stale build root with active mounts: $stale_dir"
      fi
    else
      warn "  Build root $stale_dir still has active loops; preserving"
    fi
  done

  # Remove empty build-roots directory
  rmdir "$build_roots_dir" 2>/dev/null || true

  return "$_func_rc"
}

# Find and detach loop devices from ANY previous run whose back-file matches
# build-related patterns.  Unlike the rest of setup_clear_stale_state() which
# only looks under $WORKDIR, this catches loops left behind by runs that used a
# different $WORKDIR (e.g. /dev/shm/steamos-build vs /home/image/.nvidia-usb-work).
# Called from setup_clear_stale_state().
_cleanup_stale_build_loops() {
  local json
  json="$(losetup -J 2>/dev/null)" || {
    warn "_cleanup_stale_build_loops: losetup -J failed"
    return 1
  }
  [[ -n "$json" ]] || return 0

  # python3 prints lines of "loop_name\tback_file" for matching loops.
  local matches
  matches="$(WORKDIR="$WORKDIR" python3 -c '
import json, sys, os

WORKDIR = os.environ.get("WORKDIR", "")
patterns = []
if WORKDIR:
    patterns.append(WORKDIR + "/")
    patterns.append(WORKDIR + "/build-roots/")

data = json.loads(sys.stdin.read())
for dev in data.get("loopdevices", []):
    backing = dev.get("back-file") or ""
    name = dev.get("name") or ""
    if not name or not backing:
        continue
    clean = backing.removesuffix(" (deleted)")
    matched = False
    for pat in patterns:
        if clean.startswith(pat):
            matched = True
            break
    if not matched:
        continue
    print(name + "\t" + backing)
' <<<"$json")" || {
    warn "_cleanup_stale_build_loops: JSON parse failed"
    return 1
  }

  [[ -n "$matches" ]] || return 0

  local loop backing
  while IFS=$'\t' read -r loop backing; do
    [[ -n "$loop" ]] || continue
    warn "Cleaning stale build loop from previous run: $loop ($backing)"
    if strict_detach_loop "$loop"; then
      log "  Detached $loop"
    else
      warn "  Could not detach $loop (may already be gone)"
    fi
  done <<<"$matches"
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
  local rc=0
  local _stop=0
  local m
  local loops=""

  # Allow this to work during startup recovery before _overlay_mount_with_image()
  # has populated these globals.
  : "${OVL_IMG:=${WORKDIR:+$WORKDIR/overlay-work.img}}"
  : "${OVL_MNT:=${WORKDIR:+$WORKDIR/overlay-mnt}}"

  cleanup_log "=== overlay_cleanup: start ==="
  cleanup_log_namespace
  cleanup_log_mount_state

  # ------------------------------------------------------------
  # 1. Kill known chroot daemons before touching mount topology.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: kill gpg-agent"
  if [[ -n "${MERGED:-}" ]]; then
    if ! cleanup_kill_gpg_agent "$MERGED/etc/pacman.d/gnupg" "$MERGED"; then
      warn "overlay_cleanup: gpg-agent shutdown failed — refusing to continue teardown"
      rc=1
      _stop=1
    fi
  fi

  # ------------------------------------------------------------
  # 2. Remove mounts INSIDE the OverlayFS.
  #
  # /dev children (shm) must be unmounted before /dev itself.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: unmount chroot children"
  if [[ -n "${MERGED:-}" ]]; then
    for m in \
      "$MERGED/tmp/pkgcache" \
      "$MERGED/dev/shm" \
      "$MERGED/dev" \
      "$MERGED/sys" \
      "$MERGED/proc" \
      "$MERGED/tmp"; do
      [[ -e "$m" ]] || continue

      if mountpoint -q "$m" 2>/dev/null; then
        if strict_unmount "$m" "chroot child"; then
          :
        else
          rc=1
        fi
      fi
    done
  fi

  if ((rc != 0)); then
    warn "overlay_cleanup: chroot child mounts remain; refusing to tear down OverlayFS"
    cleanup_log "overlay_cleanup: FAIL — chroot children remain (rc=$rc)"
    _stop=1
  fi

  # ------------------------------------------------------------
  # 3. Remove MERGED itself.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: unmount MERGED"
  if ((!_stop)) \
    && [[ -n "${MERGED:-}" ]] \
    && mountpoint -q "$MERGED" 2>/dev/null; then
    if [[ "${DEBUG:-0}" == 1 ]]; then
      log_debug overlay pre-merged-unmount "=== PRE-MERGED-UNMOUNT ==="
      log_debug overlay pre-merged-unmount-tree mounts "$(findmnt -R "$MERGED" 2>/dev/null || true)"
      log_debug overlay pre-merged-unmount-users users "$(fuser -vm "$MERGED" 2>/dev/null || true)"
      log_debug overlay pre-merged-unmount-mountinfo mountinfo "$(grep -F "$MERGED" /proc/self/mountinfo 2>/dev/null || true)"
      if [[ -n "${OVL_LOOPDEV:-}" ]]; then
        log_debug overlay pre-merged-unmount-loop loop "$(findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true)"
        [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
          && log_debug overlay pre-merged-unmount-ext4 "${OVL_LOOPDEV##/dev/} ext4 still alive before MERGED unmount"
      fi
    fi

    local umount_merged_rc=0
    umount -v "$MERGED" 2>&1 || umount_merged_rc=$? # lint-ignore: strict-mount

    if ((umount_merged_rc == 0)); then
      :
    else
      # Dump diagnostics on failure
      warn "overlay_cleanup: MERGED unmount failed (rc=$umount_merged_rc)"
      log_debug overlay merged-unmount-fail-tree mounts "$(findmnt -R "$MERGED" 2>/dev/null || true)"
      log_debug overlay merged-unmount-fail-users users "$(fuser -vm "$MERGED" 2>/dev/null || true)"
      log_debug overlay merged-unmount-fail-mountinfo mountinfo "$(grep -F "$MERGED" /proc/self/mountinfo 2>/dev/null || true)"
    fi

    if [[ "${DEBUG:-0}" == 1 ]]; then
      log_debug overlay post-merged-unmount "=== AFTER MERGED ==="
      log_debug overlay post-merged-unmount-tree mounts "$(findmnt -R "$MERGED" 2>/dev/null || true)"
      if [[ -n "${OVL_LOOPDEV:-}" ]]; then
        log_debug overlay post-merged-unmount-loop loop "$(findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true)"
        [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
          && log_debug overlay post-merged-unmount-ext4 "${OVL_LOOPDEV##/dev/} ext4 still alive after MERGED unmount"
      fi
    fi

    if ((umount_merged_rc != 0)); then
      warn "overlay_cleanup: refusing to unmount overlay workspace while MERGED exists"
      _stop=1
    fi
  fi

  # Explicit invariant.
  if [[ -n "${MERGED:-}" ]] \
    && mountpoint -q "$MERGED" 2>/dev/null; then
    warn "overlay_cleanup: MERGED is unexpectedly still mounted"
    rc=1
    _stop=1
  fi

  # ------------------------------------------------------------
  # 4. Now — and only now — unmount the ext4 overlay workspace.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: unmount OVL_MNT"
  if ((!_stop)) \
    && [[ -n "${OVL_MNT:-}" ]] \
    && mountpoint -q "$OVL_MNT" 2>/dev/null; then
    if [[ "${DEBUG:-0}" == 1 ]]; then
      log_debug overlay pre-ovl-mnt-unmount "=== PRE-OVL_MNT-UNMOUNT ==="
      log_debug overlay pre-ovl-mnt-unmount-tree mounts "$(findmnt -R "$OVL_MNT" 2>/dev/null || true)"
      log_debug overlay pre-ovl-mnt-unmount-users users "$(fuser -vm "$OVL_MNT" 2>/dev/null || true)"
      log_debug overlay pre-ovl-mnt-unmount-mountinfo mountinfo "$(grep -F "$OVL_MNT" /proc/self/mountinfo 2>/dev/null || true)"
      if [[ -n "${OVL_LOOPDEV:-}" ]]; then
        log_debug overlay pre-ovl-mnt-unmount-loop loop "$(findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true)"
        [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
          && log_debug overlay pre-ovl-mnt-unmount-ext4 "${OVL_LOOPDEV##/dev/} ext4 still alive before OVL_MNT unmount"
      fi
    fi

    local umount_ovl_rc=0
    umount -v "$OVL_MNT" 2>&1 || umount_ovl_rc=$? # lint-ignore: strict-mount

    if ((umount_ovl_rc == 0)); then
      :
    else
      # Dump diagnostics on failure
      warn "overlay_cleanup: OVL_MNT unmount failed (rc=$umount_ovl_rc)"
      log_debug overlay ovl-mnt-unmount-fail-tree mounts "$(findmnt -R "$OVL_MNT" 2>/dev/null || true)"
      log_debug overlay ovl-mnt-unmount-fail-users users "$(fuser -vm "$OVL_MNT" 2>/dev/null || true)"
      log_debug overlay ovl-mnt-unmount-fail-mountinfo mountinfo "$(grep -F "$OVL_MNT" /proc/self/mountinfo 2>/dev/null || true)"
    fi

    # Flush pending writes so the jbd2 thread releases the superblock
    sync -f "$OVL_MNT" 2>/dev/null || sync
    if [[ -n "${OVL_LOOPDEV:-}" ]]; then
      blockdev --flushbufs "$OVL_LOOPDEV" 2>/dev/null || true
    fi

    if [[ "${DEBUG:-0}" == 1 ]]; then
      log_debug overlay post-ovl-mnt-unmount "=== AFTER OVL_MNT ==="
      log_debug overlay post-ovl-mnt-unmount-tree mounts "$(findmnt -R "$OVL_MNT" 2>/dev/null || true)"
      if [[ -n "${OVL_LOOPDEV:-}" ]]; then
        log_debug overlay post-ovl-mnt-unmount-loop loop "$(findmnt -S "$OVL_LOOPDEV" 2>/dev/null || true)"
        [[ -d "/sys/fs/ext4/${OVL_LOOPDEV##/dev/}" ]] \
          && log_debug overlay post-ovl-mnt-unmount-ext4 "${OVL_LOOPDEV##/dev/} ext4 still alive after OVL_MNT unmount"
      fi
    fi

    if ((umount_ovl_rc != 0)); then
      warn "overlay_cleanup: overlay workspace could not be cleanly unmounted"
      rc=1
      _stop=1
    fi
  fi

  # ------------------------------------------------------------
  # 5. Find every loop associated with overlay-work.img.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: find loops for overlay-work.img"
  if ((!_stop)) && [[ -n "${OVL_IMG:-}" ]]; then
    local _loops_rc=0
    loops="$(loops_for_file "$OVL_IMG")" || _loops_rc=$?
    if [[ $_loops_rc -ne 0 ]]; then
      warn "overlay_cleanup: could not determine loop state for $OVL_IMG (rc=$_loops_rc)"
      rc=1
      cleanup_log "overlay_cleanup: FAIL — loop inventory unavailable (rc=$_loops_rc); skipping destructive cleanup"
      _stop=1
    fi
  fi

  # Include the loop we explicitly allocated even if losetup's backing-file
  # presentation is unusual.
  # lint-ignore: strict-mount (read-only existence check)
  if [[ -n "${OVL_LOOPDEV:-}" ]] && losetup "$OVL_LOOPDEV" >/dev/null 2>&1 \
    && ! grep -qxF "$OVL_LOOPDEV" <<<"$loops"; then
    loops="${loops:+$loops$'\n'}$OVL_LOOPDEV"
  fi

  # ------------------------------------------------------------
  # 6. Wait for ext4 superblock release, but don't block on it.
  # ------------------------------------------------------------
  cleanup_log "overlay_cleanup: wait ext4 superblock release"
  if ((!_stop)); then
  while IFS="" read -r m; do
    [[ -n "$m" ]] || continue

    # Unmount external/automount references (e.g., udisks2 desktop mounts)
    # that prevent the ext4 superblock from releasing.
    local _ext_mounts _ext_rc=0
    _ext_mounts="$(findmnt -rno TARGET --source "$m" 2>/dev/null)" || _ext_rc=$?
    if ((_ext_rc > 1)); then
      warn "overlay_cleanup: findmnt query failed for $m (rc=$_ext_rc) — refusing to detach loop"
      rc=1
      continue
    fi
    local _ext_umount_failed=0
    local _mp
    while IFS= read -r _mp; do
      [[ -n "$_mp" ]] || continue
      # Only unmount mounts inside our workspace
      case "$_mp" in
        "$OVL_MNT"|"$OVL_MNT"/*|"$MERGED"|"$MERGED"/*)
          ;; # OK — inside workspace
        *)
          debug "overlay_cleanup: skipping external reference $_mp (outside workspace)"
          continue
          ;;
      esac
      warn "overlay_cleanup: unmounting external reference on $m: $_mp"
      if ! strict_unmount "$_mp" "external reference"; then
        warn "overlay_cleanup: failed to unmount external reference: $_mp"
        _ext_umount_failed=1
      fi
    done <<<"$_ext_mounts"

    # Check for external mounts outside the workspace — refuse to detach
    # the loop if any remain, as this could leave the loop in an
    # inconsistent state.
    local _ext_outside=""
    while IFS= read -r _mp; do
      [[ -n "$_mp" ]] || continue
      case "$_mp" in
        "$OVL_MNT"|"$OVL_MNT"/*|"$MERGED"|"$MERGED"/*)
          ;; # Inside workspace — already handled above
        *)
          _ext_outside="${_ext_outside:+${_ext_outside}$'\n'}$_mp"
          ;;
      esac
    done <<<"$_ext_mounts"
    if [[ -n "$_ext_outside" ]]; then
      warn "overlay_cleanup: external mounts found for $m — refusing to detach"
      while IFS= read -r _ext_mp; do
        warn "  $_ext_mp"
      done <<<"$_ext_outside"
      rc=1
      continue
    fi

    if ((_ext_umount_failed)); then
      warn "overlay_cleanup: external-reference unmount failures — refusing to detach loop $m"
      rc=1
      continue
    fi

    if ! wait_ext4_gone "$m"; then
      warn "overlay_cleanup: $m ext4 superblock still alive after timeout (jbd2 journal thread)"
      warn "overlay_cleanup: attempting losetup -d anyway — unmount already succeeded"
      # Dump diagnostic info about what's holding the loop.
      local _backing
      _backing="$(losetup -l -O BACK-FILE "$m" 2>/dev/null | tail -1 | tr -d ' ')"
      warn "overlay_cleanup:   loop=$m backing=${_backing:-<unknown>}"
      # The filesystem is no longer accessible to userspace after unmount.
      # The jbd2 thread is just flushing metadata in the background.
      # losetup -d may succeed even if the superblock appears alive.
      # Do NOT signal jbd2 — it is a kernel thread, not a build-owned process.
      if strict_detach_loop "$m"; then
        log "overlay_cleanup: $m detached successfully despite live superblock"
        # Wait for the loop to fully disappear from losetup
        local _wait_i
        for _wait_i in $(seq 1 50); do
          losetup "$m" >/dev/null 2>&1 || break # lint-ignore: strict-mount
          sleep 0.2
        done
      else
        warn "overlay_cleanup: losetup -d failed for $m, attempting targeted cleanup"
        # Do NOT use losetup -D — it force-detaches ALL loop devices on the
        # system, including ones owned by unrelated processes.  Instead, find
        # only loop devices backed by files in WORKDIR or matching the
        # overlay-work.img pattern and detach those specifically.
        local _targeted_rc=0
        local _dev _backing _clean
        local _build_loops
        _build_loops="$(losetup -J 2>/dev/null)" || true
        if [[ -n "$_build_loops" ]]; then
          local _parsed_loops _py_rc=0
          _parsed_loops="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for dev in data.get("loopdevices", []):
    backing = dev.get("back-file") or ""
    name = dev.get("name") or ""
    if name and backing:
        print(name + "\t" + backing)
' <<<"$_build_loops")" || _py_rc=$?
          if ((_py_rc != 0)); then
            warn "overlay_cleanup: python3 loop inventory failed (rc=$_py_rc)"
            rc=1
          fi
          while IFS=$'\t' read -r _dev _backing; do
            [[ -n "$_dev" ]] || continue
            # Only detach loops backed by files in WORKDIR or overlay-work.img
            _clean="${_backing%\ (deleted)}"
            if [[ -n "${WORKDIR:-}" ]] &&
               { [[ "$_clean" == "$WORKDIR" ]] ||
                 [[ "$_clean" == "$WORKDIR/"* ]]; }; then
              log "overlay_cleanup: detaching WORKDIR-owned loop $_dev (backing: $_clean)"
              if ! strict_detach_loop "$_dev"; then
                warn "overlay_cleanup: could not detach $_dev"
                _targeted_rc=1
              fi
            elif [[ -n "${WORKDIR:-}" ]]; then
              local _resolved_backing
              _resolved_backing="$(realpath -m "$_clean" 2>/dev/null)" || _resolved_backing="$_clean"
              if [[ "$_resolved_backing" == "$WORKDIR"/* ]]; then
                log "overlay_cleanup: detaching WORKDIR-owned overlay loop $_dev (backing: $_clean)"
                if ! strict_detach_loop "$_dev"; then
                  warn "overlay_cleanup: could not detach $_dev"
                  _targeted_rc=1
                fi
              fi
            fi
          done <<<"$_parsed_loops"
        fi
        if [[ "$_targeted_rc" -ne 0 ]]; then
          warn "overlay_cleanup: some targeted detach attempts failed for $m"
          warn "overlay_cleanup: a reboot may be required to release this resource"
          rc=1
        fi
      fi
    fi
  done <<<"$loops"
  fi

  # ------------------------------------------------------------
  # 7. Detach loops and verify.
  # ------------------------------------------------------------
  if ((!_stop)); then
  cleanup_log "overlay_cleanup: detach loops"
  while IFS="" read -r m; do
    [[ -n "$m" ]] || continue

    if ! strict_detach_loop "$m"; then
      rc=1
    fi
  done <<<"$loops"

  if [[ -n "${OVL_IMG:-}" ]]; then
    local remaining
    local _remaining_rc=0
    remaining="$(loops_for_file "$OVL_IMG")" || _remaining_rc=$?
    if [[ $_remaining_rc -ne 0 ]]; then
      warn "overlay_cleanup: could not verify loop state for $OVL_IMG (rc=$_remaining_rc)"
      rc=1
    fi

    if [[ -n "$remaining" ]]; then
      local all_autoclear=1
      while IFS="" read -r m; do
        [[ -n "$m" ]] || continue
        local ac
        ac="$(losetup -l -O AUTOCLEAR "$m" 2>/dev/null | tail -1 | tr -d ' ')"
        if [[ "$ac" == "1" ]]; then
          log "overlay_cleanup: $m still attached but AUTOCLEAR=1 — kernel will auto-detach"
        else
          warn "overlay_cleanup: $m still attached without AUTOCLEAR"
          all_autoclear=0
        fi
      done <<<"$remaining"

      if ((all_autoclear == 0)); then
        warn "overlay_cleanup: non-autoclear loop(s) still attached to $OVL_IMG"
        rc=1
      fi
    fi
  fi
  fi

  cleanup_log "overlay_cleanup: verify remaining loops"
  if ((rc == 0)); then
    OVL_LOOPDEV=""
  fi

  cleanup_log "=== overlay_cleanup: done (rc=$rc) ==="
  return "$rc"
}
