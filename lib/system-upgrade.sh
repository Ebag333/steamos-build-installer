#!/bin/bash
#
# steamos-build-installer — lib/system-upgrade.sh
# System upgrade via pacman -Syu directly on the target image.
# This replaces the old overlay-based upgrade with selective copy-back.
#
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/system-upgrade.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# System Upgrade: Prepare
# ---------------------------------------------------------------------------
# Mount chroot filesystems and apply repo selection to $MNT.
# Must be called before system_upgrade().
#
# Args: none (uses globals: $MNT, $SKIP_SIG, $WORKDIR)
# ---------------------------------------------------------------------------
system_upgrade_prepare() {
  [[ -n "${MNT:-}" ]] || die "system_upgrade_prepare: MNT is not set"
  [[ -d "$MNT" ]] || die "system_upgrade_prepare: MNT directory not found: $MNT"

  log "Preparing system upgrade on $MNT"

  # Mount chroot filesystems
  mount_chroot_fs "$MNT"

  # Mount build cache for pacman packages (keeps downloads out of image)
  _pkgcache_dir="$WORKDIR/pkgcache"
  mkdir -p "$_pkgcache_dir"
  mkdir -p "$MNT/var/cache/pacman/pkg"
  mount --bind "$_pkgcache_dir" "$MNT/var/cache/pacman/pkg"
  log "Mounted build cache at /var/cache/pacman/pkg"

  # Inject DNS for the chroot
  # resolv.conf may be a symlink (e.g. -> /run/systemd/resolve/stub-resolv.conf)
  # so we backup, remove, install a temporary file, then restore later.
  _resolv_backup="$WORKDIR/resolv.conf.backup"
  rm -f "$_resolv_backup"
  _resolv_existed=0

  if [[ -e "$MNT/etc/resolv.conf" || -L "$MNT/etc/resolv.conf" ]]; then
    cp -a --no-dereference "$MNT/etc/resolv.conf" "$_resolv_backup"
    _resolv_existed=1
  fi

  rm -f "$MNT/etc/resolv.conf"
  host_resolv="$(readlink -f /etc/resolv.conf)"
  if [[ -f "$host_resolv" ]]; then
    install -m 0644 "$host_resolv" "$MNT/etc/resolv.conf"
    log "Injected host DNS config for chroot"
  else
    warn "Host /etc/resolv.conf not found — chroot DNS may not work"
  fi

  # Verify DNS works in chroot
  if ! chroot "$MNT" getent hosts steamdeck-packages.steamos.cloud &>/dev/null; then
    warn "DNS resolution not working in chroot"
  fi

  # Initialize pacman keyring (required for database sync)
  log "Initializing pacman keyring"
  rm -rf "$MNT/etc/pacman.d/gnupg"
  chroot "$MNT" pacman-key --init || die "pacman-key --init failed"

  # Populate keyrings based on FIX_KEYRING setting
  if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
    log "Populating Arch + Holo keyrings"
    chroot "$MNT" pacman-key --populate archlinux holo || die "pacman-key --populate failed"
  else
    log "Populating default keyrings"
    chroot "$MNT" pacman-key --populate || die "pacman-key --populate failed"
  fi

  # When Pacman repo is main, point all repos at the -main variants
  if [[ "${PACMAN_REPO:-valve}" == "main" ]]; then
    log "Switching pacman repos to main branch"
    sed -Ei \
      -e 's/^\[jupiter-[^]]+\][[:space:]]*$/[jupiter-main]/' \
      -e 's/^\[holo-[^]]+\][[:space:]]*$/[holo-main]/' \
      -e 's/^\[core-[^]]+\][[:space:]]*$/[core-main]/' \
      -e 's/^\[extra-[^]]+\][[:space:]]*$/[extra-main]/' \
      -e 's/^\[multilib-[^]]+\][[:space:]]*$/[multilib-main]/' \
      "$MNT/etc/pacman.conf"
  fi

  # Disable signature verification if requested
  if [[ "${SKIP_SIG:-0}" -eq 1 ]]; then
    log "Disabling pacman signature verification"
    sed -i 's/^SigLevel.*/SigLevel = Never/' "$MNT/etc/pacman.conf"
  fi
}

