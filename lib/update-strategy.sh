#!/bin/bash
#
# steamos-nvidia-installer — lib/update-strategy.sh
# Stage 5: apply the chosen OS-update behaviour — self-healing (default),
# hold-updates, or stock. In selfheal mode this installs the on-device
# repatch tool + the steamos-update wrapper.
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

    # Bundle HID source into the image for self-heal repatch to rebuild.
    if [[ $BUILD_HW_SUPPORT -eq 1 ]]; then
      mkdir -p "$MNT/usr/lib/steamos-nvidia/hid"
      cp -a "$DRIVER_SRC_DIR/." "$MNT/usr/lib/steamos-nvidia/hid/"
    fi

    # pinned driver record — repatch installs these exact packages (instead of
    # the slot's frozen repo, which is what the valve-driver variant does)
    cat > "$MNT/usr/lib/steamos-nvidia/driver.conf" <<EOF
# Written by steamos-nvidia-installer at image build time.
# repatch.sh installs the driver from these pinned URLs; to move to a newer
# driver later, rebuild the USB image with the latest script and reinstall
# (or update this file by hand with matching-version package URLs).
DRIVER_SPEC="$DRIVER_SPEC"
DRIVER_VERSION="$DRIVER_VERSION"
PKG_URLS="$PKG_URLS"
EOF
    chmod 644 "$MNT/usr/lib/steamos-nvidia/driver.conf"

    # ---- on-device re-patch tool: rebuilds the driver inside the OTHER slot
    cat > "$MNT/usr/lib/steamos-nvidia/repatch.sh" <<'REPATCH'
#!/bin/bash
# steamos-nvidia repatch — rebuild + install the NVIDIA driver into another
# partition set (normally "other", right after an OS update staged there).
# Run as root. Idempotent: exits 0 immediately if the slot already has the
# driver for its kernel. Logs to stdout (the update wrapper redirects).
set -euo pipefail

PARTSET="${1:-other}"
log() { echo "[repatch] $*"; }
die() { echo "[repatch] FAIL: $*" >&2; exit 1; }

ROOTDEV="/dev/disk/by-partsets/$PARTSET/rootfs"
EFIDEV="/dev/disk/by-partsets/$PARTSET/efi"
[[ -b "$ROOTDEV" && -b "$EFIDEV" ]] || die "partset '$PARTSET' not found (single-slot system?)"

NEWROOT="$(mktemp -d /tmp/repatch-root.XXXXXX)"
# SteamOS /home is ext4 with casefold enabled, which overlayfs rejects as an
# upperdir — so the build workspace lives inside a plain ext4 loopback image
# on /home (space for the build, no casefold).
WORKIMG=/home/.steamos-nvidia-work.img
WORK="$(mktemp -d /tmp/repatch-work.XXXXXX)"
UPPER="$WORK/upper"; OVLWORK="$WORK/ovlwork"; MERGED="$WORK/merged"

cleanup() {
  set +e
  # Guard: if MERGED was never initialized, no mounts were created — bail out
  # before the expansions resolve to the host's /dev, /proc, etc.
  [[ -n "${MERGED:-}" ]] || return 0
  for m in "$MERGED/dev/pts" "$MERGED/dev" "$MERGED/sys" "$MERGED/proc" "$MERGED/tmp" "$MERGED" \
           "$NEWROOT/efi" "$NEWROOT/dev/pts" "$NEWROOT/dev" "$NEWROOT/sys" "$NEWROOT/proc" "$NEWROOT" \
           "$WORK"; do
    mountpoint -q "$m" 2>/dev/null && { umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null; }
  done
  rmdir "$NEWROOT" "$WORK" 2>/dev/null
  rm -f "$WORKIMG"
}
trap cleanup EXIT

rm -f "$WORKIMG"
truncate -s 8G "$WORKIMG"
mkfs.ext4 -q -F "$WORKIMG"
mount -o loop "$WORKIMG" "$WORK"
mkdir -p "$UPPER" "$OVLWORK" "$MERGED"

