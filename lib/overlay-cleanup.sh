
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
