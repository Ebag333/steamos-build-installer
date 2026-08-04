#!/bin/bash
#
# steamos-nvidia-installer — lib/build-hid.sh
# Build libratbag (from source) and upstream Logitech HID kernel modules
# inside the overlay chroot.  Libratbag goes to /usr/local; the Logitech
# modules go to /usr/lib/modules/$KVER/updates/logitech/.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build-hid.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

build_hid() {
  [[ $BUILD_HID -eq 1 ]] || return 0

  # ---- libratbag (from source) ----
  log "Building libratbag from source (latest git)"

  in_chroot "pacman --config $PACCONF -S $PACOPTS \
    meson ninja gcc pkg-config \
    libevdev systemd glib2 json-glib \
    python-evdev check swig" \
    || die "Failed to install libratbag build deps"

  in_chroot "git clone --depth 1 https://github.com/libratbag/libratbag.git /tmp/libratbag"

  in_chroot "meson setup /tmp/libratbag/builddir /tmp/libratbag \
    --prefix=/usr/local \
    -Dsystemd-unit-dir=/usr/lib/systemd/system \
    -Druntime-dir=/run"

  log "Compiling libratbag (ninja — a few minutes)"
  in_chroot "ninja -C /tmp/libratbag/builddir"

  chroot "$MERGED" /bin/bash -c \
    "DESTDIR=$MNT ninja -C /tmp/libratbag/builddir install" \
    || die "libratbag install failed"

  rm -rf "$MERGED/tmp/libratbag"

  if [[ ! -f "$MNT/usr/local/bin/ratbagctl" ]] && \
     [[ ! -f "$MNT/usr/local/bin/ratbagd" ]]; then
    die "libratbag build produced no binaries"
  fi
  log "libratbag installed: $(ls "$MNT"/usr/local/bin/ratbag* 2>/dev/null | tr '\n' ' ')"

  # ---- Logitech HID kernel modules ----
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
