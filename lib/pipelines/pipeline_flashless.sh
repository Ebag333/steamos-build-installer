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
  define_pipeline "detect" "extract" "deploy" "configure" "activate"
  register_phase "detect"    "_phase_flashless_detect"    "Detect slots and run preflight checks"
  register_phase "extract"   "_phase_flashless_extract"   "Extract source image and check sizes"
  register_phase "deploy"    "_phase_flashless_deploy"    "Format target, write rootfs, verify partsets"
  register_phase "configure" "_phase_flashless_configure" "Restore etc, rebuild boot, restore read-only"
  register_phase "activate"  "_phase_flashless_activate"  "Verify final state and activate slot"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

register_flashless_cleanup() {
  trap '_flashless_cleanup' EXIT
}

_flashless_cleanup() {
  rm -f "${FL_UDEV_RULE:-}" 2>/dev/null
  udevadm control --reload-rules 2>/dev/null || true
  cleanup_environment 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Phase Implementations
# ---------------------------------------------------------------------------

# Phase: detect — detect slots and run preflight checks
_phase_flashless_detect() {
  stage_header "preparing & validating"
  _flashless_detect_slots

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
  stage_header "extracting source image"
  _flashless_extract_image "$IMG"
  _flashless_check_sizes
  return 0
}

# Phase: deploy — format target, write rootfs, detach source, verify partsets
_phase_flashless_deploy() {
  stage_header "deploying image to target"
  _flashless_format_target
  _flashless_write_rootfs

  # Detach source image — its partitions may be competing with
  # /dev/disk/by-partsets.  Must succeed; if detach fails, abort.
  strict_detach_loop "$FL_IMG_LOOP"
  FL_IMG_LOOP=""

  udevadm trigger --action=change \
    "$FL_TARGET_ROOTFS" \
    "$FL_TARGET_EFI" \
    "$FL_TARGET_VAR" \
    || { warn "Could not retrigger udev for target partitions"; return 1; }

  udevadm settle --timeout=10 \
    || { warn "udev did not settle after source loop detach"; return 1; }

  _flashless_verify_partsets
  return 0
}

# Phase: configure — restore /etc, rebuild boot, restore read-only
_phase_flashless_configure() {
  stage_header "configuring target system"
  _flashless_restore_etc
  _flashless_rebuild_boot
  _flashless_restore_rootfs_ro
  return 0
}

# Phase: activate — verify final state and activate slot
_phase_flashless_activate() {
  stage_header "verification & activation"
  _flashless_verify_final
  _flashless_activate_slot
  return 0
}
