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
  set +e
  for m in "$MERGED"/dev/pts "$MERGED"/dev "$MERGED"/sys "$MERGED"/proc \
           "$MERGED" "$EFIMNT" "$HOMEMNT" "$MNT"; do
    if mountpoint -q "$m" 2>/dev/null; then
      umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null
    fi
  done
  # sweep any udisks automounts of OUR loop device only
  if [[ -n "$LOOPDEV" ]]; then
    findmnt -rn -o TARGET,SOURCE | awk -v l="$LOOPDEV" '$2 ~ "^"l {print $1}' \
      | tac | while read -r m; do umount "$m" 2>/dev/null; done
    losetup -d "$LOOPDEV" 2>/dev/null
  fi
  if [[ -f "$UDEV_RULE" ]]; then
    rm -f "$UDEV_RULE"
    udevadm control --reload 2>/dev/null
  fi
}