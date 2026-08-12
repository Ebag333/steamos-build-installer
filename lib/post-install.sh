#!/bin/bash
#
# post-install.sh
#
# SteamOS NVIDIA post-install configuration utility.
#
# Normal mode:
#   Run as the logged-in desktop user.
#   Displays a Zenity checklist of optional configuration changes.
#
# Worker mode:
#   Re-executes itself through pkexec with --apply.
#   Performs only the selected privileged operations.
#
# Safe to run repeatedly.

set -uo pipefail

TITLE="SteamOS NVIDIA Configuration"
LOG="/var/log/steamos-nvidia-post-install.log"
SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"


# ============================================================
# Common helpers
# ============================================================

log() {
    echo "[nvidia-usb] $*"
}

warn() {
    echo "[warn] $*" >&2
}


# ============================================================
# Privileged worker
# ============================================================

PASS=0
FAIL=0


run_action() {
    local label="$1"
    local fn="$2"

    printf '%s... ' "$label"

    if "$fn"; then
        echo "✓"
        PASS=$((PASS + 1))
    else
        echo "✗"
        FAIL=$((FAIL + 1))
    fi
}


make_rootfs_writable() {
    if command -v steamos-readonly >/dev/null 2>&1; then
        log "Disabling SteamOS read-only mode"
        steamos-readonly disable || true
    fi
}


restore_rootfs_readonly() {
    if command -v steamos-readonly >/dev/null 2>&1; then
        log "Re-enabling SteamOS read-only mode"
        steamos-readonly enable || true
    fi
}


# ============================================================
# Thunderbolt
# ============================================================

apply_thunderbolt() {
    log "Installing Thunderbolt support"

    install -d -m755 \
        /etc/udev/rules.d \
        /usr/local/bin \
        /usr/lib/steamos-nvidia/thunderbolt \
        || return 1

    #
    # Rescan PCI when an authorized Thunderbolt device appears.
    #
    cat > /etc/udev/rules.d/98-thunderbolt-rescan.rules <<'EOF'
# steamos-nvidia-installer
# Rescan the PCI bus when an authorized Thunderbolt device appears.
ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="1", RUN+="/usr/local/bin/thunderbolt-rescan.sh"
EOF

    chmod 644 /etc/udev/rules.d/98-thunderbolt-rescan.rules \
        || return 1

    #
    # PCI rescan helper.
    #
    cat > /usr/local/bin/thunderbolt-rescan.sh <<'EOF'
#!/bin/bash
echo 1 > /sys/bus/pci/rescan
EOF

    chmod 755 /usr/local/bin/thunderbolt-rescan.sh \
        || return 1

    #
    # Bundle our custom files so the NVIDIA self-heal mechanism can
    # restore them after a SteamOS rootfs update.
    #
    install -m644 \
        /etc/udev/rules.d/98-thunderbolt-rescan.rules \
        /usr/lib/steamos-nvidia/thunderbolt/98-thunderbolt-rescan.rules \
        || return 1

    install -m755 \
        /usr/local/bin/thunderbolt-rescan.sh \
        /usr/lib/steamos-nvidia/thunderbolt/thunderbolt-rescan.sh \
        || return 1

    #
    # Activate the new rule immediately.
    #
    udevadm control --reload-rules \
        || return 1

    #
    # bolt/plasma-thunderbolt are already present in SteamOS.
    #
    if systemctl list-unit-files bolt.service >/dev/null 2>&1; then
        systemctl enable --now bolt.service \
            || return 1
    else
        warn "bolt.service was not found"
        return 1
    fi

    return 0
}


# ============================================================
# Hardware scan utility
# ============================================================

