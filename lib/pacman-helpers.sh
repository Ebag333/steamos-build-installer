#!/bin/bash
#
# steamos-build-installer — lib/pacman-helpers.sh
# Standardized pacman operations with consistent config, context, and error handling.
#
# Sourced by other libraries — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/pacman-helpers.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Internal: Resolve pacman config for the current context.
#
# Priority:
#   1. Explicit --config passed by caller
#   2. PACCONF global (set by setup_pacman_conf)
#   3. system default config file
#   4. System default (no --config)
#
# Args: $1 = optional explicit config path
# Prints: config args string (--config PATH) or empty
# ---------------------------------------------------------------------------
_pacman_resolve_config() {
  local explicit="${1:-}"

  if [[ -n "$explicit" ]]; then
    printf -- "--config '%s'\n" "$explicit"
    return
  fi

  if [[ -n "${PACCONF:-}" ]]; then
    printf -- "--config '%s'\n" "$PACCONF"
    return
  fi

  # No config — use system default
  echo ""
}

# ---------------------------------------------------------------------------
# Internal: Query installed packages and return --ignore argument to freeze them.
#
# Used in additive mode to prevent upgrading already-installed packages.
#
# Args: $1 = context ("chroot" | "host" | "auto")
# Prints: --ignore pkg1,pkg2,... or empty string on failure
# ---------------------------------------------------------------------------
_pacman_frozen_installed_args() {
  local context="${1:-auto}"
  local installed_pkgs=""

  installed_pkgs=$(_pacman_exec "$context" "pacman -Qq 2>/dev/null") || return 1

  if [[ -z "$installed_pkgs" ]]; then
    return 1
  fi

  local ignore_list
  ignore_list=$(echo "$installed_pkgs" | paste -sd, -)
  printf -- '--ignore %s' "$ignore_list"
}

# ---------------------------------------------------------------------------
# Internal: Execute pacman in the correct context.
#
# Handles chroot vs host execution based on _is_install_chroot or explicit flag.
#
# Args: $1 = "chroot" | "host" | "" (auto-detect)
#       $2... = command to run
# Returns: pacman's exit code
# ---------------------------------------------------------------------------
_pacman_exec() {
  local context="${1:-auto}"
  shift

  case "$context" in
    chroot)
      chroot "$MERGED" /bin/bash -c "$*"
      ;;
    host)
      /bin/bash -c "$*"
      ;;
    auto | *)
      if _is_install_chroot 2>/dev/null; then
        chroot "$MERGED" /bin/bash -c "$*"
      else
        /bin/bash -c "$*"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Detect whether we can interact with the user.
#
# Returns 0 (true) if stdin and stdout are both terminals, or if the
# STEAMOS_INSTALLER_INTERACTIVE env var is set to 1.
# Returns 1 (false) otherwise (background / repatch context).
# ---------------------------------------------------------------------------
_is_interactive() {
  [[ "${STEAMOS_INSTALLER_INTERACTIVE:-0}" == "1" ]] && return 0
  [[ -t 0 ]] && [[ -t 1 ]]
}

# ---------------------------------------------------------------------------
# Sync package databases.
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_sync_db() {
  local config="" context="auto" noconfirm="--noconfirm" root=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --root)
        context="root"
        root="$2"
        shift 2
        ;;
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  log "Syncing package databases"
  local sync_rc=0
  local _raw_log="${PACMAN_RAW_LOG:-/dev/null}"
  # shellcheck disable=SC2086 # word-splitting is intentional
  case "$context" in
    root)
      _pacman_retry _pacman_run_in_root "$root" "pacman $config_args -Sy $noconfirm" \
        > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
        2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2) || sync_rc=$?
      ;;
    *)
      _pacman_retry _pacman_exec "$context" "pacman $config_args -Sy $noconfirm" \
        > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
        2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2) || sync_rc=$?
      ;;
  esac

  if ((sync_rc != 0)); then
    warn "Failed to sync package databases (rc=$sync_rc)"
    return 1
  fi

  log "Syncing file databases"
  # shellcheck disable=SC2086 # word-splitting is intentional
  case "$context" in
    root)
      _pacman_retry _pacman_run_in_root "$root" "pacman $config_args -Fy $noconfirm" \
        > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
        2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
      ;;
    *)
      _pacman_retry _pacman_exec "$context" "pacman $config_args -Fy $noconfirm" \
        > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
        2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Full system sync and upgrade.
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#   --ask NUM        Override --ask value (default: 4)
#   --extra FLAGS    Extra flags appended to pacman command (e.g. --overwrite)
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_upgrade_all() {
  local config="" context="auto" noconfirm="--noconfirm" ask="--ask=4" extra=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      --ask)
        ask="--ask=$2"
        shift 2
        ;;
      --extra)
        extra="$2"
        shift 2
        ;;
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  log "Running full system upgrade"
  local _raw_log="${PACMAN_RAW_LOG:-/dev/null}"
  # shellcheck disable=SC2086 # extra is intentionally word-split
  set -o pipefail
  _pacman_retry _pacman_exec "$context" "pacman $config_args -Syu $noconfirm $ask $extra" \
    > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
    2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
  local _rc=${PIPESTATUS[0]}
  set +o pipefail
  if ((_rc != 0)); then
    warn "Pacman failed (exit $_rc); raw output (last 100 lines):"
    tail -100 "$_raw_log" >&2
  fi
  return "$_rc"
}

# ---------------------------------------------------------------------------
# Internal: Execute a pacman command with retry logic (3 attempts, exponential backoff).
#
# Args: "$@" = the command to execute
# Returns: 0 on success, 1 if all attempts fail
# ---------------------------------------------------------------------------
_pacman_retry() {
  local _attempt _ok=0
  for _attempt in 1 2 3; do
    if "$@"; then
      _ok=1
      break
    fi
    warn "${FUNCNAME[1]}: attempt $_attempt/3 failed"
    ((_attempt < 3)) && sleep "$((_attempt * 2))"
  done
  ((_ok)) || return 1
}

# ---------------------------------------------------------------------------
# Install packages from repos.
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#   --needed         Only install if not already installed (default)
#   --no-needed      Reinstall even if already installed
#   --yes            Pipe yes to handle conflict prompts
#   --cachedir PATH  Override package cache directory
#   --freeze-installed  Freeze already-installed packages (additive mode)
#   --               End of options; remaining args are package names
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_install() {
  local config="" context="auto" noconfirm="--noconfirm" needed="--needed" cachedir="" yes_prefix="" freeze_installed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      --needed)
        needed="--needed"
        shift
        ;;
      --no-needed)
        needed=""
        shift
        ;;
      --yes)
        yes_prefix="yes | "
        noconfirm=""
        shift
        ;;
      --cachedir)
        cachedir="--cachedir '$2'"
        shift 2
        ;;
      --freeze-installed)
        freeze_installed=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  local pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    warn "pacman_install: no packages specified"
    return 1
  fi

  local freeze_args=""
  if ((freeze_installed)); then
    freeze_args="$(_pacman_frozen_installed_args "$context")"
    if [[ -z "$freeze_args" ]]; then
      warn "pacman_install: --freeze-installed requested but could not query installed packages"
    fi
  fi

  log "Installing packages: ${pkgs[*]}"
  local _raw_log="${PACMAN_RAW_LOG:-/dev/null}"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_retry _pacman_exec "$context" "${yes_prefix}pacman $config_args -S $noconfirm $needed $cachedir $freeze_args ${pkgs[*]}" \
    > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
    2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
}

# ---------------------------------------------------------------------------
# Install a local package file (.pkg.tar.zst).
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#   --needed         Only install if not already installed (default)
#   --               End of options; remaining args are package file paths
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_install_local() {
  local config="" context="auto" noconfirm="--noconfirm" needed="--needed"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      --needed)
        needed="--needed"
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  local pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    warn "pacman_install_local: no package files specified"
    return 1
  fi

  log "Installing local packages: ${pkgs[*]}"
  local _raw_log="${PACMAN_RAW_LOG:-/dev/null}"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_retry _pacman_exec "$context" "pacman $config_args -U $noconfirm $needed ${pkgs[*]}" \
    > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
    2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
}

