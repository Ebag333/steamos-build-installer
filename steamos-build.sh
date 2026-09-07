#!/bin/bash
#
# steamos-build.sh — unified CLI + YAD frontend for SteamOS NVIDIA tools.
#
# No arguments: launch the YAD GUI.
# Command-line use: pass named arguments only.
#
# Examples:
#   ./steamos-build.sh --action build \
#       --image /home/image/steamdeck-repair.img.bz2 \
#       --workingdir /tmp/steamos-build \
#       --rootfs-size 10G
#
#   ./steamos-build.sh --action flash \
#       --image /home/image/steamdeck-repair-nvidia-usbinstall.img \
#       --device /dev/sda
#
#   ./steamos-build.sh --action configure
#
# The frontend owns presentation and confirmation.  lib/backend.sh owns policy
# and implementation.  Do not add build/flash implementation here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$SCRIPT_DIR/lib/backend.sh"
source "$SCRIPT_DIR/lib/pci-discovery.sh"
# shellcheck source=lib/args.sh
source "$SCRIPT_DIR/lib/args.sh"

# Load build defaults.  If defaults.conf is missing, all flags start blank.
DEFAULTS_CONF="$SCRIPT_DIR/lib/configs/defaults.conf"
if [[ -f "$DEFAULTS_CONF" ]]; then
  # shellcheck source=lib/configs/defaults.conf
  source "$DEFAULTS_CONF"
fi

[[ -f "$BACKEND" ]] || {
  echo "lib/backend.sh not found beside steamos-build.sh" >&2
  exit 1
}

ACTION=""
IMG=""
TARGET_DEV=""
CONFIG_FILE=""
CLI_MODE=0
SETUP_MODE=0

usage() { # lint-ignore: no-shadow
  cat <<'EOF'
Usage:
  steamos-build.sh
      Launch the YAD GUI.

  steamos-build.sh --action build --image FILE --config FILE [options]
  steamos-build.sh --action flash --image FILE --device /dev/sdX
  steamos-build.sh --action live --config FILE
  steamos-build.sh --action validate [--config FILE] [--image FILE] [--output FILE]
  steamos-build.sh --action reboot
  steamos-build.sh --setup

Setup:
  --setup                  Install host dependencies required by this tool

Named arguments:
  --action ACTION          build | flash | live | validate | reboot
  --image FILE             Base SteamOS repair image
  --device DEVICE          Target flash device (flash only)
  --config FILE            Build config file (all build options go here)
  --output-dir DIR         Where to write output image
  --output FILE            Write validation JSON report to file (validate only)

Flash:
  --allow-system-disk      Permit a target detected as the current system disk

Output control:
  --verbose                Show additional detail (package names, command output)
  --debug                  Show debug diagnostics (implies --verbose)

All build options (rootfs size, session, update mode, packages, tweaks, etc.)
are set via --config. See docs/customization_build_config.md for the full list.

No positional parameters are accepted.
EOF
}

# ---------------------------------------------------------------------------
# Host dependency/setup helpers.
# ---------------------------------------------------------------------------
_setup_command() {
  local q
  printf -v q '%q' "${BASH_SOURCE[0]}"
  printf 'bash %s --setup' "$q"
}

_show_setup_required() {
  local missing="$1"
  local cmd text
  cmd="$(_setup_command)"
  text="Required dependencies are missing:\n\n$missing\n\nRun this once to install them:\n\n$cmd"

  # Prefer an already-available GUI notifier.  YAD itself may be the missing
  # dependency, so keep KDE/Zenity fallbacks before dropping to the terminal.
  if command -v yad >/dev/null 2>&1; then
    yad --warning \
      --title="SteamOS NVIDIA — Setup Required" \
      --text="<b>Setup is required.</b>\n\nMissing: $missing\n\nRun:\n<tt>$cmd</tt>" \
      --button="OK":0 \
      --width=620 2>/dev/null || true
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --sorry "$(printf '%b' "$text")" "SteamOS NVIDIA — Setup Required" 2>/dev/null || true
  elif command -v zenity >/dev/null 2>&1; then
    zenity --warning \
      --title="SteamOS NVIDIA — Setup Required" \
      --text="$(printf '%b' "$text")" 2>/dev/null || true
  fi

  echo "Setup required. Missing: $missing" >&2
  echo "Run: $cmd" >&2
  return 1
}

_missing_commands() {
  local cmd
  local -a missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]})) && printf '%s\n' "${missing[*]}"
}

_require_action_dependencies() {
  local action="$1"
  local missing_cmds=""

  case "$action" in
    gui)
      missing_cmds="$(_missing_commands yad || true)"
      ;;
    build)
      missing_cmds="$(_missing_commands \
        losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar \
        zstd pacman pactree python3 readelf sgdisk sfdisk partx unshare lspci modinfo || true)"
      ;;
    flash)
      missing_cmds="$(_missing_commands \
        lsblk blockdev findmnt mountpoint sgdisk sfdisk pv udevadm || true)"
      ;;
    configure)
      # post-install configuration is GUI-driven.
      missing_cmds="$(_missing_commands yad || true)"
      ;;
    validate)
      # validate has minimal dependencies
      ;;
    reboot | list-images | list-devices | is-system-disk | preflight) ;;
  esac

  [[ -z "$missing_cmds" ]] || _show_setup_required "$missing_cmds"
}

# _ensure_user_password
#   Check whether the current user has a password set.  If not, prompt them
#   to create one interactively via passwd.  Returns 1 if the account is
#   locked or password setup fails.
_ensure_user_password() {
  local user="${SUDO_USER:-${USER:-deck}}"
  local status

  status="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"

  case "$status" in
    P)
      return 0
      ;;

    NP)
      echo
      echo "SteamOS normally ships with no password configured for '$user'."
      echo
      echo "This installer requires administrator access, and a password is"
      echo "also recommended when using SteamOS as a general-purpose desktop."
      echo
      echo "Please create a password for '$user' now."
      echo
      passwd "$user" || {
        echo "ERROR: Password setup failed." >&2
        return 1
      }
      echo
      echo "Password configured successfully."
      echo
      ;;

    L)
      echo "ERROR: The '$user' account is password-locked." >&2
      echo "Cannot continue with sudo setup." >&2
      return 1
      ;;

    *)
      echo "ERROR: Unable to determine password status for '$user'." >&2
      return 1
      ;;
  esac
}

_run_setup() {
  local self="${BASH_SOURCE[0]}"

  if [[ $EUID -ne 0 ]]; then
    # Passwordless sudo — already cached or configured.
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      exec sudo bash "$self" --setup
    fi

    # Ensure the user has a password so sudo can work.
    _ensure_user_password || exit 1

    # Now sudo should accept the password they just set.
    exec sudo bash "$self" --setup
  fi

  command -v pacman >/dev/null 2>&1 || {
    echo "--setup currently supports Arch/SteamOS hosts with pacman." >&2
    exit 1
  }

  echo "=== SteamOS NVIDIA setup ==="

  # Initialize pacman keyring if missing — pacman -S will fail without it.
  if [[ ! -d /etc/pacman.d/gnupg ]] || ! pacman-key --list-keys >/dev/null 2>&1; then
    echo "Initializing pacman keyring..."
    pacman-key --init
    pacman-key --populate archlinux holo
  fi

  # Keep the canonical dependency list in lib/check-deps.sh when available.
  # This installs build dependencies and lets that helper evolve independently
  # of the frontend.
  if [[ ! -f "$SCRIPT_DIR/lib/check-deps.sh" ]]; then
    echo "ERROR: lib/check-deps.sh is missing — cannot install dependencies." >&2
    exit 1
  fi
  bash "$SCRIPT_DIR/lib/check-deps.sh" --install

  echo
  echo "Setup complete. Run the script again normally:"
  printf '  bash %q\n' "$self"
}

# ---------------------------------------------------------------------------
# Argument parsing.  No args means GUI.
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
  CLI_MODE=1
fi

while [[ $# -gt 0 ]]; do
  if parse_common_arg "$1" "${2:-}"; then
    shift "$_ARG_SHIFT"
    continue
  fi

  case "$1" in
    --setup)
      SETUP_MODE=1
      CLI_MODE=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --gui)
      CLI_MODE=0
      shift
      ;;
    --)
      shift
      [[ $# -eq 0 ]] || {
        echo "Positional parameters are not supported." >&2
        exit 2
      }
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SETUP_MODE" -eq 1 ]]; then
  [[ -z "$ACTION" ]] || {
    echo "--setup cannot be combined with --action." >&2
    exit 2
  }
  _run_setup
  exit 0
fi

# ---------------------------------------------------------------------------
# Backend invocation helpers.
# ---------------------------------------------------------------------------
_build_backend_args() {
  BACKEND_ARGS=(--action "$ACTION")

  [[ -n "$IMG" ]] && BACKEND_ARGS+=(--image "$IMG")
  [[ -n "$TARGET_DEV" ]] && BACKEND_ARGS+=(--device "$TARGET_DEV")
  [[ -n "$CONFIG_FILE" ]] && BACKEND_ARGS+=(--config "$CONFIG_FILE")
  [[ -n "${OUTPUT_DIR:-}" ]] && BACKEND_ARGS+=(--output-dir "$OUTPUT_DIR")
  [[ "${ALLOW_SYSTEM_DISK:-0}" -eq 1 ]] && BACKEND_ARGS+=(--allow-system-disk)
  [[ -n "${VALIDATE_OUTPUT_FILE:-}" ]] && BACKEND_ARGS+=(--output "$VALIDATE_OUTPUT_FILE")
  [[ "${DEBUG:-0}" -eq 1 ]] && BACKEND_ARGS+=(--debug)
  [[ "${VERBOSE:-0}" -eq 1 ]] && BACKEND_ARGS+=(--verbose)
  return 0
}

_backend_needs_root() {
  case "$1" in
    build | flash | flashless | validate | reboot) return 0 ;;
    *) return 1 ;;
  esac
}

# Build runs in a private mount namespace so loop devices, overlay filesystems,
# and chroot mounts never leak into the desktop session.  Flash must NOT use
# namespace isolation — the flasher needs to unmount target partitions from the
# desktop's namespace.
_backend_needs_mount_namespace() {
  [[ "$1" == "build" ]]
}

# Extract --action value from a set of backend arguments.
_backend_action_from_args() {
  local prev="" arg
  for arg in "$@"; do
    if [[ "$prev" == "--action" ]]; then
      printf '%s\n' "$arg"
      return 0
    fi
    prev="$arg"
  done
  return 1
}

