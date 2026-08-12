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

  # Verify the stock Logitech drivers are built as modules (=m), not
  # built-in (=y).  A built-in driver can't be replaced by a .ko in
  # /updates — the kernel will always load the built-in version.
  local kconfig="$MERGED/usr/lib/modules/$KVER/build/.config"
  if [[ -f "$kconfig" ]]; then
    for mod in HID_LOGITECH_DJ HID_LOGITECH_HIDPP; do
      local val
      val="$(grep "^CONFIG_${mod}=" "$kconfig" 2>/dev/null | cut -d= -f2)"
      case "$val" in
        m) log "  CONFIG_${mod}=m (module — replaceable)" ;;
        y) die "CONFIG_${mod}=y (built-in) — our .ko cannot replace the built-in driver" ;;
        *) log "  CONFIG_${mod} not set (ok — no conflict)" ;;
      esac
    done
  else
    log "WARNING: kernel .config not found at $kconfig — skipping built-in check"
  fi

  rm -rf "$MERGED/tmp/hid-kmod"
  mkdir -p "$MERGED/tmp/hid-kmod"
  cp -a "$DRIVER_SRC_DIR/." "$MERGED/tmp/hid-kmod/"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod clean"

  in_chroot \
    "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod modules"

  # Post-build verification: each module must exist, be valid, and have
  # vermagic matching the target kernel.
  for mod in hid-logitech-dj hid-logitech-hidpp; do
    local ko="/tmp/hid-kmod/$mod.ko"
    [[ -s "$MERGED$ko" ]] || die "$mod.ko missing or empty after build"

    in_chroot "modinfo '$ko'" >/dev/null 2>&1 \
      || die "$mod.ko is not a valid module"

    local vermagic
    vermagic="$(in_chroot "modinfo -F vermagic '$ko'" 2>/dev/null | head -1)"
    [[ "$vermagic" == "$KVER "* ]] \
      || die "$mod.ko vermagic '$vermagic' does not match $KVER"
  done

  in_chroot \
    "install -Dm644 \
      /tmp/hid-kmod/hid-logitech-dj.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"

  in_chroot \
    "install -Dm644 \
      /tmp/hid-kmod/hid-logitech-hidpp.ko \
      /usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"

  # Run depmod so the overlay's module database recognizes /updates/logitech/
  # as higher priority than the stock kernel module in the lower layer.
  in_chroot "depmod $KVER"

  # Verify the built module has the modern Logitech receiver alias.
  in_chroot \
    "modinfo -F alias /tmp/hid-kmod/hid-logitech-dj.ko \
      | grep -qi 'v0000046Dp0000C547'" \
    || die "upstream hid-logitech-dj module lacks the 046d:c547 alias"

  # Verify the installed module path — what the image will actually load
  # after depmod — points to our /updates replacement, not the stock driver.
  for mod in hid-logitech-dj hid-logitech-hidpp; do
    local installed_path
    installed_path="$(in_chroot "modinfo -k $KVER -n $mod" 2>/dev/null)"
    [[ "$installed_path" == */updates/logitech/* ]] \
      || die "$mod resolves to $installed_path — not our replacement in /updates/logitech/"
  done

  log "Built upstream Logitech HID modules for $KVER"
}
