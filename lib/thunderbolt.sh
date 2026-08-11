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
#   - Auto-authorize udev rule (no manual dock auth needed)
#   - PCI rescan udev rule + script (fixes flaky hot-plug)
#   - bolt daemon (device management + Plasma integration)
install_thunderbolt_support() {
  [[ "${THUNDERBOLT:-0}" -eq 1 ]] || return 0

  log "Installing Thunderbolt dock support"

  # ---- 1. Auto-authorize all Thunderbolt devices ----
  cat > "$MNT/etc/udev/rules.d/99-steamos-tb-autoauth.rules" <<'EOF'
# steamos-nvidia-installer: auto-authorize Thunderbolt devices on connect.
# Allows docks and eGPUs to work without manual authorization.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
EOF
  log "  Installed auto-authorize udev rule"

  # ---- 2. PCI rescan on Thunderbolt connect ----
  cat > "$MNT/usr/local/bin/thunderbolt-rescan.sh" <<'EOF'
#!/bin/bash
# Trigger PCI bus rescan when a Thunderbolt device is authorized.
# Fixes cases where the dock's PCI devices don't appear on hot-plug.
echo 1 > /sys/bus/pci/rescan
EOF
  chmod +x "$MNT/usr/local/bin/thunderbolt-rescan.sh"

  cat > "$MNT/etc/udev/rules.d/98-thunderbolt-rescan.rules" <<'EOF'
# steamos-nvidia-installer: rescan PCI bus after Thunderbolt authorization.
ACTION=="change", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="1", RUN+="/usr/local/bin/thunderbolt-rescan.sh"
EOF
  log "  Installed PCI rescan udev rule + script"

  # ---- 3. Install bolt daemon ----
  log "  Installing bolt package"
  in_chroot "pacman -S --noconfirm bolt" || warn "Could not install bolt (non-fatal, TB auth still works via udev rule)"

  # Enable bolt service
  in_chroot "systemctl enable bolt.service" 2>/dev/null \
    || warn "Could not enable bolt.service (non-fatal)"

  log "Thunderbolt support installed"
}