log "Mounting $ROOTDEV"
mount -o compress-force=zstd:3 "$ROOTDEV" "$NEWROOT"
# Ensure rootfs is writable — check VFS mount state, not btrfs property
# (subvolid=5 doesn't support the ro property).
if findmnt -no OPTIONS "$NEWROOT" | tr ',' '\n' | grep -qx ro; then
  log "Remounting $PARTSET rootfs rw"
  mount -o remount,rw "$NEWROOT" || die "Could not remount $PARTSET rootfs read-write"
fi
if ! touch "$NEWROOT/.rw-test"; then
  die "$PARTSET rootfs is not writable"
fi
rm -f "$NEWROOT/.rw-test"

KVER=""
for d in "$NEWROOT/usr/lib/modules/"*neptune*; do
  [[ -d "$d" ]] && KVER="$(basename "$d")" && break
done
[[ -n "$KVER" ]] || die "no neptune kernel in $PARTSET rootfs"
log "Target kernel: $KVER"

if compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null; then
  HID_OK=0
  if [[ -d /usr/lib/steamos-nvidia/hid ]]; then
    compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
      && compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
      && compgen -G "$NEWROOT/usr/lib/holo/pacmandb/local/libratbag-[0-9]*" >/dev/null \
      && HID_OK=1
  else
    HID_OK=1  # no HID bundle — nothing to check
  fi
  if [[ $HID_OK -eq 1 ]]; then
    log "Driver already present for $KVER — nothing to do"
    exit 0
  fi
  log "NVIDIA present but HID modules/libratbag missing — rebuilding"
fi

PACDB="$NEWROOT/usr/lib/holo/pacmandb/local"
KPKG_DIR=""
for d in "$PACDB"/linux-neptune-*-[0-9]*; do
  [[ -d "$d" ]] || continue
  case "$(basename "$d")" in *-headers-*|*firmware*|*rtw*) continue ;; esac
  KPKG_DIR="$d"; break
done
[[ -n "$KPKG_DIR" ]] || die "kernel package not found in new slot's pacman db"
KPKG_FULL="$(basename "$KPKG_DIR")"
KPKG_NAME="${KPKG_FULL%-*-*}"
KPKG_VERREL="${KPKG_FULL#"$KPKG_NAME"-}"
JUPITER_REPO="$(awk -F'[][]' '/^\[jupiter-/{print $2; exit}' "$NEWROOT/etc/pacman.conf")"
MIRROR="$(awk '/^Server/{print $3; exit}' "$NEWROOT/etc/pacman.d/mirrorlist")"
HDR_URL="${MIRROR/\$repo/$JUPITER_REPO}"
HDR_URL="${HDR_URL/\$arch/x86_64}/${KPKG_NAME}-headers-${KPKG_VERREL}-x86_64.pkg.tar.zst"
log "Headers: $(basename "$HDR_URL")"
curl -sfIL "$HDR_URL" -o /dev/null || die "matching headers not in Valve's pool: $HDR_URL"

log "Building driver in overlay chroot (this takes 10-20 minutes)"
mount -t overlay overlay -o "index=off,lowerdir=$NEWROOT,upperdir=$UPPER,workdir=$OVLWORK" "$MERGED"
mount -t proc proc "$MERGED/proc"
mount --rbind /sys "$MERGED/sys"; mount --make-rslave "$MERGED/sys"
mount --rbind /dev "$MERGED/dev"; mount --make-rslave "$MERGED/dev"
rm -f "$MERGED/etc/resolv.conf"; cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"
ln -sf /proc/self/mounts "$MERGED/etc/mtab"
in_chroot() { chroot "$MERGED" /bin/bash -c "$*"; }

