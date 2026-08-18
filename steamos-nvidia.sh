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
  # shellcheck disable=SC1090
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

  steamos-nvidia.sh --action build --image FILE [build options]
  steamos-nvidia.sh --action flash --image FILE --device /dev/sdX
  steamos-nvidia.sh --action configure
  steamos-nvidia.sh --action reboot
  steamos-nvidia.sh --setup

Setup:
  --setup                  Install host dependencies required by this tool

Named arguments:
  --action ACTION
  --image FILE
  --device DEVICE
  --config FILE

Build:
  --workingdir DIR
  --workdir DIR             Compatibility alias
  --workdir-location MODE   auto | ram | disk
  --rootfs-size SIZE
  --session MODE            desktop | game
  --hold-updates
  --no-hold-updates
  --no-installer
  --trim-cuda
  --thunderbolt
  --hw-support
  --hw-support-items ITEMS  Space-separated: logitech-hid linux-firmware libfprint fprintd bolt
  --initramfs MODULES   Space-separated module list for initramfs (empty = stock)
  --gaming-items ITEMS  Space-separated: trim-cuda gamemode
  --debug-boot          Add rd.debug rd.log=all to kernel cmdline for boot debugging
  --skip-sigcheck
  --fix-keyring

Flash:
  --allow-system-disk       Permit a target detected as the current system disk

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

# shellcheck disable=SC2178,SC2128
require_action_dependencies() {
  local action="$1" missing=""

  case "$action" in
    gui)
      missing="$(missing_commands yad || true)"
      ;;
    build)
      missing="$(missing_commands \
        losetup blkid btrfs bzip2 gzip xz pv rsync curl depmod sed awk tar \
        zstd pacman python3 readelf sgdisk sfdisk partx unshare lspci modinfo || true)"
      ;;
    flash)
      missing="$(missing_commands \
        lsblk blockdev findmnt mountpoint sgdisk sfdisk pv udevadm || true)"
      ;;
    configure)
      # post-install configuration is GUI-driven.
      missing="$(missing_commands yad || true)"
      ;;
    reboot|list-images|list-devices|is-system-disk|preflight)
      ;;
  esac

  [[ -z "$missing" ]] || show_setup_required "$missing"
}

