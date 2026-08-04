#!/bin/bash
#
# steamos-nvidia-installer — lib/build-driver.sh
# Stage 3: set up the overlay build chroot, build nvidia-open (DKMS) against
# the image's exact kernel, and compute the driver payload (new packages minus
# build-only toolchain).
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/build-driver.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Build the driver in a throwaway overlay on top of the image rootfs, so the
# toolchain/headers never enter the image. The upper layer ($UPPER) is cached
# between runs to speed up reruns.
setup_overlay_chroot() {
  # A cached overlay from a previous run of a DIFFERENT driver version has to
  # go: pacman would happily downgrade in place, but the old version's stray
  # files and modules would ride along into the image. (The package cache in
  # $WORKDIR/pkgs is kept — only the build residue is thrown away.)
  if compgen -G "$UPPER/usr/lib/holo/pacmandb/local/nvidia-utils-[0-9]*" >/dev/null; then
    CACHED_VER="$(basename "$(echo "$UPPER"/usr/lib/holo/pacmandb/local/nvidia-utils-[0-9]*)")"
    CACHED_VER="${CACHED_VER#nvidia-utils-}"
    if [[ "$CACHED_VER" != "$DRIVER_VERSION" ]]; then
      log "Cached build is nvidia $CACHED_VER but $DRIVER_VERSION is pinned — clearing the build overlay"
      rm -rf "${UPPER:?}" "${OVLWORK:?}"
      mkdir -p "$UPPER" "$OVLWORK"
    fi
  fi

  log "Setting up overlay build chroot (build residue stays out of the image)"
  # index=off: allows reusing the upperdir even if a lazily-unmounted overlay
  # from an interrupted previous run still references it (enables resume).
  mount -t overlay overlay \
    -o "index=off,lowerdir=$MNT,upperdir=$UPPER,workdir=$OVLWORK" "$MERGED"
  mount -t proc proc "$MERGED/proc"
  mount --rbind /sys "$MERGED/sys";  mount --make-rslave "$MERGED/sys"
  mount --rbind /dev "$MERGED/dev";  mount --make-rslave "$MERGED/dev"
  rm -f "$MERGED/etc/resolv.conf"          # whiteout in upper only
  cp -L /etc/resolv.conf "$MERGED/etc/resolv.conf"

  PACOPTS="--noconfirm --needed"
  PACCONF="/etc/pacman.conf"
  if [[ $SKIP_SIG -eq 1 ]]; then
    sed 's/^SigLevel.*/SigLevel = Never/' "$MERGED/etc/pacman.conf" \
      > "$MERGED/tmp/pacman-nosig.conf"
    PACCONF="/tmp/pacman-nosig.conf"
    warn "pacman signature verification DISABLED for the build"
  fi

  if [[ $SKIP_SIG -eq 0 && ! -d "$MERGED/etc/pacman.d/gnupg/private-keys-v1.d" ]]; then
    log "Initialising pacman keyring in chroot"
    in_chroot "pacman-key --init && pacman-key --populate" \
      || die "Keyring init failed — rerun with --skip-sigcheck if you accept unsigned installs"
  fi
}

# Install headers + pinned driver in the chroot (compiles the module), or reuse
# a matching prior build from the cached overlay.
build_driver() {
  # Resume: if a previous run already built everything in the overlay for THIS
  # driver version, skip the download/compile and go straight to payload
  # extraction. (Version check matters: Arch may have bumped since the cached
  # build — then the overlay must be brought up to the newly pinned version.)
  if compgen -G "$UPPER/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
     && [[ "$(in_chroot "pacman -Q nvidia-utils 2>/dev/null" | awk '{print $2}')" == "$DRIVER_VERSION" ]]; then
    log "Overlay already contains a built nvidia $DRIVER_VERSION module — reusing previous build"
  else
    log "Downloading exact-match kernel headers"
    in_chroot "curl -sfL '$HDR_URL' -o /tmp/headers.pkg.tar.zst"

    log "Refreshing pacman databases"
    in_chroot "pacman --config $PACCONF -Sy"

    log "Installing headers + dkms (from Valve's mirror)"
    in_chroot "pacman --config $PACCONF -U $PACOPTS /tmp/headers.pkg.tar.zst"
    in_chroot "pacman --config $PACCONF -S $PACOPTS dkms"

    log "Installing pinned Arch driver packages (compiles the module, takes a few minutes)"
    rm -rf "$MERGED/tmp/nvpkgs"; mkdir -p "$MERGED/tmp/nvpkgs"
    for f in "${PKG_FILES[@]}"; do cp "$WORKDIR/pkgs/$f" "$MERGED/tmp/nvpkgs/"; done
    in_chroot "pacman --config $PACCONF -U $PACOPTS /tmp/nvpkgs/*.pkg.tar.zst" \
      || die "pacman -U failed. If it was a signature/keyring error (frozen image keyring vs current Arch packagers), rerun with --skip-sigcheck — the packages came over HTTPS from Arch infrastructure."

    if ! compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null; then
      log "DKMS hook didn't build for $KVER — forcing"
      in_chroot "dkms autoinstall -k $KVER"
      compgen -G "$MERGED/usr/lib/modules/$KVER/updates/dkms/nvidia.ko*" >/dev/null \
        || die "nvidia module failed to build for $KVER (check output above)"
    fi
  fi
  NVIDIA_VER="$(in_chroot "pacman -Q nvidia-utils" | awk '{print $2}')"
  [[ "$NVIDIA_VER" == "$DRIVER_VERSION" ]] \
    || die "Chroot has nvidia-utils $NVIDIA_VER but $DRIVER_VERSION was pinned — stale overlay? Delete $WORKDIR and rerun."
  log "Built nvidia-open $NVIDIA_VER for $KVER"
}

