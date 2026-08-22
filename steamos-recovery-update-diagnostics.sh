#!/usr/bin/env bash
#
# steamos-recovery-update-diagnostics.sh
#
# Read-only diagnostic collector for SteamOS Recovery / "Update Recovery Image"
# failures. It does not modify disks, networking, packages, or boot configuration.
#

set -u
export LC_ALL=C

TS="$(date +%Y%m%d-%H%M%S)"
HOST="$(hostname 2>/dev/null || echo unknown)"
BASE="${TMPDIR:-/tmp}/steamos-recovery-diag-${TS}"
OUT="${PWD}/steamos-recovery-diag-${HOST}-${TS}.tar.gz"

mkdir -p "$BASE"

# Preserve output even when individual commands fail.
exec 3>&1
log() { printf '[diag] %s\n' "$*" >&3; }

run() {
    local name="$1"
    shift
    {
        echo "\$ $*"
        echo
        "$@"
        rc=$?
        echo
        echo "[exit=$rc]"
    } >"$BASE/$name.txt" 2>&1 || true
}

run_sh() {
    local name="$1"
    shift
    {
        echo "\$ $*"
        echo
        bash -lc "$*"
        rc=$?
        echo
        echo "[exit=$rc]"
    } >"$BASE/$name.txt" 2>&1 || true
}

sudo_run() {
    local name="$1"
    shift
    {
        echo "\$ sudo $*"
        echo
        sudo "$@"
        rc=$?
        echo
        echo "[exit=$rc]"
    } >"$BASE/$name.txt" 2>&1 || true
}

sudo_sh() {
    local name="$1"
    shift
    {
        echo "\$ sudo bash -lc '$*'"
        echo
        sudo bash -lc "$*"
        rc=$?
        echo
        echo "[exit=$rc]"
    } >"$BASE/$name.txt" 2>&1 || true
}

log "Collecting diagnostics into $BASE"

# Prime sudo once so later commands don't interleave password prompts with output.
if command -v sudo >/dev/null 2>&1; then
    sudo -v || true
fi

###############################################################################
# 1. Basic system / recovery image identity
###############################################################################

run_sh system_identity '
echo "=== DATE ==="
date -Ins
echo
echo "=== UPTIME ==="
uptime
echo
echo "=== UNAME ==="
uname -a
echo
echo "=== HOSTNAMECTL ==="
hostnamectl 2>/dev/null || true
echo
echo "=== OS RELEASE ==="
cat /etc/os-release 2>/dev/null || true
echo
echo "=== STEAMOS RELEASE FILES ==="
for f in /etc/steamos-release /etc/steamos-version /usr/lib/os-release; do
  if [[ -f "$f" ]]; then
    echo "--- $f"
    cat "$f"
  fi
done
echo
echo "=== SESSION ==="
printf "USER=%s\nHOME=%s\nXDG_SESSION_TYPE=%s\nXDG_CURRENT_DESKTOP=%s\nDESKTOP_SESSION=%s\n" \
  "${USER:-}" "${HOME:-}" "${XDG_SESSION_TYPE:-}" "${XDG_CURRENT_DESKTOP:-}" "${DESKTOP_SESSION:-}"
echo
echo "=== PROXY ENVIRONMENT ==="
env | grep -iE "^(http|https|ftp|all|no)_proxy=" || true
'

run_sh time_and_tls '
echo "=== TIME ==="
date -Ins
timedatectl 2>&1 || true
echo
echo "=== CURL ==="
curl --version 2>&1 || true
echo
echo "=== WGET ==="
wget --version 2>&1 | head -40 || true
echo
echo "=== OPENSSL ==="
openssl version -a 2>&1 || true
echo
echo "=== CA BUNDLE ==="
ls -l /etc/ssl/certs/ca-certificates.crt /etc/ca-certificates/extracted/tls-ca-bundle.pem 2>&1 || true
'

###############################################################################
# 2. Boot state / kernel command line
###############################################################################

