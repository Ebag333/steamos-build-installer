#!/bin/bash
#
# steamos-build-installer — lib/optimizations/common.sh
# Shared utilities for optimization modules.
# Provides mode detection and common helpers for applying optimizations
# across different contexts: chroot (build or rebuild) or live system.
#
# Sourced by optimization modules — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/common.sh is a library — source it from optimization modules, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Mode Detection
# ---------------------------------------------------------------------------
# Detects the current operating context and sets OPT_MODE and OPT_ROOT.
#
# Modes:
#   chroot - Mounted target rootfs (build-time image or self-heal rebuild)
#   live   - Running system (post-install or direct execution)
#
# Override with environment variables:
#   OPT_MODE - Force mode (chroot|live)
#   OPT_ROOT - Force root path (defaults to auto-detected)

detect_mode() {
  # If already set by caller, respect it
  if [[ -n "${OPT_MODE:-}" ]]; then
    _resolve_root
    return 0
  fi

  # Auto-detect based on environment indicators.
  # Any mounted target rootfs (build or rebuild) is chroot.
  if [[ "${IN_CHROOT:-0}" == "1" ]] \
    || [[ -n "${MERGED:-}" && -d "$MERGED" ]] \
    || [[ -n "${NEWROOT:-}" && -d "$NEWROOT" ]] \
    || [[ -n "${PARTSET:-}" ]] \
    || [[ "${REBUILD:-0}" == "1" ]] \
    || [[ -f /.dockerenv ]] \
    || grep -q 'overlay.*overlay' /proc/mounts 2>/dev/null; then
    OPT_MODE="chroot"
    _resolve_root
    return 0
  fi

  # Default to live system
  OPT_MODE="live"
  _resolve_root
  return 0
}

# Resolve the root filesystem path based on mode
_resolve_root() {
  # If already set by caller, respect it
  if [[ -n "${OPT_ROOT:-}" ]]; then
    return 0
  fi

  case "${OPT_MODE:-live}" in
    chroot)
      # Mounted target rootfs — try common paths in priority order
      if [[ -n "${MERGED:-}" && -d "$MERGED" ]]; then
        OPT_ROOT="$MERGED"
      elif [[ -n "${NEWROOT:-}" && -d "$NEWROOT" ]]; then
        OPT_ROOT="$NEWROOT"
      elif [[ -n "${MNT:-}" && -d "$MNT" ]]; then
        OPT_ROOT="$MNT"
      else
        OPT_ROOT="/"
      fi
      ;;
    live)
      OPT_ROOT="/"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Context Helpers
# ---------------------------------------------------------------------------

# Check if running in a chroot environment (build or rebuild)
is_chroot() {
  [[ "${OPT_MODE:-}" == "chroot" ]]
}

# Check if running on a live system
is_live() {
  [[ "${OPT_MODE:-}" == "live" ]]
}

# Get the appropriate root path
get_root() {
  echo "${OPT_ROOT:-/}"
}

# ---------------------------------------------------------------------------
# Kernel Parameter Helpers
# ---------------------------------------------------------------------------

