#!/bin/bash
# steamos-build repatch — reconcile the NVIDIA driver + boot config into
# another partition set (normally "other", right after an OS update).
# Run as root.  Reconciles the configured Valve/Arch package manifests,
# rebuilds target-kernel modules as needed, and always runs
# GRUB/initramfs/gamemode reconciliation.  Logs to stdout
# (the update wrapper redirects).
set -Eeuo pipefail

PERSIST_LOG_DIR="/home/.steamos-build/logs"
mkdir -p "$PERSIST_LOG_DIR"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_LOG="$PERSIST_LOG_DIR/repatch-$RUN_ID.log"

ln -sfn "$(basename "$RUN_LOG")" \
  "$PERSIST_LOG_DIR/repatch-latest.log"

# Keep stdout/stderr flowing to the caller, but independently retain
# everything on the persistent /home filesystem.
exec > >(tee -a "$RUN_LOG") 2>&1

# Resolve script directory: prefer /home (writable, latest), fall back to /usr
if [[ -d "/home/.steamos-build/lib" ]]; then
  SCRIPT_DIR="/home/.steamos-build/lib"
elif [[ -d "/usr/lib/steamos-build" ]]; then
  SCRIPT_DIR="/usr/lib/steamos-build"
else
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Use the shared common.sh logging/failure framework with repatch-specific
# presentation and diagnostics.
LOG_TAG="repatch"
LOGGER_TAG="steamos-build-repatch"
LOG_COLOR=0
CURRENT_STEP="startup"
FAILURE_REPORTED=0

# May not exist yet if failure happens very early.
NEWROOT=""

failure_journal_context() {
  printf "partset='%s' kver='%s'" \
    "${PARTSET:-unknown}" \
    "${KVER:-unknown}"
}

failure_snapshot_extra() {
  local _slot

  # Send a desktop notification to the user about the critical failure.
  notify_desktop critical \
    "SteamOS update patch failed" \
    "The SteamOS update was cancelled because a critical customization failed.

Failed step: ${CURRENT_STEP:-unknown}

Log: ${RUN_LOG:-unknown}"

  echo >&2
  echo "=== SLOT STATE ===" >&2
  rauc status --detailed 2>&1 || true
  steamos-bootconf list-images 2>&1 || true

  for _slot in A B; do
    echo "--- $_slot ---" >&2
    steamos-bootconf --image "$_slot" config \
      --get boot-attempts \
      --get boot-requested-at \
      --get image-invalid \
      --get comment 2>&1 || true
  done

  if [[ -n "${NEWROOT:-}" ]] && mountpoint -q "$NEWROOT" 2>/dev/null; then
    echo >&2
    echo "=== TARGET ROOTFS ===" >&2
    findmnt "$NEWROOT" 2>&1 || true
    btrfs filesystem usage "$NEWROOT" 2>&1 || true

    if [[ -n "${KVER:-}" ]]; then
      echo >&2
      echo "=== TARGET DRIVER STATE ===" >&2
      chroot "$NEWROOT" dkms status 2>&1 || true
      chroot "$NEWROOT" pacman -Q nvidia-utils 2>&1 || true
    fi
  fi
}

# notify_desktop URGENCY TITLE BODY
#   Send a desktop notification to the deck user's Plasma session.
#   Urgency: "critical" (sticky), "normal" (auto-expires), "low".
#   Falls back through: notify-send → busctl → log only.
notify_desktop() {
  local urgency="${1:-normal}"
  local title="$2"
  local body="$3"

  local user="deck"
  local uid

  uid="$(id -u "$user" 2>/dev/null)" || {
    log "notify_desktop: cannot resolve uid for $user"
    return 1
  }

  [[ -S "/run/user/$uid/bus" ]] || {
    log "notify_desktop: no D-Bus session for $user (no /run/user/$uid/bus)"
    return 1
  }

  local icon="dialog-information"
  [[ "$urgency" == "critical" ]] && icon="dialog-error"

  # Prefer notify-send if available.
  if command -v notify-send >/dev/null 2>&1; then
    runuser -u "$user" -- env \
      XDG_RUNTIME_DIR="/run/user/$uid" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
      notify-send \
      --urgency="$urgency" \
      --app-name="SteamOS NVIDIA Patcher" \
      --icon="$icon" \
      "$title" \
      "$body" 2>/dev/null && return 0

    log "notify_desktop: notify-send failed, falling back to busctl"
  fi

  # Fallback: direct D-Bus call via busctl (part of systemd, always present).
  local urgency_byte=1
  [[ "$urgency" == "critical" ]] && urgency_byte=2
  [[ "$urgency" == "low" ]] && urgency_byte=0

  runuser -u "$user" -- env \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    busctl --user call \
    org.freedesktop.Notifications \
    /org/freedesktop/Notifications \
    org.freedesktop.Notifications \
    Notify \
    "susssasa{sv}" \
    "SteamOS NVIDIA Patcher" \
    0 \
    "$icon" \
    "$title" \
    "$body" \
    0 \
    1 "urgency" "y" "$urgency_byte" \
    2>/dev/null && return 0

  log "notify_desktop: busctl fallback also failed"
  return 1
}

# ── Source libraries ──────────────────────────────────────────────────────────

