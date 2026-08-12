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

  # Default to Linux master for the latest device IDs.  Use parameter
  # defaults so UPSTREAM_DRIVER_SRC_BASE always tracks the ref, even if the
  # wrapper set UPSTREAM_DRIVER_REF without also setting the base URL.
  : "${UPSTREAM_DRIVER_REF:=master}"
  : "${UPSTREAM_DRIVER_SRC_BASE:=https://raw.githubusercontent.com/torvalds/linux/$UPSTREAM_DRIVER_REF/drivers/hid}"
  log "HID source ref: $UPSTREAM_DRIVER_REF"

  # Re-download every run so we always get the correct version.
  DRIVER_SRC_DIR="$WORKDIR/hid-src"
  rm -rf "$DRIVER_SRC_DIR"
  mkdir -p "$DRIVER_SRC_DIR"

  local HID_DRIVER_FILES=(
    "hid-logitech-dj.c"
    "hid-logitech-hidpp.c"
    "hid-ids.h"
  )

  local f target
  for f in "${HID_DRIVER_FILES[@]}"; do
    target="$DRIVER_SRC_DIR/$f"
    mkdir -p "$(dirname "$target")"

    log "Downloading upstream HID source: $f"
    curl_retry 3 -sfL \
      "$UPSTREAM_DRIVER_SRC_BASE/$f" \
      -o "$target.part" \
      || die "download failed: $UPSTREAM_DRIVER_SRC_BASE/$f"

    # Patch kernel API changes between master and the image's headers.
    if [[ "$f" == *.c ]]; then
      # kzalloc_obj was renamed/added after 6.16; replace with kzalloc.
      sed -i 's/kzalloc_obj(\*\([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$target.part"
      sed -i 's/kzalloc_obj(struct \([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(struct \1), GFP_KERNEL)/g' "$target.part"
      # kzalloc_objs(type, count) → kcalloc(count, sizeof(type), GFP_KERNEL)
      sed -i 's/kzalloc_objs(\([a-zA-Z_][a-zA-Z_0-9]*\), \([a-zA-Z_][a-zA-Z_0-9]*\))/kcalloc(\2, sizeof(\1), GFP_KERNEL)/g' "$target.part"
      # hid_report_raw_event gained a 6th arg (bufsize) after 6.16; the
      # new call is:
      #   hid_report_raw_event(hid, type, data, bufsize, size, interrupt)
      # old 6.16 call was:
      #   hid_report_raw_event(hid, type, data, size, interrupt)
      # Strip the bufsize arg (sizeof(consumer_report)) so the call
      # matches the 6.16 signature the image's headers expect.
      sed -i \
        's/consumer_report, sizeof(consumer_report), 5, 1);/consumer_report, 5, 1);/' \
        "$target.part"
    fi

    mv "$target.part" "$target"
  done

  # usbhid.h is an internal kernel header — use the image's own copy
  # (matches the kernel ABI) rather than downloading master's version.
  local usbhid_src="$MERGED/usr/lib/modules/$KVER/build/drivers/hid/usbhid/usbhid.h"
  if [[ -f "$usbhid_src" ]]; then
    log "Copying usbhid.h from image kernel headers"
    mkdir -p "$DRIVER_SRC_DIR/usbhid"
    cp "$usbhid_src" "$DRIVER_SRC_DIR/usbhid/usbhid.h"
  else
    log "WARNING: usbhid.h not found in image headers — downloading master (ABI mismatch risk)"
    mkdir -p "$DRIVER_SRC_DIR/usbhid"
    curl_retry 3 -sfL "$UPSTREAM_DRIVER_SRC_BASE/usbhid/usbhid.h" \
      -o "$DRIVER_SRC_DIR/usbhid/usbhid.h" \
      || die "download failed: usbhid/usbhid.h"
  fi

  cat > "$DRIVER_SRC_DIR/Makefile" <<'EOF'
obj-m += hid-logitech-dj.o
obj-m += hid-logitech-hidpp.o
EOF

  # Verify compatibility patches actually removed the incompatible APIs.
  if grep -REn '\bkzalloc_objs\?\(' "$DRIVER_SRC_DIR"; then
    die "Unpatched kzalloc_obj/kzalloc_objs use remains in HID source"
  fi
  if grep -qE 'sizeof\(consumer_report\), 5, 1' "$DRIVER_SRC_DIR"/hid-logitech-*.c; then
    die "hid_report_raw_event still has 6-arg form (bufsize patch failed)"
  fi

  log "Upstream HID sources fetched to $DRIVER_SRC_DIR"
}
