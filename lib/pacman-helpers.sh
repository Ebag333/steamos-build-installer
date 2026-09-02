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
  # shellcheck disable=SC2086 # word-splitting is intentional
  case "$context" in
    root)
      _pacman_run_in_root "$root" "pacman $config_args -Sy $noconfirm" \
        > >(_pacman_filter_stdout) \
        2> >(_pacman_filter_stderr >&2) || sync_rc=$?
      ;;
    *)
      _pacman_exec "$context" "pacman $config_args -Sy $noconfirm" \
        > >(_pacman_filter_stdout) \
        2> >(_pacman_filter_stderr >&2) || sync_rc=$?
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
      _pacman_run_in_root "$root" "pacman $config_args -Fy $noconfirm" \
        > >(_pacman_filter_stdout) \
        2> >(_pacman_filter_stderr >&2)
      ;;
    *)
      _pacman_exec "$context" "pacman $config_args -Fy $noconfirm" \
        > >(_pacman_filter_stdout) \
        2> >(_pacman_filter_stderr >&2)
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
  _pacman_exec "$context" "pacman $config_args -Syu $noconfirm $ask $extra" \
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
#   --               End of options; remaining args are package names
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_install() {
  local config="" context="auto" noconfirm="--noconfirm" needed="--needed" cachedir="" yes_prefix=""

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

  log "Installing packages: ${pkgs[*]}"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_exec "$context" "${yes_prefix}pacman $config_args -S $noconfirm $needed $cachedir ${pkgs[*]}" \
    > >(_pacman_filter_stdout) \
    2> >(_pacman_filter_stderr >&2)
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
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_exec "$context" "pacman $config_args -U $noconfirm $needed ${pkgs[*]}" \
    > >(_pacman_filter_stdout) \
    2> >(_pacman_filter_stderr >&2)
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
#   --               End of options; remaining args are package names
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_download() {
  local config="" context="auto" noconfirm="--noconfirm" needed="--needed" cachedir="" yes_prefix=""

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

  log "Downloading packages: ${pkgs[*]}"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_exec "$context" "${yes_prefix}pacman $config_args -Sw $noconfirm $needed $cachedir ${pkgs[*]}" \
    > >(_pacman_filter_stdout) \
    2> >(_pacman_filter_stderr >&2)
}

# ---------------------------------------------------------------------------
# Clean package cache.
#
# Args:
#   --chroot         Force chroot context
#   --host           Force host context
#   --noconfirm      Skip confirmation prompts (default)
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_clean_cache() {
  local context="auto" noconfirm="--noconfirm"

  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      *) break ;;
    esac
  done

  log "Cleaning package cache"
  # shellcheck disable=SC2086 # word-splitting is intentional for _pacman_exec
  _pacman_exec "$context" "pacman -Sc $noconfirm" \
    > >(_pacman_filter_stdout) \
    2> >(_pacman_filter_stderr >&2)
}

