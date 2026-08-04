#!/bin/bash
#
# steamos-nvidia-installer — lib/install-hw-libs.sh
# Install hardware-support libraries into the image:
#   - libratbag (from source — Valve's packaged version is from 2024)
#   - libfprint + fprintd (from Arch repos — ships 1.94.100 with modern
#     Elan/Egis sensor support)
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/install-hw-libs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

install_hw_libs() {
  [[ $BUILD_HW_SUPPORT -eq 1 ]] || return 0

  # ---- libfprint + fprintd (pacman) ----
  log "Installing libfprint + fprintd for fingerprint reader support"
  in_chroot "pacman --config $PACCONF -S $PACOPTS libfprint fprintd" \
    || die "Failed to install libfprint/fprintd"

  # ---- libratbag (from source) ----
  log "Building libratbag from source (latest git)"

  in_chroot "pacman --config $PACCONF -S $PACOPTS \
    meson ninja gcc pkg-config \
    libevdev systemd glib2 json-glib \
    python-evdev check swig" \
    || die "Failed to install libratbag build deps"

  in_chroot "git clone --depth 1 https://github.com/libratbag/libratbag.git /tmp/libratbag"

  in_chroot "meson setup /tmp/libratbag/builddir /tmp/libratbag \
    --prefix=/usr/local \
    -Dsystemd-unit-dir=/usr/lib/systemd/system \
    -Druntime-dir=/run"

  log "Compiling libratbag (ninja — a few minutes)"
  in_chroot "ninja -C /tmp/libratbag/builddir"

  chroot "$MERGED" /bin/bash -c \
    "DESTDIR=$MNT ninja -C /tmp/libratbag/builddir install" \
    || die "libratbag install failed"

  rm -rf "$MERGED/tmp/libratbag"

  if [[ ! -f "$MNT/usr/local/bin/ratbagctl" ]] && \
     [[ ! -f "$MNT/usr/local/bin/ratbagd" ]]; then
    die "libratbag build produced no binaries"
  fi
  log "libratbag installed: $(ls "$MNT"/usr/local/bin/ratbag* 2>/dev/null | tr '\n' ' ')"
}
