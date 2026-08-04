#!/bin/bash
#
# steamos-nvidia-installer — lib/build-hid.sh
# Build upstream Logitech HID kernel modules (hid-logitech-dj,
# hid-logitech-hidpp) inside the overlay chroot.  Source files are fetched
# by fetch-hid.sh.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build-hid.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

build_hid() {
  [[ $BUILD_HW_SUPPORT -eq 1 ]] || return 0

  log "Building upstream Logitech receiver and HID++ modules for $KVER"

  [[ -d "$DRIVER_SRC_DIR" ]] || die "HID source directory not found — fetch_hid_sources must run first"

  rm -rf "$MERGED/tmp/hid-kmod"
  mkdir -p "$MERGED/tmp/hid-kmod"
  cp -a "$DRIVER_SRC_DIR/." "$MERGED/tmp/hid-kmod/"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod clean"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod modules"

  in_chroot \
    "install -Dm644 \
      /tmp/hid-kmod/hid-logitech-dj.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"

  in_chroot \
    "install -Dm644 \
      /tmp/hid-kmod/hid-logitech-hidpp.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

  # Verify the built module has the modern Logitech receiver alias.
  in_chroot \
    "modinfo -F alias /tmp/hid-kmod/hid-logitech-dj.ko \
      | grep -qi 'v0000046Dp0000C547'" \
    || die "upstream hid-logitech-dj module lacks the 046d:c547 alias"

  log "Built upstream Logitech HID modules for $KVER"
}