run_sh boot_state '
echo "=== CMDLINE ==="
cat /proc/cmdline
echo
echo "=== BOOTCTL ==="
bootctl status 2>&1 || true
echo
echo "=== EFI VARIABLES AVAILABLE ==="
test -d /sys/firmware/efi && echo yes || echo no
'

sudo_run efibootmgr efibootmgr -v

###############################################################################
# 3. Disk, partition, filesystem, and mount state
###############################################################################

run_sh block_devices '
echo "=== LSBLK ==="
lsblk -e7 -o NAME,PATH,TYPE,SIZE,RO,RM,TRAN,FSTYPE,FSVER,LABEL,UUID,PARTUUID,PARTLABEL,FSAVAIL,FSUSE%,MOUNTPOINTS
echo
echo "=== BLKID ==="
blkid 2>&1 || true
echo
echo "=== /proc/partitions ==="
cat /proc/partitions
'

sudo_run blkid_root blkid

run_sh mounts '
echo "=== FINDMNT ==="
findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS
echo
echo "=== DF ==="
df -hT
echo
echo "=== /proc/mounts ==="
cat /proc/mounts
'

sudo_sh partition_tables '
for d in /dev/sd? /dev/nvme?n1 /dev/mmcblk?; do
  [[ -b "$d" ]] || continue
  echo
  echo "===== $d ====="
  if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -p "$d" 2>&1 || true
    echo
    sgdisk -v "$d" 2>&1 || true
  elif command -v parted >/dev/null 2>&1; then
    parted -s "$d" print 2>&1 || true
  fi
done
'

###############################################################################
# 4. Networking, DNS, routes, NetworkManager
###############################################################################

run_sh network_state '
echo "=== LINKS ==="
ip -br link
echo
echo "=== ADDRESSES ==="
ip -br addr
echo
echo "=== ROUTES ==="
ip route show table all
echo
echo "=== IPv6 ROUTES ==="
ip -6 route show table all
echo
echo "=== RULES ==="
ip rule
echo
echo "=== RESOLV.CONF ==="
ls -l /etc/resolv.conf
cat /etc/resolv.conf
echo
echo "=== HOSTS ==="
cat /etc/hosts
echo
echo "=== RESOLVECTL ==="
resolvectl status 2>&1 || true
echo
echo "=== RFKILL ==="
rfkill list 2>&1 || true
'

run_sh networkmanager '
echo "=== NM GENERAL ==="
nmcli general 2>&1 || true
echo
echo "=== NM DEVICES ==="
nmcli -f DEVICE,TYPE,STATE,CONNECTION device 2>&1 || true
echo
echo "=== ACTIVE CONNECTIONS ==="
nmcli -f NAME,TYPE,DEVICE connection show --active 2>&1 || true
echo
echo "=== CONNECTIVITY ==="
nmcli networking connectivity check 2>&1 || true
'

sudo_sh firewall '
echo "=== NFTABLES ==="
nft list ruleset 2>&1 || true
echo
echo "=== IPTABLES ==="
iptables-save 2>&1 || true
echo
echo "=== IP6TABLES ==="
ip6tables-save 2>&1 || true
'

###############################################################################
# 5. Steam / Valve hostname resolution and HTTPS tests
###############################################################################

run_sh dns_tests '
for h in \
  steamdeck-images.steamos.cloud \
  store.steampowered.com \
  api.steampowered.com \
  repo.steampowered.com
do
  echo
  echo "===== $h ====="
  getent ahosts "$h" 2>&1 || true
done
'

run_sh https_tests '
for url in \
  https://steamdeck-images.steamos.cloud/ \
  https://store.steampowered.com/ \
  https://repo.steampowered.com/
do
  echo
  echo "===== $url : normal ====="
  curl -sSvkI --connect-timeout 10 --max-time 20 "$url" -o /dev/null 2>&1 || true

  echo
  echo "===== $url : IPv4 ====="
  curl -4 -sSvkI --connect-timeout 10 --max-time 20 "$url" -o /dev/null 2>&1 || true

  echo
  echo "===== $url : IPv6 ====="
  curl -6 -sSvkI --connect-timeout 10 --max-time 20 "$url" -o /dev/null 2>&1 || true