run_setup() {
  local self="${BASH_SOURCE[0]}"

  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      exec sudo bash "$self" --setup
    fi
    echo "Setup requires root privileges and sudo is not available." >&2
    exit 1
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
    --action)            ACTION="${2:?--action requires a value}"; shift 2 ;;
    --image)             IMG="${2:?--image requires a value}"; shift 2 ;;
    --device)            TARGET_DEV="${2:?--device requires a value}"; shift 2 ;;
    --config)            CONFIG_FILE="${2:?--config requires a value}"; shift 2 ;;

    --workingdir|--workdir)
                         WORKDIR="${2:?$1 requires a value}"; shift 2 ;;
    --workdir-location)  WORKDIR_LOCATION="${2:?--workdir-location requires a value}"; shift 2 ;;
    --rootfs-size)       ROOTFS_SIZE="${2:?--rootfs-size requires a value}"; shift 2 ;;
    --session)           DEFAULT_SESSION="${2:?--session requires a value}"; shift 2 ;;
    --hold-updates)      UPDATE_MODE="hold"; shift ;;
    --no-hold-updates)   UPDATE_MODE="stock"; shift ;;
    --no-installer)      ADD_INSTALLER=0; shift ;;
    --trim-cuda)         TRIM_CUDA=1; shift ;;
    --thunderbolt)       THUNDERBOLT=1; shift ;;
    --hw-support)        BUILD_HW_SUPPORT=1; shift ;;
    --hw-support-items)  HW_SUPPORT_ITEMS="${2:?--hw-support-items requires a list}"; BUILD_HW_SUPPORT=1; shift 2 ;;
    --initramfs)         INITRAMFS_MODULES="${2:?--initramfs requires a module list}"; shift 2 ;;
    --gaming-items)      GAMING_ITEMS="${2:?--gaming-items requires a list}"; shift 2 ;;
    --debug-boot)        DEBUG_BOOT=1; shift ;;
    --skip-sigcheck)     SKIP_SIG=1; shift ;;
    --fix-keyring)       FIX_KEYRING=1; shift ;;

    --allow-system-disk) ALLOW_SYSTEM_DISK=1; shift ;;
    --setup)             SETUP_MODE=1; CLI_MODE=1; shift ;;

    -h|--help) usage; exit 0 ;;
    --gui) CLI_MODE=0; shift ;;
    --) shift; [[ $# -eq 0 ]] || { echo "Positional parameters are not supported." >&2; exit 2; } ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$SETUP_MODE" -eq 1 ]]; then
  [[ -z "$ACTION" ]] || { echo "--setup cannot be combined with --action." >&2; exit 2; }
  run_setup
  exit 0
fi

# ---------------------------------------------------------------------------
# Backend invocation helpers.
# ---------------------------------------------------------------------------
build_backend_args() {
  BACKEND_ARGS=(--action "$ACTION")

  [[ -n "$IMG" ]]              && BACKEND_ARGS+=(--image "$IMG")
  [[ -n "$TARGET_DEV" ]]       && BACKEND_ARGS+=(--device "$TARGET_DEV")
  [[ -n "$CONFIG_FILE" ]]      && BACKEND_ARGS+=(--config "$CONFIG_FILE")
  [[ -n "$WORKDIR" ]]          && BACKEND_ARGS+=(--workingdir "$WORKDIR")
  [[ -n "$WORKDIR_LOCATION" ]] && BACKEND_ARGS+=(--workdir-location "$WORKDIR_LOCATION")
  [[ -n "$ROOTFS_SIZE" ]]      && BACKEND_ARGS+=(--rootfs-size "$ROOTFS_SIZE")
  [[ -n "$DEFAULT_SESSION" ]]  && BACKEND_ARGS+=(--session "$DEFAULT_SESSION")

  case "$UPDATE_MODE" in
    hold)  BACKEND_ARGS+=(--hold-updates) ;;
    stock) BACKEND_ARGS+=(--no-hold-updates) ;;
  esac

  [[ "$ADD_INSTALLER" == "0" ]]    && BACKEND_ARGS+=(--no-installer)
  [[ "$TRIM_CUDA" -eq 1 ]]         && BACKEND_ARGS+=(--trim-cuda)
  [[ "$BUILD_HW_SUPPORT" -eq 1 ]]  && {
    if [[ -n "$HW_SUPPORT_ITEMS" ]]; then
      BACKEND_ARGS+=(--hw-support-items "$HW_SUPPORT_ITEMS")
    else
      BACKEND_ARGS+=(--hw-support)
    fi
  }
  [[ "$THUNDERBOLT" -eq 1 ]]       && BACKEND_ARGS+=(--thunderbolt)
  [[ "$SKIP_SIG" -eq 1 ]]          && BACKEND_ARGS+=(--skip-sigcheck)
  [[ "$FIX_KEYRING" -eq 1 ]]       && BACKEND_ARGS+=(--fix-keyring)
  [[ -n "$INITRAMFS_MODULES" ]]    && BACKEND_ARGS+=(--initramfs "$INITRAMFS_MODULES")
  [[ -n "$GAMING_ITEMS" ]]        && BACKEND_ARGS+=(--gaming-items "$GAMING_ITEMS")
  [[ "$DEBUG_BOOT" -eq 1 ]]        && BACKEND_ARGS+=(--debug-boot)
  [[ "$ALLOW_SYSTEM_DISK" -eq 1 ]] && BACKEND_ARGS+=(--allow-system-disk)
}