# ---------------------------------------------------------------------------
# System Upgrade: Run
# ---------------------------------------------------------------------------
# Run pacman -Syu directly on $MNT. This modifies the target image in place,
# preserving the full transaction including hooks, generated files, and
# deletions.
#
# Args: none (uses globals: $MNT)
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
system_upgrade() {
  [[ -n "${MNT:-}" ]] || die "system_upgrade: MNT is not set"

  log "Running system upgrade on $MNT"

  # Snapshot package state before upgrade
  local before_file="$WORKDIR/pkgs-before-sysupgrade.txt"
  local _pre_dbpath
  _pre_dbpath="$(resolve_pacman_dbpath "$MNT")" || _pre_dbpath="$MNT/var/lib/pacman"
  pacman -Q --dbpath "$_pre_dbpath" 2>/dev/null | sort >"$before_file" || true
  if [[ ! -s "$before_file" ]]; then
    warn "Could not snapshot pre-upgrade package list — summary will be inaccurate"
  fi

  # Pre-flight: dry-run to detect and resolve known conflicts
  if [[ "${PREFLIGHT:-1}" -eq 1 ]]; then
    if ! pacman_upgrade_preflight "System upgrade" --root "$MNT"; then
      return 1
    fi
  else
    warn "Pre-flight: skipped (PREFLIGHT=0) — proceeding without conflict checks"
  fi

  # Run pacman -Syu directly on $MNT using the image's own config
  local upgrade_log="$WORKDIR/system-upgrade.log"
  local _raw_log="${PACMAN_RAW_LOG:-/tmp/steamos-pacman-raw.log}"
  local _pacman_rc

  set -o pipefail
  chroot "$MNT" /bin/bash -c "pacman -Syu --noconfirm --ask=4" \
    > >(tee -a "$_raw_log" | _pacman_filter_stdout | tee "$upgrade_log") \
    2> >(tee -a "$_raw_log" | _pacman_filter_stderr | tee -a "$upgrade_log" >&2)
  _pacman_rc=${PIPESTATUS[0]}
  set +o pipefail

  if ((_pacman_rc != 0)); then
    warn "System upgrade failed (pacman rc=$_pacman_rc) — see log: $upgrade_log"
    if [[ -s "$_raw_log" ]]; then
      warn "Pacman raw output (last 100 lines):"
      tail -100 "$_raw_log" >&2
    fi
    return "$_pacman_rc"
  fi

  # Snapshot package state after upgrade
  local after_file="$WORKDIR/pkgs-after-sysupgrade.txt"
  local _post_dbpath
  _post_dbpath="$(resolve_pacman_dbpath "$MNT")" || _post_dbpath="$MNT/var/lib/pacman"
  pacman -Q --dbpath "$_post_dbpath" 2>/dev/null | sort >"$after_file" || true
  if [[ ! -s "$after_file" ]]; then
    warn "Could not snapshot post-upgrade package list — summary will be inaccurate"
  fi

  # Log upgrade summary
  # Compare by name:version to find actual changes
  local upgraded=0 added=0 removed=0
  local before_names="$WORKDIR/pkgs-before-names.txt"
  local after_names="$WORKDIR/pkgs-after-names.txt"
  cut -d' ' -f1 "$before_file" | sort >"$before_names"
  cut -d' ' -f1 "$after_file" | sort >"$after_names"

  # Added: names in after but not in before
  added=$(comm -13 "$before_names" "$after_names" | wc -l)

  # Removed: names in before but not in after
  removed=$(comm -23 "$before_names" "$after_names" | wc -l)

  # Upgraded: names in both, but version changed
  while IFS=' ' read -r name ver; do
    local old_ver
    old_ver="$(awk -v name="$name" '$1 == name { print $2; exit }' "$before_file")"
    if [[ -n "$old_ver" && "$old_ver" != "$ver" ]]; then
      ((++upgraded)) || true
    fi
  done <"$after_file"

  log "System upgrade complete: $upgraded upgraded, $added added, $removed removed"

  # Report .pacnew files created during upgrade
  local _pacnew_count=0
  local _pacnew_list="$WORKDIR/pacnew-files.txt"
  find "$MNT/etc" "$MNT/usr" "$MNT/boot" -name '*.pacnew' -type f >"$_pacnew_list" 2>/dev/null || true
  while IFS= read -r pacnew; do
    [[ -n "$pacnew" ]] || continue
    # Skip mirrorlist.pacnew — too large and not useful
    [[ "$pacnew" == */mirrorlist.pacnew ]] && continue
    ((++_pacnew_count)) || true
    # find output already includes $MNT prefix, so strip it for the original
    local original="${pacnew%.pacnew}"
    local original_rel="${original#"$MNT"}"
    log "pacnew: $original_rel"
    if [[ -f "$original" ]]; then
      diff -u "$original" "$pacnew" 2>/dev/null | head -30 || true
    else
      log "  (original missing: $original_rel)"
    fi
  done <"$_pacnew_list"

  if ((_pacnew_count > 0)); then
    log "$_pacnew_count .pacnew file(s) created during upgrade"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# System Upgrade: Cleanup
# ---------------------------------------------------------------------------
# Unmount chroot filesystems after system upgrade.
#
# Args: none (uses globals: $MNT)
# ---------------------------------------------------------------------------
system_upgrade_cleanup() {
  [[ -n "${MNT:-}" ]] || return 0

  log "Cleaning up system upgrade chroot"

  # Restore original resolv.conf (Valve's symlink or file)
  rm -f "$MNT/etc/resolv.conf"
  if [[ "${_resolv_existed:-0}" -eq 1 &&
    (-e "${_resolv_backup:-}" || -L "${_resolv_backup:-}") ]]; then
    cp -a --no-dereference "$_resolv_backup" "$MNT/etc/resolv.conf"
    log "Restored original resolv.conf"
  fi

  # Remove backup if we created one (user's repo selection persists)
  if [[ -f "$MNT/etc/pacman.conf.pacsave" ]]; then
    log "Removing pacman.conf.pacsave (user's repo selection persists)"
    rm -f "$MNT/etc/pacman.conf.pacsave"
  fi

  # Kill gpg-agent before touching mount topology
  if [[ -d "$MNT/etc/pacman.d/gnupg" ]]; then
    gpgconf --homedir "$MNT/etc/pacman.d/gnupg" --kill gpg-agent >/dev/null 2>&1 || true
  fi

  # Unmount children in reverse order (children before parents)
  local m
  for m in \
    "$MNT/var/cache/pacman/pkg" \
    "$MNT/dev/pts" \
    "$MNT/dev/shm" \
    "$MNT/dev" \
    "$MNT/sys" \
    "$MNT/proc"; do
    [[ -e "$m" ]] || continue
    if mountpoint -q "$m" 2>/dev/null; then
      log "  Unmounting $m"
      umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null || true
    fi
  done

  log "System upgrade chroot cleaned up"
}
