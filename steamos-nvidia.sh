#!/bin/bash
#
# steamos-nvidia.sh — unified CLI + YAD frontend for SteamOS NVIDIA tools.
#
# No arguments: launch the YAD GUI.
# Command-line use: pass named arguments only.
#
# Examples:
#   ./steamos-nvidia.sh --action build \
#       --image /home/image/steamdeck-repair.img.bz2 \
#       --workingdir /tmp/nvidia-build \
#       --rootfs-size 10G
#
#   ./steamos-nvidia.sh --action flash \
#       --image /home/image/steamdeck-repair-nvidia-usbinstall.img \
#       --device /dev/sda
#
#   ./steamos-nvidia.sh --action configure
#
# The frontend owns presentation and confirmation.  lib/backend.sh owns policy
# and implementation.  Do not add build/flash implementation here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$SCRIPT_DIR/lib/backend.sh"
source "$SCRIPT_DIR/lib/pci-discovery.sh"

# Load build defaults.  If defaults.conf is missing, all flags start blank.
DEFAULTS_CONF="$SCRIPT_DIR/lib/configs/defaults.conf"
if [[ -f "$DEFAULTS_CONF" ]]; then
  # shellcheck source=lib/configs/defaults.conf
  source "$DEFAULTS_CONF"
fi

[[ -f "$BACKEND" ]] || {
  echo "lib/backend.sh not found beside steamos-nvidia.sh" >&2
  exit 1
}

ACTION=""
IMG=""
TARGET_DEV=""
CONFIG_FILE=""
CLI_MODE=0
SETUP_MODE=0

usage() {
  cat <<'EOF'
Usage:
  steamos-nvidia.sh
      Launch the YAD GUI.

  steamos-nvidia.sh --action build --image FILE --config FILE [options]
  steamos-nvidia.sh --action flash --image FILE --device /dev/sdX
  steamos-nvidia.sh --action configure
  steamos-nvidia.sh --action validate [--config FILE]
  steamos-nvidia.sh --action reboot
  steamos-nvidia.sh --setup

Setup:
  --setup                  Install host dependencies required by this tool

Named arguments:
  --action ACTION          build | flash | configure | reboot
  --image FILE             Base SteamOS repair image
  --device DEVICE          Target flash device (flash only)
  --config FILE            Build config file (all build options go here)
  --output-dir DIR         Where to write output image

Flash:
  --allow-system-disk      Permit a target detected as the current system disk

All build options (rootfs size, session, update mode, packages, tweaks, etc.)
are set via --config. See docs/customization_build_config.md for the full list.

No positional parameters are accepted.
EOF
}

# ---------------------------------------------------------------------------
# Host dependency/setup helpers.
# ---------------------------------------------------------------------------
setup_command() {
  local q
  printf -v q '%q' "${BASH_SOURCE[0]}"
  printf 'bash %s --setup' "$q"
}

show_setup_required() {
  local missing="$1"
  local cmd text
  cmd="$(setup_command)"
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

missing_commands() {
  local cmd
  local -a missing=()
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  ((${#missing[@]})) && printf '%s\n' "${missing[*]}"
}

require_action_dependencies() {
  local action="$1"
  local missing_cmds=""

  case "$action" in
    gui)
      missing_cmds="$(missing_commands yad || true)"
      ;;
    build)
      missing_cmds="$(missing_commands \
        losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar \
        zstd pacman python3 readelf sgdisk sfdisk partx unshare lspci modinfo || true)"
      ;;
    flash)
      missing_cmds="$(missing_commands \
        lsblk blockdev findmnt mountpoint sgdisk sfdisk pv udevadm || true)"
      ;;
    configure)
      # post-install configuration is GUI-driven.
      missing_cmds="$(missing_commands yad || true)"
      ;;
    reboot | list-images | list-devices | is-system-disk | preflight) ;;
  esac

  [[ -z "$missing_cmds" ]] || show_setup_required "$missing_cmds"
}

