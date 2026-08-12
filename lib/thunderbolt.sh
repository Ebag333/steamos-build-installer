#!/bin/bash
#
# steamos-nvidia-installer — lib/thunderbolt.sh
# Install Thunderbolt dock support: auto-authorize, PCI rescan, bolt daemon.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/thunderbolt.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Install Thunderbolt support into the image.
#   - PCI rescan udev rule + script (fixes flaky hot-plug)
#   - bolt service (device management + Plasma integration)
install_thunderbolt_support() {
  [[ "${THUNDERBOLT:-0}" -eq 1 ]] || return 0

  log "Installing Thunderbolt dock support"

  # The rootfs must be writable at this point — setup_mount_partitions
  # established that invariant.  If something broke it, die immediately
  # rather than trying to repair state here.
  [[ -w "$MNT/etc" ]] || die "Rootfs unexpectedly read-only before Thunderbolt install"

  # ---- 1. PCI rescan on Thunderbolt connect ----
  # bolt handles device authorization; we just need to rescan the PCI bus
  # when a device appears so its downstream PCI devices show up.
  cat > "$MNT/usr/local/bin/thunderbolt-rescan.sh" <<'EOF'
#!/bin/bash
# Trigger PCI bus rescan when a Thunderbolt device is added.
# Fixes cases where the dock's PCI devices don't appear on hot-plug.
echo 1 > /sys/bus/pci/rescan
EOF
  chmod +x "$MNT/usr/local/bin/thunderbolt-rescan.sh"

  cat > "$MNT/etc/udev/rules.d/98-thunderbolt-rescan.rules" <<'EOF'
# steamos-nvidia-installer: rescan PCI bus when a Thunderbolt device appears.
# Devices already authorized (by firmware or bolt) get a rescan so their
# downstream PCI endpoints show up immediately.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="1", RUN+="/usr/local/bin/thunderbolt-rescan.sh"
EOF
  log "  Installed PCI rescan udev rule + script"

  # ---- 2. Enable bolt service ----
  # bolt is already installed in SteamOS; just enable it.
  log "  Enabling bolt.service in image"
  mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
  ln -sf /usr/lib/systemd/system/bolt.service \
    "$MNT/etc/systemd/system/multi-user.target.wants/bolt.service"

  # ---- 3. Bundle thunderbolt files for self-heal propagation ----
  # repatch.sh copies /usr/lib/steamos-nvidia/ into every new slot, so bundle
  # our custom udev rules and rescan script there.
  log "  Bundling thunderbolt files for self-heal"
  mkdir -p "$MNT/usr/lib/steamos-nvidia/thunderbolt"
  cp "$MNT/etc/udev/rules.d/98-thunderbolt-rescan.rules" \
    "$MNT/usr/lib/steamos-nvidia/thunderbolt/"
  cp "$MNT/usr/local/bin/thunderbolt-rescan.sh" \
    "$MNT/usr/lib/steamos-nvidia/thunderbolt/"

  log "Thunderbolt support installed"
}