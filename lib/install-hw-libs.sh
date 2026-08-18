#!/bin/bash
#
# steamos-nvidia-installer — lib/install-hw-libs.sh
# Install driver/hardware-support packages into the overlay build chroot.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/install-hw-libs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# Packages required for the NVIDIA build itself.  These are installed even
# when the optional generic-hardware support toggle is disabled.
_hw_pkg_required() {
  case "${1:?_hw_pkg_required: missing package}" in
    dkms|nvidia-open-dkms|nvidia-utils|lib32-nvidia-utils)
      return 0
      ;;
  esac
  return 1
}

# Return success when a package from a hardware manifest should be installed.
# linux-firmware-* packages are treated as part of the linux-firmware selection
# so the optional firmware split packages follow the main firmware toggle.
_hw_pkg_selected() {
  local pkg="${1:?_hw_pkg_selected: missing package}"

  _hw_pkg_required "$pkg" && return 0

  # No optional hardware support was requested.
  (( ${HW_INSTALL_OPTIONAL:-0} )) || return 1

  # Legacy --hw-support means install every optional package in the manifests.
  [[ -z "${HW_SUPPORT_ITEMS:-}" ]] && return 0

  [[ " $HW_SUPPORT_ITEMS " == *" $pkg "* ]] && return 0

  if [[ "$pkg" == linux-firmware-* \
     && " $HW_SUPPORT_ITEMS " == *" linux-firmware "* ]]; then
    return 0
  fi

  return 1
}