# ensure_user_password
#   Check whether the current user has a password set.  If not, prompt them
#   to create one interactively via passwd.  Returns 1 if the account is
#   locked or password setup fails.
ensure_user_password() {
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

run_setup() {
  local self="${BASH_SOURCE[0]}"

  if [[ $EUID -ne 0 ]]; then
    # Passwordless sudo — already cached or configured.
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      exec sudo bash "$self" --setup
    fi

    # Ensure the user has a password so sudo can work.
    ensure_user_password || exit 1

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
  if [[ -f "$SCRIPT_DIR/lib/check-deps.sh" ]]; then
    bash "$SCRIPT_DIR/lib/check-deps.sh" --install
  else
    echo "WARNING: lib/check-deps.sh is missing; installing the known baseline." >&2
    pacman -S --needed --noconfirm \
      gawk util-linux btrfs-progs bzip2 curl kmod gzip pv python binutils \
      rsync sed tar xz zstd
  fi

  # Frontend/flash dependencies not guaranteed by check-deps.sh.
  pacman -S --needed --noconfirm yad gptfdisk pciutils

  # Verify the common GUI + build + flash surface rather than claiming success
  # solely because pacman returned zero.
  local missing
  missing="$(missing_commands \
    yad losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar \
    zstd pacman python3 readelf sgdisk sfdisk partx unshare lspci modinfo lsblk \
    blockdev findmnt mountpoint udevadm || true)"

  if [[ -n "$missing" ]]; then
    echo "Setup completed, but these commands are still missing: $missing" >&2
    exit 1
  fi

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
  case "$1" in
    --action)
      ACTION="${2:?--action requires a value}"
      shift 2
      ;;
    --image)
      IMG="${2:?--image requires a value}"
      shift 2
      ;;
    --device)
      TARGET_DEV="${2:?--device requires a value}"
      shift 2
      ;;
    --config)
      CONFIG_FILE="${2:?--config requires a value}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:?--output-dir requires a value}"
      shift 2
      ;;

    --allow-system-disk)
      ALLOW_SYSTEM_DISK=1
      shift
      ;;
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
  run_setup
  exit 0
fi

# ---------------------------------------------------------------------------
# Backend invocation helpers.
# ---------------------------------------------------------------------------
build_backend_args() {
  BACKEND_ARGS=(--action "$ACTION")

  [[ -n "$IMG" ]] && BACKEND_ARGS+=(--image "$IMG")
  [[ -n "$TARGET_DEV" ]] && BACKEND_ARGS+=(--device "$TARGET_DEV")
  [[ -n "$CONFIG_FILE" ]] && BACKEND_ARGS+=(--config "$CONFIG_FILE")
  [[ -n "${OUTPUT_DIR:-}" ]] && BACKEND_ARGS+=(--output-dir "$OUTPUT_DIR")
  [[ "${ALLOW_SYSTEM_DISK:-0}" -eq 1 ]] && BACKEND_ARGS+=(--allow-system-disk)
}

backend_needs_root() {
  case "$1" in
    build | flash | flashless | reboot) return 0 ;;
    *) return 1 ;;
  esac
}

# Build runs in a private mount namespace so loop devices, overlay filesystems,
# and chroot mounts never leak into the desktop session.  Flash must NOT use
# namespace isolation — the flasher needs to unmount target partitions from the
# desktop's namespace.
backend_needs_mount_namespace() {
  [[ "$1" == "build" ]]
}