done
'

run_sh steamdeck_cloud_tls '
if command -v openssl >/dev/null 2>&1; then
  echo | timeout 20 openssl s_client \
    -connect steamdeck-images.steamos.cloud:443 \
    -servername steamdeck-images.steamos.cloud \
    -brief 2>&1 || true
fi
'

###############################################################################
# 6. Systemd status and update/recovery-related units
###############################################################################

run_sh systemd_failed '
echo "=== FAILED UNITS ==="
systemctl --failed --no-pager 2>&1 || true
echo
echo "=== RUNNING/FAILED SERVICES ==="
systemctl --no-pager --type=service --state=running,failed 2>&1 || true
'

run_sh steam_related_units '
echo "=== MATCHING LOADED UNITS ==="
systemctl list-units --all --no-pager 2>&1 | \
  grep -iE "steam|recovery|update|rauc|network|resolve|download" || true
echo
echo "=== MATCHING UNIT FILES ==="
systemctl list-unit-files --no-pager 2>&1 | \
  grep -iE "steam|recovery|update|rauc|network|resolve|download" || true
'

###############################################################################
# 7. Discover the actual recovery/update launchers and scripts
###############################################################################

run_sh updater_commands '
for c in \
  steamos-update \
  steamos-install \
  steamos-reboot \
  steamos-session-select \
  steamos-readonly \
  steamos-chroot \
  repair_device \
  install_to_hd \
  update_recovery
do
  printf "%-28s " "$c"
  command -v "$c" 2>/dev/null || echo "not found"
done
'

sudo_sh updater_file_discovery '
roots=(/usr/bin /usr/sbin /usr/lib /usr/libexec /usr/share/applications /etc/systemd /usr/lib/systemd /home/deck/Desktop /home/deck/.local/share/applications)
for root in "${roots[@]}"; do
  [[ -e "$root" ]] || continue
  echo
  echo "===== $root ====="
  find "$root" -maxdepth 4 \
    \( -type f -o -type l \) \
    \( -iname "*steam*" -o -iname "*recovery*" -o -iname "*update*" -o -iname "*install*hd*" \) \
    -print 2>/dev/null | sort
done
'

sudo_sh desktop_launchers '
for root in /home/deck/Desktop /usr/share/applications /home/deck/.local/share/applications; do
  [[ -d "$root" ]] || continue
  find "$root" -maxdepth 2 -type f -name "*.desktop" -print0 2>/dev/null |
  while IFS= read -r -d "" f; do
    if grep -qiE "steam|recovery|update|install" "$f"; then
      echo
      echo "===== $f ====="
      sed -n "1,220p" "$f"
    fi
  done
done
'

###############################################################################
# 8. Process snapshot
###############################################################################

run_sh processes '
echo "=== PROCESS TREE ==="
ps auxfww
echo
echo "=== UPDATE/RECOVERY MATCHES ==="
ps auxww | grep -iE "steam|recovery|update|curl|wget|aria|install_to_hd|repair_device" | grep -v grep || true
'

###############################################################################
# 9. Journals: full boot plus focused extracts
###############################################################################

sudo_sh journal_full_boot '
journalctl -b --no-pager -o short-precise
'

sudo_sh journal_kernel '
journalctl -b -k --no-pager -o short-precise
'

sudo_sh journal_recovery_update '
journalctl -b --no-pager -o short-precise | \
  grep -iE \
  "steam|recovery|update|download|curl|wget|http|https|tls|ssl|certificate|dns|resolve|network|timeout|timed out|error|fail|failed|404|403|401|5[0-9][0-9]" || true
'

sudo_sh journal_network '
journalctl -b --no-pager -o short-precise \
  -u NetworkManager \
  -u systemd-resolved \
  -u systemd-networkd 2>&1 || true
'

###############################################################################
# 10. Kernel messages
###############################################################################

sudo_sh dmesg '
dmesg -T
'

###############################################################################
# 11. Installed package / updater context
###############################################################################