# Parse one manifest line into the global HW_LINE_* variables.
# Preferred format: package|version|description
# Legacy package:description lines are accepted as version=latest so an older
# hw-packages.conf can still be used during the transition.
_parse_hw_manifest_line() {
  local line="${1-}"
  local rest

  HW_LINE_PKG=""
  HW_LINE_VERSION=""
  HW_LINE_DESC=""

  [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1

  if [[ "$line" == *"|"*"|"* ]]; then
    HW_LINE_PKG="${line%%|*}"
    rest="${line#*|}"
    HW_LINE_VERSION="${rest%%|*}"
    HW_LINE_DESC="${rest#*|}"
  elif [[ "$line" == *:* ]]; then
    HW_LINE_PKG="${line%%:*}"
    HW_LINE_VERSION="latest"
    HW_LINE_DESC="${line#*:}"
  else
    return 2
  fi

  # Package names and versions cannot contain whitespace.  Descriptions can.
  HW_LINE_PKG="${HW_LINE_PKG//[[:space:]]/}"
  HW_LINE_VERSION="${HW_LINE_VERSION//[[:space:]]/}"

  [[ -n "$HW_LINE_PKG" && -n "$HW_LINE_VERSION" && -n "$HW_LINE_DESC" ]] \
    || return 2

  return 0
}

# Convert manifest package + version policy into a pacman sync target.
_hw_pkg_target() {
  local pkg="${1:?_hw_pkg_target: missing package}"
  local version="${2:?_hw_pkg_target: missing version}"

  if [[ "$version" == "latest" ]]; then
    printf '%s' "$pkg"
  else
    printf '%s=%s' "$pkg" "$version"
  fi
}

# Quote a list of pacman targets for the shell executed by in_chroot().
_hw_quote_targets() {
  local item
  for item in "$@"; do
    printf '%q ' "$item"
  done
}

# Copy the persistent official-Arch pacman config into the build chroot and
# prepare its isolated DBPath.  The sync databases stay separate from Valve's,
# while DBPath/local points at the image's real installed-package database so
# dependency and --needed checks see the actual SteamOS package state.
_setup_arch_hw_pacman_conf() {
  local conf_path="$MERGED/tmp/pacman-hw-arch.conf"
  local sig_level="Required DatabaseOptional"
  local tmp_conf="${conf_path}.tmp"

  [[ "${SKIP_SIG:-0}" -eq 1 ]] && sig_level="Never"

  # Generate the normal SteamOS-aware config: correct DBPath, Architecture,
  # CacheDir, DisableSandbox — but with the requested SigLevel.
  setup_pacman_conf "$conf_path" "$sig_level"

  # Keep [options], discard Valve repo definitions.
  awk '
    /^\[/ && $0 != "[options]" { exit }
    { print }
  ' "$conf_path" > "$tmp_conf"

  cat >> "$tmp_conf" <<'EOF'

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[multilib]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

  mv "$tmp_conf" "$conf_path"

  ARCH_HW_PACCONF="/tmp/pacman-hw-arch.conf"
  log "Arch pacman config: $ARCH_HW_PACCONF (DBPath from image)"
}

# Install selected packages from a normal (Valve) manifest.  Valve packages do
# not need the upstream-Arch compatibility preflight, so they can be installed
# directly after one database refresh.
_install_valve_hw_manifest() {
  local conf="${1:?_install_valve_hw_manifest: missing config}"
  local pacconf="${2:?_install_valve_hw_manifest: missing pacman config}"
  local line rc pkg version desc target

  [[ -f "$conf" ]] || return 0

  log "Refreshing Valve package database"
  if ! in_chroot "pacman --config '$pacconf' -Sy"; then
    warn "  Failed to refresh Valve package database (non-fatal)"
    HW_FAILED_SOURCES+=("Valve")
    return 0
  fi

  # shellcheck disable=SC2094
  while IFS= read -r line; do
    rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) warn "  Skipping malformed line in $(basename "$conf"): $line"; continue ;;
    esac

    pkg="$HW_LINE_PKG"
    version="$HW_LINE_VERSION"
    desc="$HW_LINE_DESC"

    if ! _hw_pkg_selected "$pkg"; then
      log "  Skipping $pkg (not selected)"
      continue
    fi

    target="$(_hw_pkg_target "$pkg" "$version")"
    log "  Installing $target from Valve ($desc)"

    if in_chroot "pacman --config '$pacconf' -S --needed ${PACOPTS:-} '$target'" 2>/dev/null; then
      log "    ✓ $pkg installed"
    else
      warn "    Failed to install $target from Valve (non-fatal)"
      HW_FAILED_PKGS+=("$target")
    fi
  done < "$conf"
}

# Verify that packages resolved from upstream Arch do not require a newer
# glibc than the pristine SteamOS image provides.
#
# Usage:
#   check_arch_glibc_compat /host/path/to/downloaded/packages
#
# The directory must contain the complete package transaction downloaded by
# pacman -Sw: explicitly requested packages plus any new/updated dependencies.
check_arch_glibc_compat() {
  local pkgdir="${1:-}"
  local img_glibc scan max_glibc pkg subdir
  local -a pkg_files=()

  [[ -n "$pkgdir" ]] \
    || die "check_arch_glibc_compat: package directory not specified"
  [[ -d "$pkgdir" ]] \
    || die "Arch package directory not found: $pkgdir"

  # Read glibc from the pristine image package database, not from the overlay.
  img_glibc="$(
    pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" glibc 2>/dev/null |
      awk 'NR == 1 { print $2 }' |
      grep -oE '[0-9]+\.[0-9]+' |
      head -1
  )"

  [[ "$img_glibc" =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "Could not determine image glibc version"

  while IFS= read -r -d '' pkg; do
    pkg_files+=("$pkg")
  done < <(
    find "$pkgdir" \
      -maxdepth 1 \
      -type f \
      -name '*.pkg.tar.*' \
      ! -name '*.sig' \
      -print0
  )

  # --needed legitimately produces an empty download transaction when the
  # cached overlay already contains the current versions.
  if (( ${#pkg_files[@]} == 0 )); then
    log "Arch package transaction has no new packages to compatibility-check"
    return 0
  fi

  log "Checking ${#pkg_files[@]} Arch packages against image glibc $img_glibc"

  scan="$WORKDIR/glibc-scan"
  rm -rf "$scan"
  mkdir -p "$scan"

  # Extract each package independently so files from one package cannot
  # overwrite files from another during the compatibility scan.
  for pkg in "${pkg_files[@]}"; do
    subdir="$scan/$(basename "$pkg")"
    mkdir -p "$subdir"

    tar -xf "$pkg" -C "$subdir" \
      || die "Could not extract $(basename "$pkg") for glibc compatibility scan"
  done

  # readelf fails on scripts and other non-ELF executables; those failures are
  # expected. Find the highest GLIBC_* symbol version required by any ELF in
  # the complete transaction.
  max_glibc="$(
    {
      find "$scan" -type f \( -name '*.so*' -o -perm -111 \) \
        -exec readelf -V {} + 2>/dev/null || true
    } |
      grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' |
      sed 's/^GLIBC_//' |
      sort -uV |
      tail -1 \
      || true
  )"

  # Firmware/data-only transactions legitimately contain no ELF objects.
  if [[ -z "$max_glibc" ]]; then
    log "Arch package transaction contains no GLIBC symbol requirements"
    rm -rf "$scan"
    return 0
  fi

  if [[ "$(printf '%s\n' "$max_glibc" "$img_glibc" | sort -V | tail -1)" != "$img_glibc" ]]; then
    die "Arch package transaction needs glibc $max_glibc but the image only has $img_glibc"
  fi

  log "OK: Arch packages need at most glibc $max_glibc (image has $img_glibc)"
  rm -rf "$scan"
}

# Resolve all selected Arch packages as one transaction, download that complete
# transaction first, compatibility-check it, then install exactly the same
# targets.  This keeps current Arch libraries from silently outrunning the
# frozen SteamOS userspace.
_install_arch_hw_manifest() {
  local conf="${1:?_install_arch_hw_manifest: missing config}"
  local pacconf="${2:?_install_arch_hw_manifest: missing pacman config}"
  local line rc pkg version desc target quoted_targets
  local txn_id arch_pkgdir_host arch_pkgdir_chroot pacopts install_prefix=""
  local has_linux_firmware=0
  local -a targets=()
  local -a pkgs=()

  [[ -f "$conf" ]] || return 0

  # shellcheck disable=SC2094
  while IFS= read -r line; do
    rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *) warn "  Skipping malformed line in $(basename "$conf"): $line"; continue ;;
    esac

    pkg="$HW_LINE_PKG"
    version="$HW_LINE_VERSION"
    desc="$HW_LINE_DESC"

    if ! _hw_pkg_selected "$pkg"; then
      log "  Skipping $pkg (not selected)"
      continue
    fi

    target="$(_hw_pkg_target "$pkg" "$version")"
    targets+=("$target")
    pkgs+=("$pkg")

    [[ "$pkg" == "linux-firmware" ]] && has_linux_firmware=1
    [[ "$pkg" == "nvidia-open-dkms" ]] && HW_NVIDIA_REQUESTED=1

    log "  Selected $target from Arch ($desc)"
  done < "$conf"

  (( ${#targets[@]} > 0 )) || return 0

  log "Refreshing Arch package databases"
  if ! in_chroot "pacman --config '$pacconf' -Sy"; then
    if (( HW_NVIDIA_REQUESTED )); then
      die "Failed to refresh Arch package databases (required for NVIDIA driver)"
    fi
    warn "  Failed to refresh Arch package databases (non-fatal)"
    HW_FAILED_SOURCES+=("Arch")
    return 0
  fi

  txn_id="$$-$RANDOM"
  arch_pkgdir_chroot="/tmp/arch-hw-pkgs.$txn_id"
  arch_pkgdir_host="$MERGED$arch_pkgdir_chroot"
  rm -rf "$arch_pkgdir_host"
  mkdir -p "$arch_pkgdir_host"

  quoted_targets="$(_hw_quote_targets "${targets[@]}")"
  pacopts="${PACOPTS:-}"

  # linux-firmware conflicts with Valve's linux-firmware-neptune package.
  # --noconfirm chooses the default "no" for that replacement, so remove it
  # for this transaction and feed explicit yes answers instead.
  if (( has_linux_firmware )); then
    pacopts="${pacopts//--noconfirm/}"
    install_prefix="yes | "
  fi

  log "Downloading complete Arch hardware package transaction"
  if ! in_chroot "${install_prefix}pacman --config '$pacconf' -Sw --needed $pacopts --cachedir '$arch_pkgdir_chroot' $quoted_targets"; then
    if (( HW_NVIDIA_REQUESTED )); then
      rm -rf "$arch_pkgdir_host"
      die "Failed to download Arch hardware packages (required for NVIDIA driver)"
    fi
    warn "  Failed to resolve/download Arch hardware package transaction (non-fatal)"
    HW_FAILED_PKGS+=("${targets[@]}")
    rm -rf "$arch_pkgdir_host"
    return 0
  fi

  check_arch_glibc_compat "$arch_pkgdir_host"

  log "Installing Arch hardware package transaction"
  if ! in_chroot "${install_prefix}pacman --config '$pacconf' -S --needed $pacopts --cachedir '$arch_pkgdir_chroot' $quoted_targets"; then
    if (( HW_NVIDIA_REQUESTED )); then
      rm -rf "$arch_pkgdir_host"
      die "Failed to install Arch hardware packages (required for NVIDIA driver)"
    fi
    warn "  Failed to install Arch hardware package transaction (non-fatal)"
    HW_FAILED_PKGS+=("${targets[@]}")
    rm -rf "$arch_pkgdir_host"
    return 0
  fi

  # Post-transaction diagnostics.
  log "Post-Arch package database verification:"
  in_chroot "pacman -Q nvidia-utils nvidia-open-dkms lib32-nvidia-utils linux-firmware 2>&1 || true"
  log "Pacman database:"
  in_chroot "pacman -v 2>/dev/null | grep -E 'Root|DB Path|Cache Dirs' || true"
  log "NVIDIA local DB entries:"
  in_chroot "ls -ld /usr/lib/holo/pacmandb/local/{nvidia-utils,nvidia-open-dkms,lib32-nvidia-utils}-* 2>/dev/null || true"
  # Check for damaged records (missing desc files).
  in_chroot '
    bad=0
    for d in /usr/lib/holo/pacmandb/local/*; do
      [[ -d "$d" ]] || continue
      if [[ ! -f "$d/desc" ]]; then
        echo "MISSING desc: $d"
        bad=1
      fi
    done
    exit "$bad"
  ' || warn "Some local DB entries have missing desc files"

  # Both transactions now share the same local DB, so bare pacman -Q works.
  for pkg in "${pkgs[@]}"; do
    local installed_ver
    installed_ver="$(in_chroot "pacman -Q '$pkg' 2>/dev/null" | awk '{print $2}' || true)"
    if [[ -n "$installed_ver" ]]; then
      log "    ✓ $pkg $installed_ver installed"
    else
      warn "    $pkg was selected but is not registered as installed"
      HW_FAILED_PKGS+=("$pkg")
    fi
  done

  rm -rf "$arch_pkgdir_host"
}

install_hw_libs() {
  local valve_conf="$SCRIPT_DIR/lib/configs/hw-packages-valve.conf"
  local arch_conf="$SCRIPT_DIR/lib/configs/hw-packages-arch.conf"
  local legacy_conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"
  local valve_pacconf="${PACCONF:?install_hw_libs: PACCONF is not set}"
  local localnvidia_ver

  # Optional hardware packages retain the old selection semantics, but the
  # NVIDIA driver packages + dkms are required and are always reconciled.
  if [[ -n "${HW_SUPPORT_ITEMS:-}" || "${BUILD_HW_SUPPORT:-0}" -eq 1 ]]; then
    HW_INSTALL_OPTIONAL=1
  else
    HW_INSTALL_OPTIONAL=0
  fi

  # Compatibility with builds that have not renamed the old Valve manifest yet.
  if [[ ! -f "$valve_conf" && -f "$legacy_conf" ]]; then
    valve_conf="$legacy_conf"
  fi

  if [[ ! -f "$valve_conf" && ! -f "$arch_conf" ]]; then
    die "Driver/hardware package configs not found: $valve_conf / $arch_conf"
  fi

  log "Installing driver and hardware support packages"

  HW_FAILED_PKGS=()
  HW_FAILED_SOURCES=()
  HW_NVIDIA_REQUESTED=0

  if [[ -f "$valve_conf" ]]; then
    _install_valve_hw_manifest "$valve_conf" "$valve_pacconf"
  fi

  if [[ -f "$arch_conf" ]]; then
    _setup_arch_hw_pacman_conf

    # The build chroot already has an initialized keyring. Refresh/populate the
    # Arch trust set before consuming current upstream packages; this is safe to
    # repeat and does not remove Valve/Holo keys.
    if [[ "${SKIP_SIG:-0}" -eq 0 ]]; then
      in_chroot "pacman-key --populate archlinux" \
        || die "Could not populate Arch keyring before driver package install"
    fi

    _install_arch_hw_manifest "$arch_conf" "$ARCH_HW_PACCONF"
  fi

  if [[ ${#HW_FAILED_SOURCES[@]} -gt 0 ]]; then
    warn "Some package sources failed to refresh: ${HW_FAILED_SOURCES[*]}"
  fi
  if [[ ${#HW_FAILED_PKGS[@]} -gt 0 ]]; then
    warn "Some packages failed to install: ${HW_FAILED_PKGS[*]}"
    warn "Continuing where possible — optional hardware packages are non-fatal"
  fi

  # nvidia-open-dkms normally builds from its pacman DKMS hook.  Keep one
  # explicit recovery attempt and then enforce the invariant before returning.
  if (( HW_NVIDIA_REQUESTED )); then
    if ! nvidia_module_exists "$MERGED" "$KVER"; then
      log "DKMS hook did not build NVIDIA for $KVER — forcing"
      in_chroot "dkms autoinstall -k '$KVER'"
    fi

    nvidia_module_exists "$MERGED" "$KVER" \
      || die "NVIDIA module failed to build for $KVER"

    nvidia_ver="$(in_chroot "pacman -Q nvidia-utils 2>/dev/null" | awk '{print $2}' || true)"
    [[ -n "$nvidia_ver" ]] \
      || die "nvidia-utils is not installed after NVIDIA package installation"
  else
    die "nvidia-open-dkms is missing or not selected in the Arch hardware manifest"
  fi

  log "Driver and hardware support installation complete"
}
