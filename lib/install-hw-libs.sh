#!/bin/bash
#
# steamos-build-installer — lib/install-hw-libs.sh
# Install driver/hardware-support packages into the overlay build chroot.
# Sourced by the wrapper — do not run directly.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "lib/install-hw-libs.sh is a library — source it from the wrapper, not run directly." >&2
  exit 1
fi

# No packages are globally required regardless of hardware support toggle.
# All packages follow the HW_INSTALL_OPTIONAL / HW_SUPPORT_ITEMS selection.
_hw_pkg_required() {
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

  return 1
}

# Parse one manifest line into the global HW_LINE_* variables.
# Expected format: TYPE|group|package|version|default|description|recipe
# Lines starting with # are comments; blank lines are skipped.
# Dies on malformed lines with a diagnostic listing all bad entries.
_parse_hw_manifest_line() {
  local line="${1-}"
  local rest

  HW_LINE_TYPE=""
  HW_LINE_GROUP=""
  HW_LINE_PKG=""
  HW_LINE_VERSION=""
  HW_LINE_DEFAULT=""
  HW_LINE_DESC=""
  HW_LINE_RECIPE=""

  [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1

  if [[ "$line" != *"|"*"|"*"|"*"|"*"|"*"|"* ]]; then
    return 2
  fi

  HW_LINE_TYPE="${line%%|*}"
  rest="${line#*|}"
  HW_LINE_GROUP="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_PKG="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_VERSION="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_DEFAULT="${rest%%|*}"
  rest="${rest#*|}"
  HW_LINE_DESC="${rest%%|*}"
  HW_LINE_RECIPE="${rest#*|}"

  # Package names, versions, defaults, and type cannot contain whitespace.
  HW_LINE_TYPE="${HW_LINE_TYPE//[[:space:]]/}"
  HW_LINE_GROUP="${HW_LINE_GROUP//[[:space:]]/}"
  HW_LINE_PKG="${HW_LINE_PKG//[[:space:]]/}"
  HW_LINE_VERSION="${HW_LINE_VERSION//[[:space:]]/}"
  HW_LINE_DEFAULT="${HW_LINE_DEFAULT//[[:space:]]/}"

  [[ -n "$HW_LINE_TYPE" && -n "$HW_LINE_GROUP" && -n "$HW_LINE_PKG" && -n "$HW_LINE_VERSION" && -n "$HW_LINE_DEFAULT" && -n "$HW_LINE_DESC" ]] \
    || return 2

  return 0
}

# Validate a hardware manifest file.  Dies if any line does not match the
# expected format: TYPE|group|package|version|default|description|recipe
# Args: $1 = conf file path
_validate_hw_manifest() {
  local conf="${1:?_validate_hw_manifest: missing conf path}"
  local line bad_lines=() line_num=0

  while IFS="" read -r line; do
    ((++line_num))
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    _parse_hw_manifest_line "$line" >/dev/null 2>&1 || bad_lines+=("  line $line_num: $line")
  done <"$conf"

  if ((${#bad_lines[@]} > 0)); then
    die "Malformed lines in $(basename "$conf"):

$(printf '%s\n' "${bad_lines[@]}")

Expected format: TYPE|group|package|version|default|description|recipe
Example: pacman|Firmware|linux-firmware|latest|TRUE|Full firmware suite|"
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

# Read a hardware manifest and populate the caller's arrays with selected
# packages.  Callers must provide: _hw_read_manifest <conf> _arr_prefix
# After the call the following arrays are set in the caller's scope:
#   ${prefix}_pkgs, ${prefix}_targets, ${prefix}_descs
# Also sets global HW_LINE_TYPE and HW_LINE_RECIPE for each parsed line.
# Returns 1 if no packages were selected.
_hw_read_manifest() {
  local conf="${1:?_hw_read_manifest: missing conf path}"
  local prefix="${2:?_hw_read_manifest: missing array prefix}"
  local line rc pkg version desc target type recipe
  local -a _pkgs=() _targets=() _descs=()

  # First pass: count selected items
  local _selected_count=0
  while IFS="" read -r line; do
    rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    [[ "$rc" -eq 0 ]] || continue
    if _hw_pkg_selected "$HW_LINE_PKG"; then
      ((++_selected_count))
    fi
  done <"$conf"

  # Second pass: collect selected packages (deduplicated across categories)
  local -A _seen_pkg=()
  # shellcheck disable=SC2094  # $conf is only read, never written
  while IFS="" read -r line; do
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
    type="$HW_LINE_TYPE"
    recipe="$HW_LINE_RECIPE"

    if ! _hw_pkg_selected "$pkg"; then
      ((_selected_count > 0)) && debug "  Skipping $pkg (not selected)"
      continue
    fi

    [[ -n "${_seen_pkg[$pkg]:-}" ]] && continue
    _seen_pkg["$pkg"]=1

    target="$(_hw_pkg_target "$pkg" "$version")"
    _pkgs+=("$pkg")
    _targets+=("$target")
    _descs+=("$desc")
  done <"$conf"

  if ((${#_pkgs[@]} > 0)); then
    eval "${prefix}_pkgs=(\"\${_pkgs[@]}\")"
    eval "${prefix}_targets=(\"\${_targets[@]}\")"
    eval "${prefix}_descs=(\"\${_descs[@]}\")"
  else
    eval "${prefix}_pkgs=()"
    eval "${prefix}_targets=()"
    eval "${prefix}_descs=()"
  fi

  ((${#_pkgs[@]} > 0))
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

# Install selected packages from a normal (Valve) manifest.  Valve packages do
# not need the upstream-Arch compatibility preflight, so they can be installed
# directly after one database refresh.
_install_valve_hw_manifest() {
  local conf="${1:?_install_valve_hw_manifest: missing config}"
  local pacconf="${2:?_install_valve_hw_manifest: missing pacman config}"

  [[ -f "$conf" ]] || return 0
  _validate_hw_manifest "$conf"

  log "Refreshing Valve package database"
  if ! pacman_upgrade_all --config "$pacconf"; then
    warn "  Failed to refresh Valve package database (non-fatal)"
    HW_FAILED_SOURCES+=("Valve")
    return 0
  fi

  local -a _v_pkgs _v_targets _v_descs
  _hw_read_manifest "$conf" _v || return 0

  local i
  for i in "${!_v_pkgs[@]}"; do
    log "  Installing ${_v_targets[$i]} from Valve (${_v_descs[$i]})"

    if pacman_install --config "$pacconf" -- "${_v_targets[$i]}" 2>/dev/null; then
      log "    ✓ ${_v_pkgs[$i]} installed"
    else
      warn "    Failed to install ${_v_targets[$i]} from Valve (non-fatal)"
      HW_FAILED_PKGS+=("${_v_targets[$i]}")
    fi
  done
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

  while IFS="" read -r -d '' pkg; do
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
  local pkg quoted_targets
  local txn_id arch_pkgdir_host arch_pkgdir_chroot
  local has_linux_firmware=0
  local -a targets=()
  local -a pkgs=()

  [[ -f "$conf" ]] || return 0
  _validate_hw_manifest "$conf"

  local -a _a_pkgs _a_targets _a_descs
  if ! _hw_read_manifest "$conf" _a; then
    return 0
  fi
  pkgs=("${_a_pkgs[@]}")
  targets=("${_a_targets[@]}")

  local i
  for i in "${!_a_pkgs[@]}"; do
    [[ "${_a_pkgs[$i]}" == "linux-firmware" ]] && has_linux_firmware=1
    [[ "${_a_pkgs[$i]}" == "nvidia-open-dkms" ]] && HW_NVIDIA_REQUESTED=1
    log "  Selected ${_a_targets[$i]} from Arch (${_a_descs[$i]})"
  done

  ((${#targets[@]} > 0)) || return 0

  log "Refreshing Arch package databases"
  if ! pacman_sync_db --config "$pacconf"; then
    if ((HW_NVIDIA_REQUESTED)); then
      die "Failed to refresh Arch package databases (required for NVIDIA driver)"
    fi
    warn "  Failed to refresh Arch package databases (non-fatal)"
    HW_FAILED_SOURCES+=("Arch")
    return 0
  fi

  txn_id="$$-$RANDOM"
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

  # linux-firmware conflicts with Valve's linux-firmware-neptune package.
  # --noconfirm chooses the default "no" for that replacement, so use --yes
  # for this transaction to feed explicit yes answers instead.
  local yes_flag=""
  if ((has_linux_firmware)); then
    yes_flag="--yes"
  fi

  log "Downloading complete Arch hardware package transaction"
  # shellcheck disable=SC2086 # yes_flag and quoted_targets are intentionally word-split
  if ! pacman_download --config "$pacconf" --cachedir "$arch_pkgdir_chroot" $yes_flag -- $quoted_targets; then
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
  # shellcheck disable=SC2086 # yes_flag and quoted_targets are intentionally word-split
  if ! pacman_install --config "$pacconf" --cachedir "$arch_pkgdir_chroot" $yes_flag -- $quoted_targets; then
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
    # shellcheck disable=SC2016 # Variables expand inside the chroot, not here.
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

# ---------------------------------------------------------------------------
# Batch Helpers (unified manifest)
# ---------------------------------------------------------------------------

# Install selected Valve packages from pre-collected arrays.
# Args: $1 = pacconf, $2-$4 = nameref arrays (pkgs, targets, descs)
_install_valve_hw_manifest_batch() {
  local pacconf="${1:?_install_valve_hw_manifest_batch: missing pacman config}"
  local -n _vb_pkgs="$2"
  local -n _vb_targets="$3"
  local -n _vb_descs="$4"

  log "Refreshing Valve package database"
  if ! pacman_upgrade_all --config "$pacconf"; then
    warn "  Failed to refresh Valve package database (non-fatal)"
    HW_FAILED_SOURCES+=("Valve")
    return 0
  fi

  local i
  for i in "${!_vb_pkgs[@]}"; do
    log "  Installing ${_vb_targets[$i]} from Valve (${_vb_descs[$i]})"

    if pacman_install --config "$pacconf" -- "${_vb_targets[$i]}" 2>/dev/null; then
      log "    ✓ ${_vb_pkgs[$i]} installed"
    else
      warn "    Failed to install ${_vb_targets[$i]} from Valve (non-fatal)"
      HW_FAILED_PKGS+=("${_vb_targets[$i]}")
    fi
  done
}

# Install selected Arch packages from pre-collected arrays.
# Args: $1 = pacconf, $2-$4 = nameref arrays (pkgs, targets, descs)
_install_arch_hw_manifest_batch() {
  local pacconf="${1:?_install_arch_hw_manifest_batch: missing pacman config}"
  local -n _ab_pkgs="$2"
  local -n _ab_targets="$3"
  local -n _ab_descs="$4"
  local pkg quoted_targets txn_id arch_pkgdir_host arch_pkgdir_chroot
  local has_linux_firmware=0
  local -a targets=("${_ab_targets[@]}")
  local -a pkgs=("${_ab_pkgs[@]}")

  local i
  for i in "${!_ab_pkgs[@]}"; do
    [[ "${_ab_pkgs[$i]}" == "linux-firmware" ]] && has_linux_firmware=1
    [[ "${_ab_pkgs[$i]}" == "nvidia-open-dkms" ]] && HW_NVIDIA_REQUESTED=1
    log "  Selected ${_ab_targets[$i]} from Arch (${_ab_descs[$i]})"
  done

  ((${#targets[@]} > 0)) || return 0

  log "Refreshing Arch package databases"
  if ! pacman_sync_db --config "$pacconf"; then
    if ((HW_NVIDIA_REQUESTED)); then
      die "Failed to refresh Arch package databases (required for NVIDIA driver)"
    fi
    warn "  Failed to refresh Arch package databases (non-fatal)"
    HW_FAILED_SOURCES+=("Arch")
    return 0
  fi

  txn_id="$$-$RANDOM"
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

  # linux-firmware conflicts with Valve's linux-firmware-neptune package.
  # --noconfirm chooses the default "no" for that replacement, so use --yes
  # for this transaction to feed explicit yes answers instead.
  local yes_flag=""
  if ((has_linux_firmware)); then
    yes_flag="--yes"
  fi

  log "Downloading complete Arch hardware package transaction"
  # shellcheck disable=SC2086 # yes_flag and quoted_targets are intentionally word-split
  if ! pacman_download --config "$pacconf" --cachedir "$arch_pkgdir_chroot" $yes_flag -- $quoted_targets; then
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
  # shellcheck disable=SC2086 # yes_flag and quoted_targets are intentionally word-split
  if ! pacman_install --config "$pacconf" --cachedir "$arch_pkgdir_chroot" $yes_flag -- $quoted_targets; then
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
    # shellcheck disable=SC2016 # Variables expand inside the chroot, not here.
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

# Install pacman packages from pre-collected arrays (unified source).
# All packages come from the image's configured repos — no separate Arch config.
# Args: $1 = pacconf, $2-$4 = nameref arrays (pkgs, targets, descs)
_install_pacman_hw_batch() {
  local pacconf="${1:?_install_pacman_hw_batch: missing pacman config}"
  local -n _pb_pkgs="$2"
  local -n _pb_targets="$3"
  local -n _pb_descs="$4"
  local pkg quoted_targets
  local has_linux_firmware=0
  local -a targets=("${_pb_targets[@]}")
  local -a pkgs=("${_pb_pkgs[@]}")

  local i
  for i in "${!_pb_pkgs[@]}"; do
    [[ "${_pb_pkgs[$i]}" == "linux-firmware" ]] && has_linux_firmware=1
    debug "  Selected ${_pb_targets[$i]} (${_pb_descs[$i]})"
  done

  ((${#targets[@]} > 0)) || return 0

  # Pre-flight with automatic fallback from upgrade to additive mode.
  # Removes offending HW packages from the list if they cause dep-breakages.
  local -a orig_targets=("${targets[@]}")
  local -a orig_pkgs=("${pkgs[@]}")
  local interactive=0
  _is_interactive && interactive=1
  # shellcheck disable=SC2034 # effective_mode is used via nameref in pacman_preflight_with_fallback
  local effective_mode="additive"
  local -a preflight_extra_args=()
  local -a preflight_provider_targets=()

  if [[ "${PREFLIGHT:-1}" -eq 1 ]]; then
    if ! pacman_preflight_with_fallback targets effective_mode preflight_extra_args preflight_provider_targets "$interactive"; then
      warn "Pre-flight: user cancelled or unresolvable conflicts"
      return 1
    fi
  else
    warn "Pre-flight: skipped (PREFLIGHT=0) — installing all ${#targets[@]} package(s) without conflict checks"
  fi

  if ((${#targets[@]} == 0)); then
    warn "Pre-flight: all packages removed — skipping hardware installation"
    return 0
  fi

  # Rebuild pkgs to match the reduced targets
  local -a new_pkgs=()
  for target in "${targets[@]}"; do
    for i in "${!orig_targets[@]}"; do
      if [[ "${orig_targets[$i]}" == "$target" ]]; then
        new_pkgs+=("${orig_pkgs[$i]}")
        break
      fi
    done
  done
  pkgs=("${new_pkgs[@]}")

  # Re-check linux-firmware flag after potential removal
  has_linux_firmware=0
  for target in "${targets[@]}"; do
    [[ "$target" == "linux-firmware" ]] && has_linux_firmware=1
  done

  log "Installing hardware packages (${#targets[@]} remaining)"

  quoted_targets="$(_hw_quote_targets "${targets[@]}")"

  # linux-firmware conflicts with Valve's linux-firmware-neptune package.
  # --noconfirm chooses the default "no" for that replacement, so use --yes
  # for this transaction to feed explicit yes answers instead.
  local yes_flag=""
  if ((has_linux_firmware)); then
    yes_flag="--yes"
  fi

  local freeze_flag=""
  if [[ "${effective_mode:-additive}" == "additive" ]]; then
    freeze_flag="--freeze-installed"
  fi

  log "Installing pacman hardware packages"
  # Include provider targets and extra args from preflight
  # shellcheck disable=SC2086,SC2206 # quoted_targets is intentionally word-split (each target is individually shell-quoted)
  local -a all_targets=($quoted_targets "${preflight_provider_targets[@]}")
  # shellcheck disable=SC2086 # yes_flag and quoted_targets are intentionally word-split
  if ! pacman_install --config "$pacconf" $yes_flag $freeze_flag "${preflight_extra_args[@]}" -- "${all_targets[@]}"; then
    local _mode_hint=""
    if [[ "${BASE_OS_MODE:-additive}" == "additive" ]]; then
      _mode_hint=" (dependency conflicts may be caused by additive mode — consider BASE_OS_MODE=upgrade)"
    fi
    if ((HW_NVIDIA_REQUESTED)); then
      die "Failed to install pacman hardware packages (required for NVIDIA driver)${_mode_hint}"
    fi
    warn "  Failed to install pacman hardware packages (non-fatal)${_mode_hint}"
    HW_FAILED_PKGS+=("${targets[@]}")
    return 0
  fi

  # Post-transaction diagnostics.
  if [[ "${DEBUG:-0}" == 1 ]]; then
    debug "Post-pacman package database verification:"
    _run_in_root "pacman -Q nvidia-utils nvidia-open-dkms lib32-nvidia-utils linux-firmware 2>&1 || true" >&2
    debug "Pacman database:"
    _run_in_root "pacman -v 2>/dev/null | grep -E 'Root|DB Path|Cache Dirs' || true" >&2
    if _is_install_chroot; then
      debug "NVIDIA local DB entries:"
      _run_in_root "ls -ld /usr/lib/holo/pacmandb/local/{nvidia-utils,nvidia-open-dkms,lib32-nvidia-utils}-* 2>/dev/null || true" >&2
      # Check for damaged records (missing desc files).
      # shellcheck disable=SC2016 # Variables expand inside the chroot, not here.
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
  fi

  local _verify_ok=0
  local _verify_fail=0
  for pkg in "${pkgs[@]}"; do
    local installed_ver
    installed_ver="$(_run_in_root "pacman -Q '$pkg' 2>/dev/null" | awk '{print $2}' || true)"
    if [[ -n "$installed_ver" ]]; then
      debug "    ✓ $pkg $installed_ver installed"
      ((++_verify_ok))
    else
      warn "    $pkg was selected but is not registered as installed"
      HW_FAILED_PKGS+=("$pkg")
      ((++_verify_fail))
    fi
  done
  log "Pacman hardware verification: $_verify_ok ok, $_verify_fail failed"
}

# Build packages from pre-collected arrays.
# Args: $1-$3 = nameref arrays (names, recipes, versions)
# VERSION format for build-recipe items: "latest" or "pkgver-sha256"
#   e.g. "152.0.7977.9-fc6e10808f589a0475ce20a0038c902701e9e59cfb0ac810a45116f8c057f9e7"
# When pinned, the PKGBUILD's pkgver and first sha256sum are patched before building.
_install_build_recipes() {
  local -n _br_names="$1"
  local -n _br_recipes="$2"
  local -n _br_versions="$3"
  local _bfr="${_build_framework_ready:-0}"

  local i
  for i in "${!_br_names[@]}"; do
    local name="${_br_names[$i]}"
    local recipe="${_br_recipes[$i]}"
    local recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe"

    if [[ -z "$recipe" || ! -d "$recipe_dir" ]]; then
      warn "  No recipe directory for $name — skipping"
      HW_FAILED_PKGS+=("$name")
      continue
    fi

    local _install_cmd=""
    _install_cmd="$(sed -n 's/^INSTALL_CMD=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

    local built=0

    if [[ -n "$_install_cmd" ]]; then
      # Direct install mode — copy recipe sources into chroot and run
      log "  Building $name via recipe (direct install)"
      local _install_args=""
      _install_args="$(sed -n 's/^INSTALL_ARGS=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"

      mkdir -p "$MERGED/tmp/build/sources"
      if [[ -d "$recipe_dir/sources" ]]; then
        cp -a "$recipe_dir/sources/." "$MERGED/tmp/build/sources/"
      fi

      local _script_name
      _script_name="$(basename "$_install_cmd")"
      if [[ -f "$MERGED/tmp/build/sources/$_script_name" ]]; then
        chmod +x "$MERGED/tmp/build/sources/$_script_name"
        if _run_in_root "cd /tmp/build/sources && ./${_script_name} ${_install_args}"; then
          log "    ✓ $name built and installed via direct recipe"
          built=1

          # Post-install hook — runs outside the chroot (host-side)
          local _post_install=""
          _post_install="$(sed -n 's/^POST_INSTALL=//p' "$recipe_dir/recipe.conf" 2>/dev/null | tr -d '"' | head -1)"
          if [[ -n "$_post_install" ]]; then
            local _post_script_name
            _post_script_name="$(basename "$_post_install")"
            if [[ -f "$MERGED/tmp/build/sources/$_post_script_name" ]]; then
              log "  Running post-install: $_post_script_name"
              if MERGED="$MERGED" SCRIPT_DIR="$SCRIPT_DIR" EFIMNT="${EFIMNT:-}" /bin/bash "$MERGED/tmp/build/sources/$_post_script_name"; then
                log "    ✓ Post-install completed for $name"
              else
                warn "    Post-install failed for $name"
                HW_FAILED_PKGS+=("$name (post-install)")
              fi
            else
              warn "    Post-install script not found: $_post_script_name"
            fi
          fi
        else
          warn "    Direct recipe install failed for $name"
        fi
      else
        warn "    Install script not found: $_script_name in $recipe_dir/sources/"
      fi
    fi

    # Fallback: build_recipe framework (requires _build_framework_ready=1)
    if [[ "$built" -eq 0 ]] && ((_bfr)); then
      log "  Building $name via build_recipe framework"

      # Apply version pinning if specified (format: pkgver-sha256)
      local _build_recipe_dir="$recipe_dir"
      local _version="${_br_versions[$i]:-latest}"
      if [[ "$_version" != "latest" && -n "$_version" ]]; then
        local _pinned_ver="${_version%-*}"
        local _pinned_sha="${_version##*-}"
        if [[ -n "$_pinned_ver" && -n "$_pinned_sha" && "$_pinned_sha" =~ ^[a-f0-9]{64}$ ]]; then
          log "  Pinning $name to version $_pinned_ver"
          local _tmp_recipe
          _tmp_recipe="$(mktemp -d "${WORKDIR:-/tmp}/recipe-pin-XXXXXX")"
          cp -a "$recipe_dir/." "$_tmp_recipe/"
          sed -i "s/^pkgver=.*/pkgver=$_pinned_ver/" "$_tmp_recipe/PKGBUILD"
          sed -i "0,/[a-f0-9]\{64\}/s/[a-f0-9]\{64\}/$_pinned_sha/" "$_tmp_recipe/PKGBUILD"
          _build_recipe_dir="$_tmp_recipe"
        else
          warn "  Invalid version pin format for $name: $_version (expected pkgver-sha256)"
        fi
      fi

      if build_recipe --recipe "$_build_recipe_dir" --profile "$PROFILE_DIR" --output "$WORKDIR/packages"; then
        if [[ -n "${BUILD_ARTIFACT:-}" && -f "$BUILD_ARTIFACT" ]]; then
          install_build_artifact "$MERGED" "$BUILD_ARTIFACT"
          log "    ✓ $name built and installed via framework"
          built=1
        else
          warn "    Build produced no artifact for $name"
        fi
      else
        warn "    Build framework failed for $name"
      fi

      # Clean up temporary recipe dir
      [[ "$_build_recipe_dir" != "$recipe_dir" ]] && rm -rf "$_build_recipe_dir"
    fi

    if [[ "$built" -eq 0 ]]; then
      HW_FAILED_PKGS+=("$name")
    fi
  done
}

# Install flatpak items from pre-collected arrays.
# Args: $1-$2 = nameref arrays (names, recipes)
_install_flatpak_items() {
  local -n _fp_names="$1"
  local -n _fp_recipes="$2"

  local i
  for i in "${!_fp_names[@]}"; do
    local name="${_fp_names[$i]}"
    local recipe="${_fp_recipes[$i]}"
    local recipe_dir="$SCRIPT_DIR/lib/configs/build_recipes/$recipe"

    if [[ -z "$recipe" || ! -d "$recipe_dir" ]]; then
      warn "  No recipe directory for flatpak $name — skipping"
      HW_FAILED_PKGS+=("$name")
      continue
    fi

    local install_script="$recipe_dir/sources/install-${recipe}.sh"
    if [[ -x "$install_script" ]]; then
      log "  Installing flatpak $name via recipe $recipe"
      if bash "$install_script" "$MERGED"; then
        log "    ✓ $name installed"
      else
        warn "    Flatpak install failed for $name"
        HW_FAILED_PKGS+=("$name")
      fi
    else
      warn "  No install script for flatpak $name at $install_script"
      HW_FAILED_PKGS+=("$name")
    fi
  done
}

install_hw_libs() {
  local conf
  if [[ -f "$SCRIPT_DIR/lib/configs/hw-packages.conf" ]]; then
    conf="$SCRIPT_DIR/lib/configs/hw-packages.conf"
  else
    conf="/home/.steamos-build/build_cache/lib/configs/hw-packages.conf"
  fi

  local valve_pacconf="${PACCONF:?install_hw_libs: PACCONF is not set}"

  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
    HW_INSTALL_OPTIONAL=1
  else
    HW_INSTALL_OPTIONAL=0
  fi

  if [[ ! -f "$conf" ]]; then
    die "Hardware package config not found: $conf"
  fi

  _validate_hw_manifest "$conf"

  log "Installing driver and hardware support packages"

  HW_FAILED_PKGS=()
  HW_FAILED_SOURCES=()
  HW_NVIDIA_REQUESTED=0

  # Collect packages by source for batch installation
  local -a _pacman_pkgs=() _pacman_targets=() _pacman_descs=() _pacman_recipes=()
  local -a _br_names=() _br_recipes=() _br_versions=()
  local -a _fp_names=() _fp_recipes=()

  # First pass: count selected items to determine verbosity
  local _selected_count=0
  local _skipped_count=0
  local line
  while IFS="" read -r line; do
    local rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    [[ "$rc" -eq 0 ]] || continue
    if _hw_pkg_selected "$HW_LINE_PKG"; then
      ((++_selected_count))
    fi
  done <"$conf"

  if ((_selected_count == 0)); then
    log "No hardware packages or modules to install"
  fi

  # Second pass: collect packages (deduplicated across categories)
  local -A _seen_pacman_pkg=()
  local -A _seen_br_pkg=()
  local -A _seen_fp_pkg=()
  while IFS="" read -r line; do
    local rc=0
    _parse_hw_manifest_line "$line" || rc=$?
    case "$rc" in
      0) ;;
      1) continue ;;
      *)
        warn "  Skipping malformed line in hw-packages.conf: $line"
        continue
        ;;
    esac

    local pkg="$HW_LINE_PKG"
    local version="$HW_LINE_VERSION"
    local desc="$HW_LINE_DESC"
    local type="$HW_LINE_TYPE"
    local recipe="$HW_LINE_RECIPE"

    if ! _hw_pkg_selected "$pkg"; then
      ((_selected_count > 0)) && debug "  Skipping $pkg (not selected)"
      ((++_skipped_count)) || true
      continue
    fi

    local target
    target="$(_hw_pkg_target "$pkg" "$version")"

    case "$type" in
      pacman)
        [[ -n "${_seen_pacman_pkg[$pkg]:-}" ]] && continue
        _seen_pacman_pkg["$pkg"]=1
        _pacman_pkgs+=("$pkg")
        _pacman_targets+=("$target")
        _pacman_descs+=("$desc")
        _pacman_recipes+=("$recipe")
        [[ "$pkg" == "nvidia-open-dkms" ]] && HW_NVIDIA_REQUESTED=1
        ;;
      build-recipe)
        [[ -n "${_seen_br_pkg[$pkg]:-}" ]] && continue
        _seen_br_pkg["$pkg"]=1
        _br_names+=("$pkg")
        _br_recipes+=("$recipe")
        _br_versions+=("$version")
        [[ "$pkg" == "nvidia-open-dkms" ]] && HW_NVIDIA_REQUESTED=1
        ;;
      flatpak)
        [[ -n "${_seen_fp_pkg[$pkg]:-}" ]] && continue
        _seen_fp_pkg["$pkg"]=1
        _fp_names+=("$pkg")
        _fp_recipes+=("$recipe")
        ;;
      *)
        warn "  Unknown type '$type' for $pkg — skipping"
        ;;
    esac
  done <"$conf"

  local _total_selected=$((${#_pacman_pkgs[@]} + ${#_br_names[@]} + ${#_fp_names[@]}))
  log "Hardware support:"
  log "  selected: $_total_selected"
  log "  skipped:  $_skipped_count"

  # Install kernel headers BEFORE nvidia-open-dkms so the DKMS hook
  # sees a real kernel with headers when the package is installed.
  if ((HW_NVIDIA_REQUESTED)) && _is_install_chroot; then
    # shellcheck disable=SC2153  # KVER is set by detect_kernel_version in common_modules.sh
    if [[ ! -e "$MERGED/usr/lib/modules/$KVER/build/Makefile" ]]; then
      log "Installing kernel headers for $KVER before nvidia-open-dkms"
      install_kernel_headers || die "Failed to install kernel headers for $KVER"
    fi
  fi

  # Capture DKMS state before package installation (before the hook runs)
  if ((HW_NVIDIA_REQUESTED)) && [[ "${DEBUG:-0}" == 1 ]]; then
    _run_in_root '
      echo "=== DKMS paths before NVIDIA package install ==="
      echo "--- framework.conf ---"
      grep -RnsE "^[[:space:]]*(install_tree|source_tree|dkms_tree)=" /etc/dkms/framework.conf /etc/dkms/framework.conf.d 2>/dev/null || true
      echo "--- module tree ---"
      printf "/usr/lib/modules -> "
      readlink -f /usr/lib/modules || true
      find /usr/lib/modules -mindepth 1 -maxdepth 2 -printf "%y %p -> %l\n" 2>/dev/null || true
      echo "--- headers ---"
      find /usr/lib/modules -mindepth 1 -maxdepth 2 \( -name build -o -name source \) -printf "%p -> %l\n" 2>/dev/null || true
    ' || true
  fi

  # Install pacman packages (single source)
  if ((${#_pacman_pkgs[@]} > 0)); then
    _install_pacman_hw_batch "$valve_pacconf" _pacman_pkgs _pacman_targets _pacman_descs
  fi

  # Build kernel modules
  if ((${#_br_names[@]} > 0)); then
    _install_build_recipes _br_names _br_recipes _br_versions
  fi

  # Install flatpaks
  if ((${#_fp_names[@]} > 0)); then
    _install_flatpak_items _fp_names _fp_recipes
  fi

  if [[ ${#HW_FAILED_SOURCES[@]} -gt 0 ]]; then
    warn "Some package sources failed to refresh: ${HW_FAILED_SOURCES[*]}"
  fi
  if [[ ${#HW_FAILED_PKGS[@]} -gt 0 ]]; then
    warn "Some packages failed to install: ${HW_FAILED_PKGS[*]}"
    warn "Continuing where possible — optional hardware packages are non-fatal"
  fi

  # nvidia-open-dkms normally builds from its pacman DKMS hook.  The recipe
  # (invoked above via _install_build_recipes) performs the authoritative
  # build.  This block handles diagnostics, environment repair, and
  # post-build verification.
  if ((HW_NVIDIA_REQUESTED)); then
    if _is_install_chroot; then
      # shellcheck disable=SC2153  # KVER is set by detect_kernel_version in common_modules.sh

      # ── Discover NVIDIA version (diagnostic) ────────────────────────────
      local _nv_src _nvver _nv_count
      _nv_count="$(_run_in_root "find /usr/src -mindepth 1 -maxdepth 1 -type d -name 'nvidia-*' | wc -l")" || true
      _nv_count="${_nv_count%%[[:space:]]}"

      if [[ "$_nv_count" != "1" ]]; then
        _run_in_root "echo 'ERROR: expected exactly one NVIDIA source tree, found $_nv_count:'; find /usr/src -mindepth 1 -maxdepth 1 -type d -name 'nvidia-*' -printf '  %f\n' || true" >&2 || true
        die "Expected exactly one NVIDIA source tree in /usr/src, found $_nv_count"
      fi

      _nv_src="$(_run_in_root "find /usr/src -mindepth 1 -maxdepth 1 -type d -name 'nvidia-*' -printf '%f\n'")" || true
      _nv_src="/usr/src/${_nv_src%%[[:space:]]}"
      _nvver="${_nv_src##*/nvidia-}"

      log "NVIDIA verification: nvidia/$_nvver for $KVER"
      log "  NVIDIA source: $_nv_src"
      log "  Kernel:        $KVER"

      # ── DKMS diagnostic ────────────────────────────────────────────────
      if [[ "${DEBUG:-0}" == 1 ]]; then
        _run_in_root "echo 'DKMS DEBUG: environment'; id; dkms --version || true; pacman -Q dkms nvidia-open-dkms nvidia-utils 2>/dev/null || true" || true
        _run_in_root "echo 'DKMS DEBUG: framework configuration'; for f in /etc/dkms/framework.conf /etc/dkms/framework.conf.d/*.conf; do [[ -f \"\$f\" ]] || continue; echo \"--- \$f ---\"; grep -nE '^[[:space:]]*(source_tree|dkms_tree|install_tree)=' \"\$f\" || true; done" || true
        _run_in_root "echo 'DKMS DEBUG: module tree'; ls -ld /usr/lib/modules /lib/modules 2>/dev/null || true; find /usr/lib/modules -mindepth 1 -maxdepth 1 -printf '%y %f -> %l\n' 2>/dev/null || true" || true
        _run_in_root "echo 'DKMS DEBUG: source tree'; find /usr/src -mindepth 1 -maxdepth 1 -printf '%y %f -> %l\n' 2>/dev/null || true" || true
        _run_in_root "echo 'DKMS DEBUG: current state'; dkms status || true" || true
      fi

      # ── DKMS repair: fix bogus install_tree ─────────────────────────────
      # shellcheck disable=SC2016  # Variables expand inside the chroot, not on the host
      if ! _run_in_root '
        DKMS_FRAMEWORK=/etc/dkms/framework.conf
        mkdir -p /etc/dkms
        touch "$DKMS_FRAMEWORK"

        # Check if /usr/lib/modules resolves to / (bad symlink or bind mount)
        modules_real="$(readlink -f /usr/lib/modules 2>/dev/null || true)"
        if [[ "$modules_real" == "/" ]]; then
          echo "ERROR: /usr/lib/modules resolves to /"
          if [[ -L /usr/lib/modules ]]; then
            echo "Repairing bogus /usr/lib/modules symlink"
            ls -l /usr/lib/modules
            rm -- /usr/lib/modules
            mkdir -p /usr/lib/modules
          else
            echo "FATAL: /usr/lib/modules resolves to / but is not a symlink" >&2
            exit 1
          fi
        fi

        if grep -Eq "^[[:space:]]*install_tree=[\"'"'"']?/[\"'"'"']?[[:space:]]*$" "$DKMS_FRAMEWORK"; then
          echo "ERROR: DKMS install_tree is set to /; repairing"
          cp -a "$DKMS_FRAMEWORK" "${DKMS_FRAMEWORK}.before-steamos-repair"
          sed -Ei "s|^[[:space:]]*install_tree=.*|# disabled by SteamOS build: &|" "$DKMS_FRAMEWORK"
          printf "\ninstall_tree=\"/usr/lib/modules\"\n" >> "$DKMS_FRAMEWORK"
          echo "DKMS REPAIR: install_tree set to /usr/lib/modules"
        else
          echo "DKMS REPAIR: install_tree looks OK (not /)"
        fi
      '; then
        die "DKMS environment repair failed"
      fi

      # ── Verify: depmod + modinfo ────────────────────────────────────────
      # Use NVIDIA_MODULES from common_modules.sh (sourced before this file).
      local _nv_mod_list="${NVIDIA_MODULES[*]}"
      _run_in_root "
        depmod '$KVER'

        missing=()
        for mod in $_nv_mod_list; do
          if ! modinfo -k '$KVER' \"\$mod\" >/dev/null 2>&1; then
            missing+=(\"\$mod\")
          fi
        done

        if (( \${#missing[@]} )); then
          echo \"ERROR: NVIDIA module validation failed for $KVER: \${missing[*]}\" >&2
          exit 1
        fi

        echo 'NVIDIA module set validated for $KVER'
        for mod in $_nv_mod_list; do
          printf '  %-16s -> ' \"\$mod\"
          modinfo -k '$KVER' -F filename \"\$mod\" 2>/dev/null || echo 'MISSING'
        done
      " || die "NVIDIA module validation failed for $KVER"

      log "NVIDIA modules validated: nvidia/$_nvver on $KVER"
    else
      # Live system — check if nvidia modules exist for running kernel
      if ! nvidia_modules_valid "/" "$(uname -r)"; then
        log "NVIDIA modules not found for $(uname -r) — attempting DKMS build"
        _run_in_root "dkms autoinstall -k '$(uname -r)'" \
          || warn "DKMS autoinstall failed (non-fatal on live)"
      fi
    fi

    local nvidia_ver
    nvidia_ver="$(_run_in_root "pacman -Q nvidia-utils 2>/dev/null" | awk '{print $2}' || true)"
    [[ -n "$nvidia_ver" ]] \
      || die "nvidia-utils is not installed after NVIDIA package installation"
  else
    log "NVIDIA not requested — skipping nvidia driver verification"
  fi

  # AMD verification: check that mesa and vulkan-radeon are installed if AMD was requested.
  if [[ -n "${HW_SUPPORT_ITEMS:-}" ]] && [[ " $HW_SUPPORT_ITEMS " == *" mesa "* || " $HW_SUPPORT_ITEMS " == *" vulkan-radeon "* ]]; then
    if _is_install_chroot; then
      log "AMD verification: checking Mesa and RADV Vulkan packages"
      local _amd_pkgs=("mesa" "lib32-mesa" "vulkan-radeon" "lib32-vulkan-radeon")
      local _amd_missing=0
      for _pkg in "${_amd_pkgs[@]}"; do
        local _amd_ver
        _amd_ver="$(_run_in_root "pacman -Q '$_pkg' 2>/dev/null" | awk '{print $2}' || true)"
        if [[ -n "$_amd_ver" ]]; then
          log "    ✓ $_pkg $_amd_ver installed"
        else
          warn "    $_pkg was selected but is not registered as installed"
          HW_FAILED_PKGS+=("$_pkg")
          ((_amd_missing++))
        fi
      done
      if ((_amd_missing)); then
        warn "AMD verification: $_amd_missing package(s) missing"
      else
        log "AMD packages validated: Mesa and RADV Vulkan packages installed"
      fi
    fi
  else
    log "AMD not requested — skipping AMD driver verification"
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

# Cached package list for verify_hw_libs (populated on first use)
_VERIFY_HW_LIBS_PKG_CACHE=""
_VERIFY_HW_LIBS_PKG_CACHE_READY=0

_verify_hw_libs_ensure_cache() {
  if [[ "$_VERIFY_HW_LIBS_PKG_CACHE_READY" -eq 1 ]]; then
    return
  fi

  local _context="live"
  _is_install_chroot && _context="chroot:$MERGED"
  debug "  [verify_hw_libs] context=$_context"

  _VERIFY_HW_LIBS_PKG_CACHE="$(_run_in_root "pacman -Qq" 2>/dev/null)" || true
  _VERIFY_HW_LIBS_PKG_CACHE_READY=1

  if [[ -n "$_VERIFY_HW_LIBS_PKG_CACHE" ]]; then
    debug "  [verify_hw_libs] installed packages:"
    while IFS= read -r _pkg; do
      debug "    $_pkg"
    done <<<"$_VERIFY_HW_LIBS_PKG_CACHE"
  fi
}

verify_hw_libs() {
  local packages="${1:-}"
  local missing=0

  # If no packages specified, determine what should be installed
  if [[ -z "$packages" ]]; then
    # Determine packages based on which GPU vendor is selected
    if nvidia_is_selected; then
      packages="dkms nvidia-open-dkms nvidia-utils lib32-nvidia-utils"
    else
      packages=""
    fi

    # Add optional packages if HW_SUPPORT_ITEMS is set
    if [[ -n "${HW_SUPPORT_ITEMS:-}" ]]; then
      packages+=" $HW_SUPPORT_ITEMS"
    fi
  fi

  _verify_hw_libs_ensure_cache

  local _verify_requested=0
  local _verify_present=0
  local _verify_failed=0

  for pkg in $packages; do
    # Strip version pin if present
    pkg="${pkg%%=*}"
    [[ -z "$pkg" ]] && continue
    ((++_verify_requested))

    # Check cached package list
    if echo "$_VERIFY_HW_LIBS_PKG_CACHE" | grep -qx "$pkg"; then
      # Package is installed — get version and install reason
      local _info
      _info="$(_run_in_root "pacman -Qi '$pkg'" 2>/dev/null)" || true
      local ver _reason
      ver="$(echo "$_info" | sed -n 's/^Version *: //p')"
      _reason="$(echo "$_info" | sed -n 's/^Install Reason *: //p')"
      debug "  [verify_hw_libs] $pkg $ver — ${_reason:-unknown}"
      debug "  ✓ $pkg $ver"
      ((++_verify_present))
    else
      warn "  ✗ $pkg not installed"
      missing=1
      ((++_verify_failed))
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
        debug "  ✓ nvidia.ko ($kver)"
      else
        warn "  ✗ nvidia.ko missing ($kver)"
        missing=1
      fi
    fi
  fi

  log "Hardware package verification:"
  log "  requested: $_verify_requested"
  log "  present:   $_verify_present"
  log "  failed:    $_verify_failed"

  return $missing
}
