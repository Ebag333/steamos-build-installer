#!/bin/bash
#
# steamos-build-installer — lib/optimizations/common.sh
# Shared utilities for optimization modules.
# Provides common helpers for applying optimizations
# across different contexts: chroot (build or rebuild) or live system.
#
# Sourced by optimization modules — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/optimizations/common.sh is a library — source it from optimization modules, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Context Helpers
# ---------------------------------------------------------------------------

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
# Usage: persist_kernel_param_live PARAM
persist_kernel_param_live() {
  local param="$1"

  if [[ -z "$param" ]]; then
    warn "persist_kernel_param_live called with empty parameter"
    return 1
  fi

  is_live || return 0

  local grub_steamos="/etc/default/grub-steamos"
  if [[ ! -f "$grub_steamos" ]]; then
    warn "grub-steamos not found — cannot persist $param"
    return 1
  fi

  # Check if already present — multiline-aware.
  # SteamOS grub-steamos uses continuation lines (\) for GRUB_CMDLINE_LINUX,
  # so a simple grep on the first line can silently miss params that appear
  # on subsequent lines.  Join the full value before checking.
  local full_value="" in_block=0 line
  while IFS="" read -r line; do
    if [[ "$line" =~ ^GRUB_CMDLINE_LINUX= ]]; then
      in_block=1
      line="${line#GRUB_CMDLINE_LINUX=\"}"
    elif [[ $in_block -eq 0 ]]; then
      continue
    fi
    if [[ $in_block -eq 1 ]]; then
      if [[ "$line" == *\\ ]]; then
        line="${line%\\}"
        full_value+="$line "
      else
        line="${line%\"*}"
        line="${line%"${line##*[![:space:]]}"}"
        full_value+="$line"
        break
      fi
    fi
  done <"$grub_steamos"

  # Exact token match — avoids false positives from substring matching
  # (e.g. "foo=1" must not match "foo=10").
  local haystack=" $full_value "
  if [[ "$haystack" == *" $param "* ]]; then
    return 0
  fi

  # Append to GRUB_CMDLINE_LINUX preserving multiline structure.
  # Use awk to find the closing-quote line and insert the new param
  # before it with proper continuation.
  awk -v param="$param" '
    /^GRUB_CMDLINE_LINUX=/ {
      line = $0
      sub(/^GRUB_CMDLINE_LINUX="/, "", line)
      # Single-line: remainder does NOT end with \ (closing quote is here).
      if (line !~ /\\[[:space:]]*$/) {
        sub(/[[:space:]]*"$/, "", line)   # strip closing quote
        if (line != "") {
          print "GRUB_CMDLINE_LINUX=\"" line " \\"
        } else {
          print "GRUB_CMDLINE_LINUX=\"${GRUB_CMDLINE_LINUX} \\"
        }
        print "  " param "\""
        in_block = 0
      } else {
        # Multiline: continuation lines follow
        in_block = 1
        print
      }
      next
    }
    in_block && !/\\[[:space:]]*$/ {
      # Closing-quote line (no trailing \)
      line = $0
      sub(/[[:space:]]*"$/, "", line)
      if (line != "") {
        print line " \\"
      }
      print "  " param "\""
      in_block = 0
      next
    }
    in_block && /\\[[:space:]]*$/ {
      # Continuation line — pass through
      print
      next
    }
    { print }
  ' "$grub_steamos" >"$grub_steamos.tmp" && mv "$grub_steamos.tmp" "$grub_steamos"

  log "Persisted $param to grub-steamos"
  # Regenerate grub.cfg if update-grub is available
  if command -v update-grub &>/dev/null; then
    update-grub &>/dev/null || warn "update-grub failed — param saved but not active until next boot"
  elif command -v grub-mkconfig &>/dev/null; then
    grub-mkconfig -o /boot/grub/grub.cfg &>/dev/null || warn "grub-mkconfig failed — param saved but not active until next boot"
  fi
}

# ---------------------------------------------------------------------------
# Command Execution Helpers
# ---------------------------------------------------------------------------
# These helpers abstract the differences between chroot and live
# execution contexts.

# Validate that a path is absolute and contains no traversal segments.
# Usage: _validate_path DESCRIPTION PATH
# Returns 0 if valid, 1 (with warning) if invalid.
_validate_path() {
  local desc="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    warn "${desc}: path is empty"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    warn "${desc}: path must be absolute, got: $path"
    return 1
  fi
  if [[ "$path" == *".."* ]]; then
    warn "${desc}: path must not contain '..' traversal, got: $path"
    return 1
  fi
  return 0
}

# Run a command in the target root context
# Usage: run_in_root COMMAND [ARGS...]
run_in_root() {
  local root
  root="$(get_root)"

  if [[ "$root" == "/" ]]; then
    "$@"
  else
    local cmd
    printf -v cmd '%q ' "$@"
    chroot "$root" /bin/bash -c "$cmd"
  fi
}

# Remove a file from the target root
# Usage: remove_file PATH
# Returns 0 on success, 1 on failure
remove_file() {
  local filepath="$1"
  if ! _validate_path "remove_file" "$filepath"; then
    return 1
  fi
  local root
  root="$(get_root)"
  local fullpath="${root}${filepath}"

  if [[ -e "$fullpath" ]]; then
    if rm -f -- "$fullpath"; then
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
  if ! _validate_path "install_file" "$dest"; then
    return 1
  fi
  local root
  root="$(get_root)"
  local fullpath="${root}${dest}"

  if [[ ! -f "$source" ]]; then
    warn "Source file not found: $source"
    return 1
  fi

  # Ensure destination directory exists
  if ! mkdir -p -- "$(dirname "$fullpath")"; then
    warn "Failed to create directory for $dest"
    return 1
  fi

  if cp -- "$source" "$fullpath"; then
    if [[ -n "$mode" ]]; then
      if ! chmod "$mode" "$fullpath"; then
        warn "Failed to set mode $mode on $dest"
        return 1
      fi
    fi
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
  if ! _validate_path "create_symlink" "$linkpath"; then
    return 1
  fi
  local root
  root="$(get_root)"
  local fullpath="${root}${linkpath}"

  # Ensure parent directory exists
  if ! mkdir -p -- "$(dirname "$fullpath")"; then
    warn "Failed to create directory for symlink"
    return 1
  fi

  if ln -sfn -- "$target" "$fullpath"; then
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
    if ! systemctl enable "$service" 2>&1; then
      warn "Failed to enable $service"
      return 1
    fi
  else
    # For chroot, create the symlink manually
    local wants_dir="${root}/etc/systemd/system/multi-user.target.wants"
    if ! mkdir -p -- "$wants_dir"; then
      warn "Failed to create $wants_dir"
      return 1
    fi
    if ! create_symlink "/usr/lib/systemd/system/$service" "/etc/systemd/system/multi-user.target.wants/$service"; then
      warn "Failed to enable $service in chroot"
      return 1
    fi
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
  if [[ $# -eq 0 ]]; then
    warn "install_boot_framework called with no hooks"
    return 1
  fi
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
    if [[ "$hook" == *..* || "$hook" == /* || "$hook" == */* ]]; then
      warn "Invalid hook name (must be a bare filename): $hook"
      return 1
    fi
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
    warn "Failed to enable steam-perf.service"
    return 1
  fi

  # Live mode: reload systemd
  if is_live; then
    systemctl daemon-reload 2>/dev/null || true
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

log() { # lint-ignore: no-shadow
  if declare -F _opt_log >/dev/null 2>&1; then
    _opt_log "$@"
  elif declare -F _original_log >/dev/null 2>&1; then
    _original_log "$@"
  else
    printf '[optimizations] %s\n' "$*"
  fi
}

warn() { # lint-ignore: no-shadow
  if declare -F _opt_warn >/dev/null 2>&1; then
    _opt_warn "$@"
  elif declare -F _original_warn >/dev/null 2>&1; then
    _original_warn "$@"
  else
    printf '[optimizations] WARNING: %s\n' "$*" >&2
  fi
}
