#!/bin/bash
#
# steamos-build-installer — lib/update-strategy.sh
# Stage 5: apply the chosen OS-update behaviour — self-healing (default),
# hold-updates, or stock. In selfheal mode this installs the on-device
# repatch tool plus wrappers for steamos-update and steamos-atomupd-client.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/update-strategy.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

apply_update_strategy() {
  UPDATE_MODE="${UPDATE_MODE:-selfheal}"
  [[ -n "${MNT:-}" && -d "${MNT:-}" ]] || { warn "apply_update_strategy: MNT is not set or not a directory"; return 1; }
  [[ -n "${SCRIPT_DIR:-}" && -d "${SCRIPT_DIR:-}" ]] || { warn "apply_update_strategy: SCRIPT_DIR is not set or not a directory"; return 1; }
  # OOBE day-1 auto-migration stays masked in all modes except stock — a
  # surprise multi-GB update mid-first-boot is bad UX even when self-healing.
  if [[ "$UPDATE_MODE" != "stock" ]]; then
    [[ -f "$MNT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] && {
      mkdir -p "$MNT/etc/systemd/system"
      ln -sf /dev/null "$MNT/etc/systemd/system/steamos-finish-oobe-migration.service"
    }
  fi

  if [[ "$UPDATE_MODE" == "hold" ]]; then
    log "Holding OS updates: masking updater services, stubbing CLIs"
    [[ -f "$MNT/usr/lib/systemd/system/atomupd.service" ]] && {
      mkdir -p "$MNT/etc/systemd/system"
      ln -sf /dev/null "$MNT/etc/systemd/system/atomupd.service"
    }
    for bin in steamos-update steamos-update-os steamos-atomupd-client; do
      if [[ ! -f "$MNT/usr/bin/$bin" ]]; then
        log "  hold: skip $bin (not found)"
        continue
      fi
      if [[ -f "$MNT/usr/bin/$bin.orig" ]]; then
        log "  hold: skip $bin (already stubbed)"
        continue
      fi
      mv "$MNT/usr/bin/$bin" "$MNT/usr/bin/$bin.orig" \
        || { warn "hold: failed to back up $bin"; continue; }
      cat >"$MNT/usr/bin/$bin" <<'STUB'
#!/bin/bash
# Stubbed by steamos-build-installer: an OS update would replace the rootfs
# and remove the NVIDIA driver. Original saved as $0.orig.
echo "OS updates are held on this system (NVIDIA-patched image)." >&2
# 7 = "no update available" to keep the Steam UI happy
exit 7
STUB
      chmod 755 "$MNT/usr/bin/$bin" \
        || warn "hold: failed to chmod $bin"
    done
  fi

  if [[ "$UPDATE_MODE" == "selfheal" ]]; then
    log "Installing self-healing update machinery"

    # ---- compatibility wrapper around steamos-update
    # This no longer owns repatch; the lower atomupd wrapper catches both
    # Steam/Game Mode and KDE Discover.
    if [[ -f "$MNT/usr/bin/steamos-update" ]]; then
      if [[ ! -f "$MNT/usr/bin/steamos-update.orig" ]]; then
        mv "$MNT/usr/bin/steamos-update" "$MNT/usr/bin/steamos-update.orig" \
          || { warn "selfheal: failed to back up steamos-update"; return 1; }
        log "  selfheal: backed up steamos-update"
      fi
    fi
    if [[ -f "$SCRIPT_DIR/lib/update-wrapper.sh" ]]; then
      install -m 755 "$SCRIPT_DIR/lib/update-wrapper.sh" "$MNT/usr/bin/steamos-update" \
        || warn "selfheal: failed to install steamos-update wrapper"
    else
      warn "selfheal: wrapper source not found: $SCRIPT_DIR/lib/update-wrapper.sh"
    fi

    # ---- authoritative wrapper around steamos-atomupd-client
    # atomupd-daemon launches this helper for OS operations, so this is the
    # shared interception point for Game Mode and Discover.
    if [[ -f "$MNT/usr/bin/steamos-atomupd-client" ]]; then
      if [[ ! -f "$MNT/usr/bin/steamos-atomupd-client.orig" ]]; then
        mv "$MNT/usr/bin/steamos-atomupd-client" "$MNT/usr/bin/steamos-atomupd-client.orig" \
          || { warn "selfheal: failed to back up steamos-atomupd-client"; return 1; }
        log "  selfheal: backed up steamos-atomupd-client"
      fi
    fi
    if [[ -f "$SCRIPT_DIR/lib/atomupd-wrapper.sh" ]]; then
      install -m 755 "$SCRIPT_DIR/lib/atomupd-wrapper.sh" "$MNT/usr/bin/steamos-atomupd-client" \
        || warn "selfheal: failed to install steamos-atomupd-client wrapper"
    else
      warn "selfheal: wrapper source not found: $SCRIPT_DIR/lib/atomupd-wrapper.sh"
    fi
  elif [[ "$UPDATE_MODE" != "stock" ]]; then
    warn "apply_update_strategy: unknown UPDATE_MODE='$UPDATE_MODE' — no strategy applied"
  fi
}
