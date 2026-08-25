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
    dkms | nvidia-open-dkms | nvidia-utils | lib32-nvidia-utils)
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
  ((${HW_INSTALL_OPTIONAL:-0})) || return 1

  # Legacy --hw-support means install every optional package in the manifests.
  [[ -z "${HW_SUPPORT_ITEMS:-}" ]] && return 0

  [[ " $HW_SUPPORT_ITEMS " == *" $pkg "* ]] && return 0

  if [[ "$pkg" == linux-firmware-* &&
    " $HW_SUPPORT_ITEMS " == *" linux-firmware "* ]]; then
    return 0
  fi

  return 1
}

# Parse one manifest line into the global HW_LINE_* variables.
# Expected format: group|package|version|default|description
# Lines starting with # are comments; blank lines are skipped.
# Dies on malformed lines with a diagnostic listing all bad entries.
_parse_hw_manifest_line() {
  local line="${1-}"
  local rest

  HW_LINE_GROUP=""
  HW_LINE_PKG=""
  HW_LINE_VERSION=""
  HW_LINE_DEFAULT=""
  HW_LINE_DESC=""

  [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1

  if [[ "$line" != *"|"*"|"*"|"*"|"* ]]; then
    return 2
  fi

  HW_LINE_GROUP="${line%%|*}"
  rest="${line#*|}"
  HW_LINE_PKG="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_VERSION="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_DEFAULT="${rest%%|*}"
  HW_LINE_DESC="${rest#*|}"

  # Package names, versions, and defaults cannot contain whitespace.
  HW_LINE_GROUP="${HW_LINE_GROUP//[[:space:]]/}"
  HW_LINE_PKG="${HW_LINE_PKG//[[:space:]]/}"
  HW_LINE_VERSION="${HW_LINE_VERSION//[[:space:]]/}"
  HW_LINE_DEFAULT="${HW_LINE_DEFAULT//[[:space:]]/}"

  [[ -n "$HW_LINE_GROUP" && -n "$HW_LINE_PKG" && -n "$HW_LINE_VERSION" && -n "$HW_LINE_DEFAULT" && -n "$HW_LINE_DESC" ]] \
    || return 2

  return 0
}

# Validate a hardware manifest file.  Dies if any line does not match the
# expected format: group|package|version|description
# Args: $1 = conf file path
_validate_hw_manifest() {
  local conf="${1:?_validate_hw_manifest: missing conf path}"
  local line bad_lines=() line_num=0

  while IFS= read -r line; do
    ((++line_num))
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    _parse_hw_manifest_line "$line" >/dev/null 2>&1 || bad_lines+=("  line $line_num: $line")
  done <"$conf"

  if ((${#bad_lines[@]} > 0)); then
    die "Malformed lines in $(basename "$conf"):

$(printf '%s\n' "${bad_lines[@]}")

Expected format: group|package|version|default|description
Example: Firmware|linux-firmware|latest|TRUE|Full firmware suite"
  fi
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

# ---------------------------------------------------------------------------
# Context Helpers
# ---------------------------------------------------------------------------

# Check if we're installing into a chroot (build/rebuild) vs live system.
_is_install_chroot() {
  [[ -n "${MERGED:-}" && -d "${MERGED:-}" ]]
}

# Run a command in the appropriate context.
# Chroot: runs via chroot $MERGED
# Live: runs directly
_run_in_root() {
  if _is_install_chroot; then
    chroot "$MERGED" /bin/bash -c "$*"
  else
    /bin/bash -c "$*"
  fi
}

# Copy the persistent official-Arch pacman config into the build chroot and
# prepare its isolated DBPath.  The sync databases stay separate from Valve's,
# while DBPath/local points at the image's real installed-package database so
# dependency and --needed checks see the actual SteamOS package state.
_setup_arch_hw_pacman_conf() {
  local conf_path
  local sig_level="Required DatabaseOptional"
  local tmp_conf

  [[ "${SKIP_SIG:-0}" -eq 1 ]] && sig_level="Never"

  if _is_install_chroot; then
    conf_path="$MERGED/tmp/pacman-hw-arch.conf"
  else
    conf_path="/tmp/pacman-hw-arch.conf"
  fi
  tmp_conf="${conf_path}.tmp"

  # Generate the normal SteamOS-aware config: correct DBPath, Architecture,
  # CacheDir, DisableSandbox — but with the requested SigLevel.
  setup_pacman_conf "$conf_path" "$sig_level"

  # Keep [options], discard Valve repo definitions.
  awk '
    /^\[/ && $0 != "[options]" { exit }
    { print }
  ' "$conf_path" >"$tmp_conf"

  cat >>"$tmp_conf" <<'EOF'

[core]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[extra]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch

[multilib]
Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch
EOF

  mv "$tmp_conf" "$conf_path"

  ARCH_HW_PACCONF="/tmp/pacman-hw-arch.conf"
  log "Arch pacman config: $ARCH_HW_PACCONF"
}

# Install selected packages from a normal (Valve) manifest.  Valve packages do
# not need the upstream-Arch compatibility preflight, so they can be installed
# directly after one database refresh.
_install_valve_hw_manifest() {
  local conf="${1:?_install_valve_hw_manifest: missing config}"
  local pacconf="${2:?_install_valve_hw_manifest: missing pacman config}"
  local line rc pkg version desc target

  [[ -f "$conf" ]] || return 0
  _validate_hw_manifest "$conf"

  log "Refreshing Valve package database"
  if ! _run_in_root "pacman --config '$pacconf' -Sy"; then
    warn "  Failed to refresh Valve package database (non-fatal)"
    HW_FAILED_SOURCES+=("Valve")
    return 0
  fi

  while IFS= read -r line; do
    rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *)
        warn "  Skipping malformed line in $(basename "$conf"): $line"
        continue
        ;;
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

    if _run_in_root "pacman --config '$pacconf' -S --needed ${PACOPTS:-} '$target'" 2>/dev/null; then
      log "    ✓ $pkg installed"
    else
      warn "    Failed to install $target from Valve (non-fatal)"
      HW_FAILED_PKGS+=("$target")
    fi
  done <"$conf"
}

# Check which packages from a list are already installed in the pristine
# SteamOS image.  Returns the subset that would be upgraded by an Arch
# install — callers can use this to refuse cross-distro upgrades.
#
# Usage:
#   already_installed=( $(check_image_packages pkg1 pkg2 pkg3) )
#
# Prints one "name=version" pair per line for each package found in the
# image's pacman database.
check_image_packages() {
  local dbpath="${MNT:-}/usr/lib/holo/pacmandb"
  local pkg

  [[ -d "$dbpath" ]] || return 0

  for pkg in "$@"; do
    # Skip empty entries
    [[ -z "$pkg" ]] && continue
    # Strip version pin if present (e.g. "libdrm=2.4.129-1.1" -> "libdrm")
    pkg="${pkg%%=*}"
    # Skip entries that don't look like package names (no spaces, no special chars)
    [[ "$pkg" =~ [[:space:]/=] ]] && continue
    local ver
    ver="$(pacman -Q --dbpath "$dbpath" "$pkg" 2>/dev/null | awk 'NR==1 {print $2}')"
    [[ -n "$ver" ]] && printf '%s=%s\n' "$pkg" "$ver"
  done
}

# Packages that are expected to be upgraded from Arch (drivers, firmware).
# These are intentionally replaced with Arch versions for generic hardware support.
CROSS_DISTRO_ALLOWED=(
  nvidia-open-dkms
  nvidia-utils
  lib32-nvidia-utils
  libva-nvidia-driver
  linux-firmware
  linux-firmware-liquidio
  linux-firmware-marvell
  linux-firmware-mellanox
  linux-firmware-nfp
  linux-firmware-qcom
  linux-firmware-qlogic
)

# Check if a package is in the allowed cross-distro upgrade list.
_cdistro_allowed() {
  local pkg="${1%%=*}"
  local allowed
  for allowed in "${CROSS_DISTRO_ALLOWED[@]}"; do
    [[ "$pkg" == "$allowed" ]] && return 0
  done
  return 1
}

# Refuse to install packages that would upgrade existing Valve packages.
# Excludes packages in CROSS_DISTRO_ALLOWED (drivers, firmware).
#
# Usage:
#   check_cross_distro_upgrade pkg1 pkg2 ...
#
# Returns 0 if no conflicts, 1 if any package is already installed in the
# image (meaning an Arch install would upgrade a Valve package).
check_cross_distro_upgrade() {
  local -a conflicts=()
  local -a filtered_pkgs=()
  local entry pkg

  # Filter out allowed packages before checking
  for pkg in "$@"; do
    if ! _cdistro_allowed "$pkg"; then
      filtered_pkgs+=("$pkg")
    fi
  done

  # Nothing to check if all packages are allowed
  ((${#filtered_pkgs[@]} > 0)) || return 0

  mapfile -t conflicts < <(check_image_packages "${filtered_pkgs[@]}")

  if ((${#conflicts[@]} > 0)); then
    for entry in "${conflicts[@]}"; do
      warn "Refusing cross-distro upgrade: $entry is already installed from Valve"
    done
    return 1
  fi
  return 0
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
    pacman -Q --dbpath "$MNT/usr/lib/holo/pacmandb" glibc 2>/dev/null \
      | awk 'NR == 1 { print $2 }' \
      | grep -oE '[0-9]+\.[0-9]+' \
      | head -1
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
  if ((${#pkg_files[@]} == 0)); then
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
    } \
      | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' \
      | sed 's/^GLIBC_//' \
      | sort -uV \
      | tail -1 \
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
  _validate_hw_manifest "$conf"

  while IFS= read -r line; do
    rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *)
        warn "  Skipping malformed line in $(basename "$conf"): $line"
        continue
        ;;
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
  done <"$conf"

  ((${#targets[@]} > 0)) || return 0

  # Guard: refuse to install Arch packages that would upgrade existing Valve packages.
  # Skip on live — no pristine image DB to compare against.
  if _is_install_chroot; then
    if ! check_cross_distro_upgrade "${pkgs[@]}"; then
      if ((HW_NVIDIA_REQUESTED)); then
        die "Arch package transaction would upgrade existing Valve packages (required for NVIDIA driver)"
      fi
      warn "  Arch package transaction would upgrade existing Valve packages — skipping"
      HW_FAILED_PKGS+=("${targets[@]}")
      return 0
    fi
  fi

  log "Refreshing Arch package databases"
  if ! _run_in_root "pacman --config '$pacconf' -Sy"; then
    if ((HW_NVIDIA_REQUESTED)); then
      die "Failed to refresh Arch package databases (required for NVIDIA driver)"
    fi
    warn "  Failed to refresh Arch package databases (non-fatal)"
    HW_FAILED_SOURCES+=("Arch")
    return 0
  fi

  txn_id="$$-$RANDOM"
  local arch_pkgdir_chroot arch_pkgdir_host
  local needs_umount=0

  if _is_install_chroot; then
    arch_pkgdir_chroot="/tmp/arch-hw-pkgs.$txn_id"
    arch_pkgdir_host="${WORKDIR:?}/arch-hw-pkgs.$txn_id"
    rm -rf "$arch_pkgdir_host"
    mkdir -p "$arch_pkgdir_host"
    mkdir -p "$MERGED$arch_pkgdir_chroot"
    mount --bind "$arch_pkgdir_host" "$MERGED$arch_pkgdir_chroot" \
      || die "Failed to bind-mount Arch package cache into chroot"
    needs_umount=1
  else
    arch_pkgdir_chroot="/tmp/arch-hw-pkgs.$txn_id"
    arch_pkgdir_host="$arch_pkgdir_chroot"
    rm -rf "$arch_pkgdir_host"
    mkdir -p "$arch_pkgdir_host"
  fi

  quoted_targets="$(_hw_quote_targets "${targets[@]}")"
  pacopts="${PACOPTS:-}"

  # linux-firmware conflicts with Valve's linux-firmware-neptune package.
  # --noconfirm chooses the default "no" for that replacement, so remove it
  # for this transaction and feed explicit yes answers instead.
  if ((has_linux_firmware)); then
    pacopts="${pacopts//--noconfirm/}"
    install_prefix="yes | "
  fi

  log "Downloading complete Arch hardware package transaction"
  if ! _run_in_root "${install_prefix}pacman --config '$pacconf' -Sw --needed $pacopts --cachedir '$arch_pkgdir_chroot' $quoted_targets"; then
    ((needs_umount)) && umount "$MERGED$arch_pkgdir_chroot" 2>/dev/null
    if ((HW_NVIDIA_REQUESTED)); then
      rm -rf "$arch_pkgdir_host"
      die "Failed to download Arch hardware packages (required for NVIDIA driver)"
    fi
    warn "  Failed to resolve/download Arch hardware package transaction (non-fatal)"
    HW_FAILED_PKGS+=("${targets[@]}")
    rm -rf "$arch_pkgdir_host"
    return 0
  fi

  # glibc compatibility check — only meaningful in chroot (live system is native).
  if _is_install_chroot; then
    check_arch_glibc_compat "$arch_pkgdir_host"
  fi

  log "Installing Arch hardware package transaction"
  if ! _run_in_root "${install_prefix}pacman --config '$pacconf' -S --needed $pacopts --cachedir '$arch_pkgdir_chroot' $quoted_targets"; then
    ((needs_umount)) && umount "$MERGED$arch_pkgdir_chroot" 2>/dev/null
    if ((HW_NVIDIA_REQUESTED)); then
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
  _run_in_root "pacman -Q nvidia-utils nvidia-open-dkms lib32-nvidia-utils linux-firmware 2>&1 || true"
  log "Pacman database:"
  _run_in_root "pacman -v 2>/dev/null | grep -E 'Root|DB Path|Cache Dirs' || true"
  if _is_install_chroot; then
    log "NVIDIA local DB entries:"
    _run_in_root "ls -ld /usr/lib/holo/pacmandb/local/{nvidia-utils,nvidia-open-dkms,lib32-nvidia-utils}-* 2>/dev/null || true"
    # Check for damaged records (missing desc files).
    _run_in_root '
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
  fi

  # Both transactions now share the same local DB, so bare pacman -Q works.
  for pkg in "${pkgs[@]}"; do
    local installed_ver
    installed_ver="$(_run_in_root "pacman -Q '$pkg' 2>/dev/null" | awk '{print $2}' || true)"
    if [[ -n "$installed_ver" ]]; then
      log "    ✓ $pkg $installed_ver installed"
    else
      warn "    $pkg was selected but is not registered as installed"
      HW_FAILED_PKGS+=("$pkg")
    fi
  done

  ((needs_umount)) && umount "$MERGED$arch_pkgdir_chroot" 2>/dev/null
  rm -rf "$arch_pkgdir_host"
}

install_hw_libs() {
  # Prefer source configs during build (SCRIPT_DIR points to project root),
  # fall back to installed configs for repatch.
  local valve_conf arch_conf legacy_conf
  if [[ -f "$SCRIPT_DIR/lib/configs/hw-packages-valve.conf" ]]; then
    valve_conf="$SCRIPT_DIR/lib/configs/hw-packages-valve.conf"
    arch_conf="$SCRIPT_DIR/lib/configs/hw-packages-arch.conf"
    legacy_conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"
  else
    valve_conf="/usr/lib/steamos-nvidia/configs/hw-packages-valve.conf"
    arch_conf="/usr/lib/steamos-nvidia/configs/hw-packages-arch.conf"
    legacy_conf="/usr/lib/steamos-nvidia/configs/hw-packages.conf"
  fi
  local valve_pacconf="${PACCONF:?install_hw_libs: PACCONF is not set}"

  # Optional hardware packages retain the old selection semantics, but the
  # NVIDIA driver packages + dkms are required and are always reconciled.
  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
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
      if [[ "${FIX_KEYRING:-0}" -eq 1 ]]; then
        log "Updating archlinux-keyring from Arch repos (fix-keyring stage 2)"
        _run_in_root "pacman -Q archlinux-keyring 2>/dev/null || true" || true
        _run_in_root "pacman --config '$ARCH_HW_PACCONF' -Sy --noconfirm archlinux-keyring" \
          || warn "archlinux-keyring update failed — continuing with bundled keys"
        _run_in_root "pacman-key --populate archlinux" \
          || die "Could not re-populate Arch keyring after keyring update"
        _run_in_root "pacman-key --updatedb" || true
        log "Post-update keyring diagnostics:"
        _run_in_root "pacman -Q archlinux-keyring 2>/dev/null || true" || true
        _run_in_root "pacman-key --list-keys 'David Runge' 2>/dev/null || echo 'David Runge: NOT FOUND'" || true
        _run_in_root "pacman-key --list-keys 'Robin Candau' 2>/dev/null || echo 'Robin Candau: NOT FOUND'" || true
      else
        _run_in_root "pacman-key --populate archlinux" \
          || die "Could not populate Arch keyring before driver package install"
      fi
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
  if ((HW_NVIDIA_REQUESTED)); then
    if _is_install_chroot; then
      if ! nvidia_module_exists "$MERGED" "$KVER"; then
        log "DKMS hook did not build NVIDIA for $KVER — forcing"
        _run_in_root "dkms autoinstall -k '$KVER'"
      fi
      nvidia_module_exists "$MERGED" "$KVER" \
        || die "NVIDIA module failed to build for $KVER"
    else
      # Live system — check if nvidia.ko exists for running kernel
      if ! nvidia_module_exists "/" "$(uname -r)"; then
        log "NVIDIA module not found for $(uname -r) — attempting DKMS build"
        _run_in_root "dkms autoinstall -k '$(uname -r)'" \
          || warn "DKMS autoinstall failed (non-fatal on live)"
      fi
    fi

    nvidia_ver="$(_run_in_root "pacman -Q nvidia-utils 2>/dev/null" | awk '{print $2}' || true)"
    [[ -n "$nvidia_ver" ]] \
      || die "nvidia-utils is not installed after NVIDIA package installation"
  else
    die "nvidia-open-dkms is missing or not selected in the Arch hardware manifest"
  fi

  log "Driver and hardware support installation complete"
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
# Check whether expected hardware packages are installed.
# Works in both chroot and live contexts.
#
# Args:
#   $1 = (optional) space-separated package list to check
#        If empty, checks packages from HW_SUPPORT_ITEMS or all required packages.
#
# Returns 0 if all packages are installed, 1 if any are missing.
# Prints status for each package to stdout.

verify_hw_libs() {
  local packages="${1:-}"
  local missing=0

  # If no packages specified, determine what should be installed
  if [[ -z "$packages" ]]; then
    # Required packages are always expected
    packages="dkms nvidia-open-dkms nvidia-utils lib32-nvidia-utils"

    # Add optional packages if HW_SUPPORT_ITEMS is set
    if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
      packages+=" $HW_SUPPORT_ITEMS"
    fi
  fi

  for pkg in $packages; do
    # Strip version pin if present
    pkg="${pkg%%=*}"
    [[ -z "$pkg" ]] && continue

    if _run_in_root "pacman -Q '$pkg'" &>/dev/null; then
      local ver
      ver="$(_run_in_root "pacman -Q '$pkg'" 2>/dev/null | awk '{print $2}')"
      log "  ✓ $pkg $ver"
    else
      warn "  ✗ $pkg not installed"
      missing=1
    fi
  done

  # Check NVIDIA DKMS module if nvidia-open-dkms is installed
  if _run_in_root "pacman -Q nvidia-open-dkms" &>/dev/null; then
    local kver
    if _is_install_chroot; then
      kver="${KVER:-}"
    else
      kver="$(uname -r)"
    fi

    if [[ -n "$kver" ]]; then
      if nvidia_module_exists "${MERGED:-/}" "$kver"; then
        log "  ✓ nvidia.ko ($kver)"
      else
        warn "  ✗ nvidia.ko missing ($kver)"
        missing=1
      fi
    fi
  fi

  return $missing
}
