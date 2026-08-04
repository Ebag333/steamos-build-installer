#!/bin/bash
#
# steamos-nvidia-installer — lib/install-hw-libs.sh
# Install hardware-support libraries into the image:
#   - libratbag (pacman — Valve's version is from 2024 but functional)
#   - libfprint + fprintd (pacman — ships 1.94.x with modern sensor support)
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/install-hw-libs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

install_hw_libs() {
  [[ $BUILD_HW_SUPPORT -eq 1 ]] || return 0

  log "Installing hardware support libraries"

  in_chroot "pacman --config $PACCONF -S $PACOPTS \
    libratbag libfprint fprintd" \
    || die "Failed to install hardware support libraries"

  # Verify something landed (check the overlay's pacman db, not the image's).
  if ! in_chroot "pacman -Q libratbag" >/dev/null 2>&1; then
    die "libratbag not found in chroot"
  fi
  if ! in_chroot "pacman -Q libfprint" >/dev/null 2>&1; then
    die "libfprint not found in chroot"
  fi

  log "Hardware support: libratbag + libfprint + fprintd installed"
}
