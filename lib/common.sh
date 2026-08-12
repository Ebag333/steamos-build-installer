#!/bin/bash
#
# steamos-nvidia-installer — lib/common.sh
# Shared helpers: logging, die, in_chroot, and the global cleanup trap.
# This is SOURCED by the wrapper (and nothing else) — do not run it directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/common.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

log()  { printf '\e[1;35m[nvidia-usb]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[fail]\e[0m %s\n' "$*" >&2; exit 1; }

# Run a command inside the overlay build chroot ($MERGED).
in_chroot() { chroot "$MERGED" /bin/bash -c "$*"; }

# Tear down everything mounted/created on OUR loop device + the overlay, and
# drop the udisks guard rule. Idempotent — safe to run twice (EXIT trap).
cleanup() {
  # Save and restore set -e so finalize()'s explicit call doesn't leak it.
  local _had_e=0
  [[ -o errexit ]] && _had_e=1
  set +e

  local m
  local mounts=()

  # Guard: only add chroot mounts if MERGED was initialized.
  if [[ -n "${MERGED:-}" ]]; then
    mounts+=(
      "$MERGED/dev/pts"
      "$MERGED/dev"
      "$MERGED/sys"
      "$MERGED/proc"
      "$MERGED/tmp"
      "$MERGED"
    )
  fi

  # Add remaining mounts only if non-empty.
  for m in "${OVL_MNT:-}" "${EFIMNT:-}" "${HOMEMNT:-}" "${MNT:-}"; do
    [[ -n "$m" ]] && mounts+=("$m")
  done

  for m in "${mounts[@]}"; do
    if mountpoint -q "$m" 2>/dev/null; then
      umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
    fi
  done

  # sweep any udisks automounts of OUR loop device only
  if [[ -n "${LOOPDEV:-}" ]]; then
    findmnt -rn -o TARGET,SOURCE | awk -v l="$LOOPDEV" '$2 ~ "^"l {print $1}' \
      | tac | while read -r m; do umount "$m" 2>/dev/null; done
    losetup -d "$LOOPDEV" 2>/dev/null
  fi
  # Detach the overlay workspace loop device if it exists.
  if [[ -n "${OVL_IMG:-}" && -f "$OVL_IMG" ]]; then
    local _ovl_dev
    _ovl_dev="$(losetup -j "$OVL_IMG" 2>/dev/null | cut -d: -f1 | head -1)"
    if [[ -n "$_ovl_dev" ]]; then
      umount "$_ovl_dev" 2>/dev/null
      losetup -d "$_ovl_dev" 2>/dev/null
    fi
  fi
  if [[ -n "${UDEV_RULE:-}" && -f "$UDEV_RULE" ]]; then
    rm -f "$UDEV_RULE"
    udevadm control --reload 2>/dev/null
  fi

  # Restore set -e if it was active.
  [[ "$_had_e" -eq 1 ]] && set -e
}
