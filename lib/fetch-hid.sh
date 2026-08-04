#!/bin/bash
#
# steamos-nvidia-installer — lib/fetch-hid.sh
# Download upstream HID driver sources (currently Logitech receiver/HID++)
# from the Linux kernel tree.  These are compiled against the image's neptune
# kernel by build-hid.sh.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/fetch-hid.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

fetch_hid_sources() {
  [[ $BUILD_HW_SUPPORT -eq 1 ]] || return 0

  # Default to the image's kernel version so the source matches the installed
  # headers (e.g. KVER=6.16.12-valve... → UPSTREAM_DRIVER_REF=v6.16).
  if [[ -z "$UPSTREAM_DRIVER_REF" ]]; then
    _kver_maj="${KVER%%.*}"                      # 6
    _kver_rest="${KVER#*.}"                       # 16.12-valve...
    _kver_min="${_kver_rest%%.*}"                 # 16
    UPSTREAM_DRIVER_REF="v${_kver_maj}.${_kver_min}"
    UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"
    log "HID source ref: $UPSTREAM_DRIVER_REF (derived from kernel $KVER)"
  fi

  # Re-download every run so we always get the correct version.
  DRIVER_SRC_DIR="$WORKDIR/hid-src"
  rm -rf "$DRIVER_SRC_DIR"
  mkdir -p "$DRIVER_SRC_DIR"

  local HID_DRIVER_FILES=(
    "hid-logitech-dj.c"
    "hid-logitech-hidpp.c"
    "hid-ids.h"
    "usbhid/usbhid.h"
  )

  for f in "${HID_DRIVER_FILES[@]}"; do
    target="$DRIVER_SRC_DIR/$f"
    mkdir -p "$(dirname "$target")"

    log "Downloading upstream HID source: $f"
    curl -sfL \
      "$UPSTREAM_DRIVER_SRC_BASE/$f" \
      -o "$target.part" \
      || die "download failed: $UPSTREAM_DRIVER_SRC_BASE/$f"

    mv "$target.part" "$target"
  done

  cat > "$DRIVER_SRC_DIR/Makefile" <<'EOF'
obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF

  log "Upstream HID sources fetched to $DRIVER_SRC_DIR"
}