apply_hardware_scan() {
    log "Installing hardware scan utility"

    install -d -m755 /usr/local/bin \
        || return 1

    cat > /usr/local/bin/scan-hardware <<'SCANEOF'
#!/bin/bash

echo "=== Hardware scan: unclaimed PCI devices ==="
echo

found=0

while IFS= read -r line; do
    dev="$(echo "$line" | cut -d' ' -f1)"
    desc="$(echo "$line" | cut -d' ' -f2-)"

    vendor_device="$(
        echo "$line" |
            grep -oP '\[\K[0-9a-fA-F]{4}:[0-9a-fA-F]{4}' |
            head -1 ||
            true
    )"

    driver="$(
        lspci -k -s "$dev" 2>/dev/null |
            grep "Kernel driver in use" |
            awk '{print $NF}' ||
            true
    )"

    #
    # If a kernel driver already owns the device, it's fine.
    #
    [[ -n "$driver" ]] && continue

    found=1

    echo "Unclaimed: $dev $desc"

    if [[ -n "$vendor_device" ]]; then
        vendor="${vendor_device%:*}"
        device="${vendor_device#*:}"

        vendor="${vendor^^}"
        device="${device^^}"

        modalias="pci:v0000${vendor}d0000${device}sv*sd*bc*sc*i*"

        modules="$(
            modprobe -R "$modalias" 2>/dev/null |
                head -5 ||
                true
        )"

        if [[ -n "$modules" ]]; then
            echo "  Matching module(s):"
            echo "$modules" | sed 's/^/    /'
        else
            echo "  No matching kernel module found for $vendor_device"
        fi
    fi

    echo

done < <(lspci -nn)


if [[ $found -eq 0 ]]; then
    echo "All PCI devices have drivers loaded."
fi
SCANEOF

    chmod 755 /usr/local/bin/scan-hardware \
        || return 1

    return 0
}


# ============================================================
# Default SteamOS session
# ============================================================

apply_desktop_mode() {
    if ! command -v steamosctl >/dev/null 2>&1; then
        warn "steamosctl is not available"
        return 1
    fi

    steamosctl set-default-login-mode desktop
}


# ============================================================
# NVIDIA initramfs configuration
# ============================================================

apply_initramfs() {
    #
    # Prefer dracut when available.
    #
    if command -v dracut >/dev/null 2>&1; then
        log "Configuring NVIDIA modules for dracut"

        install -d -m755 /etc/dracut.conf.d \
            || return 1

        cat > /etc/dracut.conf.d/99-steamos-nvidia.conf <<'EOF'
add_drivers+=" nvidia nvidia_modeset nvidia_drm nvidia_uvm "
EOF

        chmod 644 /etc/dracut.conf.d/99-steamos-nvidia.conf \
            || return 1

        log "Regenerating initramfs"

        dracut -f \
            || return 1

        return 0
    fi


    #
    # Fall back to mkinitcpio.
    #
    if command -v mkinitcpio >/dev/null 2>&1; then
        log "Configuring NVIDIA modules for mkinitcpio"

        if [[ -d /etc/mkinitcpio.conf.d ]]; then
            cat > /etc/mkinitcpio.conf.d/99-steamos-nvidia.conf <<'EOF'
MODULES+=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)
EOF

            chmod 644 /etc/mkinitcpio.conf.d/99-steamos-nvidia.conf \
                || return 1

        elif [[ -f /etc/mkinitcpio.conf ]]; then

            if grep -q '^MODULES=()' /etc/mkinitcpio.conf; then
                sed -i \
                    's/^MODULES=()/MODULES=(nvidia nvidia_modeset nvidia_drm nvidia_uvm)/' \
                    /etc/mkinitcpio.conf \
                    || return 1

            elif ! grep -q 'nvidia_drm' /etc/mkinitcpio.conf; then
                warn "Could not safely update MODULES in /etc/mkinitcpio.conf"
                return 1
            fi

        else
            warn "mkinitcpio configuration not found"
            return 1
        fi

        log "Regenerating initramfs"

        mkinitcpio -P \
            || return 1

        return 0
    fi


    warn "Neither dracut nor mkinitcpio was found"
    return 1
}


# ============================================================
# Privileged action dispatcher
# ============================================================