_run_backend_cli() {
  _build_backend_args
  echo "[cli] ACTION=$ACTION EUID=$EUID" >&2

  if _backend_needs_mount_namespace "$ACTION"; then
    echo "[cli] needs mount namespace" >&2
    command -v unshare >/dev/null 2>&1 || {
      echo "unshare is required for build mount isolation." >&2
      exit 1
    }
    if [[ $EUID -ne 0 ]]; then
      sudo unshare --mount --propagation private -- \
        bash "$BACKEND" "${BACKEND_ARGS[@]}"
      return $?
    fi
    unshare --mount --propagation private -- \
      bash "$BACKEND" "${BACKEND_ARGS[@]}"
    return $?
  fi

  echo "[cli] checking root" >&2
  if _backend_needs_root "$ACTION" && [[ $EUID -ne 0 ]]; then
    echo "[cli] needs root, checking sudo" >&2
    if ! command -v sudo >/dev/null 2>&1; then
      echo "Error: $ACTION requires root. Run with sudo or as root." >&2
      exit 1
    fi
    echo "[cli] running with sudo" >&2
    sudo bash "$BACKEND" "${BACKEND_ARGS[@]}"
    return $?
  fi

  echo "[cli] running directly" >&2
  bash "$BACKEND" "${BACKEND_ARGS[@]}"
  return $?
}

_ui_error() {
  yad --error \
    --title="SteamOS NVIDIA" \
    --text="$1" \
    --button="OK":0 \
    --width=560 2>/dev/null || echo "ERROR: $1" >&2
}

_ui_info() {
  yad --info \
    --title="SteamOS NVIDIA" \
    --text="$1" \
    --button="OK":0 \
    --width=560 2>/dev/null || true
}

_ui_require_yad() {
  _require_action_dependencies gui || exit 1
}

# _feed_progress LOGFILE RCFILE [LOG_LINES] [RUNNER_PID]
#   Emit yad/zenity-compatible progress lines from a backend log file.
#   Blocks until RCFILE appears (runner finished), then emits 100.
#   If LOG_LINES is "log", also emits "# " prefixed log lines for yad --enable-log.
_feed_progress() {
  local logfile="$1" rcfile="$2" show_log="${3:-}" runner_pid="${4:-}"
  local offset=0 line

  while [[ ! -f "$rcfile" ]]; do
    if IFS= read -r line < <(tail -c +$((offset + 1)) "$logfile" 2>/dev/null | head -n 1); then
      offset=$((offset + $(printf '%s\n' "$line" | wc -c)))
      if [[ "$line" =~ @@PROGRESS:([0-9]+)@@ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      elif [[ "$show_log" == "log" ]]; then
        printf '# %s\n' "$line"
      fi
    else
      # No new data yet.  If the runner is gone and rcfile still doesn't
      # exist, the backend died without writing its exit code — bail out.
      if [[ -n "$runner_pid" ]] && ! kill -0 "$runner_pid" 2>/dev/null; then
        break
      fi
      sleep 0.2
    fi
  done

  # Drain any remaining output after the runner exited.
  tail -c +$((offset + 1)) "$logfile" 2>/dev/null | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ @@PROGRESS:([0-9]+)@@ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ "$show_log" == "log" ]]; then
      printf '# %s\n' "$line"
    fi
  done

  printf '%s\n' 100
}

# Prompt for and cache the user's sudo password via yad.
# Usage: _gui_cache_sudo_password <context_label> <prompt_text>
#   context_label – "build" or "non-build" (used in debug messages)
#   prompt_text   – the yad dialog prompt string
# Returns 0 on success, 1 on cancellation or auth failure.
# On failure, the caller's $tmpdir is cleaned up.
_gui_cache_sudo_password() {
  local ctx="$1" prompt="$2"

  if ! sudo -n true 2>/dev/null; then
    echo "[gui] sudo -n failed, prompting for password ($ctx)..." >&2
    local pass
    pass="$(yad --entry \
      --title="Authentication required" \
      --text="$prompt" \
      --hide-text \
      --button="Cancel":1 \
      --button="OK":0 \
      --center \
      --width=400 \
      2>/dev/null)" || {
      rm -rf "$tmpdir"
      return 1
    }
    printf '%s\n' "$pass" | sudo -S -v 2>/dev/null \
      || {
        _ui_error "Authentication failed."
        rm -rf "$tmpdir"
        return 1
      }
    sudo -n true 2>/dev/null \
      || {
        _ui_error "Authentication failed."
        rm -rf "$tmpdir"
        return 1
      }
  else
    echo "[gui] sudo credentials cached, skipping password prompt ($ctx)" >&2
  fi
}

_run_backend_gui() {
  local title="$1"
  shift

  echo "[gui] _run_backend_gui: $title" >&2
  echo "[gui] args: $*" >&2

  local logfile rcfile
  local tmpdir
  tmpdir="$(mktemp -d /tmp/steamos-build.XXXXXX)"
  logfile="$tmpdir/backend.log"
  rcfile="$tmpdir/rc"
  echo "[gui] logfile=$logfile" >&2
  echo "[gui] rcfile=$rcfile" >&2

  local backend_action
  backend_action="$(_backend_action_from_args "$@" || true)"

  local -a launcher=(bash "$BACKEND" "$@")
  if [[ "$backend_action" == "build" ]]; then
    # Build runs in a private mount namespace so loop devices, overlay
    # filesystems, and chroot mounts never leak into the desktop session.
    command -v unshare >/dev/null 2>&1 || {
      _ui_error "unshare is required for build mount isolation."
      rm -rf "$tmpdir"
      return 1
    }
    if [[ $EUID -ne 0 ]]; then
      if command -v sudo >/dev/null 2>&1; then
        # Cache sudo credentials before launching — yad has no terminal
        # for sudo to read a password from.
        _gui_cache_sudo_password "build" "Enter your password to run the build as root:" || return 1
        launcher=(sudo
          unshare --mount --propagation private --
          bash "$BACKEND" "$@")
        echo "[gui] using sudo + private mount namespace" >&2
      elif command -v pkexec >/dev/null 2>&1; then
        launcher=(pkexec
          unshare --mount --propagation private --
          bash "$BACKEND" "$@")
        echo "[gui] using pkexec + private mount namespace" >&2
      else
        echo "[gui] ERROR: no sudo or pkexec available" >&2
        _ui_error "This operation requires root and neither sudo nor pkexec is available."
        rm -rf "$tmpdir"
        return 1
      fi
    else
      launcher=(unshare --mount --propagation private --
        bash "$BACKEND" "$@")
      echo "[gui] using private mount namespace" >&2
    fi
  elif [[ $EUID -ne 0 ]]; then
    # Non-build actions (flash, reboot, etc.) — no namespace isolation.
    if command -v sudo >/dev/null 2>&1; then
      _gui_cache_sudo_password "non-build" "Enter your password to run as root:" || return 1
      launcher=(sudo bash "$BACKEND" "$@")
      echo "[gui] using sudo for elevation" >&2
    elif command -v pkexec >/dev/null 2>&1; then
      launcher=(pkexec bash "$BACKEND" "$@")
      echo "[gui] using pkexec for elevation" >&2
    else
      echo "[gui] ERROR: no sudo or pkexec available" >&2
      _ui_error "This operation requires root and neither sudo nor pkexec is available."
      rm -rf "$tmpdir"
      return 1
    fi
  else
    echo "[gui] already root, no elevation needed" >&2
  fi

  # Run the complete launcher in a wrapper owned by this shell.
  # Record its actual exit status in rcfile so the progress UI can poll it.
  echo "[gui] starting backend runner..." >&2
  (
    set +e
    "${launcher[@]}" >"$logfile" 2>&1
    _rc=$?
    echo "$_rc" >"$rcfile"
    sync "$rcfile" 2>/dev/null
    echo "[gui] runner finished with exit $_rc" >&2
  ) &
  local runner_pid=$!
  echo "[gui] runner_pid=$runner_pid" >&2

  # Brief pause to let the runner start and verify it's alive.
  sleep 0.3
  if ! kill -0 "$runner_pid" 2>/dev/null; then
    echo "[gui] WARNING: runner exited immediately" >&2
  fi

  local yad_rc=0
  local progress_pipe
  progress_pipe="$tmpdir/progress"
  mkfifo "$progress_pipe"

  # Feed progress from the log file, tied to rcfile lifecycle.
  # _feed_progress blocks until the runner writes rcfile, drains remaining
  # output, emits 100, and exits.  No tail -F, no hangs.
  echo "[gui] starting yad progress dialog (primary)..." >&2
  _feed_progress "$logfile" "$rcfile" log "$runner_pid" >"$progress_pipe" &
  local feed_pid=$!
  disown "$feed_pid" 2>/dev/null || true

  yad --progress \
    --title="$title" \
    --text="<b>$title</b>" \
    --auto-close \
    --no-buttons \
    --enable-log="Build / operation log" \
    --log-on-top \
    --scroll \
    --center \
    --width=900 \
    --height=600 \
    <"$progress_pipe" \
    2>/dev/null || yad_rc=$?
  echo "[gui] yad primary exited with code $yad_rc" >&2

  wait "$feed_pid" 2>/dev/null || true
  rm -f "$progress_pipe"

  # If yad failed (e.g. unsupported --enable-log), retry with simpler flags.
  if [[ $yad_rc -ne 0 ]]; then
    echo "[gui] WARNING: progress dialog failed (exit $yad_rc)" >&2
    echo "[gui] Backend log: $logfile" >&2
    echo "[gui] Retrying with simpler yad flags..." >&2
    progress_pipe="$tmpdir/progress-simple"
    mkfifo "$progress_pipe"
    _feed_progress "$logfile" "$rcfile" "" "$runner_pid" >"$progress_pipe" &
    disown $! 2>/dev/null || true

    yad --progress \
      --title="$title" \
      --text="<b>$title</b>" \
      --auto-close \
      --no-buttons \
      --center \
      --width=700 \
      --height=400 \
      <"$progress_pipe" \
      2>/dev/null \
      || {
        echo "[gui] simple yad also failed. Trying zenity..." >&2
        rm -f "$progress_pipe"
        progress_pipe="$tmpdir/progress-zenity"
        mkfifo "$progress_pipe"
        _feed_progress "$logfile" "$rcfile" "" "$runner_pid" >"$progress_pipe" &
        disown $! 2>/dev/null || true
        zenity --progress \
          --title="$title" \
          --text="$title" \
          --auto-close \
          --no-cancel \
          --width=500 \
          <"$progress_pipe" \
          2>/dev/null \
          || {
            echo "[gui] zenity also failed. Waiting in console..." >&2
            echo "[gui] Monitor: tail -f $logfile" >&2
            while [[ ! -f "$rcfile" ]]; do sleep 1; done
          }
      }
    rm -f "$progress_pipe"
  fi

  # Make sure our actual launcher wrapper is finished.
  echo "[gui] waiting for runner to finish..." >&2
  wait "$runner_pid" 2>/dev/null || true

  local rc
  if [[ -s "$rcfile" ]]; then
    rc="$(cat "$rcfile")"
  else
    rc=1
    echo "[gui] WARNING: rcfile empty or missing, assuming failure" >&2
  fi
  rm -f "$rcfile" "$tmpdir"/progress*
  echo "[gui] backend exit code: $rc" >&2

  GUI_LAST_LOG="$logfile"

  if [[ "$rc" -ne 0 ]]; then
    # Extract the actual error reason from the log.
    # die() emits "[fail] message" — grab the last one, strip ANSI codes.
    local error_reason
    error_reason="$(sed 's/\x1b\[[0-9;]*m//g' "$logfile" 2>/dev/null \
      | grep -F '[fail]' \
      | tail -1 \
      | sed 's/.*\[fail\] //')" || true

    # Also grab the last few lines before the error for context.
    local tail_text
    tail_text="$(tail -60 "$logfile" 2>/dev/null || true)"

    echo "ERROR: $title failed (exit $rc)." >&2
    [[ -n "$error_reason" ]] && echo "Reason: $error_reason" >&2
    echo "$tail_text" >&2
    echo "Full log: $logfile" >&2

    # Build a concise error message for the dialog.
    local error_msg="$title failed (exit $rc)."
    if [[ -n "$error_reason" ]]; then
      error_msg="$error_reason"
    fi

    if [[ "${GUI_QUIET:-0}" -ne 1 ]]; then
      _ui_error "<b>$error_msg</b>

Full log: $logfile"

      # Show scrollable log tail so the user can inspect the failure context.
      printf '%s\n' "$tail_text" | yad --text-info \
        --title="Build Log (tail)" \
        --image=dialog-error \
        --window-icon=dialog-error \
        --text="<b>$error_msg</b>" \
        --button="OK":0 \
        --width=900 --height=500 \
        --wrap \
        --tail \
        2>/dev/null || true
    fi

    return "$rc"
  fi

  echo "[gui] success. Log: $logfile" >&2
  return 0
}