# Persist a kernel parameter to grub-steamos on live systems.
# On chroot, this is a no-op — the pipeline flushes params later.
# Usage: _persist_kernel_param_live PARAM
_persist_kernel_param_live() {
  local param="$1"

  is_live || return 0

  local grub_steamos="/etc/default/grub-steamos"
  if [[ ! -f "$grub_steamos" ]]; then
    warn "grub-steamos not found — cannot persist $param"
    return 1
  fi

  # Check if already present
  if grep -qF "$param" "$grub_steamos" 2>/dev/null; then
    return 0
  fi

  # Append to GRUB_CMDLINE_LINUX
  if sed -i "/^GRUB_CMDLINE_LINUX=/s/\"$/ $param\"/" "$grub_steamos"; then
    log "Persisted $param to grub-steamos"
    # Regenerate grub.cfg if update-grub is available
    if command -v update-grub &>/dev/null; then
      update-grub &>/dev/null || warn "update-grub failed — param saved but not active until next boot"
    elif command -v grub-mkconfig &>/dev/null; then
      grub-mkconfig -o /boot/grub/grub.cfg &>/dev/null || warn "grub-mkconfig failed — param saved but not active until next boot"
    fi
  else
    warn "Failed to persist $param to grub-steamos"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Command Execution Helpers
# ---------------------------------------------------------------------------
# These helpers abstract the differences between chroot and live
# execution contexts.

# Run a command in the target root context
# Usage: run_in_root COMMAND [ARGS...]
run_in_root() {
  local root
  root="$(get_root)"

  if [[ "$root" == "/" ]]; then
    # Live system or already at root
    "$@"
  elif [[ -n "${MERGED:-}" ]]; then
    # Build-time chroot with MERGED overlay
    chroot "$MERGED" /bin/bash -c "$*"
  else
    # Mounted rootfs (build or rebuild)
    chroot "$root" /bin/bash -c "$*"
  fi
}

# Remove a file from the target root
# Usage: remove_file PATH
# Returns 0 on success, 1 on failure
remove_file() {
  local filepath="$1"
  local root
  root="$(get_root)"
  local fullpath="${root}${filepath}"

  if [[ -e "$fullpath" ]]; then
    if rm -f "$fullpath"; then
      log "Removed $filepath"
      return 0
    else
      warn "Failed to remove $filepath"
      return 1
    fi
  else
    # File doesn't exist, consider success (idempotent)
    return 0
  fi
}

# Copy a file into the target root
# Usage: install_file SOURCE DEST_PATH [MODE]
install_file() {
  local source="$1"
  local dest="$2"
  local mode="${3:-}"
  local root
  root="$(get_root)"
  local fullpath="${root}${dest}"

  if [[ ! -f "$source" ]]; then
    warn "Source file not found: $source"
    return 1
  fi

  # Ensure destination directory exists
  mkdir -p "$(dirname "$fullpath")"

  if cp "$source" "$fullpath"; then
    [[ -n "$mode" ]] && chmod "$mode" "$fullpath"
    log "Installed $dest"
    return 0
  else
    warn "Failed to install $dest"
    return 1
  fi
}

# Create a symlink in the target root
# Usage: create_symlink TARGET LINK_PATH
create_symlink() {
  local target="$1"
  local linkpath="$2"
  local root
  root="$(get_root)"
  local fullpath="${root}${linkpath}"

  # Ensure parent directory exists
  mkdir -p "$(dirname "$fullpath")"

  if ln -sf "$target" "$fullpath"; then
    log "Created symlink $linkpath -> $target"
    return 0
  else
    warn "Failed to create symlink $linkpath -> $target"
    return 1
  fi
}

# Enable a systemd service in the target root
# Usage: enable_service SERVICE_NAME
enable_service() {
  local service="$1"
  local root
  root="$(get_root)"

  if is_live; then
    systemctl enable "$service" 2>/dev/null
  else
    # For chroot, create the symlink manually
    local wants_dir="${root}/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$wants_dir"
    create_symlink "/usr/lib/systemd/system/$service" "$wants_dir/$service"
  fi
}

# ---------------------------------------------------------------------------
# Boot Framework Helpers
# ---------------------------------------------------------------------------
# The steam-perf boot framework runs hooks at boot time via systemd.
# Shared by gpu-power-limit and cpu-performance optimizations.

# Install the boot framework and specified hooks.
# Usage: install_boot_framework HOOK [HOOK...]
#   HOOK - Hook filename(s) to install (e.g. "20-nvidia-gpu", "30-cpu")
#
# The framework includes:
#   - /usr/lib/steam-perf/apply-boot (runner)
#   - /usr/lib/steam-perf/boot.d/ (hook directory)
#   - /etc/steam-perf/config.conf (configuration)
#   - /usr/lib/systemd/system/steam-perf.service (systemd unit)
#
# Returns 0 on success, 1 on failure.

install_boot_framework() {
  local hooks=("$@")
  local root
  root="$(get_root)"

  # Determine source directory (configs/boot relative to project root)
  local boot_src
  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    boot_src="$SCRIPT_DIR/lib/configs/boot"
  elif [[ -n "${CUSTOMIZATION_DIR:-}" ]]; then
    boot_src="$(dirname "$CUSTOMIZATION_DIR")/configs/boot"
  else
    warn "Cannot determine boot config source directory"
    return 1
  fi

  log "Installing steam-perf boot framework"

  # Install framework files
  if ! install_file "$boot_src/apply-boot" "/usr/lib/steam-perf/apply-boot" 755; then
    return 1
  fi

  if ! install_file "$boot_src/config.conf" "/etc/steam-perf/config.conf"; then
    return 1
  fi

  # Install requested hooks
  local hook
  for hook in "${hooks[@]}"; do
    if [[ -f "$boot_src/$hook" ]]; then
      if ! install_file "$boot_src/$hook" "/usr/lib/steam-perf/boot.d/$hook" 755; then
        return 1
      fi
    else
      warn "Boot hook not found: $hook"
      return 1
    fi
  done

  # Install and enable systemd service
  if ! install_file "$boot_src/steam-perf.service" "/usr/lib/systemd/system/steam-perf.service"; then
    return 1
  fi

  if ! enable_service "steam-perf.service"; then
    warn "Failed to enable steam-perf.service (non-fatal)"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Logging Integration
# ---------------------------------------------------------------------------
# These functions delegate to the parent script's logging functions if available,
# otherwise use basic fallbacks.
# We save the original functions first to avoid recursion.

# Save original functions if they exist
if [[ "$(type -t log)" == "function" ]]; then
  eval "$(declare -f log | sed '1s/^log/_original_log/')"
fi
if [[ "$(type -t warn)" == "function" ]]; then
  eval "$(declare -f warn | sed '1s/^warn/_original_warn/')"
fi

log() {
  if declare -F _opt_log >/dev/null 2>&1; then
    _opt_log "$@"
  elif declare -F _original_log >/dev/null 2>&1; then
    _original_log "$@"
  else
    printf '[optimizations] %s\n' "$*"
  fi
}

warn() {
  if declare -F _opt_warn >/dev/null 2>&1; then
    _opt_warn "$@"
  elif declare -F _original_warn >/dev/null 2>&1; then
    _original_warn "$@"
  else
    printf '[optimizations] WARNING: %s\n' "$*" >&2
  fi
}

# Initialize mode detection on source
detect_mode