# Bind-mount host /tmp into the chroot — the overlay mount path doesn't match
# inside the chroot (host sees /path/to/merged, chroot sees /), so pacman
# can't resolve mount points for its cachedir space check.  Using host /tmp
# (tmpfs) gives pacman a real, detectable mount point.
mount --bind /tmp "$MERGED/tmp"
cp "$MERGED/etc/pacman.conf" "$MERGED/tmp/pacman-repatch.conf"
mkdir -p "$MERGED/tmp/pkgcache"
printf '\n[options]\nCacheDir = /tmp/pkgcache\n' >> "$MERGED/tmp/pacman-repatch.conf"
# pacman 7+ has download sandboxing that creates temp dirs pacman can't
# resolve mount points for; disable it on 7+, skip on older.
PACMAN_MAJOR="$(
  chroot "$MERGED" pacman --version 2>/dev/null |
    sed -n 's/.*Pacman v\([0-9][0-9]*\).*/\1/p' | head -1
)"
if [[ "$PACMAN_MAJOR" =~ ^[0-9]+$ ]] && (( PACMAN_MAJOR >= 7 )); then
  printf 'DisableSandbox\n' >> "$MERGED/tmp/pacman-repatch.conf"
fi
REPCONF="/tmp/pacman-repatch.conf"

rm -rf "$MERGED/etc/pacman.d/gnupg"
in_chroot "pacman-key --init && pacman-key --populate"
in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"
in_chroot "pacman --config $REPCONF -Sy"
in_chroot "pacman -Q" | LC_ALL=C sort > "$WORK/before.txt"
in_chroot "pacman --config $REPCONF -U --noconfirm --needed /tmp/headers.pkg.tar.zst"
in_chroot "pacman --config $REPCONF -S --noconfirm --needed dkms"
# Install libratbag if the HID source bundle is present
[[ -d /usr/lib/steamos-nvidia/hid ]] \
  && in_chroot "pacman --config $REPCONF -S --noconfirm --needed libratbag"

# Driver = the exact pinned Arch packages this image was built with (NOT the
# slot's frozen repo — that only has Valve's older driver).
source /usr/lib/steamos-nvidia/driver.conf
[[ -n "${PKG_URLS:-}" ]] || die "driver.conf has no PKG_URLS"
log "Installing pinned driver $DRIVER_VERSION"
in_chroot "mkdir -p /tmp/nvpkgs"
for u in $PKG_URLS; do
  in_chroot "curl -sfL '$u' -o /tmp/nvpkgs/\$(basename '$u')" || die "download failed: $u"
done
if ! in_chroot "pacman --config $REPCONF -U --noconfirm --needed /tmp/nvpkgs/*.pkg.tar.zst"; then
  # unattended context: a keyring mismatch (frozen image keyring vs current
  # Arch packager keys) must not brick updates — packages came over HTTPS
  # from Arch infrastructure, so retry unsigned rather than fail the update
  log "WARNING: pacman -U failed (keyring?) — retrying with signature checks off"
  sed 's/^SigLevel.*/SigLevel = Never/' "$MERGED/tmp/pacman-repatch.conf" > "$MERGED/tmp/pacman-nosig.conf"
  in_chroot "pacman --config /tmp/pacman-nosig.conf -U --noconfirm --needed /tmp/nvpkgs/*.pkg.tar.zst" \
    || die "driver package install failed"
fi
compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
  || in_chroot "dkms autoinstall -k $KVER"
compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
  || die "driver failed to build for $KVER"

# Build upstream Logitech HID modules if the source bundle is present.
if [[ -d /usr/lib/steamos-nvidia/hid ]]; then
  log "Building upstream Logitech receiver and HID++ modules"
  rm -rf "$MERGED/tmp/hid-kmod"
  mkdir -p "$MERGED/tmp/hid-kmod"
  cp -a /usr/lib/steamos-nvidia/hid/. "$MERGED/tmp/hid-kmod/"
  in_chroot "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod clean"
  in_chroot "make -C /usr/lib/modules/$KVER/build M=/tmp/hid-kmod modules"
  in_chroot "install -Dm644 /tmp/hid-kmod/hid-logitech-dj.ko /usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko"
  in_chroot "install -Dm644 /tmp/hid-kmod/hid-logitech-hidpp.ko /usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko"
  in_chroot "modinfo -F alias /tmp/hid-kmod/hid-logitech-dj.ko | grep -qi 'v0000046Dp0000C547'" \
    || die "upstream hid-logitech-dj module lacks the 046d:c547 alias"
  log "Built upstream Logitech modules for $KVER"