# ---------------------------------------------------------------------------
# Check for required commands and install missing packages.
#
# Args:
#   --noconfirm      Skip confirmation prompts
#   --check-only     Only check, don't install
#   --               End of options; remaining args are "cmd:pkg" pairs
#
# The cmd:pkg pairs map command names to their package names.
# Example: "awk:gawk" "blkid:util-linux" "yad:yad"
#
# Returns: 0 if all commands present, 1 if any required missing
# ---------------------------------------------------------------------------
pacman_check_and_install_deps() {
  local noconfirm="--noconfirm" check_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --noconfirm)
        noconfirm="--noconfirm"
        shift
        ;;
      --check-only)
        check_only=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *) break ;;
    esac
  done

  local -a missing_pkgs=()
  local entry cmd pkg

  for entry in "$@"; do
    IFS=':' read -r cmd pkg <<<"$entry"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      log "  Missing: $cmd ($pkg)"
      missing_pkgs+=("$pkg")
    fi
  done

  if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
    log "All dependencies satisfied"
    return 0
  fi

  if [[ "$check_only" -eq 1 ]]; then
    warn "Missing packages: ${missing_pkgs[*]}"
    return 1
  fi

  # Deduplicate
  local -a unique_pkgs
  mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)

  log "Installing missing dependencies: ${unique_pkgs[*]}"
  pacman_install --host $noconfirm -- "${unique_pkgs[@]}"
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
# Pacman dry-run: preview what -S --needed would do without modifying the system.
#
# Runs pacman -S --needed --print and captures the planned transaction.
#
# Args:
#   --config PATH    Override pacman config
#   --chroot         Force chroot context (uses $MERGED)
#   --host           Force host context
#   --root PATH      Use specific root directory for chroot
#
# Prints: one package name per line (packages that would be installed/upgraded)
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
pacman_dry_run() {
  # Redirect stdout to stderr so log() calls don't pollute the output pipe.
  exec 7>&1 1>&2

  local config="" context="auto" root=""

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
      *) break ;;
    esac
  done

  local config_args
  config_args="$(_pacman_resolve_config "$config")"

  log "Running pacman dry-run (--print)"

  # Restore stdout for the actual pacman output
  exec 1>&7 7>&-

  if [[ "$context" == "root" && -n "$root" ]]; then
    chroot "$root" /bin/bash -c "pacman $config_args -Syu --print --print-format '%n' --noconfirm --ask=4 2>/dev/null" \
      | awk 'NF{print $1}'
  else
    _pacman_exec "$context" "pacman $config_args -Syu --print --print-format '%n' --noconfirm --ask=4 2>/dev/null" \
      | awk 'NF{print $1}'
  fi
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
  local dep_unresolved=0

  if [[ -s "$dry_errors" ]]; then
    log "Pre-flight: scanning dry-run output for dependency breakage errors"
    local _prev_breaker="" _dependents=""
    # Store regex in variable to avoid bash parsing issues with parentheses
    local _dep_break_re='^::[[:space:]]+installing[[:space:]]+([a-zA-Z0-9@._+-]+)[[:space:]]+\([^)]+\)[[:space:]]+breaks dependency'
    local _dep_required_re='required by[[:space:]]+([a-zA-Z0-9@._+-]+)'

    while IFS= read -r line; do
      if [[ "$line" =~ $_dep_break_re ]]; then
        local _breaker="${BASH_REMATCH[1]}"
        local _dependent=""
        if [[ "$line" =~ $_dep_required_re ]]; then
          _dependent="${BASH_REMATCH[1]}"
        fi
        if [[ "$_breaker" == "$_prev_breaker" ]]; then
          _dependents+=" $_dependent"
        else
          if [[ -n "$_prev_breaker" ]]; then
            dep_break_pkgs+=("$_prev_breaker")
            dep_break_details+=("$_dependents")
            ((++dep_unresolved)) || true
          fi
          _prev_breaker="$_breaker"
          _dependents="$_dependent"
        fi
      fi
    done <"$dry_errors"

    # Flush the last group
    if [[ -n "$_prev_breaker" ]]; then
      dep_break_pkgs+=("$_prev_breaker")
      dep_break_details+=("$_dependents")
      ((++dep_unresolved)) || true
    fi

    for _i in "${!dep_break_pkgs[@]}"; do
      warn "Pre-flight: ${dep_break_pkgs[$_i]} breaks dependency — affects:${dep_break_details[$_i]}"
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
    _pacman_run_in_root "$chroot_dir" \
      "pacman $config_args -Fl --machinereadable $_pkg_list 2>/dev/null" \
      >"$planned_raw" 2>/dev/null || fl_rc=$?

    if ((fl_rc != 0)) || [[ ! -s "$planned_raw" ]]; then
      machine_readable=0
      fl_rc=0
      # Fallback: regular -Fl output: "pkg path" → "pkg /path"
      # shellcheck disable=SC2086 # _pkg_list is intentionally word-split
      _pacman_run_in_root "$chroot_dir" \
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
      awk '$2 !~ /\/$/ {print $2}' "$planned_files" | sort -u | \
        comm -23 - "$WORKDIR/preflight-installed-paths.txt" >"$unowned_candidates"

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
  local -a skip_actions=()
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
        skip_actions+=("$cr_old → $cr_new")
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
    exec 1>&7 7>&-
    return 1
  fi

  if ((unresolved > 0)); then
    warn "Pre-flight: $unresolved conflict(s) require manual intervention"
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
# Handles dependency-breakage resolution by tracing breakages back to their
# root HW_SUPPORT_ITEMS entry via pactree and removing it.
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
  local -n _pff_extra_args=${3:-_pff_extra_args_dummy}
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

  # ── Phase 2: Additive mode ──────────────────────────────────────────────
  if ((${#_pff_packages[@]} == 0)); then
    return 0
  fi

  local requested_count=${#_pff_packages[@]}

  # ── Layer 1: Remove already-installed targets ───────────────────────────
  # In additive mode, packages that are already installed should be preserved
  # at their current version — don't target them for upgrade.
  local -a filtered_packages=()
  local already_installed=0
  for pkg in "${_pff_packages[@]}"; do
    if _pacman_run_in_root "${MERGED:-}" \
      "pacman -Q '$pkg' >/dev/null 2>&1"; then
      debug "Pre-flight: $pkg already installed — preserving current version"
      ((++already_installed)) || true
    else
      filtered_packages+=("$pkg")
    fi
  done

  if ((already_installed > 0)); then
    log "Pre-flight: $already_installed package(s) already installed — preserved"
  fi

  _pff_packages=("${filtered_packages[@]}")

  if ((${#_pff_packages[@]} == 0)); then
    log "Additive package resolution:"
    log "  requested:          $requested_count"
    log "  already installed:  $already_installed (preserved)"
    log "  conflict-skipped:   0"
    log "  installable:        0"
    return 0
  fi

  # ── Layer 2: Iterative conflict-removal loop ────────────────────────────
  local conflict_skipped=0
  local remaining_count=${#_pff_packages[@]}

  log "Pre-flight: additive mode — checking $remaining_count package(s)"
  local max_iter=$remaining_count
  local iter

  for ((iter = 0; iter < max_iter; iter++)); do
    local rc=0
    local preflight_output=""
    preflight_output=$(pacman_preflight_check --install -- "${_pff_packages[@]}") || rc=$?
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

    if ((rc == 0)); then
      # Clean — proceed
      break
    fi

    # Check for dep-breakages or file conflicts
    local dep_file="$WORKDIR/preflight-dep-breakages.txt"
    local fc_file="$WORKDIR/preflight-file-conflicts.txt"
    local blocker_file=""
    local blocker_type=""

    if [[ -s "$dep_file" ]]; then
      blocker_file="$dep_file"
      blocker_type="dep-breakage"
    elif [[ -s "$fc_file" ]]; then
      blocker_file="$fc_file"
      blocker_type="file-conflict"
    else
      # Neither dep-breakages nor file-conflicts — unexpected failure
      if ((interactive)); then
        echo "" >&2
        echo "Pre-flight failed with unknown error." >&2
        echo "Check the build log for details." >&2
      fi
      warn "Pre-flight: unknown preflight failure — cannot proceed"
      return 1
    fi

    # Find the root HW package that causes the blocker
    local root_pkg=""
    local blocker_name=""
    local dependent_names=""

    if [[ "$blocker_type" == "dep-breakage" ]]; then
      # Dep-breakage: blocker is the breaking package
      while IFS='|' read -r breaker dependents; do
        [[ -n "$breaker" ]] || continue
        blocker_name="$breaker"
        dependent_names="$dependents"

        for pkg in "${_pff_packages[@]}"; do
          if _pff_pactree_depends "$pkg" "$breaker"; then
            root_pkg="$pkg"
            break 2
          fi
        done
      done <"$blocker_file"
    else
      # File-conflict: blocker is the new package
      while IFS='|' read -r new_pkg old_pkg file_path; do
        [[ -n "$new_pkg" ]] || continue
        blocker_name="$new_pkg"
        dependent_names="$old_pkg"

        for pkg in "${_pff_packages[@]}"; do
          if _pff_pactree_depends "$pkg" "$new_pkg"; then
            root_pkg="$pkg"
            break 2
          fi
        done
      done <"$blocker_file"
    fi

    if [[ -z "$root_pkg" ]]; then
      # Can't trace back to a requested package
      if ((interactive)); then
        echo "" >&2
        if [[ "$blocker_type" == "dep-breakage" ]]; then
          echo "Dependency breakage detected but cannot be traced to a requested package:" >&2
          echo "  $blocker_name breaks: $dependent_names" >&2
        else
          echo "File conflict detected but cannot be traced to a requested package:" >&2
          echo "  $blocker_name conflicts with: $dependent_names" >&2
        fi
      fi
      warn "Pre-flight: cannot trace $blocker_name to a requested HW package"
      return 1
    fi

    # Remove the root package
    if ((interactive)); then
      echo "" >&2
      if [[ "$blocker_type" == "dep-breakage" ]]; then
        echo "Installing $root_pkg would require upgrading $blocker_name," >&2
        echo "which is incompatible with packages in the current SteamOS image." >&2
        echo "" >&2
        echo "Affected dependents: $dependent_names" >&2
      else
        echo "Installing $root_pkg would install $blocker_name," >&2
        echo "which conflicts with files owned by $dependent_names." >&2
      fi
      echo "" >&2
      local choice=""
      read -rp "Skip $root_pkg? [y/n]: " choice </dev/tty || true
      if [[ "$choice" != "y" && "$choice" != "Y" ]]; then
        warn "Pre-flight: user declined to skip $root_pkg"
        return 1
      fi
    else
      if [[ "$blocker_type" == "dep-breakage" ]]; then
        warn "Pre-flight: auto-skipping $root_pkg (requires $blocker_name upgrade)"
      else
        warn "Pre-flight: auto-skipping $root_pkg (conflicts with $dependent_names)"
      fi
    fi

    # Remove from array
    local -a new_packages=()
    for pkg in "${_pff_packages[@]}"; do
      [[ "$pkg" == "$root_pkg" ]] || new_packages+=("$pkg")
    done
    _pff_packages=("${new_packages[@]}")
    ((++conflict_skipped)) || true

    log "Pre-flight: skipped $root_pkg, ${#_pff_packages[@]} package(s) remaining"
  done

  # Summary logging
  local installable_count=${#_pff_packages[@]}
  log "Additive package resolution:"
  log "  requested:          $requested_count"
  log "  already installed:  $already_installed (preserved)"
  log "  conflict-skipped:   $conflict_skipped"
  log "  installable:        $installable_count"

  if ((installable_count == 0)); then
    warn "No packages can be safely added without upgrading existing SteamOS packages."
    warn "Leaving package state unchanged."
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Helper: check if a package transitively depends on another via pactree.
#
# Args: $1 = package to check, $2 = dependency to look for
# Uses: MERGED (for chroot context)
# Returns: 0 if $1 depends on $2, 1 otherwise
# ---------------------------------------------------------------------------
_pff_pactree_depends() {
  local pkg="$1"
  local dep="$2"

  # Explicitly handle self-dependency
  [[ "$pkg" == "$dep" ]] && return 0

  local -a _pactree_config=()
  if [[ -n "${PACCONF:-}" ]]; then
    _pactree_config=(--config "$PACCONF")
  fi

  # Run pactree in the chroot if available, otherwise on host
  if [[ -n "${MERGED:-}" && -d "$MERGED" ]]; then
    chroot "$MERGED" pactree "${_pactree_config[@]}" -slu "$pkg" 2>/dev/null | grep -Fxq -- "$dep"
  else
    pactree "${_pactree_config[@]}" -slu "$pkg" 2>/dev/null | grep -Fxq -- "$dep"
  fi
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