backend_needs_root() {
  case "$1" in
    build|flash|reboot) return 0 ;;
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
  while IFS= read -r line < <(tail -c +$((offset + 1)) "$logfile" 2>/dev/null | head -n 1); do
    [[ -z "$line" ]] && break
    offset=$((offset + ${#line} + 1))
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
    echo "$_rc" > "$rcfile"
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
        < "$progress_pipe" \
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
          < "$progress_pipe" \
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
            < "$progress_pipe" \
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
    --title="SteamOS NVIDIA" \
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
    "Build" "Build a patched SteamOS NVIDIA installer image" \
    "Flash" "Flash a completed installer image to USB" \
    "Configure" "Run post-install configuration" \
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
    [[ "$module" == "-" ]] && continue  # no matching module

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
      0x01*)   check="TRUE"; cat_label="boot-path" ;;  # storage controllers
      0x0c03*) check="TRUE"; cat_label="boot-path" ;;  # USB/USB4 host controllers
      *)       cat_label="$category" ;;
    esac

    # Specific overrides for known boot-critical modules.
    case "$module" in
      thunderbolt|typec|xhci_hcd|xhci_pci|nvme|ahci|btrfs|usbhid|hid_generic)
        check="TRUE"
        cat_label="boot-path"
        ;;
      btusb)
        cat_label="bluetooth"
        ;;
    esac

    rows+=("$check" "$module" "$cat_label" "$device" "$bound_driver" "$mod_desc")
  done <<< "$hw_data"

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
# Items: logitech-hid linux-firmware libfprint fprintd bolt thunderbolt
ui_select_hw_support() {
  local selected
  selected="$(yad --list --checklist \
    --title="Hardware Support Components" \
    --text="<b>Select hardware support components to install.</b>

<span fgcolor='gray'>Each component is independent. linux-firmware replaces Valve's Deck subset
with the full Arch firmware suite — may cause WiFi/Bluetooth issues on Deck.</span>" \
    --column="Install" \
    --column="Component" \
    --column="Risk" \
    --column="Description" \
    --separator=" " \
    --print-column=2 \
    --center \
    --width=700 \
    --height=420 \
    --button="Cancel":1 \
    --button="OK":0 \
    TRUE  logitech-hid   "medium"  "Logitech receiver/HID++ kernel modules (hid-logitech-dj, hid-logitech-hidpp)" \
    TRUE  linux-firmware  "medium"  "Full Arch firmware suite — replaces Valve's Deck subset (not recommended for Steam Deck/Machine)" \
    TRUE  libfprint      "low"     "Fingerprint reader library" \
    TRUE  fprintd        "low"     "Fingerprint reader daemon" \
    TRUE  bolt           "low"     "Thunderbolt device manager (already in SteamOS, just enables service)" \
    TRUE  thunderbolt    "low"     "Thunderbolt dock support: PCI rescan udev rule + bolt service enable" \
    2>/dev/null)" || selected=""

  # Clean trailing separators.
  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

# System tweaks selection dialog.
# Prints space-separated item list to stdout; empty if cancelled.
# Items: trim-cuda gamemode pci-realloc tb-host-reset resize-bar
ui_select_system_tweaks() {
  local selected
  selected="$(yad --list --checklist \
    --title="Gaming Tweaks" \
    --text="<b>Select gaming optimizations to apply.</b>" \
    --column="Enable" \
    --column="Tweak" \
    --column="Description" \
    --separator=" " \
    --print-column=2 \
    --center \
    --width=700 \
    --height=340 \
    --button="Cancel":1 \
    --button="OK":0 \
    FALSE trim-cuda "Remove CUDA/OpenCL/NVVM/OptiX libraries (~350 MB) — not needed for gaming, required for AI models" \
    TRUE  gamemode  "Add deck user to gamemode group — allows CPU performance mode switching" \
    TRUE  pci-realloc "pci=realloc=on — fix firmware PCI bridge resource allocation" \
    TRUE  tb-host-reset "thunderbolt.host_reset=0 — improve Thunderbolt/eGPU hotplug stability" \
    TRUE  resize-bar "nvidia.NVreg_EnableResizableBar=1 — enable resizable BAR for NVIDIA GPU" \
    TRUE  fix-keyring "Force initialize Arch + holo pacman keyrings" \
    FALSE skip-sigcheck "Disable pacman signature checks in build chroot" \
    FALSE debug-boot "Add rd.debug rd.log=all to kernel cmdline for boot debugging" \
    2>/dev/null)" || selected=""

  selected="${selected%%|*}"
  selected="${selected% }"
  echo "$selected"
}

ui_build() {
  require_action_dependencies build || return 0

  # YAD form defaults are supplied as the values following the field
  # declarations.  Combo entries prefixed with ^ are selected by default.
  # This lets the entire build configuration live in one pre-populated form.
  local sep=$'\x1f'
  local form

  form="$(yad --form \
    --title="Build SteamOS NVIDIA Image" \
    --text="<b>Build settings</b>

Select the clean SteamOS repair image and adjust any settings you want.
NVIDIA packages follow the version policy in hw-packages-arch.conf." \
    --columns=2 \
    --separator="$sep" \
    --item-separator="!" \
    --align=left \
    --center \
    --width=1000 \
    --height=520 \
    --field="Base image!Clean SteamOS repair image (.img or compressed):FL" \
    --field="Rootfs size!Size in MiB, or use K/M/G suffixes" \
    --field="Default session:CB" \
    --field="Update mode:CB" \
    --field="Workspace location:CB" \
    --field="Working directory!Use automatic unless you want an explicit build directory" \
    --field="Hardware support!Install Logitech HID modules, firmware, fingerprint libs, and Thunderbolt support:CHK" \
    --field="Initramfs support!Select which kernel modules to force into the initramfs for early boot:CHK" \
    --field="System tweaks!PCI realloc, resizable BAR, gamemode, keyring, and more:CHK" \
    --field="Add one-click installer!Adds desktop icon to install SteamOS to internal drive:CHK" \
    --field=":LBL" \
    --field=":LBL" \
    --field=":LBL" \
    --button="Cancel":1 \
    --button="Build":0 \
    "" \
    "10240" \
    "^stock!game!desktop" \
    "^selfheal!hold!stock" \
    "^auto!ram!disk" \
    "automatic" \
    "TRUE" \
    "FALSE" \
    "TRUE" \
    "TRUE" \
    "" "" "" \
    2>/dev/null)" || return 0

  local base_image rootfs session update workspace workdir
  local hw_support initramfs_support system_tweaks add_installer
  local _spacer1 _spacer2 _spacer3

  IFS="$sep" read -r \
    base_image rootfs session update workspace workdir \
    hw_support initramfs_support system_tweaks add_installer \
    _spacer1 _spacer2 _spacer3 \
    <<<"$form"

  [[ -n "$base_image" && -f "$base_image" ]] || {
    ui_error "Select a valid SteamOS repair image."
    return 0
  }

  rootfs="${rootfs:-10240}"
  session="${session:-stock}"
  update="${update:-selfheal}"
  workspace="${workspace:-auto}"

  # "automatic" is a UI sentinel.  Do not pass --workingdir in that case,
  # because an explicit directory disables backend auto workspace selection.
  if [[ -z "$workdir" || "$workdir" == "automatic" ]]; then
    workdir=""
  fi

  local -a args=(
    --action build
    --image "$base_image"
    --rootfs-size "$rootfs"
    --workdir-location "$workspace"
  )

  [[ "$session" != "stock" ]] && args+=(--session "$session")
  [[ -n "$workdir" ]] && args+=(--workingdir "$workdir")

  case "$update" in
    hold)  args+=(--hold-updates) ;;
    stock) args+=(--no-hold-updates) ;;
  esac

  # Hardware support — show component selection dialog if checkbox is checked.
  if [[ "${hw_support^^}" == "TRUE" ]]; then
    local hw_items
    hw_items="$(ui_select_hw_support)"
    if [[ -z "$hw_items" ]]; then
      return 0  # cancelled — back to main menu
    fi
    # Normalize: yad may output newlines instead of spaces.
    hw_items="$(echo "$hw_items" | tr '\n' ' ' | xargs)"
    args+=(--hw-support-items "$hw_items")
    # Thunderbolt is now selected inside the hardware support dialog.
    [[ " $hw_items " == *" thunderbolt "* ]] && args+=(--thunderbolt)
  fi
  [[ "${add_installer^^}" != "TRUE" ]] && args+=(--no-installer)

  # System tweaks — show dialog if checkbox is checked.
  if [[ "${system_tweaks^^}" == "TRUE" ]]; then
    local gaming_items
    gaming_items="$(ui_select_system_tweaks)"
    if [[ -z "$gaming_items" ]]; then
      return 0  # cancelled — back to main menu
    fi
    gaming_items="$(echo "$gaming_items" | tr '\n' ' ' | xargs)"
    args+=(--gaming-items "$gaming_items")
    # Backward compat: pass --trim-cuda if selected.
    [[ " $gaming_items " == *" trim-cuda "* ]] && args+=(--trim-cuda)
    # Pass individual flags extracted from gaming items.
    [[ " $gaming_items " == *" skip-sigcheck "* ]] && args+=(--skip-sigcheck)
    [[ " $gaming_items " == *" fix-keyring "* ]]    && args+=(--fix-keyring)
    [[ " $gaming_items " == *" debug-boot "* ]]     && args+=(--debug-boot)
  fi

  # Initramfs module selection — show dialog if checkbox is checked.
  if [[ "${initramfs_support^^}" == "TRUE" ]]; then
    local initramfs_mods
    initramfs_mods="$(ui_select_initramfs_modules)"
    if [[ -z "$initramfs_mods" ]]; then
      return 0  # cancelled — back to main menu
    fi
    args+=(--initramfs "$initramfs_mods")
  fi

  local feature_summary=""
  [[ "${hw_support^^}" == "TRUE" ]]  && feature_summary+="Hardware support\n"
  [[ "${initramfs_support^^}" == "TRUE" ]] && feature_summary+="Initramfs customization\n"
  [[ "${system_tweaks^^}" == "TRUE" ]] && feature_summary+="System tweaks\n"
  [[ "${add_installer^^}" == "TRUE" ]] && feature_summary+="One-click installer\n"
  [[ -n "$feature_summary" ]] || feature_summary="None\n"

  yad --question \
    --title="Confirm Build" \
    --text="<b>Build NVIDIA-patched SteamOS image?</b>