# ---------------------------------------------------------------------------
# YAD GUI.
# ---------------------------------------------------------------------------
_ui_select_action() {
  local _result _rc=0
  _result="$(yad --list \
    --title="SteamOS Custom Image" \
    --text="Choose an action:" \
    --column="Action" \
    --column="Description" \
    --print-column=1 \
    --separator="" \
    --center \
    --width=700 \
    --height=340 \
    --button="Cancel":1 \
    --button="OK":0 \
    "Generate Config" "Create a build configuration file" \
    "Build" "Build a custom SteamOS image" \
    "Flash" "Flash a completed installer image to USB" \
    "Flashless" "Install a built image to inactive A/B slot (no USB)" \
    "Live OS" "Apply configuration to the running system" \
    "Validate" "Check configuration and system state" \
    "Diagnostics" "System diagnostics and reporting" \
    "Boot Selector" "Choose which A/B slot to boot into next" \
    "Quit" "Exit" \
    2>/dev/null)" || _rc=$?

  printf '%s' "$_result"
  return "$_rc"
}

# Initramfs module selection dialog.
# Enumerates PCI hardware and shows a checklist of modules grouped by category.
# Prints space-separated module list to stdout; empty if cancelled.
_ui_select_initramfs_modules() {
  # Enumerate hardware and matching modules.
  local kver
  kver="$(uname -r)"
  local hw_data
  hw_data="$(pci_discover_modules "$kver")"

  # Build yad checklist rows from hardware data.
  # Categories: boot-path (storage/USB/TB), display, network, bluetooth, other
  local -a rows=()

  # Add nvidia modules as pre-checked rows if available on this system
  # (the build machine may not have NVIDIA, but the target does).
  for _nmod in nvidia nvidia_modeset nvidia_drm nvidia_uvm; do
    if modinfo "$_nmod" >/dev/null 2>&1; then
      local _ndesc
      _ndesc="$(modinfo -F description "$_nmod" 2>/dev/null | head -1)"
      rows+=("TRUE" "$_nmod" "graphics" "NVIDIA GPU" "-" "${_ndesc:-NVIDIA module}")
    fi
  done

  # Process discovered hardware.
  local seen_modules=""
  while IFS=$'\t' read -r pci class category device bound_driver module mod_desc; do
    [[ "$pci" == "PCI" ]] && continue  # skip header
    [[ "$module" == "-" ]] && continue # no matching module

    # Deduplicate modules (same module may match multiple devices).
    if [[ " $seen_modules " == *" $module "* ]]; then
      continue
    fi
    seen_modules+=" $module"

    # Determine default check state from actual PCI class code.
    # Broad category is still shown for presentation.
    local check="FALSE"
    local cat_label="$category"

    case "$class" in
      0x01*)
        check="TRUE"
        cat_label="boot-path"
        ;; # storage controllers
      0x0c03*)
        check="TRUE"
        cat_label="boot-path"
        ;; # USB/USB4 host controllers
      *) cat_label="$category" ;;
    esac

    # Specific overrides for known boot-critical modules.
    case "$module" in
      thunderbolt | typec | xhci_hcd | xhci_pci | nvme | ahci | btrfs | usbhid | hid_generic)
        check="TRUE"
        cat_label="boot-path"
        ;;
      btusb)
        cat_label="bluetooth"
        ;;
    esac

    rows+=("$check" "$module" "$cat_label" "$device" "$bound_driver" "$mod_desc")
  done <<<"$hw_data"

  if [[ ${#rows[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  local selected
  selected="$(yad --list --checklist \
    --title="Initramfs Module Selection" \
    --text="<b>Select modules for early boot (initramfs).</b>
Modules discovered from PCI hardware on this machine.
<span fgcolor='gray'>Checked = explicitly force into initramfs.
Unchecked = leave to SteamOS's normal initramfs/autoload behavior.
Modules selected by default are detected as critical boot modules.
eGPU users: recommended not to select video/display drivers.</span>" \
    --column="Include" \
    --column="Module" \
    --column="Category" \
    --column="Device" \
    --column="Driver" \
    --column="Description" \
    --separator=" " \
    --print-column=2 \
    --center \
    --width=1000 \
    --height=650 \
    --button="Cancel":1 \
    --button="OK":0 \
    --search-column=2 \
    "${rows[@]}" 2>/dev/null)" || selected=""

  # Clean trailing separators.
  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

# Parse a hardware manifest file and append rows to the caller's 'rows' array.
# Bad lines are appended to the caller's 'bad_lines' array.
# Args: $1 = conf file path, $2 = type filter (e.g. "pacman")
_ui_parse_hw_manifest() {
  local conf="$1"
  local filter_type="$2"
  local line_num=0 line rest type group pkg version default desc

  # shellcheck disable=SC2094  # Read-only: $conf is only read; bad_lines is an array, not a file
  while IFS= read -r line; do
    ((++line_num))
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" != *"|"*"|"*"|"*"|"*"|"*"|"* ]]; then
      bad_lines+=("  $(basename "$conf"):$line_num: $line")
      continue
    fi
    type="${line%%|*}"
    rest="${line#*|}"
    [[ -n "$filter_type" && "$type" != "$filter_type" ]] && continue
    group="${rest%%|*}"
    rest="${rest#*|}"
    pkg="${rest%%|*}"
    rest="${rest#*|}"
    version="${rest%%|*}"
    rest="${rest#*|}"
    default="${rest%%|*}"
    rest="${rest#*|}"
    desc="${rest%%|*}"
    rows+=("$default" "$group" "$pkg" "$version" "$type" "$desc")
  done <"$conf"
}

# Run hardware detection and return detected package names.
# Prints space-separated list to stdout.
_ui_detect_hw() {
  # shellcheck source=lib/detect-hw-packages.sh
  source "$SCRIPT_DIR/lib/detect-hw-packages.sh"
  detect_hw_packages | tr '\n' ' '
}

# Hardware support component selection dialog.
# Prints space-separated item list to stdout; empty if cancelled.
# Items: logitech-hid linux-firmware libfprint fprintd bolt
_ui_select_hw_support() {
  local conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"
  local -a rows=()
  local -a bad_lines=()

  # Read packages from unified manifest.
  [[ -f "$conf" ]] && _ui_parse_hw_manifest "$conf" "pacman"

  if ((${#bad_lines[@]} > 0)); then
    _ui_error "Malformed lines in hardware config:

$(printf '%s\n' "${bad_lines[@]}")

Expected format: group|package|version|default|description
Example: Firmware|linux-firmware|latest|TRUE|Full firmware suite"
    echo ""
    return
  fi

  ((${#rows[@]} > 0)) || {
    _ui_error "No hardware packages found in config files."
    echo ""
    return
  }

  # Run hardware detection.
  local detected
  detected="$(_ui_detect_hw)"

  # Override defaults for detected packages.
  if [[ -n "$detected" ]]; then
    local -a new_rows=()
    local i
    for ((i = 0; i < ${#rows[@]}; i += 6)); do
      local default="${rows[$i]}"
      local group="${rows[$i + 1]}"
      local pkg="${rows[$i + 2]}"
      local version="${rows[$i + 3]}"
      local source="${rows[$i + 4]}"
      local desc="${rows[$i + 5]}"

      # If package is detected, pre-select it.
      if [[ " $detected " == *" $pkg "* ]]; then
        default="TRUE"
      fi

      new_rows+=("$default" "$group" "$pkg" "$version" "$source" "$desc")
    done
    rows=("${new_rows[@]}")
  fi

  local selected yad_rc=0
  selected="$(yad --list --checklist \
    --title="Hardware Support Components" \
    --text="<b>Select hardware support components to install.</b>

<span fgcolor='gray'>Auto-detected packages are pre-selected based on your hardware.
Packages are sourced from Valve's repository or official Arch repositories.</span>" \
    --column="Install" \
    --column="Group" \
    --column="Package" \
    --column="Version" \
    --column="Source" \
    --column="Description" \
    --separator=" " \
    --print-column=3 \
    --center \
    --width=1500 \
    --height=840 \
    --button="Cancel":1 \
    --button="Auto-detect":2 \
    --button="OK":0 \
    "${rows[@]}" \
    2>/dev/null)" || yad_rc=$?

  # Handle Auto-detect button — re-run detection and refresh dialog.
  if [[ "$yad_rc" -eq 2 ]]; then
    _ui_select_hw_support
    return
  fi

  # Clean trailing separators.
  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

# System tweaks selection dialog.
# Reads items from configs/customizations.conf.
# Prints space-separated item list to stdout; empty if cancelled.
_ui_select_system_tweaks() {
  local conf="$SCRIPT_DIR/lib/configs/customizations.conf"
  if [[ ! -r "$conf" ]]; then
    echo "Customizations config not found: $conf" >&2
    echo ""
    return
  fi

  # Build yad arguments from config file
  local -a yad_args=()
  local module item default desc

  while IFS='|' read -r module item default desc; do
    # Skip comments and empty lines
    [[ "$module" =~ ^#.*$ || -z "$module" ]] && continue

    # Skip "always" items (they're not optional)
    [[ "$default" == "always" ]] && continue

    # Add to yad dialog with group prefix
    yad_args+=("$default" "$module: $item" "$desc")
  done <"$conf"

  # If no optional items, return empty
  if [[ ${#yad_args[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  # Show dialog
  local selected
  selected="$(yad --list --checklist \
    --title="System Optimizations" \
    --text="<b>Select system optimizations to apply.</b>" \
    --column="Enable" \
    --column="Tweak" \
    --column="Description" \
    --separator=" " \
    --print-column=2 \
    --center \
    --width=900 \
    --height=600 \
    --button="Cancel":1 \
    --button="OK":0 \
    "${yad_args[@]}" \
    2>/dev/null)" || selected=""

  # Strip group prefix from selected items (remove "Module: " prefix)
  selected="${selected%%|*}"
  selected="${selected% }"
  selected="${selected//*: /}"
  echo "$selected"
}

# Common yad --field definitions and default values for the build settings form.
# Populates _BF_FIELDS and _BF_DEFAULTS arrays for use by callers.
_build_form_common_args() {
  _BF_FIELDS=(
    --field="Branch:CB"
    --field="Rootfs size!Size in MiB, or use K/M/G suffixes"
    --field="Default session:CB"
    --field="Update mode:CB"
    --field="Workspace location:CB"
    --field="Working directory!Use automatic unless you want an explicit build directory"
    --field="Pacman repository!Which package repos to use:CB"
    --field="Base OS packages:CB"
    --field="Hardware support!Install Logitech HID modules, firmware, fingerprint libs, and Thunderbolt support:CHK"
    --field="Initramfs support!Select which kernel modules to force into the initramfs for early boot:CHK"
    --field="System tweaks!PCI realloc, resizable BAR, gamemode, keyring, and more:CHK"
    --field="Add one-click installer!Adds desktop icon to install SteamOS to internal drive:CHK"
    --field="Custom finalize script!Optional .sh to run after image is built:FL"
    --field="Persist builder to /home!Copy steamos-build to /home/.steamos-build for re-use:CHK"
    --button="Cancel":1
    --button="OK":0
  )
  _BF_DEFAULTS=(
    "^stable!beta!preview!rc!bc!pc!main"
    "10240"
    "^game!desktop"
    "^selfheal!hold!stock"
    "^auto!ram!disk"
    "automatic"
    "^Valve default!main"
    "^Add selected packages only!Upgrade base OS first"
    "TRUE"
    "FALSE"
    "TRUE"
    "TRUE"
    ""
    "TRUE"
  )
}

_ui_build() {
  _require_action_dependencies build || return 0

  local conf_file="" source_img="" output_dir=""

  # Selection loop — show a list menu; clicking a row opens the right dialog.
  # The list always reflects current selections so the user can re-pick any item.
  while true; do
    local choice rc=0
    choice="$(yad --list \
      --title="Build SteamOS NVIDIA Image" \
      --text="<b>Select build inputs, then press Build.</b>" \
      --column="Input" \
      --column="Selection" \
      --print-column=1 \
      --separator="" \
      --center \
      --width=1000 \
      --height=320 \
      --button="Cancel":1 \
      --button="Build":2 \
      "Build configuration" "${conf_file:-<i>not selected</i>}" \
      "Source image" "${source_img:-<i>not selected</i>}" \
      "Output directory" "${output_dir:-<i>not selected</i>}" \
      2>/dev/null)" || rc=$?

    # Exit code 2 = Build button, 0 = row double-clicked, 1 = Cancel
    if ((rc == 1)); then
      return 0
    elif ((rc == 2)); then
      # Build pressed — validate all inputs
      local -a missing=()
      [[ -f "$conf_file" ]] || missing+=("  - Build configuration")
      [[ -f "$source_img" ]] || missing+=("  - Source image")
      [[ -d "$output_dir" ]] || missing+=("  - Output directory")
      if [[ ${#missing[@]} -gt 0 ]]; then
        _ui_error "<b>Please select all inputs before building:</b>\n\n$(printf '%s\n' "${missing[@]}")"
        continue
      fi
      break
    fi

    # Row was selected — open the appropriate dialog
    local _tmp=""
    case "$choice" in
      "Build configuration")
        _tmp="$(yad --file \
          --title="Select Build Configuration" \
          --text="Select a build configuration file:" \
          --file-filter="Config files (*.conf) | *.conf" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && conf_file="$_tmp"
        ;;
      "Source image")
        _tmp="$(yad --file \
          --title="Select Source Image" \
          --text="Select the clean SteamOS repair image:" \
          --file-filter="Images (*.img *.img.bz2 *.img.gz *.img.xz *.img.zst) | *.img *.img.bz2 *.img.gz *.img.xz *.img.zst" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && source_img="$_tmp"
        ;;
      "Output directory")
        _tmp="$(yad --file --directory \
          --title="Select Output Directory" \
          --text="Select where to save the finished image:" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && output_dir="$_tmp"
        ;;
    esac
  done

  # Confirmation summary — same box-drawing style as generate-config
  local summary=""
  summary+="═══════════════════════════════════════════════════════════\n"
  summary+="                      BUILD SUMMARY\n"
  summary+="═══════════════════════════════════════════════════════════\n\n"
  summary+="┌─ Inputs ───────────────────────────────────────────────┐\n"
  summary+="│  Config:  $conf_file\n"
  summary+="│  Source:  $source_img\n"
  summary+="│  Output:  $output_dir\n"
  summary+="└────────────────────────────────────────────────────────┘\n"

  yad --text-info \
    --title="Confirm Build" \
    --text="<b>Review build inputs before starting.</b>" \
    --filename=<(printf '%b' "$summary") \
    --button="Cancel":1 \
    --button="Build":0 \
    --center \
    --width=700 \
    --height=300 \
    --fontname="monospace" \
    2>/dev/null || return 0

  # Build
  if _run_backend_gui "Building SteamOS NVIDIA image..." --action build --config "$conf_file" --image "$source_img" --output-dir "$output_dir"; then
    local output
    output="$(grep -oP '(?<=DONE — ).*' "$GUI_LAST_LOG" 2>/dev/null | tail -1 || true)"
    _ui_info "<b>Build complete.</b>

${output:+<b>Output:</b>
$output

}<b>Log:</b>
$GUI_LAST_LOG"
  fi
}

_ui_generate_conf() {
  local sep=$'\x1f'

  # Mode selector — choose between Build and Live OS config generation
  local gen_mode
  gen_mode="$(yad --list \
    --title="Generate Configuration" \
    --text="<b>What type of configuration do you want to generate?</b>" \
    --column="Mode" \
    --column="Description" \
    --print-column=1 \
    --separator="" \
    --center \
    --width=500 \
    --height=250 \
    --button="Cancel":1 \
    --button="OK":0 \
    "Build" "Create a custom SteamOS image from a source image" \
    "Live OS" "Apply configuration to the running system" \
    2>/dev/null)" || return 0

  gen_mode="$(echo "$gen_mode" | tr -d '|' | xargs)"

  local is_live=0
  [[ "$gen_mode" == "Live OS" ]] && is_live=1

  # Shared settings form fields (used by both modes)
  local -a _SHARED_FIELDS=(
    --field="Branch:CB"
    --field="Default session:CB"
    --field="Update mode:CB"
    --field="Pacman repository!Which package repos to use:CB"
    --field="Base OS packages:CB"
    --field="Hardware support!Install Logitech HID modules, firmware, fingerprint libs, and Thunderbolt support:CHK"
    --field="Initramfs support!Select which kernel modules to force into the initramfs for early boot:CHK"
    --field="System tweaks!PCI realloc, resizable BAR, gamemode, keyring, and more:CHK"
  )
  local -a _SHARED_DEFAULTS=(
    "^stable!beta!preview!rc!bc!pc!main"
    "^game!desktop"
    "^selfheal!hold!stock"
    "^Valve default!main"
    "^Add selected packages only!Upgrade base OS first"
    "TRUE"
    "FALSE"
    "TRUE"
  )

  local form
  local -a form_fields form_defaults

  if ((is_live)); then
    form_fields=("${_SHARED_FIELDS[@]}")
    form_defaults=("${_SHARED_DEFAULTS[@]}")

    form="$(yad --form \
      --title="Generate Live OS Configuration" \
      --text="<b>Live OS settings</b>

Configure the options below. This config will be applied directly to your running system." \
      --columns=1 \
      --separator="$sep" \
      --item-separator="!" \
      --align=left \
      --center \
      --scroll \
      --width=900 \
      --height=500 \
      "${form_fields[@]}" \
      "${form_defaults[@]}" \
      2>/dev/null)" || return 0

    local update_branch session update pacman_repo base_os_mode
    local hw_support initramfs_support system_tweaks

    IFS="$sep" read -r \
      update_branch session update \
      pacman_repo base_os_mode \
      hw_support initramfs_support system_tweaks \
      <<<"$form"

    session="${session:-game}"
    update="${update:-selfheal}"
    update_branch="${update_branch:-stable}"
  else
    # Build mode — use the full form with build-specific fields
    local -a _BF_FIELDS _BF_DEFAULTS
    _build_form_common_args

    form="$(yad --form \
      --title="Generate Build Configuration" \
      --text="<b>Build settings</b>

Configure the build options below. The image will be selected when you build." \
      --columns=1 \
      --separator="$sep" \
      --item-separator="!" \
      --align=left \
      --center \
      --scroll \
      --width=900 \
      --height=500 \
      "${_BF_FIELDS[@]}" \
      "${_BF_DEFAULTS[@]}" \
      2>/dev/null)" || return 0

    local update_branch rootfs session update workspace workdir
    local pacman_repo hw_support initramfs_support system_tweaks add_installer
    local custom_finalize persist_builder

    IFS="$sep" read -r \
      update_branch rootfs session update workspace workdir \
      pacman_repo base_os_mode hw_support initramfs_support system_tweaks add_installer \
      custom_finalize persist_builder \
      <<<"$form"

    rootfs="${rootfs:-10240}"
    session="${session:-game}"
    update="${update:-selfheal}"
    workspace="${workspace:-auto}"
    update_branch="${update_branch:-stable}"
  fi

  # Map pacman repo dropdown to config value
  case "$pacman_repo" in
    "Valve default") pacman_repo="valve" ;;
    "main") pacman_repo="main" ;;
  esac

  case "$base_os_mode" in
    "Add selected packages only") base_os_mode="additive" ;;
    "Upgrade base OS first") base_os_mode="upgrade" ;;
  esac

  # Show sub-dialogs for optional items
  local hw_items="" gaming_items="" initramfs_mods=""

  if [[ "${hw_support^^}" == "TRUE" ]]; then
    hw_items="$(_ui_select_hw_support)"
    [[ -n "$hw_items" ]] || return 0
    hw_items="$(echo "$hw_items" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${system_tweaks^^}" == "TRUE" ]]; then
    gaming_items="$(_ui_select_system_tweaks)"
    [[ -n "$gaming_items" ]] || return 0
    gaming_items="$(echo "$gaming_items" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${initramfs_support^^}" == "TRUE" ]]; then
    initramfs_mods="$(_ui_select_initramfs_modules)"
    [[ -n "$initramfs_mods" ]] || return 0
  fi

  # Derive TARGET_VARIANT from neutralize-oobe checkbox state.
  # If neutralize-oobe is selected, suppress OOBE (steamdeck); otherwise keep it (steamdeck-oobe).
  local target_variant="steamdeck-oobe"
  if [[ -n "${gaming_items:-}" && " $gaming_items " == *" neutralize-oobe "* ]]; then
    target_variant="steamdeck"
  fi

  # Helper function to format items with 4 per line
  # Args: $1 = items string (space or newline separated), $2 = prefix (optional)
  _format_items() {
    local items="$1"
    local prefix="${2:-│  }"

    # Normalize: replace newlines with spaces and collapse multiple spaces
    items="$(echo "$items" | tr '\n' ' ' | tr -s ' ')"

    local -a arr
    read -ra arr <<<"$items"
    local count=${#arr[@]}
    local result=""
    local line=""

    if ((count <= 5)); then
      # Single line for 5 or fewer items
      result+="${prefix}${items}\n"
    else
      # Multiple lines, 4 items per line
      local i=0
      for item in "${arr[@]}"; do
        line+="$item "
        ((++i))
        if ((i % 4 == 0)) || ((i == count)); then
          result+="${prefix}${line}\n"
          line=""
        fi
      done
    fi

    # Return the result (printf '%b' interprets escape sequences)
    printf '%b' "$result"
  }

  # Build confirmation summary
  local summary_title="BUILD CONFIGURATION"
  ((is_live)) && summary_title="LIVE OS CONFIGURATION"

  local summary=""
  summary+="═══════════════════════════════════════════════════════════\n"
  summary+="                    $summary_title\n"
  summary+="═══════════════════════════════════════════════════════════\n\n"

  summary+="┌─ General Settings ─────────────────────────────────────┐\n"
  summary+="│  Update Branch:   $update_branch\n"
  ((!is_live)) && summary+="│  Rootfs Size:     ${rootfs} MB\n"
  summary+="│  Default Session: ${session:-game}\n"
  summary+="│  Update Mode:     $update\n"
  local base_os_label
  case "${base_os_mode:-additive}" in
    additive) base_os_label="Add selected packages only" ;;
    upgrade) base_os_label="Upgrade base OS first" ;;
  esac
  summary+="│  Base OS mode:  $base_os_label\n"
  ((!is_live)) && summary+="│  Workspace:       $workspace\n"
  if ((!is_live)) && [[ -n "${workdir:-}" && "$workdir" != "automatic" ]]; then
    summary+="│  Working Dir:     $workdir\n"
  fi
  summary+="└────────────────────────────────────────────────────────┘\n\n"

  summary+="┌─ Enabled Features ─────────────────────────────────────┐\n"
  ((!is_live)) && [[ "${add_installer^^}" == "TRUE" ]] && summary+="│  ✓ One-click installer\n"
  [[ -n "$hw_items" ]] && summary+="│  ✓ Hardware support\n"
  [[ -n "$gaming_items" ]] && summary+="│  ✓ System tweaks\n"
  [[ -n "$initramfs_mods" ]] && summary+="│  ✓ Initramfs modules\n"
  ((!is_live)) && [[ -n "${custom_finalize:-}" ]] && summary+="│  ✓ Custom finalize script\n"
  summary+="└────────────────────────────────────────────────────────┘\n\n"

  summary+="┌─ Hardware Support ─────────────────────────────────────┐\n"
  if [[ -n "$hw_items" ]]; then
    summary+="$(_format_items "$hw_items")\n"
  else
    summary+="│  (none selected)\n"
  fi
  summary+="└────────────────────────────────────────────────────────┘\n\n"

  summary+="┌─ System Tweaks ────────────────────────────────────────┐\n"
  if [[ -n "$gaming_items" ]]; then
    summary+="$(_format_items "$gaming_items")\n"
  else
    summary+="│  (none selected)\n"
  fi
  summary+="└────────────────────────────────────────────────────────┘\n\n"

  summary+="┌─ Initramfs Modules ────────────────────────────────────┐\n"
  if [[ -n "$initramfs_mods" ]]; then
    summary+="$(_format_items "$initramfs_mods")\n"
  else
    summary+="│  (none selected)\n"
  fi
  summary+="└────────────────────────────────────────────────────────┘\n"

  # Show confirmation dialog with scrollable text view
  yad --text-info \
    --title="Confirm Configuration" \
    --text="<b>Review your $gen_mode configuration before saving.</b>" \
    --filename=<(printf '%b' "$summary") \
    --button="Cancel":1 \
    --button="Save":0 \
    --center \
    --width=700 \
    --height=500 \
    --fontname="monospace" \
    2>/dev/null || return 0

  # Build config content
  local conf_content
  conf_content="# steamos-build config — generated $(date -Iseconds)\n"
  ((is_live)) && conf_content+="# For use with: --action live --config <this file>\n" \
    || conf_content+="# Image path will be set when building\n"
  conf_content+="\n"
  ((!is_live)) && conf_content+="ROOTFS_SIZE=\"$rootfs\"\n"
  conf_content+="TARGET_VARIANT=\"$target_variant\"\n"
  conf_content+="UPDATE_BRANCH=\"$update_branch\"\n"
  conf_content+="DEFAULT_SESSION=\"${session:-game}\"\n"
  conf_content+="UPDATE_MODE=\"${update:-selfheal}\"\n"
  ((!is_live)) && conf_content+="WORKDIR_LOCATION=\"${workspace:-auto}\"\n"
  conf_content+="PACMAN_REPO=\"$pacman_repo\"\n"
  conf_content+="BASE_OS_MODE=\"${base_os_mode:-additive}\"\n"

  if ((!is_live)); then
    [[ -n "${workdir:-}" && "$workdir" != "automatic" ]] && conf_content+="WORKDIR=\"$workdir\"\n"
    [[ "${add_installer^^}" != "TRUE" ]] && conf_content+="ADD_INSTALLER=0\n"
  fi

  # Always write all selection keys (empty if not selected)
  conf_content+="HW_SUPPORT_ITEMS=\"${hw_items:-}\"\n"
  conf_content+="GAMING_ITEMS=\"${gaming_items:-}\"\n"
  conf_content+="INITRAMFS_MODULES=\"${initramfs_mods:-}\"\n"
  if ((!is_live)); then
    [[ -n "${custom_finalize:-}" ]] && conf_content+="CUSTOM_FINALIZE_SCRIPT=\"$custom_finalize\"\n"
    [[ "${persist_builder^^}" != "TRUE" ]] && conf_content+="PERSIST_BUILDER=0\n"
  fi

  # Show file save dialog
  local default_name="steamos-build.conf"
  ((is_live)) && default_name="steamos-live.conf"

  local outfile
  outfile="$(yad --file --save \
    --title="Save Configuration" \
    --filename="$default_name" \
    --file-filter="Config files (*.conf) | *.conf" \
    --center \
    --width=600 \
    2>/dev/null)" || return 0

  # Check if file exists and prompt for overwrite
  if [[ -f "$outfile" ]]; then
    yad --question \
      --title="Overwrite File?" \
      --text="<b>File already exists:</b>

$outfile

Do you want to overwrite it?" \
      --button="Cancel":1 \
      --button="Overwrite":0 \
      --center \
      --width=400 \
      2>/dev/null || return 0
  fi

  printf '%b' "$conf_content" >"$outfile"
  chmod 644 "$outfile"

  local action_hint="build"
  ((is_live)) && action_hint="live"

  _ui_info "<b>Configuration saved.</b>

<b>Path:</b>
$outfile

Press OK to return to the home screen.

<b>Command line usage:</b>
<tt>./steamos-build.sh --action $action_hint --config $outfile</tt>"
}

_ui_flash_pick_image() {
  local rows
  rows="$(bash "$BACKEND" --action list-images 2>/dev/null || true)"

  # No auto-discovered images — fall back to a file chooser.
  if [[ -z "$rows" ]]; then
    yad --file \
      --title="Select Image" \
      --text="No completed installer images were found automatically.\nSelect a SteamOS image file to flash:" \
      --file-filter="Images (*.img *.img.bz2 *.img.gz *.img.xz *.img.zst) | *.img *.img.bz2 *.img.gz *.img.xz *.img.zst" \
      --center \
      --width=700 \
      --height=500
    return
  fi

  local -a table=()
  # shellcheck disable=SC2034
  while IFS=$'\t' read -r path where size epoch modified; do
    [[ -n "$path" ]] || continue
    table+=("$path" "$where" "$size" "$modified")
  done <<<"$rows"

  local selected
  selected="$(yad --list \
    --title="Select Completed Image" \
    --text="Select the installer image to flash:" \
    --column="Image" \
    --column="Location" \
    --column="Size" \
    --column="Modified" \
    --print-column=1 \
    --expand-column=1 \
    --center \
    --width=1050 \
    --height=420 \
    --button="Browse...":12 \
    --button="Cancel":1 \
    --button="OK":0 \
    "${table[@]}")"

  local list_rc=$?

  # Button 12 = "Browse..." — fall back to file chooser.
  if [[ $list_rc -eq 12 ]]; then
    yad --file \
      --title="Select Image" \
      --text="Select a SteamOS image file to flash:" \
      --file-filter="Images (*.img *.img.bz2 *.img.gz *.img.xz *.img.zst) | *.img *.img.bz2 *.img.gz *.img.xz *.img.zst" \
      --center \
      --width=700 \
      --height=500
    return
  fi

  # Cancel or closed.
  [[ $list_rc -eq 0 ]] || return "$list_rc"
  printf '%s' "$selected"
}

_ui_flash_pick_device() {
  local rows
  rows="$(bash "$BACKEND" --action list-devices 2>/dev/null || true)"
  [[ -n "$rows" ]] || {
    _ui_error "No target block devices were found."
    return 1
  }

  local -a table=()
  while IFS=$'\t' read -r dev size tran model tag; do
    [[ -n "$dev" ]] || continue
    table+=("$dev" "$size" "$model" "$tran" "${tag:-}")
  done <<<"$rows"

  yad --list \
    --title="Select Target Device" \
    --text="<b>ALL DATA ON THE SELECTED DEVICE WILL BE DESTROYED.</b>" \
    --column="Device" \
    --column="Size" \
    --column="Model" \
    --column="Bus" \
    --column="Flags" \
    --print-column=1 \
    --center \
    --width=900 \
    --height=420 \
    --button="Cancel":1 \
    --button="OK":0 \
    "${table[@]}" 2>/dev/null
}

_ui_flash() {
  _require_action_dependencies flash || return 0

  echo "[_ui_flash] entered" >&2
  local image device
  image="$(_ui_flash_pick_image)" || {
    echo "[_ui_flash] pick_image cancelled/failed (rc=$?)" >&2
    return 0
  }
  [[ -n "$image" ]] || {
    echo "[_ui_flash] no image selected" >&2
    return 0
  }
  image="${image%%|*}"
  echo "[_ui_flash] image=$image" >&2

  device="$(_ui_flash_pick_device)" || {
    echo "[_ui_flash] pick_device cancelled/failed (rc=$?)" >&2
    return 0
  }
  [[ -n "$device" ]] || {
    echo "[_ui_flash] no device selected" >&2
    return 0
  }
  device="${device%%|*}"
  echo "[_ui_flash] device=$device" >&2

  local allow_system=0
  echo "[_ui_flash] checking system disk (device=$device)..." >&2
  local is_sys=0
  set +e
  bash "$BACKEND" --action is-system-disk --device "$device" >/dev/null 2>&1
  is_sys=$?
  set -e
  echo "[_ui_flash] is-system-disk exit=$is_sys (0=system disk)" >&2
  if [[ $is_sys -eq 0 ]]; then
    yad --warning \
      --title="System Disk Warning" \
      --text="<b>$device appears to be the current system disk.</b>

Do not continue unless you have explicitly verified that overwriting it is intended." \
      --button="Cancel":1 \
      --button="Continue":0 \
      --center \
      --width=600 2>/dev/null || return 0

    yad --question \
      --title="Override System Disk Protection?" \
      --text="Allow flashing <b>$device</b> despite the system-disk check?" \
      --button="Cancel":1 \
      --button="Allow":0 \
      --center \
      --width=520 2>/dev/null || return 0
    allow_system=1
  fi

  local size model tran
  size="$(lsblk -dno SIZE "$device" 2>/dev/null | xargs)"
  model="$(lsblk -dno MODEL "$device" 2>/dev/null | xargs)"
  tran="$(lsblk -dno TRAN "$device" 2>/dev/null | xargs)"

  # Run preflight checks (needs root for blockdev/sgdisk).
  # Cache sudo credentials first so the command substitution doesn't hang on a password prompt.
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
    _gui_cache_sudo_password "flash-preflight" "Enter your password to run preflight checks:" || return 0
  fi

  echo "[_ui_flash] running preflight..." >&2
  local preflight_output preflight_rc=0
  set +e
  if [[ $EUID -eq 0 ]]; then
    preflight_output="$(bash "$BACKEND" --action preflight --image "$image" --device "$device")"
  elif command -v sudo >/dev/null 2>&1; then
    preflight_output="$(sudo bash "$BACKEND" --action preflight --image "$image" --device "$device")"
  elif command -v pkexec >/dev/null 2>&1; then
    preflight_output="$(pkexec bash "$BACKEND" --action preflight --image "$image" --device "$device")"
  else
    preflight_output="$(bash "$BACKEND" --action preflight --image "$image" --device "$device")"
  fi
  preflight_rc=$?
  set -e
  echo "[_ui_flash] preflight exit=$preflight_rc" >&2
  echo "$preflight_output" >&2

  if [[ $preflight_rc -ne 0 ]]; then
    # Extract failure summary for the dialog header.
    local failure_summary
    failure_summary="$(echo "$preflight_output" | sed -n '/^Checks:.*failed$/,/^Flash aborted\.$/p' | awk '!/^Checks:/ && !/^Flash aborted\.$/' | sed 's/^  - /• /')"

    local header="<b>Preflight check failed — high risk action.</b>"
    if [[ -n "$failure_summary" ]]; then
      header+=$'\n\n'"$failure_summary"
    fi
    header+=$'\n\n'"<b>Resolve all preflight issues before flashing.</b>"
    header+=$'\n'"Proceeding anyway may result in a corrupted flash or data loss."

    yad --form \
      --title="Preflight Check Failed" \
      --text="$header" \
      --field="Full Results:TXT" "$preflight_output" \
      --button="Cancel":1 \
      --button="Accept Risk":0 \
      --center \
      --width=700 \
      --height=500 \
      --fontname="monospace" \
      2>/dev/null || return 0
  fi

  # Require the user to confirm the target serial number.
  # Parse from preflight output since TARGET_SERIAL lives in the backend subshell.
  local target_serial
  target_serial="$(echo "$preflight_output" | sed -n 's/^[[:space:]]*Serial:[[:space:]]*//p' | head -1)"
  if [[ -n "$target_serial" && "$target_serial" != "<unknown>" ]]; then
    yad --question \
      --title="Confirm Target Device" \
      --text="<b>WARNING: All data on $device will be destroyed.</b>

Verify this is the correct device:

  Device:  $device
  Model:   ${model:-<unknown>}
  Serial:  $target_serial
  Size:    $size

Is this the correct target?" \
      --button="Cancel":1 \
      --button="Yes, flash this device":0 \
      --center \
      --width=520 2>/dev/null || {
      echo "[_ui_flash] device confirm cancelled" >&2
      return 0
    }
  fi

  yad --form \
    --title="Confirm Flash" \
    --text="<b>About to flash:</b>

$image

<b>To:</b>
$device — $model ($tran, $size)

<b>This permanently destroys all data on $device.</b>" \
    --field="Preflight Results:TXT" "$preflight_output" \
    --button="Cancel":1 \
    --button="Flash":0 \
    --center \
    --width=800 \
    --height=400 \
    2>/dev/null || {
    echo "[_ui_flash] confirm cancelled (rc=$?)" >&2
    return 0
  }

  echo "[_ui_flash] confirmed, starting flash..." >&2

  local -a args=(
    --action flash
    --image "$image"
    --device "$device"
    --confirm
  )
  [[ "$allow_system" -eq 1 ]] && args+=(--allow-system-disk)

  echo "[_ui_flash] calling _run_backend_gui..." >&2

  if _run_backend_gui "Flashing $(basename "$image")..." "${args[@]}"; then
    local flash_log_content
    flash_log_content="$(cat "$GUI_LAST_LOG" 2>/dev/null || true)"
    yad --text-info \
      --title="Flash Complete" \
      --text="<b>Flash complete.</b>\n\n$image → $device" \
      --fontname="monospace" \
      --wrap \
      --center \
      --width=800 \
      --height=500 \
      --button="OK":0 \
      <<<"$flash_log_content" \
      2>/dev/null || true
  fi
}

_ui_flashless() {
  _require_action_dependencies flash || return 0

  local image
  image="$(_ui_flash_pick_image)" || return 0
  [[ -n "$image" ]] || return 0
  image="${image%%|*}"

  yad --question \
    --title="Flashless Install" \
    --text="<b>Install NVIDIA-patched image directly to inactive A/B slot?</b>

Image: $image

This will:
  - Identify the inactive slot (A or B)
  - Write the rootfs to that slot
  - Rebuild the boot environment
  - Activate the slot for next boot

The currently running slot is preserved as a rollback target.
No USB stick is required." \
    --button="Cancel":1 \
    --button="Install":0 \
    --center \
    --width=560 2>/dev/null || return 0

  if _run_backend_gui "Flashless install to inactive slot..." --action flashless --image "$image"; then
    yad --info \
      --title="Flashless Install Complete" \
      --text="<b>Image installed to inactive slot.</b>

Reboot to activate the new slot.
If it fails to boot, SteamOS will automatically fall back." \
      --button="OK":0 \
      --center \
      --width=500 2>/dev/null || true
  fi
}

_ui_live() {
  _require_action_dependencies build || return 0

  local conf_file=""

  # Selection loop — same pattern as _ui_build
  while true; do
    local choice rc=0
    choice="$(yad --list \
      --title="Live OS Configuration" \
      --text="<b>Select a configuration file, then press Apply.</b>

This will apply the configuration directly to your running SteamOS installation.
Requires administrator privileges.

Generate a config first using <b>Generate Config</b> from the main menu." \
      --column="Input" \
      --column="Selection" \
      --print-column=1 \
      --separator="" \
      --center \
      --width=700 \
      --height=300 \
      --button="Cancel":1 \
      --button="Apply":2 \
      "Configuration file" "${conf_file:-<i>not selected</i>}" \
      2>/dev/null)" || rc=$?

    if ((rc == 1)); then
      return 0
    elif ((rc == 2)); then
      [[ -f "$conf_file" ]] || {
        _ui_error "<b>Please select a configuration file before applying.</b>"
        continue
      }
      break
    fi

    local _tmp=""
    case "$choice" in
      "Configuration file")
        _tmp="$(yad --file \
          --title="Select Configuration" \
          --text="Select a configuration file:" \
          --file-filter="Config files (*.conf) | *.conf" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && conf_file="$_tmp"
        ;;
    esac
  done

  # Source config to check for dangerous actions
  # shellcheck disable=SC1090
  source "$conf_file"

  # Build list of dangerous/risky actions present in the config
  local -a warnings=()

  if [[ "${BASE_OS_MODE:-additive}" == "upgrade" ]]; then
    warnings+=("  \u2022 <b>Base OS upgrade</b> — full pacman -Syu; may break packages or pull in unwanted updates")
  fi
  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    [[ " $GAMING_ITEMS " == *" password "* ]] \
      && warnings+=("  \u2022 <b>Set user password</b> — will prompt to change the deck user password")
    [[ " $GAMING_ITEMS " == *" disable-autologin "* ]] \
      && warnings+=("  \u2022 <b>Disable autologin</b> — system will require password at every boot")
    [[ " $GAMING_ITEMS " == *" fix-keyring "* ]] \
      && warnings+=("  \u2022 <b>Fix keyring</b> — reinitializes pacman keyrings")
    [[ " $GAMING_ITEMS " == *" skip-sigcheck "* ]] \
      && warnings+=("  \u2022 <b>Skip signature checks</b> — disables pacman package verification")
  fi

  # Show warning dialog if there are risky items
  if [[ ${#warnings[@]} -gt 0 ]]; then
    local warning_text=""
    warning_text+="The following potentially destructive actions are in your config:\n\n"
    for w in "${warnings[@]}"; do
      warning_text+="$w\n"
    done
    warning_text+="\nAre you sure you want to continue?"

    yad --question \
      --title="Warning — Destructive Actions Detected" \
      --text="$warning_text" \
      --button="Cancel":1 \
      --button="Continue":0 \
      --center \
      --width=600 \
      --height=300 \
      2>/dev/null || return 0
  fi

  # Build confirmation summary
  local summary=""
  summary+="\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n"
  summary+="                    LIVE OS CONFIGURATION\n"
  summary+="\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n\n"
  summary+="\u250c\u2500 Config \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
  summary+="\u2502  $conf_file\n"
  summary+="\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n"

  summary+="\u250c\u2500 Settings \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
  summary+="\u2502  Session:       ${DEFAULT_SESSION:-game}\n"
  summary+="\u2502  Update mode:   ${UPDATE_MODE:-selfheal}\n"
  summary+="\u2502  Base OS mode:  ${BASE_OS_MODE:-additive}\n"
  summary+="\u2502  Update branch: ${UPDATE_BRANCH:-stable}\n"
  summary+="\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n"

  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
    summary+="\u250c\u2500 Hardware Support \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
    summary+="\u2502  ${HW_SUPPORT_ITEMS}\n"
    summary+="\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n"
  fi

  if [[ -n "${GAMING_ITEMS:-}" ]]; then
    summary+="\u250c\u2500 System Tweaks \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
    summary+="\u2502  ${GAMING_ITEMS}\n"
    summary+="\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n"
  fi

  if [[ -n "${INITRAMFS_MODULES:-}" ]]; then
    summary+="\u250c\u2500 Initramfs Modules \u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2510\n"
    summary+="\u2502  ${INITRAMFS_MODULES}\n"
    summary+="\u2514\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2518\n\n"
  fi

  yad --text-info \
    --title="Confirm Live Configuration" \
    --text="<b>Review configuration before applying to the running system.</b>" \
    --filename=<(printf '%b' "$summary") \
    --button="Cancel":1 \
    --button="Apply":0 \
    --center \
    --width=700 \
    --height=500 \
    --fontname="monospace" \
    2>/dev/null || return 0

  # Run live pipeline
  _run_backend_gui "Applying live configuration..." --action live --config "$conf_file"
}

_ui_validate() {
  local conf_file="" image=""

  # Selection loop — same pattern as _ui_build
  while true; do
    local choice rc=0
    choice="$(yad --list \
      --title="Validate Configuration" \
      --text="<b>Select what to validate, then press Validate.</b>

Config file: build configuration to validate against.
Leave blank to validate all items as if everything were enabled.

Image: SteamOS image to validate offline.
Leave blank to validate against the live running system." \
      --column="Input" \
      --column="Selection" \
      --print-column=1 \
      --separator="" \
      --center \
      --width=700 \
      --height=300 \
      --button="Cancel":1 \
      --button="Validate":2 \
      "Config file" "${conf_file:-<i>not selected</i>}" \
      "Image" "${image:-<i>not selected</i>}" \
      2>/dev/null)" || rc=$?

    if ((rc == 1)); then
      return 0
    elif ((rc == 2)); then
      break
    fi

    local _tmp=""
    case "$choice" in
      "Config file")
        _tmp="$(yad --file \
          --title="Select Config File" \
          --text="Select a build configuration file:" \
          --file-filter="Config files (*.conf) | *.conf" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && conf_file="$_tmp"
        ;;
      "Image")
        _tmp="$(yad --file \
          --title="Select Image" \
          --text="Select a SteamOS image to validate offline:" \
          --file-filter="Images (*.img *.img.bz2 *.img.gz *.img.xz *.img.zst) | *.img *.img.bz2 *.img.gz *.img.xz *.img.zst" \
          --center \
          --width=700 \
          --height=500 \
          2>/dev/null)" || true
        [[ -n "$_tmp" ]] && image="$_tmp"
        ;;
    esac
  done

  local -a args=(--action validate)
  [[ -z "$conf_file" ]] || args+=(--config "$conf_file")
  [[ -z "$image" ]] || args+=(--image "$image")

  GUI_QUIET=1
  _run_backend_gui "Validating configuration..." "${args[@]}"
  local rc=$?

  # Show validation results if we have a log
  if [[ -n "${GUI_LAST_LOG:-}" && -f "$GUI_LAST_LOG" ]]; then
    local report
    report="$(sed -n '/SYSTEM STATE REPORT\|VALIDATION REPORT/,$ p' "$GUI_LAST_LOG" 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g')"

    if [[ -n "$report" ]]; then
      local icon="dialog-information"
      if echo "$report" | grep -qE 'Failed:\s*[1-9]'; then
        icon="dialog-error"
      fi

      local key="KEY:
  ✓ = present / passes validation
  · = absent / not configured (informational)
  ✗ = expected but missing (failure — only with config)
  ◆ = present but not selected in config (informational)
  ○ = not present and not selected in config
"
      report="${key}${report}"

      echo "$report" | yad --text-info \
        --title="Validation Results" \
        --image="$icon" \
        --window-icon="$icon" \
        --text="<b>Validation complete</b>" \
        --button="OK":0 \
        --width=700 --height=500 \
        --monospace \
        2>/dev/null || true
    fi
  fi

  return $rc
}

_ui_diagnostics() {
  while true; do
    local choice rc
    set +e
    choice="$(yad --list \
      --title="Diagnostics" \
      --text="Select a diagnostic to run:" \
      --column="Diagnostic" \
      --column="Description" \
      --print-column=1 \
      --separator="" \
      --center \
      --width=700 \
      --height=380 \
      --button="Back":1 \
      --button="Run":0 \
      "Boot Logs" "journalctl, dmesg, and collected boot log archives" \
      "Hardware Info" "PCI device scan with driver status" \
      "Driver State" "NVIDIA driver version, loaded modules, DKMS status" \
      "Package Manifest" "All installed packages (pacman -Q)" \
      "Verify Customizations" "Run verify-customizations.py against the running system" \
      "A/B Slot Status" "RAUC A/B slot health, booted slot, and update state" \
      2>/dev/null)"
    rc=$?
    set -e

    [[ $rc -eq 0 ]] || return 0

    choice="${choice%%|*}"
    choice="${choice//$'\n'/}"

    local -a output=()

    case "$choice" in
      "Boot Logs")
        output+=("=== Boot Logs (journalctl -b) ===")
        output+=("$(journalctl -b --no-pager 2>&1 | tail -200 || echo '  (journalctl unavailable)')")
        output+=("")
        output+=("=== Kernel Messages (dmesg) ===")
        output+=("$(dmesg --level=err,warn 2>&1 | tail -100 || echo '  (dmesg unavailable)')")
        output+=("")
        if [[ -d /boot-logs ]]; then
          output+=("=== Collected Boot Log Archives ===")
          output+=("$(ls -lhtr /boot-logs/*.tar.gz 2>/dev/null || echo '  (none found)')")
        elif [[ -d /home/deck/logs/boot ]]; then
          output+=("=== Collected Boot Log Archives ===")
          output+=("$(ls -lhtr /home/deck/logs/boot/*.tar.gz 2>/dev/null || echo '  (none found)')")
        fi
        ;;
      "Hardware Info")
        output+=("=== Hardware Info ===")
        output+=("$(bash "$SCRIPT_DIR/lib/scan-hardware.sh" 2>&1)")
        ;;
      "Driver State")
        output+=("=== NVIDIA Driver Version ===")
        output+=("$(nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>&1 || echo '  nvidia-smi not available')")
        output+=("")
        output+=("=== Loaded NVIDIA Modules ===")
        output+=("$(lsmod | grep -i nvidia 2>&1 || echo '  (no nvidia modules loaded)')")
        output+=("")
        output+=("=== DKMS Status ===")
        output+=("$(dkms status 2>&1 || echo '  dkms not available')")
        output+=("")
        output+=("=== modprobe config ===")
        output+=("$(cat /etc/modprobe.d/*.conf 2>/dev/null || echo '  (no modprobe configs)')")
        ;;
      "Package Manifest")
        output+=("=== Installed Packages ===")
        output+=("$(pacman -Q 2>&1 || echo '  (pacman unavailable)')")
        ;;
      "Verify Customizations")
        local verify_script="$SCRIPT_DIR/tools/verify-customizations.py"
        if [[ -f "$verify_script" ]]; then
          output+=("=== Verify Customizations ===")
          output+=("$(python3 "$verify_script" --online --all 2>&1 || echo '  (verify script failed)')")
        else
          output+=("=== Verify Customizations ===")
          output+=("ERROR: $verify_script not found")
        fi
        ;;
      "A/B Slot Status")
        output+=("=== RAUC A/B Slot Status ===")
        output+=("$(rauc status --detailed 2>&1 || echo '  rauc not available or not running')")
        output+=("")
        output+=("=== steamos-bootconf ===")
        if command -v steamos-bootconf >/dev/null 2>&1; then
          output+=("  this-image: $(steamos-bootconf this-image 2>&1 || echo '(failed)')")
          output+=("  selected-image: $(steamos-bootconf selected-image 2>&1 || echo '(failed)')")
          output+=("  list-images:")
          output+=("$(steamos-bootconf list-images 2>&1 | sed 's/^/    /' || echo '  (failed)')")
        else
          output+=("  steamos-bootconf not found")
        fi
        ;;
      "")
        continue
        ;;
    esac

    printf '%s\n' "${output[@]}" \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | yad --text-info \
        --title="Diagnostic Results — $choice" \
        --text="<b>$choice</b>" \
        --fontname="monospace" \
        --wrap \
        --center \
        --width=1000 \
        --height=600 \
        --button="Back":0 \
        2>/dev/null || true
  done
}

