#!/bin/bash
#
# build-hid.sh — Build and install upstream Logitech HID kernel modules.
# Runs inside the build chroot via INSTALL_CMD.
#
# Usage: build-hid.sh [REF]
#   REF: git ref for upstream Linux HID sources (default: master)
#
set -euo pipefail

REF="${1:-master}"
BASE_URL="https://raw.githubusercontent.com/torvalds/linux/$REF/drivers/hid"
KVER="$(
  find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
    | sort -V \
    | tail -1
)"

if [[ -z "$KVER" ]]; then
  echo "ERROR: no kernel versions found in /usr/lib/modules" >&2
  exit 1
fi

[[ -d "/usr/lib/modules/$KVER/build" ]] || {
  echo "ERROR: headers/build tree missing for $KVER" >&2
  exit 1
}

BUILD_DIR="/tmp/hid-kmod"
INSTALL_DIR="/usr/lib/modules/$KVER/updates/logitech"
BUNDLE_DIR="/home/.steamos-build/bundles/hid"

echo "=== Logitech HID module build ==="
echo "  Kernel: $KVER"
echo "  Source ref: $REF"
echo "  URL base: $BASE_URL"

# ── 1. Download sources ──────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/usbhid"

for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h; do
  echo "  Downloading $f"
  curl -sfL "$BASE_URL/$f" -o "$BUILD_DIR/$f" || {
    echo "ERROR: failed to download $f" >&2
    exit 1
  }
done

# usbhid.h — prefer the kernel's own copy (ABI match), fall back to upstream
if [[ -f "/usr/lib/modules/$KVER/build/drivers/hid/usbhid/usbhid.h" ]]; then
  echo "  Copying usbhid.h from kernel headers"
  cp "/usr/lib/modules/$KVER/build/drivers/hid/usbhid/usbhid.h" "$BUILD_DIR/usbhid/usbhid.h" || {
    echo "ERROR: failed to copy usbhid.h from kernel headers" >&2
    exit 1
  }
else
  echo "  WARNING: usbhid.h not in kernel headers — downloading master"
  curl -sfL "$BASE_URL/usbhid/usbhid.h" -o "$BUILD_DIR/usbhid/usbhid.h" || {
    echo "ERROR: failed to download usbhid/usbhid.h" >&2
    exit 1
  }
fi

# ── 2. Patch kernel API compat ───────────────────────────────────────────
echo "  Patching kernel API compatibility"
for f in "$BUILD_DIR"/hid-logitech-*.c; do
  [[ -f "$f" ]] || continue
  # kzalloc_obj → kzalloc
  sed -i 's/kzalloc_obj(\*\([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(*\1), GFP_KERNEL)/g' "$f"
  sed -i 's/kzalloc_obj(struct \([a-zA-Z_][a-zA-Z_0-9]*\))/kzalloc(sizeof(struct \1), GFP_KERNEL)/g' "$f"
  # kzalloc_objs(type, count) → kcalloc(count, sizeof(type), GFP_KERNEL)
  sed -i 's/kzalloc_objs(\([a-zA-Z_][a-zA-Z_0-9]*\), \([a-zA-Z_][a-zA-Z_0-9]*\))/kcalloc(\2, sizeof(\1), GFP_KERNEL)/g' "$f"
  # Strip bufsize arg from hid_report_raw_event (6-arg → 5-arg for 6.16)
  sed -i 's/consumer_report, sizeof(consumer_report), 5, 1);/consumer_report, 5, 1);/' "$f"
done

# Verify patches took effect
if grep -REn '\bkzalloc_objs?\(' "$BUILD_DIR" >&2; then
  echo "ERROR: unpatched kzalloc_obj/kzalloc_objs remains" >&2
  exit 1