<b>Source:</b>
$base_image

<b>Rootfs:</b> $rootfs
<b>Session:</b> $session
<b>Update mode:</b> $update
<b>Workspace:</b> $workspace
<b>Working directory:</b> ${workdir:-automatic}

<b>Features:</b>
$(printf '%b' "$feature_summary")" \
    --button="Cancel":1 \
    --button="Build":0 \
    --center \
    --width=680 2>/dev/null || return 0

  if run_backend_gui "Building SteamOS NVIDIA image..." "${args[@]}"; then
    local output
    output="$(grep -oP '(?<=DONE — ).*' "$GUI_LAST_LOG" 2>/dev/null | tail -1 || true)"
    ui_info "<b>Build complete.</b>

${output:+<b>Output:</b>
$output

}<b>Log:</b>
$GUI_LAST_LOG"
  fi
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
  image="$(ui_flash_pick_image)" || { echo "[ui_flash] pick_image cancelled/failed (rc=$?)" >&2; return 0; }
  [[ -n "$image" ]] || { echo "[ui_flash] no image selected" >&2; return 0; }
  image="${image%%|*}"
  echo "[ui_flash] image=$image" >&2

  device="$(ui_flash_pick_device)" || { echo "[ui_flash] pick_device cancelled/failed (rc=$?)" >&2; return 0; }
  [[ -n "$device" ]] || { echo "[ui_flash] no device selected" >&2; return 0; }
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
      --width=520 2>/dev/null || { echo "[ui_flash] device confirm cancelled" >&2; return 0; }
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
    2>/dev/null || { echo "[ui_flash] confirm cancelled (rc=$?)" >&2; return 0; }

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
      <<< "$flash_log_content" \
      2>/dev/null || true
  fi
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
      Flash)
        ui_flash
        ;;
      Configure)
        require_action_dependencies configure || continue
        bash "$BACKEND" --action configure || ui_error "Post-install configuration failed."
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
      Quit|"")
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
    [[ -n "$IMG" ]] || { echo "Flash requires --image FILE." >&2; exit 2; }
    [[ -n "$TARGET_DEV" ]] || { echo "Flash requires --device DEVICE." >&2; exit 2; }

    echo "WARNING: flashing permanently destroys all data on $TARGET_DEV." >&2
    read -r -p "Type YES to continue: " answer
    [[ "$answer" == "YES" ]] || { echo "Canceled."; exit 1; }

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
