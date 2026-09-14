#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_flashless.sh
# Flashless pipeline — installs a SteamOS image to inactive partitions.
#
# Sourced by backend.sh — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_flashless.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pipeline Definition
# ---------------------------------------------------------------------------

register_flashless_pipeline() {
  _PIPELINE_NAME="flashless"
  define_pipeline "detect" "extract" "deploy" "configure" "activate"
  register_phase "detect" "_phase_flashless_detect" "Detect slots and run preflight checks" "preparing & validating"
  register_phase "extract" "_phase_flashless_extract" "Extract source image and check sizes" "extracting source image"
  register_phase "deploy" "_phase_flashless_deploy" "Format target, write rootfs, verify partsets" "deploying image to target"
  register_phase "configure" "_phase_flashless_configure" "Restore etc, rebuild boot, restore read-only" "configuring target system"
  register_phase "activate" "_phase_flashless_activate" "Verify final state and activate slot" "verification & activation"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

register_flashless_cleanup() {
  trap '_flashless_cleanup' EXIT
}

_flashless_cleanup() {
  log_debug pipeline cleanup "_flashless_cleanup: start"
  if [[ -n "${FL_UDEV_RULE:-}" ]]; then
    log "_flashless_cleanup: removing udev rule $FL_UDEV_RULE"
    rm -f "$FL_UDEV_RULE" 2>/dev/null
  else
    log_debug pipeline cleanup "_flashless_cleanup: FL_UDEV_RULE is unset; nothing to remove"
  fi
  log "_flashless_cleanup: reloading host udev rules (udevadm control --reload-rules)"
  if ! run_dangerous_cmd udevadm control --reload-rules 2>/dev/null; then
    warn "_flashless_cleanup: udevadm control --reload-rules failed"
  fi
  cleanup_environment 2>/dev/null || true
  log_debug pipeline cleanup "_flashless_cleanup: done"
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: detect — detect slots and run preflight checks
_phase_flashless_detect() {
  flashless_detect_slots

  preflight_validate \
    --scenario "flashless" \
    --rootfs "/" \
    --efi "" \
    --esp "" \
    --slot "$FL_TARGET" \
    --variant "${TARGET_VARIANT:-}"

  return 0
}

# Phase: extract — extract source image and check sizes
_phase_flashless_extract() {
  flashless_extract_image "$IMG"
  flashless_check_sizes
  return 0
}

# Phase: deploy — format target, write rootfs, detach source, verify partsets
_phase_flashless_deploy() {
  flashless_format_target
  flashless_write_rootfs

  # Detach source image — its partitions may be competing with
  # /dev/disk/by-partsets.  Must succeed; if detach fails, abort.
  strict_detach_loop "$FL_IMG_LOOP"
  FL_IMG_LOOP=""

  log "flashless: triggering udev for partition devices (udevadm trigger --action=change ${FL_TARGET_ROOTFS:-} ${FL_TARGET_EFI:-} ${FL_TARGET_VAR:-})"
  run_dangerous_cmd udevadm trigger --action=change \
    "$FL_TARGET_ROOTFS" \
    "$FL_TARGET_EFI" \
    "$FL_TARGET_VAR" \
    || {
      warn "Could not retrigger udev for target partitions"
      return 1
    }

  log "flashless: waiting for udev events to settle (udevadm settle --timeout=10)"
  run_dangerous_cmd udevadm settle --timeout=10 \
    || {
      warn "udev did not settle after source loop detach"
      return 1
    }

  flashless_verify_partsets
  return 0
}

# Phase: configure — restore /etc, rebuild boot, restore read-only
_phase_flashless_configure() {
  flashless_restore_etc
  flashless_rebuild_boot
  flashless_restore_rootfs_ro
  return 0
}

# Phase: activate — verify final state and activate slot
_phase_flashless_activate() {
  flashless_verify_final
  flashless_activate_slot
  return 0
}