# common.sh owns log/warn/step/die, ERR handling, and the low-level mount/loop
# helpers used transitively by overlay.sh and common_system.sh.
if [[ ! -r "$SCRIPT_DIR/common.sh" ]]; then
  echo "[repatch] ERROR: missing helper: $SCRIPT_DIR/common.sh" >&2
  exit 1
fi
source "$SCRIPT_DIR/common.sh"

# Ensure the full .steamos-build tree exists (logs already created above;
# this also creates recovery/ with world-writable perms).
ensure_steamos_build_dirs

# Source library loader, pipeline, and workflow common functions
[[ -r "$SCRIPT_DIR/library-loader.sh" ]] \
  || die "missing library loader: $SCRIPT_DIR/library-loader.sh"
source "$SCRIPT_DIR/library-loader.sh"

[[ -r "$SCRIPT_DIR/pipeline.sh" ]] \
  || die "missing pipeline: $SCRIPT_DIR/pipeline.sh"
source "$SCRIPT_DIR/pipeline.sh"

[[ -r "$SCRIPT_DIR/workflow-common.sh" ]] \
  || die "missing workflow common: $SCRIPT_DIR/workflow-common.sh"
source "$SCRIPT_DIR/workflow-common.sh"

# Source pipeline definition
[[ -r "$SCRIPT_DIR/pipelines/pipeline_rebuild.sh" ]] \
  || die "missing rebuild pipeline: $SCRIPT_DIR/pipelines/pipeline_rebuild.sh"
source "$SCRIPT_DIR/pipelines/pipeline_rebuild.sh"

# Load all repatch workflow libraries
load_workflow_libs "repatch" "$SCRIPT_DIR"

# ── Patch result tracking ────────────────────────────────────────────────────
# Three-state exit model:
#   0  = all patches applied successfully
#   10 = OS update is bootable, but one or more optional patches failed
#   1  = critical failure; staged OS should not be booted
declare -a PATCH_RESULTS=()

# patch_record NAME STATUS [DETAIL]
#   STATUS is "ok" or "fail".
patch_record() {
  local name="$1" status="$2" detail="${3:-}"
  PATCH_RESULTS+=("$name|$status|$detail")
  if [[ "$status" == "fail" ]]; then
    warn "Optional patch failed: $name — $detail"
  fi
}

REPATCH_EXIT=0

PARTSET="${1:-other}"

ROOTDEV="/dev/disk/by-partsets/$PARTSET/rootfs"
EFIDEV="/dev/disk/by-partsets/$PARTSET/efi"

NEWROOT="$(mktemp -d /tmp/repatch-root.XXXXXX)"
# SteamOS /home is ext4 with casefold enabled, which OverlayFS rejects as an
# upperdir.  Build inside a temporary plain-ext4 loopback filesystem stored on
# /home, where there is enough space for DKMS/toolchain work.
WORKIMG=/home/.steamos-build-work.img
WORK="$(mktemp -d /tmp/repatch-work.XXXXXX)"
WORK_LOOPDEV=""

# ── Register and run pipeline ────────────────────────────────────────────────

register_rebuild_pipeline
register_rebuild_cleanup

# Run the pipeline
if run_pipeline; then
  # Pipeline succeeded — summarize results
  _ok_count=0
  _fail_count=0
  for _entry in "${PATCH_RESULTS[@]}"; do
    IFS='|' read -r _name _status _detail <<<"$_entry"
    if [[ "$_status" == "ok" ]]; then
      ((_ok_count++)) || true
    else
      ((_fail_count++)) || true
    fi
  done

  if ((_fail_count == 0)); then
    step "OK — $PARTSET is NVIDIA-ready ($KVER)"
    exit 0
  fi

  # Some optional patches failed but slot is bootable
  warn ""
  warn "============================================================"
  warn " SteamOS NVIDIA Repatch: COMPLETED WITH WARNINGS"
  warn "============================================================"
  warn ""
  warn "SteamOS update installed successfully, but some optional"
  warn "patches failed.  The updated slot remains bootable."
  warn ""
  _warn_failed_list=""
  warn "Patch results:"
  for _entry in "${PATCH_RESULTS[@]}"; do
    IFS='|' read -r _name _status _detail <<<"$_entry"
    if [[ "$_status" == "ok" ]]; then
      warn "  ✓ $_name"
    else
      warn "  ✗ $_name — $_detail"
      _warn_failed_list+="$_name, "
    fi
  done
  _warn_failed_list="${_warn_failed_list%, }"
  warn ""
  warn "Full log: $RUN_LOG"
  warn "============================================================"
  warn ""

  notify_desktop normal \
    "SteamOS NVIDIA: patch warnings" \
    "The SteamOS update succeeded, but some optional patches failed: $_warn_failed_list.

Your system is bootable. See the repatch log for details:
$RUN_LOG"

  exit 10
else
  # Pipeline failed — critical failure
  warn ""
  warn "============================================================"
  warn " SteamOS NVIDIA Repatch: CRITICAL FAILURE"
  warn "============================================================"
  warn ""
  warn "A critical customization failed. The staged OS update has been"
  warn "cancelled to prevent an unbootable system."
  warn ""
  warn "Full log: $RUN_LOG"
  warn "============================================================"
  warn ""

  notify_desktop critical \
    "SteamOS NVIDIA: patch failed" \
    "The SteamOS update was cancelled because a critical customization failed.

Your system is unchanged. See the repatch log for details:
$RUN_LOG"

  exit 1
fi