# Extract --action value from a set of backend arguments.
backend_action_from_args() {
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

run_backend_cli() {
  build_backend_args

  if backend_needs_mount_namespace "$ACTION"; then
    command -v unshare >/dev/null 2>&1 || {
      echo "unshare is required for build mount isolation." >&2
      exit 1
    }
    if [[ $EUID -ne 0 ]]; then
      exec sudo unshare --mount --propagation private -- \
        bash "$BACKEND" "${BACKEND_ARGS[@]}"
    fi
    exec unshare --mount --propagation private -- \
      bash "$BACKEND" "${BACKEND_ARGS[@]}"
  fi

  if backend_needs_root "$ACTION" && [[ $EUID -ne 0 ]]; then
    exec sudo bash "$BACKEND" "${BACKEND_ARGS[@]}"
  fi

  exec bash "$BACKEND" "${BACKEND_ARGS[@]}"
}

ui_error() {
  yad --error \
    --title="SteamOS NVIDIA" \
    --text="$1" \
    --button="OK":0 \
    --width=560 2>/dev/null || echo "ERROR: $1" >&2
}

ui_info() {
  yad --info \
    --title="SteamOS NVIDIA" \
    --text="$1" \
    --button="OK":0 \
    --width=560 2>/dev/null || true
}

ui_require_yad() {
  require_action_dependencies gui || exit 1
}

# _feed_progress LOGFILE RCFILE [LOG_LINES]
#   Emit yad/zenity-compatible progress lines from a backend log file.
#   Blocks until RCFILE appears (runner finished), then emits 100.
#   If LOG_LINES is "log", also emits "# " prefixed log lines for yad --enable-log.
_feed_progress() {
  local logfile="$1" rcfile="$2" show_log="${3:-}"
  local offset=0 line

  while [[ ! -f "$rcfile" ]]; do
    if IFS= read -r line < <(tail -c +$((offset + 1)) "$logfile" 2>/dev/null | head -n 1); then
      offset=$((offset + ${#line} + 1))
      if [[ "$line" =~ @@PROGRESS:([0-9]+)@@ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      elif [[ "$show_log" == "log" ]]; then
        printf '# %s\n' "$line"
      fi
    else
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

run_backend_gui() {
  local title="$1"
  shift

  echo "[gui] run_backend_gui: $title" >&2
  echo "[gui] args: $*" >&2

  local logfile rcfile
  local tmpdir
  tmpdir="$(mktemp -d /tmp/steamos-nvidia.XXXXXX)"
  logfile="$tmpdir/backend.log"
  rcfile="$tmpdir/rc"
  echo "[gui] logfile=$logfile" >&2
  echo "[gui] rcfile=$rcfile" >&2

  local backend_action
  backend_action="$(backend_action_from_args "$@" || true)"

  local -a launcher=(bash "$BACKEND" "$@")
  if [[ "$backend_action" == "build" ]]; then
    # Build runs in a private mount namespace so loop devices, overlay
    # filesystems, and chroot mounts never leak into the desktop session.
    command -v unshare >/dev/null 2>&1 || {
      ui_error "unshare is required for build mount isolation."
      rm -rf "$tmpdir"
      return 1
    }
    if [[ $EUID -ne 0 ]]; then
      if command -v sudo >/dev/null 2>&1; then
        # Cache sudo credentials before launching — yad has no terminal
        # for sudo to read a password from.
        if ! sudo -n true 2>/dev/null; then
          echo "[gui] sudo -n failed, prompting for password (build)..." >&2
          local pass
          pass="$(yad --entry \
            --title="Authentication required" \
            --text="Enter your password to run the build as root:" \
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
              ui_error "Authentication failed."
              rm -rf "$tmpdir"
              return 1
            }
          sudo -n true 2>/dev/null \
            || {
              ui_error "Authentication failed."
              rm -rf "$tmpdir"
              return 1
            }
        else
          echo "[gui] sudo credentials cached, skipping password prompt (build)" >&2
        fi
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
        ui_error "This operation requires root and neither sudo nor pkexec is available."
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
      if ! sudo -n true 2>/dev/null; then
        echo "[gui] sudo -n failed, prompting for password (non-build)..." >&2
        local pass
        pass="$(yad --entry \
          --title="Authentication required" \
          --text="Enter your password to run as root:" \
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
            ui_error "Authentication failed."
            rm -rf "$tmpdir"
            return 1
          }
        sudo -n true 2>/dev/null \
          || {
            ui_error "Authentication failed."
            rm -rf "$tmpdir"
            return 1
          }
      else
        echo "[gui] sudo credentials cached, skipping password prompt (non-build)" >&2
      fi
      launcher=(sudo bash "$BACKEND" "$@")
      echo "[gui] using sudo for elevation" >&2
    elif command -v pkexec >/dev/null 2>&1; then
      launcher=(pkexec bash "$BACKEND" "$@")
      echo "[gui] using pkexec for elevation" >&2
    else
      echo "[gui] ERROR: no sudo or pkexec available" >&2
      ui_error "This operation requires root and neither sudo nor pkexec is available."
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
  _feed_progress "$logfile" "$rcfile" log >"$progress_pipe" &
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
    _feed_progress "$logfile" "$rcfile" >"$progress_pipe" &
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
        _feed_progress "$logfile" "$rcfile" >"$progress_pipe" &
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

    ui_error "<b>$error_msg</b>

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

    return "$rc"
  fi

  GUI_LAST_LOG="$logfile"
  echo "[gui] success. Log: $logfile" >&2
  return 0
}

# ---------------------------------------------------------------------------
# YAD GUI.
# ---------------------------------------------------------------------------
ui_select_action() {
  yad --list \
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
    "Configure" "Apply configuration to a live system" \
    "Validate" "Check configuration and system state" \
    "Diagnostics" "System diagnostics and reporting" \
    "Reboot" "Run the project reboot helper" \
    "Quit" "Exit"
}

# Initramfs module selection dialog.
# Enumerates PCI hardware and shows a checklist of modules grouped by category.
# Prints space-separated module list to stdout; empty if cancelled.
ui_select_initramfs_modules() {
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

# Hardware support component selection dialog.
# Prints space-separated item list to stdout; empty if cancelled.
# Items: logitech-hid linux-firmware libfprint fprintd bolt
ui_select_hw_support() {
  local arch_conf="$SCRIPT_DIR/lib/configs/hw-packages-arch.conf"
  local valve_conf="$SCRIPT_DIR/lib/configs/hw-packages-valve.conf"
  local -a rows=()
  local -a bad_lines=()
  local line rest group pkg version default desc line_num

  # Read Valve manifest.
  if [[ -f "$valve_conf" ]]; then
    line_num=0
    while IFS= read -r line; do
      ((++line_num))
      [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" != *"|"*"|"*"|"*"|"* ]]; then
        bad_lines+=("  $(basename "$valve_conf"):$line_num: $line")
        continue
      fi
      group="${line%%|*}"
      rest="${line#*|}"
      pkg="${rest%%|*}"
      rest="${rest#*|}"
      version="${rest%%|*}"
      rest="${rest#*|}"
      default="${rest%%|*}"
      desc="${rest#*|}"
      rows+=("$default" "$group" "$pkg" "$version" "valve" "$desc")
    done <"$valve_conf"
  fi

  # Read Arch manifest.
  if [[ -f "$arch_conf" ]]; then
    line_num=0
    while IFS= read -r line; do
      ((++line_num))
      [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
      if [[ "$line" != *"|"*"|"*"|"*"|"* ]]; then
        bad_lines+=("  $(basename "$arch_conf"):$line_num: $line")
        continue
      fi
      group="${line%%|*}"
      rest="${line#*|}"
      pkg="${rest%%|*}"
      rest="${rest#*|}"
      version="${rest%%|*}"
      rest="${rest#*|}"
      default="${rest%%|*}"
      desc="${rest#*|}"
      rows+=("$default" "$group" "$pkg" "$version" "arch" "$desc")
    done <"$arch_conf"
  fi

  if ((${#bad_lines[@]} > 0)); then
    ui_error "Malformed lines in hardware config:

$(printf '%s\n' "${bad_lines[@]}")

Expected format: group|package|version|default|description
Example: Firmware|linux-firmware|latest|TRUE|Full firmware suite"
    echo ""
    return
  fi

  ((${#rows[@]} > 0)) || {
    ui_error "No hardware packages found in config files."
    echo ""
    return
  }

  local selected
  selected="$(yad --list --checklist \
    --title="Hardware Support Components" \
    --text="<b>Select hardware support components to install.</b>

<span fgcolor='gray'>linux-firmware replaces Valve's Deck subset with the full Arch firmware suite.
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
    --button="OK":0 \
    "${rows[@]}" \
    2>/dev/null)" || selected=""

  # Clean trailing separators.
  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

# System tweaks selection dialog.
# Reads items from configs/customizations.conf.
# Prints space-separated item list to stdout; empty if cancelled.
ui_select_system_tweaks() {
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
  selected="$(echo "$selected" | sed 's/[A-Za-z]*: //g')"
  echo "$selected"
}

# Package and driver builds selection dialog.
# Reads items from configs/hw-packages-build.conf.
# Prints space-separated driver list to stdout; empty if cancelled.
ui_select_package_builds() {
  local conf="$SCRIPT_DIR/lib/configs/hw-packages-build.conf"
  if [[ ! -r "$conf" ]]; then
    echo "Drivers config not found: $conf" >&2
    echo ""
    return
  fi

  # Build yad arguments from config file
  local -a yad_args=()
  local type name version default desc

  while IFS='|' read -r type name version default desc; do
    # Skip comments and empty lines
    [[ "$type" =~ ^#.*$ || -z "$type" ]] && continue

    # Add to yad dialog (show name, not type)
    yad_args+=("$default" "$name" "$desc")
  done <"$conf"

  # If no drivers, return empty
  if [[ ${#yad_args[@]} -eq 0 ]]; then
    echo ""
    return
  fi

  # Show dialog
  local selected
  selected="$(yad --list --checklist \
    --title="Custom Drivers" \
    --text="<b>Select custom drivers to build and install.</b>" \
    --column="Enable" \
    --column="Driver" \
    --column="Description" \
    --separator=" " \
    --print-column=2 \
    --center \
    --width=600 \
    --height=400 \
    --button="Cancel":1 \
    --button="OK":0 \
    "${yad_args[@]}" \
    2>/dev/null)" || selected=""

  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

# Collect build configuration from the shared form + sub-dialogs.
# Prints one arg per line to stdout.  Returns 1 if cancelled.
ui_collect_build_args() {
  local sep=$'\x1f'
  local form

  form="$(yad --form \
    --title="Build SteamOS NVIDIA Image" \
    --text="<b>Build settings</b>

Select the clean SteamOS repair image and adjust any settings you want.
NVIDIA packages follow the version policy in hw-packages-arch.conf." \
    --columns=1 \
    --separator="$sep" \
    --item-separator="!" \
    --align=left \
    --center \
    --scroll \
    --width=1000 \
    --height=600 \
    --field="Base image!Clean SteamOS repair image (.img or compressed):FL" \
    --field="Branch:CB" \
    --field="Rootfs size!Size in MiB, or use K/M/G suffixes" \
    --field="Default session:CB" \
    --field="Update mode:CB" \
    --field="Workspace location:CB" \
    --field="Working directory!Use automatic unless you want an explicit build directory" \
    --field="Hardware support!Install Logitech HID modules, firmware, fingerprint libs, and Thunderbolt support:CHK" \
    --field="Initramfs support!Select which kernel modules to force into the initramfs for early boot:CHK" \
    --field="System tweaks!PCI realloc, resizable BAR, gamemode, keyring, and more:CHK" \
    --field="Package & driver builds!Build and install custom drivers (Logitech HID, AoTofu VA-API, etc.):CHK" \
    --field="Add one-click installer!Adds desktop icon to install SteamOS to internal drive:CHK" \
    --button="Cancel":1 \
    --button="OK":0 \
    "" \
    "^stable!beta!preview!rc!bc!pc!main" \
    "10240" \
    "^game!desktop" \
    "^selfheal!hold!stock" \
    "^auto!ram!disk" \
    "automatic" \
    "TRUE" \
    "FALSE" \
    "TRUE" \
    "TRUE" \
    "TRUE" \
    2>/dev/null)" || return 1

  local base_image update_branch rootfs session update workspace workdir
  local hw_support initramfs_support system_tweaks package_builds add_installer

  IFS="$sep" read -r \
    base_image update_branch rootfs session update workspace workdir \
    hw_support initramfs_support system_tweaks package_builds add_installer \
    <<<"$form"

  rootfs="${rootfs:-10240}"
  session="${session:-game}"
  update="${update:-selfheal}"
  workspace="${workspace:-auto}"
  update_branch="${update_branch:-stable}"

  if [[ "$update_branch" != "stable" ]]; then
    local branch_text="<b>The Stable branch is recommended for most users.</b> Beta and preview are more prone to unexpected issues."
    if [[ "$update_branch" != "beta" && "$update_branch" != "preview" ]]; then
      branch_text+=$'\n\n'"Branches other than stable, beta, and preview are undocumented, choose at your own risk!"
    fi
    yad --question \
      --title="Branch Warning" \
      --text="$branch_text" \
      --button="Cancel":1 \
      --button="Accept":0 \
      --width=500 \
      --center \
      2>/dev/null || return 1
  fi

  if [[ -z "$workdir" || "$workdir" == "automatic" ]]; then
    workdir=""
  fi

  # Write build config to a temporary file
  local conf_file
  conf_file="$(mktemp /tmp/steamos-nvidia-build-XXXXXX.conf)"

  cat >"$conf_file" <<EOF
# Generated by steamos-nvidia GUI at $(date -Iseconds)
IMG="$base_image"
ROOTFS_SIZE="$rootfs"
UPDATE_BRANCH="$update_branch"
DEFAULT_SESSION="$session"
UPDATE_MODE="$update"
WORKDIR_LOCATION="$workspace"
EOF

  [[ -n "$workdir" ]] && echo "WORKDIR=\"$workdir\"" >>"$conf_file"

  local hw_items="" gaming_items="" drivers="" initramfs_mods=""

  if [[ "${hw_support^^}" == "TRUE" ]]; then
    hw_items="$(ui_select_hw_support)"
    if [[ -z "$hw_items" ]]; then
      rm -f "$conf_file"
      return 1
    fi
    hw_items="$(echo "$hw_items" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${system_tweaks^^}" == "TRUE" ]]; then
    gaming_items="$(ui_select_system_tweaks)"
    if [[ -z "$gaming_items" ]]; then
      rm -f "$conf_file"
      return 1
    fi
    gaming_items="$(echo "$gaming_items" | tr '\n' ' ' | xargs)"
  fi

  # Package & driver builds — show selection dialog if checkbox is checked.
  if [[ "${package_builds^^}" == "TRUE" ]]; then
    drivers="$(ui_select_package_builds)"
    if [[ -z "$drivers" ]]; then
      rm -f "$conf_file"
      return 1
    fi
    drivers="$(echo "$drivers" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${initramfs_support^^}" == "TRUE" ]]; then
    initramfs_mods="$(ui_select_initramfs_modules)"
    if [[ -z "$initramfs_mods" ]]; then
      rm -f "$conf_file"
      return 1
    fi
  fi

  # Always write all selection keys (empty if not selected)
  echo "HW_SUPPORT_ITEMS=\"$hw_items\"" >>"$conf_file"
  echo "GAMING_ITEMS=\"$gaming_items\"" >>"$conf_file"
  echo "CUSTOM_DRIVERS=\"$drivers\"" >>"$conf_file"
  echo "INITRAMFS_MODULES=\"$initramfs_mods\"" >>"$conf_file"

  [[ "${add_installer^^}" != "TRUE" ]] && echo "ADD_INSTALLER=0" >>"$conf_file"

  # Derive TARGET_VARIANT from neutralize-oobe checkbox state.
  # If neutralize-oobe is selected, suppress OOBE (steamdeck); otherwise keep it (steamdeck-oobe).
  local target_variant="steamdeck-oobe"
  if [[ -n "${gaming_items:-}" && " $gaming_items " == *" neutralize-oobe "* ]]; then
    target_variant="steamdeck"
  fi

  echo "TARGET_VARIANT=\"$target_variant\"" >>"$conf_file"
  echo "UPDATE_BRANCH=\"$update_branch\"" >>"$conf_file"

  local -a args=(
    --action build
    --config "$conf_file"
  )

  printf '%s\n' "${args[@]}"
}

ui_build() {
  require_action_dependencies build || return 0

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
      --width=900 \
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
      local missing=""
      [[ -f "$conf_file" ]] || missing+="  - Build configuration\n"
      [[ -f "$source_img" ]] || missing+="  - Source image\n"
      [[ -d "$output_dir" ]] || missing+="  - Output directory\n"
      if [[ -n "$missing" ]]; then
        ui_error "<b>Please select all inputs before building:</b>\n\n$missing"
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
  if run_backend_gui "Building SteamOS NVIDIA image..." --action build --config "$conf_file" --image "$source_img" --output-dir "$output_dir"; then
    local output
    output="$(grep -oP '(?<=DONE — ).*' "$GUI_LAST_LOG" 2>/dev/null | tail -1 || true)"
    ui_info "<b>Build complete.</b>

${output:+<b>Output:</b>
$output

}<b>Log:</b>
$GUI_LAST_LOG"
  fi
}

ui_generate_conf() {
  local sep=$'\x1f'
  local form

  # Show settings form (without image selection)
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
    --field="Branch:CB" \
    --field="Rootfs size!Size in MiB, or use K/M/G suffixes" \
    --field="Default session:CB" \
    --field="Update mode:CB" \
    --field="Workspace location:CB" \
    --field="Working directory!Use automatic unless you want an explicit build directory" \
    --field="Hardware support!Install Logitech HID modules, firmware, fingerprint libs, and Thunderbolt support:CHK" \
    --field="Initramfs support!Select which kernel modules to force into the initramfs for early boot:CHK" \
    --field="System tweaks!PCI realloc, resizable BAR, gamemode, keyring, and more:CHK" \
    --field="Package & driver builds!Build and install custom drivers (Logitech HID, AoTofu VA-API, etc.):CHK" \
    --field="Add one-click installer!Adds desktop icon to install SteamOS to internal drive:CHK" \
    --button="Cancel":1 \
    --button="OK":0 \
    "^stable!beta!preview!rc!bc!pc!main" \
    "10240" \
    "^game!desktop" \
    "^selfheal!hold!stock" \
    "^auto!ram!disk" \
    "automatic" \
    "TRUE" \
    "FALSE" \
    "TRUE" \
    "TRUE" \
    "TRUE" \
    2>/dev/null)" || return 0

  local update_branch rootfs session update workspace workdir
  local hw_support initramfs_support system_tweaks package_builds add_installer

  IFS="$sep" read -r \
    update_branch rootfs session update workspace workdir \
    hw_support initramfs_support system_tweaks package_builds add_installer \
    <<<"$form"

  rootfs="${rootfs:-10240}"
  session="${session:-game}"
  update="${update:-selfheal}"
  workspace="${workspace:-auto}"
  update_branch="${update_branch:-stable}"

  # Show sub-dialogs for optional items
  local hw_items="" gaming_items="" drivers="" initramfs_mods=""

  if [[ "${hw_support^^}" == "TRUE" ]]; then
    hw_items="$(ui_select_hw_support)"
    [[ -n "$hw_items" ]] || return 0
    hw_items="$(echo "$hw_items" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${system_tweaks^^}" == "TRUE" ]]; then
    gaming_items="$(ui_select_system_tweaks)"
    [[ -n "$gaming_items" ]] || return 0
    gaming_items="$(echo "$gaming_items" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${package_builds^^}" == "TRUE" ]]; then
    drivers="$(ui_select_package_builds)"
    [[ -n "$drivers" ]] || return 0
    drivers="$(echo "$drivers" | tr '\n' ' ' | xargs)"
  fi

  if [[ "${initramfs_support^^}" == "TRUE" ]]; then
    initramfs_mods="$(ui_select_initramfs_modules)"
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
        ((i++))
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
  local summary=""
  summary+="═══════════════════════════════════════════════════════════\n"
  summary+="                    BUILD CONFIGURATION\n"
  summary+="═══════════════════════════════════════════════════════════\n\n"

  summary+="┌─ General Settings ─────────────────────────────────────┐\n"
  summary+="│  Update Branch:   $update_branch\n"
  summary+="│  Rootfs Size:     ${rootfs} MB\n"
  summary+="│  Default Session: ${session:-game}\n"
  summary+="│  Update Mode:     $update\n"
  summary+="│  Workspace:       $workspace\n"
  [[ -n "$workdir" && "$workdir" != "automatic" ]] && summary+="│  Working Dir:     $workdir\n"
  summary+="└────────────────────────────────────────────────────────┘\n\n"

  summary+="┌─ Enabled Features ─────────────────────────────────────┐\n"
  [[ "${add_installer^^}" == "TRUE" ]] && summary+="│  ✓ One-click installer\n"
  [[ -n "$hw_items" ]] && summary+="│  ✓ Hardware support\n"
  [[ -n "$gaming_items" ]] && summary+="│  ✓ System tweaks\n"
  [[ -n "$drivers" ]] && summary+="│  ✓ Package & driver builds\n"
  [[ -n "$initramfs_mods" ]] && summary+="│  ✓ Initramfs modules\n"
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

  summary+="┌─ Custom Drivers and Build Packages ────────────────────┐\n"
  if [[ -n "$drivers" ]]; then
    summary+="$(_format_items "$drivers")\n"
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
    --text="<b>Review your build configuration before saving.</b>" \
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
  conf_content="# steamos-nvidia build config — generated $(date -Iseconds)\n"
  conf_content+="# Image path will be set when building\n\n"
  conf_content+="ROOTFS_SIZE=\"$rootfs\"\n"
  conf_content+="TARGET_VARIANT=\"$target_variant\"\n"
  conf_content+="UPDATE_BRANCH=\"$update_branch\"\n"
  conf_content+="DEFAULT_SESSION=\"${session:-game}\"\n"
  conf_content+="UPDATE_MODE=\"${update:-selfheal}\"\n"
  conf_content+="WORKDIR_LOCATION=\"$workspace\"\n"

  [[ -n "$workdir" && "$workdir" != "automatic" ]] && conf_content+="WORKDIR=\"$workdir\"\n"
  [[ "${add_installer^^}" != "TRUE" ]] && conf_content+="ADD_INSTALLER=0\n"

  # Always write all selection keys (empty if not selected)
  conf_content+="HW_SUPPORT_ITEMS=\"${hw_items:-}\"\n"
  conf_content+="GAMING_ITEMS=\"${gaming_items:-}\"\n"
  conf_content+="CUSTOM_DRIVERS=\"${drivers:-}\"\n"
  conf_content+="INITRAMFS_MODULES=\"${initramfs_mods:-}\"\n"

  # Show file save dialog
  local outfile
  outfile="$(yad --file --save \
    --title="Save Build Configuration" \
    --filename="steamos-nvidia-build.conf" \
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

  ui_info "<b>Configuration saved.</b>

<b>Path:</b>
$outfile

Press OK to return to the home screen and build an image or apply to a live OS.

<b>Command line usage:</b>
<tt>./steamos-nvidia.sh --action build --config $outfile</tt>"
}

ui_flash_pick_image() {
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

ui_flash_pick_device() {
  local rows
  rows="$(bash "$BACKEND" --action list-devices 2>/dev/null || true)"
  [[ -n "$rows" ]] || {
    ui_error "No target block devices were found."
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

ui_flash() {
  require_action_dependencies flash || return 0

  echo "[ui_flash] entered" >&2
  local image device
  image="$(ui_flash_pick_image)" || {
    echo "[ui_flash] pick_image cancelled/failed (rc=$?)" >&2
    return 0
  }
  [[ -n "$image" ]] || {
    echo "[ui_flash] no image selected" >&2
    return 0
  }
  image="${image%%|*}"
  echo "[ui_flash] image=$image" >&2

  device="$(ui_flash_pick_device)" || {
    echo "[ui_flash] pick_device cancelled/failed (rc=$?)" >&2
    return 0
  }
  [[ -n "$device" ]] || {
    echo "[ui_flash] no device selected" >&2
    return 0
  }
  device="${device%%|*}"
  echo "[ui_flash] device=$device" >&2

  local allow_system=0
  echo "[ui_flash] checking system disk (device=$device)..." >&2
  local is_sys=0
  set +e
  bash "$BACKEND" --action is-system-disk --device "$device" >/dev/null 2>&1
  is_sys=$?
  set -e
  echo "[ui_flash] is-system-disk exit=$is_sys (0=system disk)" >&2
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
  echo "[ui_flash] running preflight..." >&2
  local preflight_output preflight_rc=0
  set +e
  if [[ $EUID -eq 0 ]]; then
    preflight_output="$(bash "$BACKEND" --action preflight --image "$image" --device "$device" 2>&1)"
  elif command -v sudo >/dev/null 2>&1; then
    preflight_output="$(sudo bash "$BACKEND" --action preflight --image "$image" --device "$device" 2>&1)"
  elif command -v pkexec >/dev/null 2>&1; then
    preflight_output="$(pkexec bash "$BACKEND" --action preflight --image "$image" --device "$device" 2>&1)"
  else
    preflight_output="$(bash "$BACKEND" --action preflight --image "$image" --device "$device" 2>&1)"
  fi
  preflight_rc=$?
  set -e
  echo "[ui_flash] preflight exit=$preflight_rc" >&2
  echo "$preflight_output" >&2

  # Format preflight for the dialog (escape for Pango markup).
  # Pango renders literal newlines as line breaks — no <br> tags needed.
  local preflight_html
  preflight_html="$(echo "$preflight_output" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"

  if [[ $preflight_rc -ne 0 ]]; then
    yad --question \
      --title="Preflight Check Failed" \
      --text="<b>Preflight check failed — high risk action.</b>

$preflight_html

<b>Resolve all preflight issues before flashing.</b>

Proceeding anyway may result in a corrupted flash or data loss." \
      --button="Cancel":1 \
      --button="Accept Risk":0 \
      --center \
      --width=700 \
      --height=500 2>/dev/null || return 1
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
      echo "[ui_flash] device confirm cancelled" >&2
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
    echo "[ui_flash] confirm cancelled (rc=$?)" >&2
    return 0
  }

  echo "[ui_flash] confirmed, starting flash..." >&2

  local -a args=(
    --action flash
    --image "$image"
    --device "$device"
    --confirm
  )
  [[ "$allow_system" -eq 1 ]] && args+=(--allow-system-disk)

  echo "[ui_flash] calling run_backend_gui..." >&2

  if run_backend_gui "Flashing $(basename "$image")..." "${args[@]}"; then
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

ui_flashless() {
  require_action_dependencies flash || return 0

  local image
  image="$(ui_flash_pick_image)" || return 0
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

  if run_backend_gui "Flashless install to inactive slot..." --action flashless --image "$image"; then
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

ui_diagnostics() {
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

ui_main() {
  ui_require_yad

  while true; do
    local choice rc
    set +e
    choice="$(ui_select_action)"
    rc=$?
    set -e

    echo "[ui_main] selector rc=$rc choice='$choice'" >&2

    # yad exit codes: 0=OK, 1=Cancel, 70=window close, etc.
    [[ $rc -eq 0 ]] || exit 0

    # YAD list output can include a trailing row separator depending on
    # version/options. Normalize it before dispatch so "Build|" does not fall
    # through the case statement and redraw the main menu.
    choice="${choice%%|*}"
    choice="${choice//$'\n'/}"

    case "$choice" in
      Build)
        ui_build
        ;;
      "Generate Config")
        ui_generate_conf
        ;;
      Flash)
        ui_flash
        ;;
      Flashless)
        ui_flashless
        ;;
      Diagnostics)
        ui_diagnostics
        ;;
      Configure)
        require_action_dependencies configure || continue
        bash "$BACKEND" --action configure || ui_error "Post-install configuration failed."
        ;;
      Validate)
        run_backend_gui "Validating configuration..." --action validate
        ;;
      Reboot)
        yad --question \
          --title="Confirm Reboot" \
          --text="Run the project reboot helper now?" \
          --button="Cancel":1 \
          --button="Reboot":0 \
          --center \
          --width=480 2>/dev/null || continue
        run_backend_gui "Preparing reboot..." --action reboot || true
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
  ui_main
  exit 0
fi

[[ -n "$ACTION" ]] || {
  echo "--action is required when using command-line arguments." >&2
  usage >&2
  exit 2
}

require_action_dependencies "$ACTION" || exit 1

case "$ACTION" in
  build)
    [[ -n "$IMG" || -n "$CONFIG_FILE" ]] || {
      echo "Build requires --image FILE or a config that supplies IMG." >&2
      exit 2
    }
    run_backend_cli
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

    build_backend_args
    BACKEND_ARGS+=(--confirm)

    if [[ $EUID -ne 0 ]]; then
      exec sudo bash "$BACKEND" "${BACKEND_ARGS[@]}"
    fi
    exec bash "$BACKEND" "${BACKEND_ARGS[@]}"
    ;;
  configure)
    exec bash "$BACKEND" --action configure
    ;;
  reboot)
    if [[ $EUID -ne 0 ]]; then
      exec sudo bash "$BACKEND" --action reboot
    fi
    exec bash "$BACKEND" --action reboot
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    usage >&2
    exit 2
    ;;
esac
