
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

  _cleanup_stale_workspace_processes || return
  _cleanup_primary_overlay || return
  _cleanup_effective_etc_mounts || return
  _cleanup_rootfs_helper_mounts || return
  _cleanup_output_image_loops || return
  _cleanup_project_mounts || return
  _remove_incomplete_output || return
  _cleanup_overlay_directories || return
  _verify_no_stale_loops || return
  _cleanup_stale_build_roots || return
}

_cleanup_stale_workspace_processes() {
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
}

_cleanup_primary_overlay() {
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
}

_cleanup_effective_etc_mounts() {
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
}

_cleanup_rootfs_helper_mounts() {
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
}

_cleanup_output_image_loops() {
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
}

_cleanup_project_mounts() {
  # ============================================================
  # 3. Explicit project mountpoints.
  # ============================================================
  _stale_rc=0
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
}

_remove_incomplete_output() {
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
}

_cleanup_overlay_directories() {
  # ============================================================
  # 5. Remove host-side scratch residue only after proving it is unmounted.
  # ============================================================
  for m in "$MERGED" "$UPPER" "$OVLWORK"; do
    [[ -n "$m" && -e "$m" ]] || continue
    if ! safe_rmdir "$m"; then
      die "Refusing to remove stale directory with active mounts: $m"
    fi
  done
}

_verify_no_stale_loops() {
  # ============================================================
  # 6. Clean up stale build root overlays from previous runs.
  # ============================================================
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
