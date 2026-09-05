#!/bin/bash
#
# steamos-build-installer — lib/pipelines/pipeline_live.sh
# Live workflow pipeline definition.
# Defines the sequential phases for configuring a running or offline SteamOS system.
#
# Sourced by the pipeline dispatcher — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pipelines/pipeline_live.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

register_live_pipeline() {
  define_pipeline \
    "validate" \
    "prepare" \
    "preflight" \
    "sysupgrade" \
    "install" \
    "configure" \
    "verify"

  register_phase "validate" "phase_live_validate" "Validate target system"
  register_phase "prepare" "phase_live_prepare" "Prepare system for changes"
  register_phase "preflight" "phase_live_preflight" "Run preflight safety checks"
  register_phase "sysupgrade" "phase_live_sysupgrade" "System upgrade (pacman -Syu)"
  register_phase "install" "phase_live_install" "Install drivers and packages"
  register_phase "configure" "phase_live_configure" "Configure system"
  register_phase "verify" "phase_live_verify" "Verify and cleanup"
}

phase_live_validate() {
  stage_header "preparation"
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    warn "Live configuration requires root privileges"
    return 1
  fi

  if [[ -n "${config_root:-}" && "$config_root" != "/" ]]; then
    if [[ ! -d "$config_root" ]]; then
      warn "Target root not found: $config_root"
      return 1
    fi
    if [[ ! -f "$config_root/etc/os-release" ]]; then
      warn "Target doesn't look like a rootfs: $config_root"
      return 1
    fi
  fi

  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
  fi

  # Log condensed configuration
  if [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]]; then
    log "Live config: $CONFIG_FILE"
  else
    log "Live config: (defaults — no config file)"
  fi

  local _hw_count=0 _nvidia="no"
  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
    # shellcheck disable=SC2206
    local _hw_array=($HW_SUPPORT_ITEMS)
    _hw_count=${#_hw_array[@]}
    for _item in "${_hw_array[@]}"; do
      case "$_item" in
        nvidia* | *-nvidia*) _nvidia="yes" ;;
      esac
    done
  fi

  log "Live configuration:"
  log "  variant:        ${TARGET_VARIANT:-steamdeck}"
  log "  update branch:  ${UPDATE_BRANCH:-stable}"
  log "  pacman repo:    ${PACMAN_REPO:-valve}"
  log "  session:        ${DEFAULT_SESSION:-game}"
  log "  update mode:    ${UPDATE_MODE:-selfheal}"
  log "  base OS mode:   ${BASE_OS_MODE:-additive}"
  log "  hardware items: ${_hw_count} selected"
  log "  NVIDIA:         ${_nvidia}"

  # Validate session
  case "${DEFAULT_SESSION:-}" in
    "" | desktop | game) ;;
    *)
      warn "Invalid session: $DEFAULT_SESSION"
      return 1
      ;;
  esac

  # Validate update mode
  case "${UPDATE_MODE:-selfheal}" in
    selfheal | hold | stock) ;;
    *)
      warn "Invalid update mode: $UPDATE_MODE"
      return 1
      ;;
  esac

  # Validate base OS mode
  case "${BASE_OS_MODE:-additive}" in
    additive | upgrade) ;;
    *)
      warn "Invalid base OS mode: $BASE_OS_MODE"
      return 1
      ;;
  esac

  # Derive build-flag items from GAMING_ITEMS
  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    [[ " $GAMING_ITEMS " == *" fix-keyring "* ]] && export FIX_KEYRING=1
    [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] && export SKIP_SIG=1
  fi

  return 0
}

phase_live_prepare() {
  if [[ -z "${config_root:-}" || "${config_root:-}" == "/" ]]; then
    disable_steamos_readonly
  else
    ensure_rootfs_writable "$config_root"
  fi

  set_user_password

  return 0
}