run_sh package_context '
echo "=== RELEVANT PACMAN PACKAGES ==="
pacman -Q 2>/dev/null | \
  grep -iE "steam|steamos|valve|networkmanager|curl|wget|openssl|ca-cert|rauc|kde|plasma" || true
echo
echo "=== PACMAN DATABASE STATUS ==="
pacman -Qkk 2>/dev/null | \
  grep -iE "warning|error|missing|altered" | head -500 || true
'

###############################################################################
# 12. Recent logs/files likely created by the updater
###############################################################################

sudo_sh recent_log_inventory '
echo "Files modified in the last 6 hours:"
find /tmp /var/tmp /var/log /home/deck \
  -xdev -maxdepth 5 -type f -mmin -360 \
  \( -iname "*.log" -o -iname "*.txt" -o -iname "*.out" -o -iname "*.err" \) \
  -printf "%TY-%Tm-%Td %TH:%TM:%TS %s %p\n" 2>/dev/null | \
  sort -r | head -1000
'

mkdir -p "$BASE/recent-logs"
while IFS= read -r f; do
    [[ -f "$f" ]] || continue

    # Keep this intentionally narrow and size-limited.
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [[ "$size" -le 5242880 ]]; then
        safe="$(printf '%s' "$f" | sed 's#^/##; s#[/ ]#_#g')"
        sudo cp -a "$f" "$BASE/recent-logs/$safe" 2>/dev/null || true
        sudo chown "$(id -u):$(id -g)" "$BASE/recent-logs/$safe" 2>/dev/null || true
    fi
done < <(
    sudo find /tmp /var/tmp /var/log /home/deck \
      -xdev -maxdepth 5 -type f -mmin -360 \
      \( -iname "*.log" -o -iname "*.txt" -o -iname "*.out" -o -iname "*.err" \) \
      -print 2>/dev/null | head -300
)

###############################################################################
# 13. A compact summary for quick inspection
###############################################################################

{
    echo "SteamOS Recovery Update Diagnostics"
    echo "Generated: $(date -Ins)"
    echo
    echo "=== OS ==="
    grep -E '^(NAME|PRETTY_NAME|VERSION|VERSION_ID|BUILD_ID)=' /etc/os-release 2>/dev/null || true
    echo
    echo "=== Kernel ==="
    uname -a
    echo
    echo "=== Cmdline ==="
    cat /proc/cmdline
    echo
    echo "=== Failed units ==="
    systemctl --failed --no-pager 2>&1 || true
    echo
    echo "=== Default route ==="
    ip route show default 2>&1 || true
    echo
    echo "=== DNS ==="
    resolvectl dns 2>&1 || true
    echo
    echo "=== SteamOS cloud lookup ==="
    getent ahosts steamdeck-images.steamos.cloud 2>&1 || true
    echo
    echo "=== Mounted filesystems ==="
    findmnt -A -o TARGET,SOURCE,FSTYPE,OPTIONS
} >"$BASE/SUMMARY.txt" 2>&1

###############################################################################
# Package it
###############################################################################

cat >"$BASE/README.txt" <<'EOF'
This archive was generated by steamos-recovery-update-diagnostics.sh.

The collector is read-only. It captures:
- SteamOS/recovery image identity and boot command line
- disks, partitions, filesystems, and mounts
- network/DNS/routing state
- HTTPS/TLS connectivity to Valve/Steam endpoints
- systemd failures and relevant units
- updater/recovery launcher discovery
- full current-boot journal and focused extracts
- kernel log
- relevant package state
- recent small log files

Privacy note:
The archive can contain local IP addresses, hostnames, Wi-Fi connection names,
mount paths, usernames, and other system-specific information. Review it before
posting it publicly.
EOF

tar -C "$(dirname "$BASE")" -czf "$OUT" "$(basename "$BASE")"

# Make sure the invoking user owns the result even if the script itself was run with sudo.
if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$OUT" 2>/dev/null || true
fi

log "Done."
log "Archive: $OUT"
printf '\n%s\n' "$OUT"
