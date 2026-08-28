# OS Updates

This document covers how OS updates work on the installed system, what gets preserved across updates, and how to tweak things post-install.

## How updates work (self-heal mode)

In the default `selfheal` mode, OS updates from Steam work transparently:

```
Steam downloads update
        |
        v
steamos-atomupd-client stages new OS on inactive A/B slot
        |
        v
atomupd-wrapper detects the staged update
        |
        v
repatch.sh mounts the staged rootfs
        |
        v
rebuilds NVIDIA driver (DKMS) against new kernel
reconciles hardware packages, initramfs, GRUB, system tweaks
        |
        v
propagates self-heal machinery to new slot
        |
        v
marks slot bootable, prompts reboot
```

If the rebuild fails at any point, the staged update is invalidated and the machine keeps running the current system. This is fail-safe — a failed update never leaves the machine unbootable.

**Added time:** 10-20 minutes per OS update (the DKMS build is the bulk of it).

## What gets preserved across updates

An OS update replaces the rootfs entirely. The repatch process re-applies:

- NVIDIA driver packages (rebuilt against the new kernel)
- All hardware packages from the manifests
- System tweaks (gamemode, scx-lavd, vm.swappiness, boot hooks, etc.)
- Kernel parameters (pci-realloc, resize-bar, etc.)
- Initramfs module configuration
- GRUB configuration
- Modprobe config (blacklist nouveau, enable KMS)
- Custom script (`/home/.steamos-build/recovery/custom.sh`)
- Self-heal wrappers (propagated to the new slot)

## What lives on the installed system

### `/usr/lib/steamos-build/`

| Path | Purpose |
|---|---|
| `driver.conf` | Persisted build selections (gaming items, initramfs modules, etc.) |
| `build.conf` | Build manifest (versions, flags, timestamp) |
| `configs/hw-packages-arch.conf` | Arch package manifest |
| `configs/hw-packages-valve.conf` | Valve package manifest |
| `configs/pipx-packages.conf` | Pipx package definitions |
| `configs/99-nvidia-patch.conf` | Modprobe config |
| `configs/scx_loader_config.toml` | scx_lavd scheduler config |
| `configs/swappiness-zram.conf` | vm.swappiness=180 |
| `configs/swappiness-disk.conf` | vm.swappiness=10 |
| `configs/boot/` | Boot-time performance hooks |
| `repatch.sh` | On-device repatch script |
| `atomupd-wrapper.sh` | Wrapper around steamos-atomupd-client |
| `hid/` | Logitech HID module source (if logitech-hid was selected) |
| `thunderbolt/` | Thunderbolt support files (if thunderbolt was selected) |

### `/home/.steamos-build/`

| Path | Purpose |
|---|---|
| `logs/atomupd-latest.log` | Most recent self-heal log |
| `logs/atomupd-*.log` | All self-heal logs (timestamped) |
| `logs/update-latest.log` | Most recent update wrapper log |
| `logs/update-*.log` | All update wrapper logs |
| `recovery/custom.sh` | User custom script (runs during build + every repatch) |

## Tweaking the installed system

### Pin a driver version

The package manifests at `/usr/lib/steamos-build/configs/` control what gets installed during self-heal. To pin a specific NVIDIA driver version:

```bash
sudo nano /usr/lib/steamos-build/configs/hw-packages-arch.conf
```

Change `latest` to a specific version:

```
NVIDIA|nvidia-open-dkms|570.86.15|TRUE|NVIDIA open kernel module sources for DKMS
NVIDIA|nvidia-utils|570.86.15|TRUE|NVIDIA userspace driver libraries and tools
NVIDIA|lib32-nvidia-utils|570.86.15|TRUE|32-bit NVIDIA userspace libraries
```

The next OS update will use these pinned versions instead of resolving `latest`.

### Add or remove packages

Edit the manifests to add or remove packages from future self-heal cycles:

```bash
sudo nano /usr/lib/steamos-build/configs/hw-packages-arch.conf
sudo nano /usr/lib/steamos-build/configs/hw-packages-valve.conf
```

Remove a line or set its default to `FALSE` to exclude it. Add a line to include a new package.

### Adjust system tweaks

Edit `driver.conf` to change which tweaks are applied during the next self-heal:

```bash
sudo nano /usr/lib/steamos-build/driver.conf
```

The `GAMING_ITEMS` variable is a space-separated list of tweak names. Remove or add items as needed. See [System Tweaks](customization_system_tweaks.md) for the full list.

### Run a custom script on every update

Place an executable script at `/home/.steamos-build/recovery/custom.sh`:

```bash
mkdir -p /home/.steamos-build/recovery
cat > /home/.steamos-build/recovery/custom.sh << 'EOF'
#!/bin/bash
# Runs during build and during every self-heal repatch
pacman -S --noconfirm my-custom-package
EOF
chmod +x /home/.steamos-build/recovery/custom.sh
```

### Tune boot-time performance hooks

The boot hooks read from `/etc/steam-perf/config.conf`:

```bash
sudo nano /etc/steam-perf/config.conf
```

```bash
CPU_GOVERNOR=performance    # or powersave, schedutil, etc.
CPU_EPP=performance         # or balance_performance, balance_powersave, power
GPU_POWER_LIMIT=max         # or a specific wattage
```

You can also add custom hooks by placing executable scripts in `/etc/steam-perf/boot.d/`. These run alongside the shipped hooks on every boot.

## Checking update status

### View the build manifest

```bash
cat /usr/lib/steamos-build/build.conf
```

This shows the original build flags, driver version, kernel version, and timestamp.

### View self-heal logs

```bash
# Most recent
cat /home/.steamos-build/logs/atomupd-latest.log

# All logs
ls -la /home/.steamos-build/logs/
```

### Check if NVIDIA driver is loaded

```bash
lsmod | grep nvidia
nvidia-smi
```

### Verify driver version matches package

```bash
# Package version
pacman -Q nvidia-open-dkms

# Loaded module version
modinfo nvidia | grep version
```

## Changing the driver version (reinstall)

To move to a completely different NVIDIA driver version (not just pinning), rebuild the USB image with the desired driver and reinstall using the **Upgrade** icon. The Upgrade path preserves games, saves, and Steam login.

The installed system stays on whatever driver it was built with until you explicitly reinstall. Self-heal updates never drift the driver version — they rebuild the same version against the new kernel.