apply_actions() {
    local selected="$1"
    local action
    local -a actions

    if [[ $EUID -ne 0 ]]; then
        echo "Privileged worker must run as root." >&2
        return 1
    fi

    mkdir -p "$(dirname "$LOG")"

    #
    # Everything from here goes both to the terminal/pkexec process
    # and the persistent log.
    #
    exec > >(tee -a "$LOG") 2>&1

    echo
    echo "=============================================="
    echo " SteamOS NVIDIA Post-Install Configuration"
    echo "=============================================="
    echo
    date
    echo

    make_rootfs_writable

    #
    # Restore SteamOS filesystem protection regardless of how the
    # worker exits.
    #
    trap restore_rootfs_readonly EXIT

    IFS='|' read -r -a actions <<< "$selected"

    for action in "${actions[@]}"; do
        case "$action" in

            thunderbolt)
                run_action \
                    "Configuring Thunderbolt support" \
                    apply_thunderbolt
                ;;

            hardware-scan)
                run_action \
                    "Installing hardware scan utility" \
                    apply_hardware_scan
                ;;

            desktop)
                run_action \
                    "Setting Desktop Mode as default" \
                    apply_desktop_mode
                ;;

            initramfs)
                run_action \
                    "Adding NVIDIA modules to initramfs" \
                    apply_initramfs
                ;;

            "")
                ;;

            *)
                warn "Unknown action: $action"
                FAIL=$((FAIL + 1))
                ;;
        esac
    done

    echo
    echo "=============================================="
    echo " Results"
    echo "=============================================="
    echo
    echo "Successful: $PASS"
    echo "Failed:     $FAIL"
    echo
    echo "Log: $LOG"
    echo

    if (( FAIL > 0 )); then
        return 1
    fi

    return 0
}


# ============================================================
# Worker entry point
# ============================================================

if [[ "${1:-}" == "--apply" ]]; then
    shift

    selected="${1:-}"

    if [[ -z "$selected" ]]; then
        echo "No configuration actions supplied." >&2
        exit 1
    fi

    apply_actions "$selected"
    exit $?
fi


# ============================================================
# GUI frontend
# ============================================================

#
# The GUI must run as the desktop user.
#
if [[ $EUID -eq 0 ]]; then
    echo "Run this configuration utility as the logged-in desktop user."
    echo
    echo "Do not run it with sudo."
    exit 1
fi


if ! command -v zenity >/dev/null 2>&1; then
    echo "zenity is required for the graphical configuration utility."
    exit 1
fi


if ! command -v pkexec >/dev/null 2>&1; then
    zenity \
        --error \
        --title="$TITLE" \
        --width=400 \
        --text="<b>pkexec was not found.</b>

Administrator privileges are required to apply system configuration changes."

    exit 1
fi


# ============================================================
# Configuration checklist
# ============================================================

SELECTED="$(
    zenity \
        --list \
        --checklist \
        --title="$TITLE" \
        --text="Select the changes you want to apply:" \
        --width=760 \
        --height=420 \
        --column="Apply" \
        --column="ID" \
        --column="Configuration change" \
        --hide-column=2 \
        --print-column=2 \
        --separator='|' \
        TRUE  thunderbolt   "Configure Thunderbolt dock and hotplug support" \
        TRUE  hardware-scan "Install the hardware driver scan utility" \
        TRUE  desktop       "Boot into Desktop Mode by default" \
        TRUE  initramfs     "Add NVIDIA modules to the initramfs"
)"

ZENITY_RC=$?


#
# Cancel or window close.
#
if [[ $ZENITY_RC -ne 0 ]]; then
    exit 0
fi


#
# OK with nothing selected.
#
if [[ -z "$SELECTED" ]]; then
    zenity \
        --info \
        --title="$TITLE" \
        --width=360 \
        --text="No configuration changes were selected."

    exit 0
fi


IFS='|' read -r -a SELECTED_ARRAY <<< "$SELECTED"
COUNT="${#SELECTED_ARRAY[@]}"


# ============================================================
# Elevate only the worker
# ============================================================

if pkexec /bin/bash "$SCRIPT" --apply "$SELECTED"; then

    zenity \
        --info \
        --title="$TITLE" \
        --width=450 \
        --text="<b>Configuration complete.</b>

$COUNT selected configuration item(s) completed successfully.

Some changes may require a reboot to take effect."

else
    RC=$?

    zenity \
        --warning \
        --title="$TITLE" \
        --width=500 \
        --text="<b>Configuration completed with one or more errors.</b>

Check the log for details:

$LOG

Worker exit code: $RC"
fi