# Phase: Run preflight safety checks
phase_live_preflight() {
  stage_header "preflight"

  local root="${config_root:-/}"

  # Discover current slot
  local current_slot=""
  if command -v steamos-bootconf &>/dev/null; then
    current_slot="$(steamos-bootconf this-image 2>/dev/null)" || current_slot=""
  fi

  # Discover ESP mount point
  local esp_mount=""
  if [[ -n "$current_slot" && -e "/dev/disk/by-partsets/$current_slot/esp" ]]; then
    local esp_dev
    esp_dev="$(readlink -f "/dev/disk/by-partsets/$current_slot/esp" 2>/dev/null)" || esp_dev=""
    if [[ -n "$esp_dev" ]]; then
      esp_mount="$(findmnt -rnmo TARGET -S "$esp_dev" 2>/dev/null | head -1)" || esp_mount=""
    fi
  fi

  preflight_validate \
    --scenario "live" \
    --rootfs "$root" \
    --efi "/efi" \
    --esp "$esp_mount" \
    --slot "${current_slot:-}" \
    --variant "${TARGET_VARIANT:-}"

  return 0
}

phase_live_sysupgrade() {
  stage_header "system update"
  local root="${config_root:-/}"

  # Only run system upgrade if base OS mode is "upgrade" (matches build behavior)
  if [[ "${BASE_OS_MODE:-additive}" != "upgrade" ]]; then
    log "Skipping system upgrade (BASE_OS_MODE=${BASE_OS_MODE:-additive})"
    return 0
  fi

  step "System upgrade"
  log "Base OS mode: upgrade"
  log "Running full system upgrade (pacman -Syu)"

  # For live systems, we need to handle the root differently
  if [[ "$root" == "/" ]]; then
    # Running on the live system itself
    log "Running system upgrade on live system"
    if [[ "${PREFLIGHT:-1}" -eq 1 ]]; then
      if pacman_upgrade_preflight "System upgrade" --host; then
        pacman_upgrade_all || warn "System upgrade failed (non-fatal)"
      fi
    else
      warn "Pre-flight: skipped (PREFLIGHT=0) — proceeding without conflict checks"
      pacman_upgrade_all || warn "System upgrade failed (non-fatal)"
    fi
  else
    # Offline target - use system upgrade functions
    MNT="$root"
    system_upgrade_prepare

    local _upgrade_ok=0 _attempt
    for _attempt in 1 2 3; do
      if system_upgrade; then
        _upgrade_ok=1
        break
      fi
      warn "System upgrade attempt $_attempt failed"
      sleep "$((_attempt * 2))"
    done

    if ((_upgrade_ok)); then
      log "System upgrade completed successfully"
    else
      die "System upgrade failed after retries"
    fi

    system_upgrade_cleanup
  fi

  progress_emit sysupgrade

  return 0
}

phase_live_install() {
  stage_header "driver installation"
  local root="${config_root:-/}"

  install_hw_libs

  local all_items
  all_items="$(get_all_customization_items)"
  if [[ -n "$all_items" ]]; then
    apply_customizations "$all_items" "live" "$root"
  fi

  local _saved_mnt="${MNT:-}"
  MNT="$root"
  configure_update_channel
  MNT="$_saved_mnt"

  return 0
}

phase_live_configure() {
  local root="${config_root:-/}"

  reconcile_initramfs "$root" "$(uname -r)" "${INITRAMFS_MODULES:-}"
  if nvidia_is_selected; then
    enable_nvidia_power_services "$root"
    install_nvidia_modprobe_conf "$root"
  else
    log "Skipping nvidia power services and modprobe config (nvidia not selected)"
  fi

  if [[ -n "${DEFAULT_SESSION:-}" ]]; then
    configure_desktop_session "$root" "$DEFAULT_SESSION"
  fi

  run_custom_script "$root"
  ensure_project_persisted

  return 0
}

phase_live_verify() {
  stage_header "finalization"
  local root="${config_root:-/}"

  cleanup_disk_space "${config_root:-/}" "live"

  if [[ "$root" != "/" ]]; then
    _regenerate_initramfs "$root"
  fi

  if [[ -z "${config_root:-}" || "${config_root:-}" == "/" ]]; then
    enable_steamos_readonly
  fi

  return 0
}
