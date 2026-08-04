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

  # Default to Linux master for the latest device IDs.  The kzalloc_obj
  # compatibility patch in the download loop handles header mismatches.
  if [[ -z "$UPSTREAM_DRIVER_REF" ]]; then
    UPSTREAM_DRIVER_REF="master"
    UPSTREAM_DRIVER_SRC_BASE="https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid"
    log "HID source ref: $UPSTREAM_DRIVER_REF (default)"
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

    # Patch kernel API changes between master and the image's headers.
    if [[ "$f" == *.c ]]; then
      # kzalloc_obj was renamed/added after 6.16; replace with kzalloc.
      sed -i 's/kzalloc_obj(\*\([a-z_]*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$target.part"
      sed -i 's/kzalloc_obj(struct \([a-z_]*\))/kzalloc(sizeof(struct \1), GFP_KERNEL)/g' "$target.part"
      # kzalloc_objs(type, count) → kcalloc(count, sizeof(type), GFP_KERNEL)
      sed -i 's/kzalloc_objs(\([a-z_]*\), \([a-z_]*\))/kcalloc(\2, sizeof(\1), GFP_KERNEL)/g' "$target.part"
      # hid_report_raw_event gained a 6th arg after 6.16; strip it.
      # Call spans two lines: match the closing line after hid_report_raw_event.
      sed -i '/hid_report_raw_event/,/);/{s/, 1);/);/}' "$target.part"
    fi

    mv "$target.part" "$target"
  done

  cat > "$DRIVER_SRC_DIR/Makefile" <<'EOF'
obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF

  log "Upstream HID sources fetched to $DRIVER_SRC_DIR"
}