fi
matched_files=("$BUILD_DIR"/hid-logitech-*.c)
if [[ ${#matched_files[@]} -eq 0 ]]; then
  echo "ERROR: no hid-logitech-*.c files found for hid_report_raw_event check" >&2
  exit 1
fi
if grep -qE 'sizeof\(consumer_report\), 5, 1' "${matched_files[@]}"; then
  echo "ERROR: hid_report_raw_event still has 6-arg form" >&2
  exit 1
fi

# ── 3. Create Makefile ───────────────────────────────────────────────────
cat "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../../../heredocs/static/logitech-hid-makefile" >"$BUILD_DIR/Makefile"

# ── 4. Verify stock drivers are modules (not built-in) ───────────────────
KCONFIG="/usr/lib/modules/$KVER/build/.config"
if [[ -f "$KCONFIG" ]]; then
  for mod in HID_LOGITECH_DJ HID_LOGITECH_HIDPP; do
    val="$(grep "^CONFIG_${mod}=" "$KCONFIG" 2>/dev/null | cut -d= -f2 || true)"
    case "$val" in
      m) echo "  CONFIG_${mod}=m (module — replaceable)" ;;
      y)
        echo "ERROR: CONFIG_${mod}=y (built-in) — cannot replace" >&2
        exit 1
        ;;
      *) echo "  CONFIG_${mod} not set (ok)" ;;
    esac
  done
else
  echo "  WARNING: kernel .config not found — skipping built-in check"
fi

# ── 5. Build ─────────────────────────────────────────────────────────────
echo "  Building modules"
make -C "/usr/lib/modules/$KVER/build" M="$BUILD_DIR" clean || true
make -C "/usr/lib/modules/$KVER/build" M="$BUILD_DIR" modules

# ── 6. Verify built modules ──────────────────────────────────────────────
for mod in hid-logitech-dj hid-logitech-hidpp; do
  ko="$BUILD_DIR/$mod.ko"
  [[ -s "$ko" ]] || {
    echo "ERROR: $mod.ko missing or empty" >&2
    exit 1
  }
  modinfo "$ko" >/dev/null 2>&1 || {
    echo "ERROR: $mod.ko is not a valid module" >&2
    exit 1
  }
  vermagic="$(modinfo -F vermagic "$ko" 2>/dev/null | head -1)"
  [[ "$vermagic" == "$KVER "* ]] || {
    echo "ERROR: $mod.ko vermagic '$vermagic' != $KVER" >&2
    exit 1
  }
  echo "  OK $mod.ko (vermagic: $vermagic)"
done

# Verify the 046d:c547 alias
modinfo -F alias "$BUILD_DIR/hid-logitech-dj.ko" | grep -qi 'v0000046Dp0000C547' \
  || {
    echo "ERROR: hid-logitech-dj lacks 046d:c547 alias" >&2
    exit 1
  }
echo "  OK 046d:c547 alias present"

# ── 7. Install ───────────────────────────────────────────────────────────
echo "  Installing to $INSTALL_DIR"
install -Dm644 "$BUILD_DIR/hid-logitech-dj.ko" "$INSTALL_DIR/hid-logitech-dj.ko"
install -Dm644 "$BUILD_DIR/hid-logitech-hidpp.ko" "$INSTALL_DIR/hid-logitech-hidpp.ko"
depmod "$KVER"

# Verify installed paths resolve to our replacement
for mod in hid-logitech-dj hid-logitech-hidpp; do
  installed_path="$(modinfo -k "$KVER" -n "$mod" 2>/dev/null)"
  [[ "$installed_path" == */updates/logitech/* ]] \
    || {
      echo "ERROR: $mod resolves to $installed_path — not /updates/logitech/" >&2
      exit 1
    }
  echo "  OK $mod → $installed_path"
done

# ── 8. Bundle sources for self-heal ──────────────────────────────────────
echo "  Bundling sources for self-heal"
mkdir -p "$BUNDLE_DIR"
cp -a "$BUILD_DIR/." "$BUNDLE_DIR/"

echo "=== Logitech HID modules built and installed ==="