# Check if the persisted project in /home/.steamos-build/ differs from the
# current run directory.  If so, offer to sync so repatch/live use latest code.
_check_persisted_sync() {
  local persisted="/home/.steamos-build/build_cache"
  local current="$SCRIPT_DIR"

  # If persisted copy doesn't exist, create it silently.
  # This ensures repatch/live paths always have code to work with.
  if [[ ! -d "$persisted/lib" ]]; then
    mkdir -p "$persisted" 2>/dev/null || true
    if ! touch "$persisted/.write-test" 2>/dev/null; then
      return 0
    fi
    rm -f "$persisted/.write-test" 2>/dev/null
    # Remove existing files first (may be owned by root from a previous build)
    rm -f "$persisted/lib" 2>/dev/null || true
    cp -a "$current/lib/." "$persisted/lib/" 2>/dev/null || true
    if [[ -f "$current/steamos-build.sh" ]]; then
      rm -f "$persisted/steamos-build.sh" 2>/dev/null || true
      cp -f "$current/steamos-build.sh" "$persisted/"
    fi
    if [[ -f "$current/LICENSE" ]]; then
      rm -f "$persisted/LICENSE" 2>/dev/null || true
      cp -f "$current/LICENSE" "$persisted/"
    fi
    if [[ -f "$current/README.md" ]]; then
      rm -f "$persisted/README.md" 2>/dev/null || true
      cp -f "$current/README.md" "$persisted/"
    fi
    if [[ -f "$current/.version" ]]; then
      cp -f "$current/.version" "$persisted/.version"
    else
      echo "initial-$(date +%Y%m%d-%H%M%S)" >"$persisted/.version"
    fi
    find "$persisted" -name '*.sh' -type f -exec chmod +x {} +
    return 0
  fi

  # Only check if current also exists
  if [[ ! -d "$current/lib" ]]; then
    return 0
  fi

  # Compare version stamps
  local persisted_ver="" current_ver=""
  [[ -f "$persisted/.version" ]] && persisted_ver="$(cat "$persisted/.version")"
  [[ -f "$current/.version" ]] && current_ver="$(cat "$current/.version")"

  # If versions match, skip
  if [[ -n "$persisted_ver" && -n "$current_ver" && "$persisted_ver" == "$current_ver" ]]; then
    return 0
  fi

  # Count differing files between the synced subset (lib/, top-level files)
  local diff_count=0
  local diff_detail=""
  if command -v diff >/dev/null 2>&1; then
    # Only compare files that the sync actually touches
    diff_detail="$(diff -rq \
      "$current/lib" "$persisted/lib" 2>/dev/null | head -30)" || true
    # Also check top-level files (exclude .version — it's a sync artifact)
    for _f in steamos-build.sh LICENSE README.md; do
      if [[ -f "$current/$_f" && -f "$persisted/$_f" ]]; then
        if ! diff -q "$current/$_f" "$persisted/$_f" >/dev/null 2>&1; then
          diff_detail+=$'\n'"Files $current/$_f and $persisted/$_f differ"
        fi
      elif [[ -f "$current/$_f" && ! -f "$persisted/$_f" ]]; then
        diff_detail+=$'\n'"Only in $current: $_f"
      elif [[ ! -f "$current/$_f" && -f "$persisted/$_f" ]]; then
        diff_detail+=$'\n'"Only in $persisted: $_f"
      fi
    done
    diff_count="$(echo "$diff_detail" | grep -c '^' || true)"
    [[ -z "$diff_detail" ]] && diff_count=0
  fi

  # If mtime difference is less than 60 seconds and no diffs, skip
  local persisted_mtime="" current_mtime=""
  [[ -f "$persisted/lib/common.sh" ]] && persisted_mtime="$(stat -c '%Y' "$persisted/lib/common.sh" 2>/dev/null)"
  [[ -f "$current/lib/common.sh" ]] && current_mtime="$(stat -c '%Y' "$current/lib/common.sh" 2>/dev/null)"
  if [[ -n "$persisted_mtime" && -n "$current_mtime" && "$diff_count" -eq 0 ]]; then
    local diff=$((current_mtime - persisted_mtime))
    [[ "$diff" -lt 0 ]] && diff=$((-diff))
    [[ "$diff" -lt 60 ]] && return 0
  fi

  # Files differ — build the dialog text
  local persisted_label="$persisted_ver"
  [[ -z "$persisted_label" ]] && persisted_label="<no version stamp>"
  local current_label="$current_ver"
  [[ -z "$current_label" ]] && current_label="<no version stamp>"

  # Build diff summary — count direction per file
  local diff_lines=""
  if [[ "$diff_count" -gt 0 ]]; then
    local count_newer=0 count_older=0 count_same=0 count_missing=0 count_extra=0
    while IFS="" read -r line; do
      [[ -n "$line" ]] || continue

      # "Only in /path: file" — file exists in one tree but not the other
      if [[ "$line" == "Only in "* ]]; then
        local only_dir="${line#Only in }"
        only_dir="${only_dir%%:*}"
        if [[ "$only_dir" == "$current"* ]]; then
          ((++count_missing)) || true # exists in current, missing from cache
        else
          ((++count_extra)) || true # exists in cache, not in current
        fi
        continue
      fi

      # "Files /path/a and /path/b differ" — both exist, compare mtimes
      local relpath="${line#*"$current/lib/"}"
      relpath="${relpath%% *}"
      local cur_mtime="" per_mtime=""
      [[ -f "$current/lib/$relpath" ]] && cur_mtime="$(stat -c '%Y' "$current/lib/$relpath" 2>/dev/null)"
      [[ -f "$persisted/lib/$relpath" ]] && per_mtime="$(stat -c '%Y' "$persisted/lib/$relpath" 2>/dev/null)"
      if [[ -n "$cur_mtime" && -n "$per_mtime" ]]; then
        if ((cur_mtime > per_mtime)); then
          ((++count_newer)) || true
        elif ((cur_mtime < per_mtime)); then
          ((++count_older)) || true
        else
          ((++count_same)) || true
        fi
      fi
    done <<<"$diff_detail"

    diff_lines="$diff_count file(s) differ:"
    if ((count_newer > 0)); then
      diff_lines+=$'\n'"  $count_newer cache file(s) are out of date"
    fi
    if ((count_older > 0)); then
      diff_lines+=$'\n'"  $count_older local file(s) are older than cache"
    fi
    if ((count_same > 0)); then
      diff_lines+=$'\n'"  $count_same file(s) differ in contents only"
    fi
    if ((count_missing > 0)); then
      diff_lines+=$'\n'"  $count_missing file(s) missing from cache"
    fi
    if ((count_extra > 0)); then
      diff_lines+=$'\n'"  $count_extra file(s) only in cache"
    fi
  else
    diff_lines="Version stamps differ (file-level diff unavailable)"
  fi

  # Build full dialog text
  local dialog_text
  printf -v dialog_text '%s\n\n%s\n%s\n\n%s\n%s\n\n%s\n%s' \
    "PERSISTED PROJECT IS OUT OF DATE." \
    "The on-device copy at $persisted ($persisted_label)" \
    "differs from the current run directory ($current_label)." \
    "Why this matters: Repatch (self-heal after OS updates) and live" \
    "configuration use the persisted copy. If it's stale, those paths will run old code." \
    "What changed:" \
    "$diff_lines"

  # Write dialog text to temp file — YAD --text doesn't handle embedded
  # newlines in a variable reliably, but --text-info --filename does.
  local _sync_tmp
  _sync_tmp="$(mktemp /tmp/steamos-build-sync-XXXXXX.txt)"
  printf '%s' "$dialog_text" >"$_sync_tmp"

  local _sync_rc=0
  yad --text-info \
    --title="Project Sync" \
    --filename="$_sync_tmp" \
    --button="Skip":1 \
    --button="Sync":0 \
    --center \
    --width=700 \
    --height=400 \
    --wrap \
    2>/dev/null || _sync_rc=$?
  rm -f "$_sync_tmp"
  if [[ $_sync_rc -ne 0 ]]; then
    return 0
  fi

  # User chose Sync
  # Ensure directory exists and files are writable (may be owned by root from a build)
  mkdir -p "$persisted" 2>/dev/null || true

  local _test_file="$persisted/.sync-write-test"
  if ! touch "$_test_file" 2>/dev/null || ! echo "test" >"$_test_file" 2>/dev/null; then
    sudo chown -R "$(id -u):$(id -g)" "$persisted" 2>/dev/null || true
    if ! touch "$_test_file" 2>/dev/null || ! echo "test" >"$_test_file" 2>/dev/null; then
      rm -f "$_test_file" 2>/dev/null
      return 0
    fi
  fi
  rm -f "$_test_file" 2>/dev/null

  # lib/ — full sync with delete (removes stale files from cache)
  local _sync_rc=0
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$current/lib/" "$persisted/lib/" 2>&1 || _sync_rc=$?
  else
    rm -rf "${persisted:?}/lib" 2>&1 || true
    cp -a "$current/lib" "$persisted/lib" 2>&1 || _sync_rc=$?
  fi

  # Clean stale top-level files/dirs from cache that don't exist in current project
  local _entry
  for _entry in "$persisted"/*; do
    [[ -e "$_entry" ]] || continue
    local _name
    _name="$(basename "$_entry")"
    # Skip hidden files (.version, .editorconfig, etc.) — they're managed separately
    [[ "$_name" == .* ]] && continue
    # If this entry doesn't exist in current, remove it from cache
    if [[ ! -e "$current/$_name" ]]; then
      rm -rf "$_entry" 2>&1 || true
    fi
  done

  # Top-level files — only steamos-build.sh, LICENSE, and README
  # Remove existing files first (may be owned by root from a previous build)
  if [[ -f "$current/steamos-build.sh" ]]; then
    rm -f "$persisted/steamos-build.sh" 2>/dev/null || true
    cp -f "$current/steamos-build.sh" "$persisted/" 2>&1 || true
  fi
  if [[ -f "$current/LICENSE" ]]; then
    rm -f "$persisted/LICENSE" 2>/dev/null || true
    cp -f "$current/LICENSE" "$persisted/" 2>&1 || true
  fi
  if [[ -f "$current/README.md" ]]; then
    rm -f "$persisted/README.md" 2>/dev/null || true
    cp -f "$current/README.md" "$persisted/" 2>&1 || true
  fi

  # Update version stamp — remove existing file first (may be owned by root)
  rm -f "$persisted/.version" 2>/dev/null || true
  if [[ -f "$current/.version" ]]; then
    cp -f "$current/.version" "$persisted/.version" 2>&1 || true
  else
    echo "manual-sync-$(date +%Y%m%d-%H%M%S)" >"$persisted/.version" 2>&1 || true
  fi

  # Ensure scripts are executable
  find "$persisted" -name '*.sh' -type f -exec chmod +x {} + 2>&1 || true
}

_ui_main() {
  _ui_require_yad

  # Check if persisted project in /home differs from the run directory.
  # If so, offer to sync so repatch/live paths use the latest code.
  _check_persisted_sync

  while true; do
    local choice rc
    set +e
    choice="$(_ui_select_action)"
    rc=$?
    set -e

    # yad exit codes: 0=OK, 1=Cancel, 70=window close, etc.
    [[ $rc -eq 0 ]] || exit 0

    # YAD list output can include a trailing row separator depending on
    # version/options. Normalize it before dispatch so "Build|" does not fall
    # through the case statement and redraw the main menu.
    choice="${choice%%|*}"
    choice="${choice//$'\n'/}"

    case "$choice" in
      Build)
        _ui_build
        ;;
      "Generate Config")
        _ui_generate_conf
        ;;
      Flash)
        _ui_flash
        ;;
      Flashless)
        _ui_flashless
        ;;
      "Live OS")
        _ui_live
        ;;
      Diagnostics)
        _ui_diagnostics
        ;;
      Validate)
        _ui_validate
        ;;
      "Boot Selector")
        yad --question \
          --title="Boot Selector" \
          --text="Choose which A/B slot to boot into next?" \
          --button="Cancel":1 \
          --button="Select":0 \
          --center \
          --width=480 2>/dev/null || continue
        _run_backend_gui "Boot selector..." --action reboot || true
        ;;
      Quit | "")
        exit 0
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# CLI dispatch.
# ---------------------------------------------------------------------------
if [[ "$CLI_MODE" -eq 0 ]]; then
  _ui_main
  exit 0
fi

[[ -n "$ACTION" ]] || {
  echo "--action is required when using command-line arguments." >&2
  usage >&2
  exit 2
}

_require_action_dependencies "$ACTION" || exit 1

case "$ACTION" in
  build)
    [[ -n "$IMG" || -n "$CONFIG_FILE" ]] || {
      echo "Build requires --image FILE or a config that supplies IMG." >&2
      exit 2
    }
    _run_backend_cli
    ;;
  flash)
    [[ -n "$IMG" ]] || {
      echo "Flash requires --image FILE." >&2
      exit 2
    }
    [[ -n "$TARGET_DEV" ]] || {
      echo "Flash requires --device DEVICE." >&2
      exit 2
    }

    echo "WARNING: flashing permanently destroys all data on $TARGET_DEV." >&2
    read -r -p "Type YES to continue: " answer
    [[ "$answer" == "YES" ]] || {
      echo "Canceled."
      exit 1
    }

    _build_backend_args
    BACKEND_ARGS+=(--confirm)

    if [[ $EUID -ne 0 ]]; then
      exec sudo bash "$BACKEND" "${BACKEND_ARGS[@]}"
    fi
    exec bash "$BACKEND" "${BACKEND_ARGS[@]}"
    ;;
  live)
    [[ -n "$CONFIG_FILE" ]] || {
      echo "Live action requires --config FILE." >&2
      exit 2
    }
    _run_backend_cli
    ;;
  reboot)
    if [[ $EUID -ne 0 ]]; then
      exec sudo bash "$BACKEND" --action reboot
    fi
    exec bash "$BACKEND" --action reboot
    ;;
  validate)
    _run_backend_cli
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