# ---------------------------------------------------------------------------
# Download packages without installing.
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#   --needed         Only download if not already installed (default)
#   --yes            Pipe yes to handle conflict prompts
#   --cachedir PATH  Override package cache directory
#   --freeze-installed  Freeze already-installed packages (additive mode)
#   --               End of options; remaining args are package names
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_download() {
  local config="" context="auto" noconfirm="--noconfirm" needed="--needed" cachedir="" yes_prefix="" freeze_installed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      --needed)
        needed="--needed"
        shift
        ;;
      --yes)
        yes_prefix="yes | "
        noconfirm=""
        shift
        ;;
      --cachedir)
        cachedir="--cachedir '$2'"
        shift 2
        ;;
      --freeze-installed)
        freeze_installed=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  local pkgs=("$@")
  if [[ ${#pkgs[@]} -eq 0 ]]; then
    warn "pacman_download: no packages specified"
    return 1
  fi

  local freeze_args=""
  if ((freeze_installed)); then
    freeze_args="$(_pacman_frozen_installed_args "$context")"
    if [[ -z "$freeze_args" ]]; then
      warn "pacman_download: --freeze-installed requested but could not query installed packages"
    fi
  fi

  log "Downloading packages: ${pkgs[*]}"
  local _raw_log="${PACMAN_RAW_LOG:-/dev/null}"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_retry _pacman_exec "$context" "${yes_prefix}pacman $config_args -Sw $noconfirm $needed $cachedir $freeze_args ${pkgs[*]}" \
    > >(tee -a "$_raw_log" | _pacman_filter_stdout) \
    2> >(tee -a "$_raw_log" | _pacman_filter_stderr >&2)
}

# ---------------------------------------------------------------------------
# Conflict resolution config
# ---------------------------------------------------------------------------
# Loads lib/configs/conflict-resolutions.conf at source time if it exists.
# Format: ACTION|old_package|new_package|file_path|reason
# ---------------------------------------------------------------------------

_CONFLICT_RESOLUTIONS_FILE="${SCRIPT_DIR:-}/lib/configs/conflict-resolutions.conf"

# Global arrays populated by _pacman_load_conflict_resolutions().
# Declared here so they persist across function calls in the same shell.
declare -a _CR_ACTIONS=() _CR_OLD_PKGS=() _CR_NEW_PKGS=() _CR_FILES=() _CR_REASONS=()

# Load conflict resolutions from the config file.
#
# Populates the global _CR_* arrays. Safe to call multiple times (reloads).
#
# Args: none
# Returns: 0 always
# ---------------------------------------------------------------------------
_pacman_load_conflict_resolutions() {
  _CR_ACTIONS=() _CR_OLD_PKGS=() _CR_NEW_PKGS=() _CR_FILES=() _CR_REASONS=()

  [[ -f "$_CONFLICT_RESOLUTIONS_FILE" ]] || return 0

  local line
  while IFS='|' read -r action old_pkg new_pkg file_path reason; do
    # Skip comments and blank lines
    [[ -z "$action" || "$action" == \#* ]] && continue
    _CR_ACTIONS+=("$action")
    _CR_OLD_PKGS+=("$old_pkg")
    _CR_NEW_PKGS+=("$new_pkg")
    _CR_FILES+=("$file_path")
    _CR_REASONS+=("$reason")
  done <"$_CONFLICT_RESOLUTIONS_FILE"

  if ((${#_CR_ACTIONS[@]} > 0)); then
    log "Loaded ${#_CR_ACTIONS[@]} conflict resolution(s) from $(basename "$_CONFLICT_RESOLUTIONS_FILE")"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Provider resolutions for ambiguous virtual dependencies.
# ---------------------------------------------------------------------------

_PROVIDER_RESOLUTIONS_FILE="${SCRIPT_DIR:-}/lib/configs/provider-resolutions.conf"

# Global arrays populated by _pacman_load_provider_resolutions().
declare -a _PR_VIRTUALS=() _PR_PACKAGES=() _PR_REASONS=()

# Load provider resolutions from the config file.
#
# Populates the global _PR_* arrays. Safe to call multiple times (reloads).
#
# Args: none
# Returns: 0 always
# ---------------------------------------------------------------------------
_pacman_load_provider_resolutions() {
  _PR_VIRTUALS=() _PR_PACKAGES=() _PR_REASONS=()

  [[ -f "$_PROVIDER_RESOLUTIONS_FILE" ]] || return 0

  local line
  while IFS='|' read -r virtual package reason; do
    [[ -z "$virtual" || "$virtual" == \#* ]] && continue
    _PR_VIRTUALS+=("$virtual")
    _PR_PACKAGES+=("$package")
    _PR_REASONS+=("$reason")
  done <"$_PROVIDER_RESOLUTIONS_FILE"

  if ((${#_PR_VIRTUALS[@]} > 0)); then
    log "Loaded ${#_PR_VIRTUALS[@]} provider resolution(s) from $(basename "$_PROVIDER_RESOLUTIONS_FILE")"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Internal: Filter out noisy pacman warnings from stderr.
#
# Suppresses the "could not get file information for" warnings that pacman
# emits ~111k times during upgrades when repo packages reference files that
# don't exist in the local filesystem (e.g. man pages from split packages).
#
# Usage: 2> >(_pacman_filter_stderr)
# ---------------------------------------------------------------------------
_pacman_filter_stderr() {
  awk '
    / downloading\.\.\.$/ && !/error:|failed|warning:|corrupted|timeout|could not resolve/ { next }
    /^warning: could not get file information for / { next }
    /Conflict with earlier configuration.*01-steamos-enforce-UID-GID\.conf.*ignoring line\./ {
      steamos_sysusers_suppressed++
      next
    }
    /^(New )?Optional dependencies for / { in_optdeps=1; next }
    in_optdeps && /^    / { next }
    { in_optdeps=0; print }
    END {
      if (steamos_sysusers_suppressed > 0)
        printf "systemd-sysusers: %d SteamOS UID/GID override(s) retained\n", steamos_sysusers_suppressed
    }
  ' >&2
}

# ---------------------------------------------------------------------------
# Internal: Filter out noisy pacman download progress from stdout.
#
# Suppresses lines like "package-name-1.2.3-4 downloading..." that pacman
# emits for every package during sync/upgrade operations.
#
# Preserves lines containing error indicators so failures remain visible.
#
# Usage: | _pacman_filter_stdout
# ---------------------------------------------------------------------------
_pacman_filter_stdout() {
  awk '
    / downloading\.\.\.$/ && !/error:|failed|warning:|corrupted|timeout|could not resolve/ { next }
    /^upgrading [^ ]+\.\.\.$/ && !/error:|failed|warning:|corrupted|timeout|could not resolve/ { next }
    /^installing [^ ]+\.\.\.$/ && !/error:|failed|warning:|corrupted|timeout|could not resolve/ { next }
    /^Packages \([0-9]+\)/ {
      match($0, /\(([0-9]+)\)/, m)
      pkg_count = m[1]
      next
    }
    /^Total Download Size:/ {
      match($0, /:[[:space:]]+(.*)/, m)
      download_size = m[1]
      next
    }
    /^Total Installed Size:/ {
      match($0, /:[[:space:]]+(.*)/, m)
      installed_size = m[1]
      next
    }
    /^Net Upgrade Size:/ {
      match($0, /:[[:space:]]+(.*)/, m)
      net_size = m[1]
      next
    }
    /Conflict with earlier configuration.*01-steamos-enforce-UID-GID\.conf.*ignoring line\./ {
      steamos_sysusers_suppressed++
      next
    }
    /^(New )?Optional dependencies for / { in_optdeps=1; next }
    in_optdeps && /^    / { next }
    { in_optdeps=0; print }
    END {
      if (pkg_count != "") {
        printf "Pacman transaction:\n"
        printf "  packages:   %s\n", pkg_count
        if (download_size != "") printf "  download:   %s\n", download_size
        if (installed_size != "") printf "  installed:  %s\n", installed_size
        if (net_size != "") printf "  net change: %s\n", net_size
      }
      if (steamos_sysusers_suppressed > 0)
        printf "systemd-sysusers: %d SteamOS UID/GID override(s) retained\n", steamos_sysusers_suppressed
    }
  '
}

# ---------------------------------------------------------------------------
# Internal: Run a command in a chroot root, or on the host if root is empty.
#
# Args:
#   $1 = root directory (empty string = host)
#   $2 = command to run
#
# Returns: exit code of the command
# ---------------------------------------------------------------------------
_pacman_run_in_root() {
  local root="${1:-}"
  local cmd="$2"

  if [[ -n "$root" ]]; then
    chroot "$root" /bin/bash -c "$cmd"
  else
    /bin/bash -c "$cmd"
  fi
}

# ---------------------------------------------------------------------------
# Internal: Snapshot installed file ownership to a file for reuse.
#
# Runs `pacman -Ql` once and writes output in "pkg /path" format.
# Used by the individual preflight loop to check file conflicts without
# re-querying the full installed file list for every package.
#
# Args:
#   $1 = chroot directory (empty string = host)
#   $2 = output file path
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
_pacman_snapshot_installed_files() {
  local chroot_dir="${1:-}"
  local output_file="$2"

  local config_args
  config_args="$(_pacman_resolve_config)"

  if [[ -n "$chroot_dir" && -d "$chroot_dir" ]]; then
    _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args -Ql 2>/dev/null" >"$output_file" || return 1
  else
    # shellcheck disable=SC2086 # config_args is intentionally word-split
    pacman $config_args -Ql 2>/dev/null >"$output_file" || return 1
  fi

  [[ -s "$output_file" ]] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Internal: Check a single package for file conflicts against an installed-files snapshot.
#
# Queries the package's file list via `pacman -Fl` and cross-references it
# against the installed-files snapshot to detect file path collisions.
#
# Args:
#   $1 = package name (e.g. "libgcc" or "extra/libgcc")
#   $2 = installed files snapshot file (from _pacman_snapshot_installed_files)
#   $3 = chroot directory (empty string = host)
#
# Prints: tab-separated lines: "new_pkg\tconflicting_path\told_owner"
# Returns: 0 = no conflicts, 1 = conflicts found, 2 = error (could not check)
# ---------------------------------------------------------------------------
_pacman_check_single_pkg_file_conflicts() {
  local pkg="$1"
  local installed_files="$2"
  local chroot_dir="${3:-}"

  local config_args
  config_args="$(_pacman_resolve_config)"

  # Get file list for the package — write to temp files to preserve NUL bytes
  # (command substitution strips \0, causing bash warnings with --machinereadable)
  local planned_raw_file="$WORKDIR/preflight-fl-${pkg//\//-}.txt"
  if [[ -n "$chroot_dir" && -d "$chroot_dir" ]]; then
    _pacman_retry _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args -Fl --machinereadable '$pkg' 2>/dev/null" \
      >"$planned_raw_file" || true
  else
    # shellcheck disable=SC2086 # config_args is intentionally word-split
    _pacman_retry pacman $config_args -Fl --machinereadable "$pkg" 2>/dev/null \
      >"$planned_raw_file" || true
  fi

  # Normalize to "pkg /path" format
  local planned_files
  if [[ -s "$planned_raw_file" ]]; then
    planned_files=$(awk -F'\0' '{print $2 " /" $4}' "$planned_raw_file")
  else
    # Fallback to non-machinereadable
    local planned_fallback_file="$WORKDIR/preflight-fl-fallback-${pkg//\//-}.txt"
    if [[ -n "$chroot_dir" && -d "$chroot_dir" ]]; then
      _pacman_retry _pacman_run_in_root "$chroot_dir" \
        "pacman $config_args -Fl '$pkg' 2>/dev/null" \
        >"$planned_fallback_file" || true
    else
      # shellcheck disable=SC2086 # config_args is intentionally word-split
      _pacman_retry pacman $config_args -Fl "$pkg" 2>/dev/null \
        >"$planned_fallback_file" || true
    fi
    if [[ -s "$planned_fallback_file" ]]; then
      planned_files=$(awk '{print $1 " /" $2}' "$planned_fallback_file")
    else
      return 2 # Could not get file list
    fi
  fi

  [[ -n "$planned_files" ]] || return 2

  # Cross-reference against installed files snapshot.
  # For each file the new package would install, check whether it is already
  # owned by a different (installed) package — that's a collision.
  local conflicts
  conflicts=$(awk '
    NR==FNR {
      # First file: installed files (pkg /path)
      split($0, a, " ")
      fpath = a[2]
      owner[fpath] = a[1]
      next
    }
    {
      # Second file: planned files (pkg /path)
      split($0, a, " ")
      fpath = a[2]
      newpkg = a[1]

      # Check for collision
      if (fpath in owner) {
        if (owner[fpath] != newpkg) {
          printf "%s\t%s\t%s\n", newpkg, fpath, owner[fpath]
        }
      }
    }
  ' "$installed_files" <(echo "$planned_files") 2>/dev/null)

  if [[ -n "$conflicts" ]]; then
    echo "$conflicts"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pre-flight check: detect and resolve known conflicts before upgrade.
#
# Workflow:
#   1. Load conflict resolutions from config
#   2. Run pacman dry-run (--print) to get planned transaction
#   3. Check each planned package against installed packages for renames
#   4. Check pacman stderr for file-conflict messages
#   5. Apply resolutions: uninstall old packages, collect --overwrite paths
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context (uses $MERGED)
#   --host           Force host context
#   --root PATH      Use specific root directory for chroot
#   --install        Use -S --needed (for package install) instead of -Syu
#
# Prints: extra pacman flags to append to the real upgrade command
#          (e.g. "--overwrite /usr/bin/drm_info")
# Returns: 0 if no unresolvable conflicts, 1 if manual intervention needed
#
# Side effects:
#   - May uninstall packages via pacman -Rdd (for "uninstall" actions)
#   - Logs all decisions for debugging
# ---------------------------------------------------------------------------
pacman_preflight_check() {
  # Redirect stdout to stderr so log() calls don't pollute command substitution.
  # The only stdout this function should produce is the final overwrite flags.
  exec 7>&1 1>&2

  local config="" context="auto" root="" txn_type="upgrade"
  local -a _pf_targets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        config="$2"
        shift 2
        ;;
      --chroot)
        context="chroot"
        shift
        ;;
      --host)
        context="host"
        shift
        ;;
      --root)
        context="root"
        root="$2"
        shift 2
        ;;
      --install)
        txn_type="install"
        shift
        ;;
      --)
        shift
        _pf_targets=("$@")
        break
        ;;
      *) break ;;
    esac
  done

  local txn_flags
  case "$txn_type" in
    install) txn_flags="-S --needed" ;;
    *) txn_flags="-Syu" ;;
  esac

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  # Resolve the chroot root directory
  local chroot_dir=""
  case "$context" in
    root) chroot_dir="$root" ;;
    chroot) chroot_dir="${MERGED:-}" ;;
    host) chroot_dir="" ;;
    *) chroot_dir="${MERGED:-}" ;;
  esac

  # Load known conflict resolutions
  _pacman_load_conflict_resolutions

  # Load known provider resolutions
  _pacman_load_provider_resolutions

  # ── Step 1: Dry run ──────────────────────────────────────────────────────
  log "Pre-flight: running dry-run transaction preview"
  local dry_output="$WORKDIR/pacman-dry-run.txt"
  local dry_stderr="$WORKDIR/pacman-dry-run-stderr.txt"
  local dry_rc=0

  # shellcheck disable=SC2086 # _pf_targets is intentionally word-split
  _pacman_run_in_root "$chroot_dir" \
    "pacman $config_args $txn_flags --print --print-format '%r|%n' --noconfirm --ask=4 ${_pf_targets[*]}" \
    >"$dry_output" 2>"$dry_stderr" || dry_rc=$?

  # Build provider targets — only for virtuals the transaction actually needs
  local -a _provider_targets=()
  local _i
  for _i in "${!_PR_VIRTUALS[@]}"; do
    if grep -qF "${_PR_VIRTUALS[$_i]}" "$dry_stderr"; then
      _provider_targets+=("${_PR_PACKAGES[$_i]}")
      log "Pre-flight: provider resolution: ${_PR_VIRTUALS[$_i]} → ${_PR_PACKAGES[$_i]} (${_PR_REASONS[$_i]})"
    fi
  done

  # Re-run dry-run with provider targets if any were needed
  if ((${#_provider_targets[@]} > 0)); then
    log "Pre-flight: re-running dry-run with ${#_provider_targets[@]} provider target(s)"
    dry_rc=0
    # shellcheck disable=SC2086 # _provider_targets and _pf_targets are intentionally word-split
    _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args $txn_flags --print --print-format '%r|%n' --noconfirm --ask=4 ${_pf_targets[*]} ${_provider_targets[*]}" \
      >"$dry_output" 2>"$dry_stderr" || dry_rc=$?
  fi

  # ── Step 1a-bis: Write combined dry-run log ─────────────────────────────
  local dry_combined_log="$WORKDIR/pacman-dry-run-combined.log"
  {
    echo "=== pacman dry-run combined log ==="
    echo "=== timestamp: $(date -Iseconds) ==="
    echo "=== rc: $dry_rc ==="
    echo ""
    echo "--- stdout ($dry_output) ---"
    cat "$dry_output"
    echo ""
    echo "--- stderr ($dry_stderr) ---"
    cat "$dry_stderr"
  } >"$dry_combined_log"

  # ── Step 1b: Filter dry-run output ───────────────────────────────────────
  # pacman --print writes package names to stdout, but also emits error/warning
  # lines like ":: installing X (ver) breaks dependency 'Y' required by Z".
  # Split into clean package list vs error lines.
  local dry_packages="$WORKDIR/pacman-dry-run-packages.txt"
  local dry_errors="$WORKDIR/pacman-dry-run-errors.txt"
  grep -v '^\(::\|error:\)' "$dry_output" >"$dry_packages" || true
  grep '^\(::\|error:\)' "$dry_output" >"$dry_errors" || true

  local planned_count
  planned_count=$(wc -l <"$dry_packages")
  log "Pre-flight: dry-run produced $planned_count package(s)"

  # Log first 30 packages for debugging (avoid flooding the log)
  if ((planned_count > 0)); then
    log "Pre-flight: planned transaction (first 30):"
    head -30 "$dry_packages" | while IFS= read -r line; do
      # Display as repo/package for clarity
      log "  → ${line/|/\/}"
    done
  fi

  # ── Step 1c: Detect dependency breakages from dry-run errors ─────────────
  # Group ":: installing X breaks dependency" lines by the breaking package.
  # Each unique breaker counts as one unresolved ABI transition.
  local -a dep_break_pkgs=()
  local -a dep_break_details=()
  local -a dep_break_raw_lines=()
  local dep_unresolved=0

  if [[ -s "$dry_errors" ]]; then
    log "Pre-flight: scanning dry-run output for dependency breakage errors"
    debug "Pre-flight: raw dry-run errors ($(wc -l <"$dry_errors") lines):"
    while IFS= read -r _de_line; do
      debug "  | $_de_line"
    done <"$dry_errors"
    local _prev_breaker="" _dependents=""
    # Store regex in variable to avoid bash parsing issues with parentheses
    local _dep_break_re='^::[[:space:]]+installing[[:space:]]+([a-zA-Z0-9@._+-]+)[[:space:]]+\([^)]+\)[[:space:]]+breaks dependency'
    local _dep_required_re='required by[[:space:]]+([a-zA-Z0-9@._+-]+)'
    local _raw_lines=""

    while IFS= read -r line; do
      if [[ "$line" =~ $_dep_break_re ]]; then
        local _breaker="${BASH_REMATCH[1]}"
        local _dependent=""
        if [[ "$line" =~ $_dep_required_re ]]; then
          _dependent="${BASH_REMATCH[1]}"
        fi
        if [[ "$_breaker" == "$_prev_breaker" ]]; then
          _dependents+=" $_dependent"
          _raw_lines+=$'\n'"$line"
        else
          if [[ -n "$_prev_breaker" ]]; then
            dep_break_pkgs+=("$_prev_breaker")
            dep_break_details+=("$_dependents")
            dep_break_raw_lines+=("$_raw_lines")
            ((++dep_unresolved)) || true
          fi
          _prev_breaker="$_breaker"
          _dependents="$_dependent"
          _raw_lines="$line"
        fi
      fi
    done <"$dry_errors"

    # Flush the last group
    if [[ -n "$_prev_breaker" ]]; then
      dep_break_pkgs+=("$_prev_breaker")
      dep_break_details+=("$_dependents")
      dep_break_raw_lines+=("$_raw_lines")
      ((++dep_unresolved)) || true
    fi

    for _i in "${!dep_break_pkgs[@]}"; do
      warn "Pre-flight: ${dep_break_pkgs[$_i]} breaks dependency — affects:${dep_break_details[$_i]}"
      debug "Pre-flight: raw error lines for ${dep_break_pkgs[$_i]}:"
      while IFS= read -r _raw; do
        debug "  $_raw"
      done <<<"${dep_break_raw_lines[$_i]}"
    done
  fi

  # Write structured dep-breakage summary for callers to consume
  local dep_breakage_file="$WORKDIR/preflight-dep-breakages.txt"
  : >"$dep_breakage_file"
  for _i in "${!dep_break_pkgs[@]}"; do
    printf '%s|%s\n' "${dep_break_pkgs[$_i]}" "${dep_break_details[$_i]}" >>"$dep_breakage_file"
  done

  # ── Step 2: Detect file conflicts proactively ───────────────────────────
  # --print mode never reaches the commit stage, so pacman cannot report
  # file conflicts in stderr.  We detect them by cross-referencing the
  # file lists of planned packages against installed packages.
  local -a conflict_files=()
  local -a conflict_new_pkgs=()
  local -a conflict_old_pkgs=()

  if [[ -s "$dry_packages" ]]; then
    log "Pre-flight: checking planned packages for file conflicts"

    local planned_files="$WORKDIR/preflight-planned-files.txt"
    local installed_files="$WORKDIR/preflight-installed-files.txt"

    # Files that planned packages would install (from sync DB).
    # Use --machinereadable when available for robust NUL-separated parsing.
    # Format: repo\0pkgname\0version\0filepath\n  (no leading / on paths)
    # Normalize to "pkg /path" to match -Ql output.
    local _pkg_list
    # Convert repo|pkg format to repo/pkg for pacman -Fl queries
    _pkg_list=$(sed 's/|/\//' "$dry_packages" | paste -sd' ')
    local planned_raw="$WORKDIR/preflight-planned-raw.txt"
    local fl_rc=0
    local machine_readable=1
    # shellcheck disable=SC2086 # _pkg_list is intentionally word-split
    _pacman_retry _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args -Fl --machinereadable $_pkg_list 2>/dev/null" \
      >"$planned_raw" 2>/dev/null || fl_rc=$?

    if ((fl_rc != 0)) || [[ ! -s "$planned_raw" ]]; then
      machine_readable=0
      fl_rc=0
      # Fallback: regular -Fl output: "pkg path" → "pkg /path"
      # shellcheck disable=SC2086 # _pkg_list is intentionally word-split
      _pacman_retry _pacman_run_in_root "$chroot_dir" \
        "pacman $config_args -Fl $_pkg_list 2>/dev/null" \
        >"$planned_raw" 2>/dev/null || fl_rc=$?
    fi

    # If both -Fl attempts failed, fail closed
    if ((fl_rc != 0)); then
      warn "Pre-flight: failed to query package file lists (rc=$fl_rc)"
      warn "Pre-flight: cannot verify file conflicts — aborting for safety"
      exec 1>&7 7>&-
      return 1
    fi

    if ((machine_readable)); then
      # --machinereadable: repo\0pkg\0ver\0path → "pkg /path"
      awk -F'\0' '{print $2 " /" $4}' "$planned_raw" >"$planned_files"
    else
      awk '{print $1 " /" $2}' "$planned_raw" >"$planned_files"
    fi

    # All currently installed files and their owners.
    # -Ql format: "pkg /path" — already normalized.
    local ql_rc=0
    _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args -Ql 2>/dev/null" \
      >"$installed_files" 2>/dev/null || ql_rc=$?

    # If -Ql failed, fail closed
    if ((ql_rc != 0)); then
      warn "Pre-flight: failed to query installed file lists (rc=$ql_rc)"
      warn "Pre-flight: cannot verify file conflicts — aborting for safety"
      exec 1>&7 7>&-
      return 1
    fi

    # Build a set of packages in the transaction for quick lookup
    local -A _txn_pkg_set=()
    local _tp
    while IFS= read -r _tp; do
      [[ -n "$_tp" ]] || continue
      # Extract package name from repo|pkg format
      local _tp_name="${_tp#*|}"
      _txn_pkg_set["$_tp_name"]=1
    done <"$dry_packages"

    # Cross-reference: find files claimed by both a planned package and an
    # installed package, where the installed owner is NOT in the transaction.
    # Both files are now in "pkg /path" format with consistent leading /.
    if [[ -s "$planned_files" && -s "$installed_files" ]]; then
      local conflict_results="$WORKDIR/preflight-file-conflicts-raw.tsv"

      awk '
        NR==FNR {
          pkg = $1; fpath = $2
          if (fpath ~ /\/$/) {
            dir_owner[fpath] = pkg
          } else {
            owner[fpath] = pkg
          }
          next
        }
        {
          new_pkg = $1; fpath = $2
          if (fpath ~ /\/$/) {
            # directory-vs-file collision (hard collision)
            # planned directory at path where installed file exists
            file_path = substr(fpath, 1, length(fpath)-1)
            if (file_path in owner && owner[file_path] != new_pkg) {
              print new_pkg "\t" file_path "\t" owner[file_path] "\t" "dir"
            }
            next
          }
          # file-vs-file collision
          if (fpath in owner && owner[fpath] != new_pkg) {
            print new_pkg "\t" fpath "\t" owner[fpath] "\t" "file"
          }
          # file-vs-directory collision (hard collision)
          dir_path = fpath "/"
          if (dir_path in dir_owner && dir_owner[dir_path] != new_pkg) {
            print new_pkg "\t" fpath "\t" dir_owner[dir_path] "\t" "dir"
          }
        }
      ' "$installed_files" "$planned_files" | sort -u >"$conflict_results"

      local _fc_new _fc_path _fc_old _fc_type
      while IFS=$'\t' read -r _fc_new _fc_path _fc_old _fc_type; do
        [[ -n "$_fc_new" ]] || continue
        [[ -n "${_txn_pkg_set[$_fc_old]+x}" ]] && continue
        log "Pre-flight: detected file conflict: $_fc_new wants $_fc_path (owned by $_fc_old)"
        conflict_new_pkgs+=("$_fc_new")
        conflict_files+=("$_fc_path")
        conflict_old_pkgs+=("$_fc_old")
      done <"$conflict_results"
    fi

    # Detect target-vs-target collisions: paths claimed by >1 planned package
    if [[ -s "$planned_files" ]]; then
      local tvt_results="$WORKDIR/preflight-tvt-collisions.txt"
      awk '
        {
          pkg = $1; fpath = $2
          if (fpath ~ /\/$/) {
            # Record directory claims but never emit dir-vs-dir collisions
            # (shared directories like /usr/ are completely normal)
            if (!(fpath in dir_seen)) {
              dir_seen[fpath] = pkg
            }
            next
          }
          # file-vs-file collision
          if (fpath in seen) {
            if (seen[fpath] != pkg) {
              print seen[fpath] "\t" fpath "\t" pkg "\t" "file"
            }
          } else {
            seen[fpath] = pkg
          }
          # file-vs-directory collision (hard collision)
          dir_path = fpath "/"
          if (dir_path in dir_seen && dir_seen[dir_path] != pkg) {
            print pkg "\t" fpath "\t" dir_seen[dir_path] "\t" "dir"
          }
        }
      ' "$planned_files" | sort -u >"$tvt_results"

      local _tvt_old _tvt_path _tvt_new _tvt_type
      while IFS=$'\t' read -r _tvt_old _tvt_path _tvt_new _tvt_type; do
        [[ -n "$_tvt_old" ]] || continue
        # Check if this pair is already recorded
        local _tvt_pair="${_tvt_new}|${_tvt_old}"
        local _tvt_dup=0
        for _k in "${!conflict_new_pkgs[@]}"; do
          if [[ "${conflict_new_pkgs[$_k]}|${conflict_old_pkgs[$_k]}" == "$_tvt_pair" &&
            "${conflict_files[$_k]}" == "$_tvt_path" ]]; then
            _tvt_dup=1
            break
          fi
        done
        if ((_tvt_dup == 0)); then
          log "Pre-flight: detected target-vs-target collision: $_tvt_new and $_tvt_old both claim $_tvt_path"
          conflict_new_pkgs+=("$_tvt_new")
          conflict_files+=("$_tvt_path")
          conflict_old_pkgs+=("$_tvt_old")
        fi
      done <"$tvt_results"
    fi

    # ── Step 2c: Detect unowned files that planned packages would overwrite ──
    # Files that exist on disk but are not owned by any installed package.
    # These would cause "exists in filesystem" errors without an owner.
    if [[ -s "$planned_files" && -s "$installed_files" ]]; then
      log "Pre-flight: checking for unowned files in planned package paths"

      # Use installed_files as ownership database instead of per-file pacman -Qo
      # Extract paths that are NOT in installed_files (potential unowned files)
      local unowned_candidates="$WORKDIR/preflight-unowned-candidates.txt"
      awk '{print $2}' "$installed_files" | sort -u >"$WORKDIR/preflight-installed-paths.txt"
      awk '$2 !~ /\/$/ {print $2}' "$planned_files" | sort -u \
        | comm -23 - "$WORKDIR/preflight-installed-paths.txt" >"$unowned_candidates"

      # Check candidates against filesystem (in chroot namespace)
      while IFS= read -r _uo_path; do
        [[ -n "$_uo_path" ]] || continue
        # Check existence in chroot namespace (handles symlinks correctly)
        local _is_file=0 _is_dir=0
        if _pacman_run_in_root "$chroot_dir" \
          "test -e '$_uo_path' || test -L '$_uo_path'" 2>/dev/null; then
          _is_file=1
        fi
        if _pacman_run_in_root "$chroot_dir" \
          "test -d '$_uo_path'" 2>/dev/null; then
          _is_dir=1
        fi
        ((_is_file || _is_dir)) || continue

        # Find which planned package claims this path
        local _uo_pkg
        _uo_pkg=$(awk -v p="$_uo_path" '$2 == p {print $1; exit}' "$planned_files")

        if ((_is_dir)); then
          log "Pre-flight: detected unowned directory at file path: $_uo_path/ (would be overwritten by $_uo_pkg)"
          conflict_new_pkgs+=("$_uo_pkg")
          conflict_files+=("$_uo_path/")
          conflict_old_pkgs+=("(unowned dir)")
        else
          log "Pre-flight: detected unowned file: $_uo_path (would be installed by $_uo_pkg)"
          conflict_new_pkgs+=("$_uo_pkg")
          conflict_files+=("$_uo_path")
          conflict_old_pkgs+=("(unowned)")
        fi
      done <"$unowned_candidates"
    fi

    if ((${#conflict_new_pkgs[@]} > 0)); then
      log "Pre-flight: found ${#conflict_new_pkgs[@]} file conflict(s)"
    fi
  fi

  # ── Step 2b: Supplement from stderr (fallback for non --print modes) ───
  # pacman stderr may contain lines like:
  #   error: failed to commit transaction (conflicting files)
  #   drm-info: /usr/bin/drm_info exists in filesystem (owned by drm_info)
  if [[ -s "$dry_stderr" ]]; then
    log "Pre-flight: scanning stderr for additional conflict messages"
    local _se_new_pkg _se_file_path _se_old_owner

    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9@._+-]+):[[:space:]]+(/[[:graph:]]+)[[:space:]]+exists\ in\ filesystem\ \(owned\ by[[:space:]]+([a-zA-Z0-9@._+-]+)\) ]]; then
        _se_new_pkg="${BASH_REMATCH[1]}"
        _se_file_path="${BASH_REMATCH[2]}"
        _se_old_owner="${BASH_REMATCH[3]}"
        # Deduplicate against proactive results
        local _se_dup=0 _se_i
        for _se_i in "${!conflict_files[@]}"; do
          if [[ "${conflict_new_pkgs[$_se_i]}" == "$_se_new_pkg" && "${conflict_files[$_se_i]}" == "$_se_file_path" ]]; then
            _se_dup=1
            break
          fi
        done
        if ((_se_dup == 0)); then
          log "Pre-flight: detected file conflict (stderr): $_se_new_pkg wants $_se_file_path (owned by $_se_old_owner)"
          conflict_new_pkgs+=("$_se_new_pkg")
          conflict_files+=("$_se_file_path")
          conflict_old_pkgs+=("$_se_old_owner")
        fi
      fi
    done <"$dry_stderr"
  fi

  # ── Step 3: Detect renames from dry-run vs installed packages ────────────
  # If a package in the dry-run output has a different name than what's
  # installed but provides the same files, it's likely a rename.
  # We check this against the conflict resolutions config.
  local -a extra_overwrite_args=()
  local -a uninstall_pkgs=()
  local resolved=0 unresolved=0
  local -A _resolved_conflict_pairs=()
  local -A _resolved_files=()

  # Check each conflict resolution entry against what we found
  local i
  for i in "${!_CR_ACTIONS[@]}"; do
    local cr_action="${_CR_ACTIONS[$i]}"
    local cr_old="${_CR_OLD_PKGS[$i]}"
    local cr_new="${_CR_NEW_PKGS[$i]}"
    local cr_file="${_CR_FILES[$i]}"
    local cr_reason="${_CR_REASONS[$i]}"

    local found=0

    # Check if this conflict was detected in stderr
    local j
    for j in "${!conflict_old_pkgs[@]}"; do
      if [[ "${conflict_old_pkgs[$j]}" == "$cr_old" && "${conflict_new_pkgs[$j]}" == "$cr_new" ]]; then
        found=1
        break
      fi
    done

    # Also check if old package is installed and new package is in dry-run
    if ((found == 0)); then
      local _installed=0
      if [[ -n "$chroot_dir" ]]; then
        chroot "$chroot_dir" pacman -Q "$cr_old" &>/dev/null && _installed=1
      else
        pacman -Q "$cr_old" &>/dev/null && _installed=1
      fi
      if ((_installed)); then
        if grep -q "^[^|]*|${cr_new}$" "$dry_packages" 2>/dev/null; then
          found=1
          log "Pre-flight: detected rename $cr_old → $cr_new (from config + dry-run)"
        fi
      fi
    fi

    if ((found == 0)); then
      continue
    fi

    log "Pre-flight: conflict matched — $cr_old → $cr_new ($cr_action): $cr_reason"

    case "$cr_action" in
      uninstall)
        uninstall_pkgs+=("$cr_old")
        ((++resolved)) || true
        _resolved_conflict_pairs["$cr_new|$cr_old"]=1
        ;;
      overwrite)
        extra_overwrite_args+=("--overwrite" "$cr_file")
        ((++resolved)) || true
        _resolved_files["$cr_new|$cr_old|$cr_file"]=1
        ;;
      skip)
        warn "Pre-flight: skipping conflict $cr_old → $cr_new (manual intervention required)"
        ((++unresolved)) || true
        _resolved_conflict_pairs["$cr_new|$cr_old"]=1
        ;;
      *)
        warn "Pre-flight: unknown action '$cr_action' for $cr_old → $cr_new"
        ((++unresolved)) || true
        _resolved_conflict_pairs["$cr_new|$cr_old"]=1
        ;;
    esac
  done

  # ── Step 3b: Mark unmatched detected conflicts as unresolved ─────────────
  local -A _unresolved_conflict_pairs=()

  for j in "${!conflict_old_pkgs[@]}"; do
    local pair="${conflict_new_pkgs[$j]}|${conflict_old_pkgs[$j]}"
    local file_key="${conflict_new_pkgs[$j]}|${conflict_old_pkgs[$j]}|${conflict_files[$j]}"

    # Skip if entire pair is resolved (uninstall) or specific file is resolved (overwrite)
    if [[ -n "${_resolved_conflict_pairs[$pair]+x}" ||
      -n "${_resolved_files[$file_key]+x}" ]]; then
      continue
    fi

    if [[ -z "${_unresolved_conflict_pairs[$pair]+x}" ]]; then
      _unresolved_conflict_pairs["$pair"]=1
      warn "Pre-flight: unresolved file conflict: ${conflict_new_pkgs[$j]} conflicts with ${conflict_old_pkgs[$j]}"
      ((++unresolved)) || true
    fi
  done

  # Write structured file-conflict summary for callers to consume
  # Contains only unresolved conflicts in pipe-delimited format
  local file_conflict_file="$WORKDIR/preflight-file-conflicts.txt"
  : >"$file_conflict_file"
  local -A _seen_fc_pairs=()
  for _i in "${!conflict_new_pkgs[@]}"; do
    local _fc_pair="${conflict_new_pkgs[$_i]}|${conflict_old_pkgs[$_i]}"
    local _fc_file_key="${conflict_new_pkgs[$_i]}|${conflict_old_pkgs[$_i]}|${conflict_files[$_i]}"
    if [[ -z "${_resolved_conflict_pairs[$_fc_pair]+x}" &&
      -z "${_resolved_files[$_fc_file_key]+x}" &&
      -z "${_seen_fc_pairs[$_fc_pair]+x}" ]]; then
      _seen_fc_pairs["$_fc_pair"]=1
      printf '%s|%s|%s\n' "${conflict_new_pkgs[$_i]}" "${conflict_old_pkgs[$_i]}" "${conflict_files[$_i]}" >>"$file_conflict_file"
    fi
  done

  # ── Step 5: Summary ──────────────────────────────────────────────────────
  # Fold dep-breakage unresolved into the total
  ((unresolved += dep_unresolved)) || true

  log "Pre-flight summary: $resolved resolved, $unresolved unresolved (${dep_unresolved} dep-breakage, $((unresolved - dep_unresolved)) file-conflict), ${#uninstall_pkgs[@]} removed, ${#extra_overwrite_args[@]} overwrite arg(s), ${#_provider_targets[@]} provider target(s)"

  if ((dry_rc != 0 && dep_unresolved == 0 && unresolved == 0)); then
    warn "Pre-flight: pacman dry-run failed with unrecognized error (rc=$dry_rc)"
    cat "$dry_stderr" >&2
    warn "Pre-flight: injecting dry-run log for diagnostics"
    cat "$dry_combined_log" >&2
    exec 1>&7 7>&-
    return 1
  fi

  if ((unresolved > 0)); then
    warn "Pre-flight: $unresolved conflict(s) require manual intervention"
    warn "Pre-flight: injecting dry-run log for diagnostics"
    cat "$dry_combined_log" >&2
    exec 1>&7 7>&-
    return 1
  fi

  # ── Step 4: Apply resolutions ────────────────────────────────────────────

  # Uninstall conflicting old packages
  if ((${#uninstall_pkgs[@]} > 0)); then
    log "Pre-flight: removing ${#uninstall_pkgs[@]} conflicting package(s): ${uninstall_pkgs[*]}"
    for pkg in "${uninstall_pkgs[@]}"; do
      log "Pre-flight:   pacman -Rdd --noconfirm $pkg"
      if _pacman_run_in_root "$chroot_dir" "pacman $config_args -Rdd --noconfirm '$pkg'" \
        >>"$WORKDIR/preflight-uninstall.log" 2>&1; then
        log "Pre-flight:   ✓ removed $pkg"
      else
        warn "Pre-flight: failed to apply required resolution: remove $pkg"
        exec 1>&7 7>&-
        return 1
      fi
    done
  fi

  # Restore stdout for the final output
  exec 1>&7 7>&-

  # Print overwrite args and provider targets for caller to append to the real upgrade command
  if ((${#extra_overwrite_args[@]} > 0)); then
    printf '%s ' "${extra_overwrite_args[@]}"
  fi
  if ((${#_provider_targets[@]} > 0)); then
    printf '%s ' "${_provider_targets[@]}"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Pre-flight with automatic fallback from upgrade to additive mode.
#
# Handles dependency-breakage resolution by individually preflighting each
# package and iteratively removing offenders if bulk install fails.
#
# Args:
#   $1 = nameref to package array (modified in place — offending entries removed)
#   $2 = nameref to mode variable (modified if fallback occurs: "upgrade" → "additive")
#   $3 = nameref to extra args array (populated with --overwrite args)
#   $4 = nameref to provider targets array (populated with resolved provider packages)
#   $5 = interactive: 1 = prompt user, 0 = auto-decide
#
# Uses globals: WORKDIR, MERGED (for chroot context)
#
# Returns: 0 = proceed (array may be reduced or empty), 1 = cancel
# ---------------------------------------------------------------------------
pacman_preflight_with_fallback() {
  local -n _pff_packages=$1
  local -n _pff_mode=$2
  # lint-ignore: dead-code
  local -n _pff_extra_args=${3:-_pff_extra_args_dummy}
  # lint-ignore: dead-code
  local -n _pff_provider_targets=${4:-_pff_provider_targets_dummy}
  local interactive="${5:-0}"

  # Initialize output arrays
  _pff_extra_args=()
  _pff_provider_targets=()

  # ── Phase 1: Upgrade pre-flight ─────────────────────────────────────────
  if [[ "$_pff_mode" == "upgrade" ]]; then
    log "Pre-flight: checking system upgrade"
    local rc=0
    local preflight_output=""
    preflight_output=$(pacman_preflight_check --root "${MERGED:-/}") || rc=$?
    if [[ -n "$preflight_output" ]]; then
      # Parse overwrite args and provider targets from output
      # Overwrite args are pairs: --overwrite <path>
      # Provider targets are bare package names
      local -a _all_output=()
      read -ra _all_output <<<"$preflight_output"
      local _idx=0
      while ((_idx < ${#_all_output[@]})); do
        if [[ "${_all_output[$_idx]}" == "--overwrite" ]]; then
          _pff_extra_args+=("${_all_output[$_idx]}" "${_all_output[$_idx + 1]}")
          ((_idx += 2))
        else
          _pff_provider_targets+=("${_all_output[$_idx]}")
          ((++_idx))
        fi
      done
    fi

    if ((rc != 0)); then
      # Check if dep-breakages were the cause
      local dep_file="$WORKDIR/preflight-dep-breakages.txt"
      local has_dep_breaks=0
      if [[ -s "$dep_file" ]]; then
        has_dep_breaks=1
      fi

      if ((has_dep_breaks)); then
        # Dep-breakage blocked the upgrade
        if ((interactive)); then
          echo "" >&2
          echo "System upgrade blocked by dependency breakage:" >&2
          while IFS='|' read -r breaker dependents; do
            echo "  $breaker breaks: $dependents" >&2
          done <"$dep_file"
          echo "" >&2
          echo "Options:" >&2
          echo "  c) Cancel entirely" >&2
          echo "  a) Switch to additive mode (skip system upgrade, install HW packages only)" >&2
          echo "" >&2
          local choice=""
          read -rp "Choice [c/a]: " choice </dev/tty || true
          if [[ "$choice" != "a" && "$choice" != "A" ]]; then
            warn "Pre-flight: user cancelled"
            return 1
          fi
        else
          # Non-interactive: auto-fallback
          warn "Pre-flight: system upgrade blocked by dep-breakage — falling back to additive mode"
        fi
        _pff_mode="additive"
      else
        # File conflicts, not dep-breakages
        if ((interactive)); then
          echo "" >&2
          echo "System upgrade blocked by unresolvable file conflicts." >&2
          echo "Check the build log for details." >&2
        fi
        warn "Pre-flight: unresolvable file conflicts — cannot proceed"
        return 1
      fi
    else
      # Clean upgrade
      return 0
    fi
  fi

  # ── Phase 2: Additive mode — individual preflight per package ────────
  if ((${#_pff_packages[@]} == 0)); then
    _pff_packages=()
    _pff_result_already_installed=0
    _pff_result_conflict_skipped=0
    _pff_result_installable=0
    return 0
  fi

  # Layer 1: Remove already-installed targets
  local -a filtered_packages=()
  local already_installed=0
  for pkg in "${_pff_packages[@]}"; do
    if _pacman_run_in_root "${MERGED:-}" "pacman -Q '$pkg' >/dev/null 2>&1"; then
      debug "Pre-flight: $pkg already installed — preserving current version"
      ((++already_installed)) || true
    else
      filtered_packages+=("$pkg")
    fi
  done
  _pff_packages=("${filtered_packages[@]}")

  if ((${#_pff_packages[@]} == 0)); then
    log "Pre-flight: $already_installed package(s) already installed — preserved"
    _pff_result_already_installed=$already_installed
    _pff_result_conflict_skipped=0
    _pff_result_installable=0
    return 0
  fi

  log "Pre-flight: additive mode — checking ${#_pff_packages[@]} package(s)"
  debug "Pre-flight: additive mode package list: ${_pff_packages[*]}"

  # Resolve pacman config for direct pacman calls
  local config_args
  config_args="$(_pacman_resolve_config)"

  # Get frozen installed args for consistent --ignore
  local freeze_args
  freeze_args="$(_pacman_frozen_installed_args "auto")"

  # Layer 2: Individual preflight for each package
  local -a passing_packages=()
  local -a skipped_packages=()
  local conflict_skipped=0

  # Snapshot installed file ownership once for file conflict checking
  local installed_files_snapshot="$WORKDIR/preflight-installed-files-snapshot.txt"
  local _snapshot_ok=0
  _pacman_snapshot_installed_files "${MERGED:-}" "$installed_files_snapshot" && _snapshot_ok=1

  for pkg in "${_pff_packages[@]}"; do
    local rc=0
    local dry_stderr="$WORKDIR/preflight-individual-${pkg}-stderr.txt"

    _pacman_run_in_root "${MERGED:-}" \
      "pacman $config_args -S --needed $freeze_args --print --print-format '%r|%n' --noconfirm --ask=4 '$pkg'" \
      >/dev/null 2>"$dry_stderr" || rc=$?

    if ((rc == 0)); then
      debug "Pre-flight: $pkg — individual dependency check passed"

      # Check file conflicts against installed packages
      if ((_snapshot_ok)); then
        local _fc_output="" _fc_rc=0
        _fc_output=$(_pacman_check_single_pkg_file_conflicts "$pkg" "$installed_files_snapshot" "${MERGED:-}") || _fc_rc=$?
        if ((_fc_rc == 1)); then
          warn "Pre-flight: $pkg — file conflicts with installed packages, skipping"
          while IFS=$'\t' read -r _fc_new _fc_path _fc_old; do
            warn "Pre-flight:   $_fc_new wants $_fc_path (owned by $_fc_old)"
          done <<<"$_fc_output"
          skipped_packages+=("$pkg")
          ((++conflict_skipped)) || true
          continue
        elif ((_fc_rc == 2)); then
          debug "Pre-flight: $pkg — could not verify file conflicts (proceeding)"
        fi
      fi

      passing_packages+=("$pkg")
    else
      warn "Pre-flight: $pkg — individual check failed, skipping"
      skipped_packages+=("$pkg")
      ((++conflict_skipped)) || true
      if [[ "${DEBUG:-0}" == 1 ]]; then
        debug "Pre-flight: individual check stderr for $pkg:"
        while IFS= read -r line; do debug "  $line"; done <"$dry_stderr"
      fi
    fi
  done

  if ((${#passing_packages[@]} == 0)); then
    _pff_packages=()
    _pff_result_already_installed=$already_installed
    _pff_result_conflict_skipped=$conflict_skipped
    _pff_result_installable=0
    log "Pre-flight summary: $already_installed preserved, $conflict_skipped skipped, 0 installable"
    if ((${#skipped_packages[@]} > 0)); then
      log "Pre-flight: packages that will not be installed: ${skipped_packages[*]}"
    fi
    return 0
  fi

  # Layer 3: Bulk preflight with all individually-passing packages
  log "Pre-flight: running bulk check with ${#passing_packages[@]} package(s)"
  local bulk_rc=0
  local bulk_stderr="$WORKDIR/preflight-bulk-stderr.txt"

  _pacman_run_in_root "${MERGED:-}" \
    "pacman $config_args -S --needed $freeze_args --print --print-format '%r|%n' --noconfirm --ask=4 ${passing_packages[*]}" \
    >/dev/null 2>"$bulk_stderr" || bulk_rc=$?

  if ((bulk_rc == 0)); then
    _pff_packages=("${passing_packages[@]}")
    _pff_result_already_installed=$already_installed
    _pff_result_conflict_skipped=$conflict_skipped
    _pff_result_installable=${#passing_packages[@]}
    log "Pre-flight summary: $already_installed preserved, $conflict_skipped skipped, ${#passing_packages[@]} installable"
    if ((${#skipped_packages[@]} > 0)); then
      log "Pre-flight: packages that will not be installed: ${skipped_packages[*]}"
    fi
    return 0
  fi

  # Layer 4: Bulk failed — iterative removal on the smaller passing set
  warn "Pre-flight: bulk check failed with ${#passing_packages[@]} packages, attempting iterative removal"
  if [[ "${DEBUG:-0}" == 1 ]]; then
    debug "Pre-flight: bulk check stderr:"
    while IFS= read -r line; do debug "  $line"; done <"$bulk_stderr"
  fi

  # Use pacman_preflight_check on the passing set
  local -a final_packages=("${passing_packages[@]}")
  local max_iterations=${#final_packages[@]}

  for ((i = 0; i < max_iterations; i++)); do
    if ((${#final_packages[@]} == 0)); then
      break
    fi

    local pf_rc=0
    pacman_preflight_check --install -- "${final_packages[@]}" || pf_rc=$?

    if ((pf_rc == 0)); then
      break
    fi

    # Read the dep-breakage file to find the blocker
    local blocker_file="$WORKDIR/preflight-dep-breakages.txt"
    if [[ -s "$blocker_file" ]]; then
      local blocker_name=""
      read -r blocker_name _ <"$blocker_file"
      blocker_name="${blocker_name%%|*}"

      # Find and remove the first package that depends on the blocker
      local found=0
      local -a new_final=()
      for pkg in "${final_packages[@]}"; do
        if ((found == 0)) && _pacman_run_in_root "${MERGED:-}" "pacman -S --needed $freeze_args --print --print-format '%n' --noconfirm '$pkg' 2>/dev/null" | grep -q "^${blocker_name}$"; then
          warn "Pre-flight: removing $pkg (requires $blocker_name upgrade)"
          skipped_packages+=("$pkg")
          ((++conflict_skipped)) || true
          found=1
        else
          new_final+=("$pkg")
        fi
      done
      final_packages=("${new_final[@]}")
    else
      # No dep-breakage file, try file-conflict
      local conflict_file="$WORKDIR/preflight-file-conflicts.txt"
      if [[ -s "$conflict_file" ]]; then
        local conflict_pkg=""
        read -r conflict_pkg _ <"$conflict_file"
        conflict_pkg="${conflict_pkg%%|*}"

        local -a new_final=()
        for pkg in "${final_packages[@]}"; do
          if [[ "$pkg" == "$conflict_pkg" ]]; then
            warn "Pre-flight: removing $pkg (file conflict)"
            skipped_packages+=("$pkg")
            ((++conflict_skipped)) || true
          else
            new_final+=("$pkg")
          fi
        done
        final_packages=("${new_final[@]}")
      else
        warn "Pre-flight: unknown failure, removing last package"
        skipped_packages+=("${final_packages[${#final_packages[@]} - 1]}")
        final_packages=("${final_packages[@]::${#final_packages[@]}-1}")
        ((++conflict_skipped)) || true
      fi
    fi
  done

  _pff_packages=("${final_packages[@]}")
  _pff_result_already_installed=$already_installed
  _pff_result_conflict_skipped=$conflict_skipped
  _pff_result_installable=${#final_packages[@]}
  log "Pre-flight summary: $already_installed preserved, $conflict_skipped skipped, ${#final_packages[@]} installable"
  if ((${#skipped_packages[@]} > 0)); then
    log "Pre-flight: packages that will not be installed: ${skipped_packages[*]}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Pre-flight check for upgrade transactions (no package list).
#
# Runs pacman_preflight_check and handles dep-breakage detection centrally.
# For interactive sessions, prompts the user to cancel or skip.
# For non-interactive sessions, auto-skips on dep-breakage.
#
# Args:
#   $1 = context label for messages (e.g. "System upgrade", "Build root sync")
#   $2... = args passed to pacman_preflight_check (e.g. --root "$MNT", --host)
#
# Returns: 0 = proceed with upgrade, 1 = skip/cancel (caller should not proceed)
# ---------------------------------------------------------------------------
pacman_upgrade_preflight() {
  local context_label="$1"
  shift

  local rc=0
  pacman_preflight_check "$@" || rc=$?

  if ((rc == 0)); then
    return 0
  fi

  # Check if dep-breakages were the cause
  local dep_file="$WORKDIR/preflight-dep-breakages.txt"
  if [[ -s "$dep_file" ]]; then
    if _is_interactive; then
      echo "" >&2
      echo "$context_label blocked by dependency breakage:" >&2
      while IFS='|' read -r breaker dependents; do
        echo "  $breaker breaks: $dependents" >&2
      done <"$dep_file"
      echo "" >&2
      echo "Options:" >&2
      echo "  c) Cancel entirely" >&2
      echo "  s) Skip $context_label and continue" >&2
      echo "" >&2
      local choice=""
      read -rp "Choice [c/s]: " choice </dev/tty || true
      if [[ "$choice" != "s" && "$choice" != "S" ]]; then
        die "$context_label cancelled by user"
      fi
      warn "Pre-flight: user chose to skip $context_label"
    else
      warn "Pre-flight: $context_label blocked by dep-breakage — skipping"
    fi
    return 1
  fi

  # File conflicts — not skippable
  if _is_interactive; then
    echo "" >&2
    echo "$context_label blocked by unresolvable file conflicts." >&2
    echo "Check the build log for details." >&2
  fi
  die "$context_label blocked by unresolvable pre-flight conflicts"
}

# ---------------------------------------------------------------------------
# Cache Cleanup
# ---------------------------------------------------------------------------
# Clean the pacman package cache.
# --host  : clean cache on the host system
# --chroot: clean cache for a target root (uses pacman --root natively)

pacman_clean_cache() {
  local mode="${1:---host}"
  local root="${2:-/}"

  case "$mode" in
    --host)
      pacman -Sc --noconfirm
      ;;

    --chroot)
      [[ "$root" != "/" ]] || {
        warn "pacman_clean_cache: refusing --chroot with /"
        return 1
      }

      [[ -d "$root" && -e "$root/etc/pacman.conf" ]] || {
        warn "pacman_clean_cache: invalid target root: $root"
        return 1
      }

      pacman \
        --root "$root" \
        --dbpath "$root/var/lib/pacman" \
        --cachedir "$root/var/cache/pacman/pkg" \
        --config "$root/etc/pacman.conf" \
        -Sc --noconfirm
      ;;

    *)
      warn "pacman_clean_cache: unknown mode '$mode' (use --host or --chroot)"
      return 1
      ;;
  esac
}
