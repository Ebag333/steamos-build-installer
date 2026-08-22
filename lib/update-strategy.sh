#!/bin/bash
#
# steamos-nvidia-installer — lib/update-strategy.sh
# Stage 5: apply the chosen OS-update behaviour — self-healing (default),
# hold-updates, or stock. In selfheal mode this installs the on-device
# repatch tool plus wrappers for steamos-update and steamos-atomupd-client.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/update-strategy.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

apply_update_strategy() {
  # OOBE day-1 auto-migration stays masked in all modes except stock — a
  # surprise multi-GB update mid-first-boot is bad UX even when self-healing.
  if [[ $UPDATE_MODE != stock ]]; then
    [[ -f "$MNT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] \
      && ln -sf /dev/null "$MNT/etc/systemd/system/steamos-finish-oobe-migration.service"
  fi

  if [[ $UPDATE_MODE == hold ]]; then
    log "Holding OS updates: masking updater services, stubbing CLIs"
    [[ -f "$MNT/usr/lib/systemd/system/atomupd.service" ]] \
      && ln -sf /dev/null "$MNT/etc/systemd/system/atomupd.service"
    for bin in steamos-update steamos-update-os steamos-atomupd-client; do
      [[ -f "$MNT/usr/bin/$bin" && ! -f "$MNT/usr/bin/$bin.orig" ]] || continue
      mv "$MNT/usr/bin/$bin" "$MNT/usr/bin/$bin.orig"
      cat > "$MNT/usr/bin/$bin" <<'EOF'
#!/bin/bash
# Stubbed by steamos-nvidia-installer: an OS update would replace the rootfs
# and remove the NVIDIA driver. Original saved as $0.orig.
echo "OS updates are held on this system (NVIDIA-patched image)." >&2
# 7 = "no update available" to keep the Steam UI happy
exit 7
EOF
      chmod 755 "$MNT/usr/bin/$bin"
    done
  fi

  if [[ $UPDATE_MODE == selfheal ]]; then
    log "Installing self-healing update machinery"
    mkdir -p "$MNT/usr/lib/steamos-nvidia"

    # Bundle HID source into the rootfs for self-heal repatch.
    # Only if logitech-hid was selected in system tweaks.
    if [[ -n "${GAMING_ITEMS:-}" && " $GAMING_ITEMS " == *" logitech-hid "* ]]; then
      local hid_bundle="$MNT/usr/lib/steamos-nvidia/hid"
      rm -rf "$hid_bundle"
      mkdir -p "$hid_bundle"
      cp -a "$DRIVER_SRC_DIR/." "$hid_bundle/"
    fi

    # Persist build selections needed by repatch.  Package source/version policy
    # lives in the bundled hw-packages-{valve,arch}.conf manifests.  Entries
    # marked "latest" are resolved again on every self-heal.
    cat > "$MNT/usr/lib/steamos-nvidia/driver.conf" <<EOF
# Written by steamos-nvidia-installer at image build time.
# Package versions are controlled by:
#   /usr/lib/steamos-nvidia/configs/hw-packages-valve.conf
#   /usr/lib/steamos-nvidia/configs/hw-packages-arch.conf
INITRAMFS_MODULES="${INITRAMFS_MODULES:-}"
GAMING_ITEMS="${GAMING_ITEMS:-}"
DEBUG_BOOT=${DEBUG_BOOT:-0}
HW_SUPPORT_ITEMS="${HW_SUPPORT_ITEMS:-}"
BUILD_HW_SUPPORT=${BUILD_HW_SUPPORT:-0}
SKIP_SIG=${SKIP_SIG:-0}
FIX_KEYRING=${FIX_KEYRING:-0}
EXTRA_CMDLINE_ADD="${EXTRA_CMDLINE_ADD:-}"
EOF
    chmod 644 "$MNT/usr/lib/steamos-nvidia/driver.conf"

    # ---- on-device re-patch/runtime bundle
    # common.sh is required by repatch; keep both wrappers in the bundle so a
    # successful repatch can propagate the update machinery into the new slot.
    for helper in \
      repatch \
      common \
      overlay \
      common_system \
      common_modules \
      common_drivers \
      install-hw-libs \
      grub \
      update-wrapper \
      atomupd-wrapper
    do
      install -m 755 \
        "$SCRIPT_DIR/lib/$helper.sh" \
        "$MNT/usr/lib/steamos-nvidia/$helper.sh"
    done

    # ---- compatibility wrapper around steamos-update
    # This no longer owns repatch; the lower atomupd wrapper catches both
    # Steam/Game Mode and KDE Discover.
    if [[ ! -f "$MNT/usr/bin/steamos-update.orig" ]]; then
      mv "$MNT/usr/bin/steamos-update" "$MNT/usr/bin/steamos-update.orig"
    fi
    install -m 755 \
      "$SCRIPT_DIR/lib/update-wrapper.sh" \
      "$MNT/usr/bin/steamos-update"

    # ---- authoritative wrapper around steamos-atomupd-client
    # atomupd-daemon launches this helper for OS operations, so this is the
    # shared interception point for Game Mode and Discover.
    if [[ ! -f "$MNT/usr/bin/steamos-atomupd-client.orig" ]]; then
      mv "$MNT/usr/bin/steamos-atomupd-client" \
         "$MNT/usr/bin/steamos-atomupd-client.orig"
    fi
    install -m 755 \
      "$SCRIPT_DIR/lib/atomupd-wrapper.sh" \
      "$MNT/usr/bin/steamos-atomupd-client"
  fi
}