# Diff the chroot's new packages against the pristine image db to get the list
# of files that actually ship, then size-check it against available rootfs space.
compute_payload() {
  # "Before" = the pristine image's own pacman db (read directly, host-side) —
  # NOT the chroot's, whose db carries installs cached in the overlay upper
  # layer from previous runs and would make the diff come out empty.
  pacman -Qq --dbpath "$MNT/usr/lib/holo/pacmandb" | LC_ALL=C sort > "$WORKDIR/pkgs-before.txt"
  in_chroot "pacman -Qq" | LC_ALL=C sort > "$WORKDIR/pkgs-after.txt"

  # New packages minus build-only toolchain = what ships in the image.
  # nvidia-open-dkms is build-only too: it's the module SOURCE (~70 MB); the
  # compiled module is copied from /usr/lib/modules separately.
  BUILD_ONLY_RE='^(dkms|nvidia-open-dkms|patch|gcc|gcc-libs|make|binutils|libisl|libmpc|mpfr|pahole|python-setuptools|linux-neptune.*-headers|.*-headers)$'
  mapfile -t NEW_PKGS < <(LC_ALL=C comm -13 "$WORKDIR/pkgs-before.txt" "$WORKDIR/pkgs-after.txt" \
                          | grep -Ev "$BUILD_ONLY_RE")
  [[ ${#NEW_PKGS[@]} -gt 0 ]] || die "Payload package list came out empty — check $WORKDIR/pkgs-*.txt"
  log "Payload packages: ${NEW_PKGS[*]}"

  FILELIST="$WORKDIR/payload-files.txt"
  : > "$FILELIST"
  for pkg in "${NEW_PKGS[@]}"; do
    in_chroot "pacman -Qlq $pkg" >> "$FILELIST"
  done

  if [[ $TRIM_CUDA -eq 1 ]]; then
    log "Trimming CUDA/OpenCL/NVVM/OptiX libraries"
    grep -Ev 'libcuda|libcudadebugger|libnvidia-nvvm|libnvidia-opencl|libnvoptix|nvidia-cuda-mps|OpenCL' \
      "$FILELIST" > "$FILELIST.trim" && mv "$FILELIST.trim" "$FILELIST"
  fi
  sed 's|^/||' "$FILELIST" > "$FILELIST.rel"

  # Space check: pacman -Qlq lists directories too — size only files/symlinks.
  PAYLOAD_MB="$(set +o pipefail; cd "$MERGED" && while IFS= read -r p; do
      if [[ -f "$p" || -L "$p" ]]; then printf '%s\0' "$p"; fi
    done < "$FILELIST.rel" | { du -scm --no-dereference --files0-from=- 2>/dev/null || true; } | tail -1 | cut -f1)"
  [[ "$PAYLOAD_MB" =~ ^[0-9]+$ ]] || die "Could not size the payload"
  MODULES_MB="$(du -sm "$UPPER/usr/lib/modules/$KVER/updates" | cut -f1)"
  AVAIL_MB="$(df -m --output=avail "$MNT" | tail -1 | tr -d ' ')"
  log "Payload ≈ ${PAYLOAD_MB} MB files + ${MODULES_MB} MB modules (before btrfs zstd); rootfs has ${AVAIL_MB} MB free"
  if (( PAYLOAD_MB + MODULES_MB > AVAIL_MB * 2 )); then   # zstd roughly halves it
    die "Not enough space in rootfs. Rerun with --trim-cuda."
  fi
}