fi
in_chroot "pacman -Q" | LC_ALL=C sort > "$WORK/after.txt"

BUILD_ONLY_RE='^(dkms|nvidia-open-dkms|patch|gcc|gcc-libs|make|binutils|libisl|libmpc|mpfr|pahole|python-setuptools|linux-neptune.*-headers|.*-headers)$'
mapfile -t NEW_PKGS < <(LC_ALL=C comm -13 "$WORK/before.txt" "$WORK/after.txt" | awk '{print $1}' | grep -Ev "$BUILD_ONLY_RE")
if [[ ${#NEW_PKGS[@]} -eq 0 ]]; then
  log "No runtime package changes — module-only payload"
else
  log "Payload: ${NEW_PKGS[*]}"
fi

: > "$WORK/files.txt"
for pkg in "${NEW_PKGS[@]}"; do in_chroot "pacman -Qlq $pkg" >> "$WORK/files.txt"; done
sed 's|^/||' "$WORK/files.txt" > "$WORK/files.rel"

log "Copying driver into $PARTSET rootfs"
rsync -a --files-from="$WORK/files.rel" "$MERGED/" "$NEWROOT/"
rsync -a "$UPPER/usr/lib/modules/$KVER/updates" "$NEWROOT/usr/lib/modules/$KVER/"
for pkg in "${NEW_PKGS[@]}"; do
  # Remove old version entries first — otherwise upgrading nvidia-utils 580→590
  # leaves both /local/nvidia-utils-580.../ and /local/nvidia-utils-590.../
  rm -rf "$NEWROOT/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*
  for ENTRY in "$UPPER/usr/lib/holo/pacmandb/local/$pkg"-[0-9]*; do
    [[ -d "$ENTRY" ]] && rsync -a "$ENTRY" "$NEWROOT/usr/lib/holo/pacmandb/local/" && break
  done
done
chroot "$NEWROOT" depmod "$KVER"
chroot "$NEWROOT" ldconfig

# Verify HID modules and libratbag landed in the target rootfs.
if [[ -d /usr/lib/steamos-nvidia/hid ]]; then
  compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-dj.ko*" >/dev/null \
    || die "hid-logitech-dj.ko was not copied into $PARTSET"
  compgen -G "$NEWROOT/usr/lib/modules/$KVER/updates/logitech/hid-logitech-hidpp.ko*" >/dev/null \
    || die "hid-logitech-hidpp.ko was not copied into $PARTSET"
  compgen -G "$NEWROOT/usr/lib/holo/pacmandb/local/libratbag-[0-9]*" >/dev/null \
    || die "libratbag was not registered in $PARTSET"
fi

cat > "$NEWROOT/etc/modprobe.d/99-nvidia-patch.conf" <<'EOF'
# Added by steamos-nvidia repatch
blacklist nouveau
options nouveau modeset=0
options nvidia-drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

log "Restoring module autoloading in mkinitcpio.conf"
# Discover which modules the new slot's kernel would load for this machine's
# hardware — depmod already ran above so the slot's alias db is current.
auto_modules=""
for dev in /sys/bus/pci/devices/*/modalias; do
  auto_modules+="$(chroot "$NEWROOT" modprobe -R "$(cat "$dev")" 2>/dev/null)"$'\n'
done
auto_modules=$(echo "$auto_modules" | sort -u | grep -Ev '^nouveau$' | tr '\n' ' ')
if [[ -n "$auto_modules" ]]; then
  # Read any existing modules Valve already put in the image, merge, deduplicate.
  existing_modules=$(sed -n 's/^MODULES=(\(.*\))/\1/p' "$NEWROOT/etc/mkinitcpio.conf")
  merged_modules=$(echo "$existing_modules $auto_modules" | tr ' ' '\n' | sort -u | grep -v '^$' | tr '\n' ' ')
  sed -i "s|^MODULES=(.*)|MODULES=($merged_modules)|" "$NEWROOT/etc/mkinitcpio.conf"
  log "MODULES=($merged_modules)"
fi

log "Regenerating initramfs"
mount -t proc proc "$NEWROOT/proc"
mount --rbind /sys "$NEWROOT/sys"; mount --make-rslave "$NEWROOT/sys"
mount --rbind /dev "$NEWROOT/dev"; mount --make-rslave "$NEWROOT/dev"
chroot "$NEWROOT" mkinitcpio -P || log "WARNING: mkinitcpio failed (non-fatal — will regenerate on first boot)"
umount -R "$NEWROOT/proc" "$NEWROOT/sys" "$NEWROOT/dev" 2>/dev/null || true

chroot "$NEWROOT" systemctl enable nvidia-suspend nvidia-resume nvidia-hibernate 2>/dev/null || true

CMDLINE_ADD='rd.driver.blacklist=nouveau modprobe.blacklist=nouveau nvidia-drm.modeset=1 nvidia-drm.fbdev=1'
grep -q 'rd.driver.blacklist=nouveau' "$NEWROOT/etc/default/grub" \
  || sed -i -E "s#^(GRUB_CMDLINE_LINUX_DEFAULT=\")#\1$CMDLINE_ADD #" "$NEWROOT/etc/default/grub"

# propagate the self-healing machinery (repatch.sh + driver.conf) so the
# NEXT update is covered too
mkdir -p "$NEWROOT/usr/lib/steamos-nvidia"
cp -a /usr/lib/steamos-nvidia/. "$NEWROOT/usr/lib/steamos-nvidia/"

# Verify the HID source bundle propagated for the NEXT self-heal.
if [[ -d /usr/lib/steamos-nvidia/hid ]]; then
  for f in hid-logitech-dj.c hid-logitech-hidpp.c hid-ids.h usbhid/usbhid.h Makefile; do
    [[ -f "$NEWROOT/usr/lib/steamos-nvidia/hid/$f" ]] \
      || die "HID self-heal source missing from $PARTSET: $f"
  done
fi
# Restore thunderbolt files from bundle into the new slot.
if [[ -d /usr/lib/steamos-nvidia/thunderbolt ]]; then
  log "Restoring thunderbolt support into $PARTSET"
  mkdir -p "$NEWROOT/etc/udev/rules.d" "$NEWROOT/usr/local/bin" \
           "$NEWROOT/etc/systemd/system/multi-user.target.wants"
  cp /usr/lib/steamos-nvidia/thunderbolt/98-thunderbolt-rescan.rules \
    "$NEWROOT/etc/udev/rules.d/"
  cp /usr/lib/steamos-nvidia/thunderbolt/thunderbolt-rescan.sh \
    "$NEWROOT/usr/local/bin/"
  chmod +x "$NEWROOT/usr/local/bin/thunderbolt-rescan.sh"
  ln -sf /usr/lib/systemd/system/bolt.service \
    "$NEWROOT/etc/systemd/system/multi-user.target.wants/bolt.service"
fi
if [[ ! -f "$NEWROOT/usr/bin/steamos-update.orig" ]]; then
  mv "$NEWROOT/usr/bin/steamos-update" "$NEWROOT/usr/bin/steamos-update.orig"
  cp -a /usr/bin/steamos-update "$NEWROOT/usr/bin/steamos-update"
fi
[[ -f "$NEWROOT/usr/lib/systemd/system/steamos-finish-oobe-migration.service" ]] \
  && ln -sf /dev/null "$NEWROOT/etc/systemd/system/steamos-finish-oobe-migration.service"
[[ -f /etc/sudoers.d/zz-deck-nopasswd ]] \
  && install -m 440 /etc/sudoers.d/zz-deck-nopasswd "$NEWROOT/etc/sudoers.d/zz-deck-nopasswd"

# regenerate the new slot's grub.cfg with the nvidia cmdline
log "Regenerating grub config for $PARTSET"
mkdir -p "$NEWROOT/efi"
mount "$EFIDEV" "$NEWROOT/efi"
mount -t proc proc "$NEWROOT/proc"
mount --rbind /sys "$NEWROOT/sys"; mount --make-rslave "$NEWROOT/sys"
mount --rbind /dev "$NEWROOT/dev"; mount --make-rslave "$NEWROOT/dev"
chroot "$NEWROOT" update-grub
grep -q 'rd.driver.blacklist=nouveau' "$NEWROOT/efi/EFI/steamos/grub.cfg" \
  || die "regenerated grub.cfg is missing the nvidia cmdline"

log "Syncing"
btrfs filesystem sync "$NEWROOT"
sync -f "$NEWROOT"
log "OK — $PARTSET is NVIDIA-ready ($KVER)"
REPATCH
    chmod 755 "$MNT/usr/lib/steamos-nvidia/repatch.sh"

    # ---- wrapper around steamos-update: real update, then repatch the new slot
    if [[ ! -f "$MNT/usr/bin/steamos-update.orig" ]]; then
      mv "$MNT/usr/bin/steamos-update" "$MNT/usr/bin/steamos-update.orig"
    fi
    cat > "$MNT/usr/bin/steamos-update" <<'WRAP'
#!/bin/bash
# steamos-update wrapper (steamos-nvidia self-healing updates).
# Runs Valve's real updater, then rebuilds the NVIDIA driver inside the
# freshly staged OS slot. If that fails, the update is cancelled: the
# bootloader keeps booting the current (working) image.
REAL=/usr/bin/steamos-update.orig
REPATCH=/usr/lib/steamos-nvidia/repatch.sh
LOG=/var/log/steamos-nvidia-repatch.log

is_apply=1
for a in "$@"; do
  case "$a" in check|--supports-duplicate-detection) is_apply=0 ;; esac
done

"$REAL" "$@"
rc=$?

# Edit the boot config of every slot EXCEPT the currently booted one.
# The conf files on the ESP are plain text; editing them directly is the
# only revert that reliably steers steamcl (set-mode booted does NOT undo a
# staged switch, and a zeroed boot-requested-at still gets retried while
# boot-attempts is nonzero — both verified the hard way).
edit_other_confs() {  # args: sed expressions
  local this conf
  this="$(steamos-bootconf this-image 2>/dev/null)" || return 0
  [[ -n "$this" ]] || return 0
  for conf in /esp/SteamOS/conf/*.conf; do
    [[ -f "$conf" ]] || continue
    [[ "$(basename "$conf" .conf)" == "$this" ]] && continue
    sed -i "$@" "$conf"
  done
  sync -f /esp/SteamOS/conf 2>/dev/null || sync
}

if [[ $rc -eq 0 && $is_apply -eq 1 ]]; then
  echo "Update staged. Building NVIDIA driver for the new OS (10-20 min, do NOT power off)..." >&2
  if "$REPATCH" other >> "$LOG" 2>&1; then
    echo "NVIDIA driver installed into the updated OS. Safe to reboot." >&2
    # make sure the freshly patched slot is bootable (clears an
    # image-invalid left by a previously cancelled update)
    edit_other_confs -e 's/^image-invalid:.*/image-invalid: 0/'
  else
    echo "!! NVIDIA driver rebuild FAILED — cancelling this update." >&2
    echo "!! The system will keep booting the current working version." >&2
    echo "!! Details: $LOG" >&2
    edit_other_confs \
      -e 's/^boot-requested-at:.*/boot-requested-at: 0/' \
      -e 's/^boot-attempts:.*/boot-attempts: 0/' \
      -e 's/^image-invalid:.*/image-invalid: 1/'
    steamos-bootconf set-mode booted 2>/dev/null
    exit 1
  fi
fi
exit $rc
WRAP
    chmod 755 "$MNT/usr/bin/steamos-update"
  fi
}
