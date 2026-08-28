# System Tweaks

The system tweaks dialog contains optimizations and tunables applied during the build. Each checkbox is described below with what it does and what files it touches.

## Tweak reference

### trim-cuda

**Default:** off

Removes CUDA, OpenCL, NVVM, and OptiX libraries from the image. Saves ~350 MB. These are not needed for gaming — only for AI/ML workloads and GPU compute.

**What it removes:** CUDA runtime libraries, OpenCL ICD loaders, OptiX ray-tracing libraries.

### gamemode

**Default:** on

Adds the `deck` user to the `gamemode` group and enables the `gamemoded` user service. Games can then request CPU performance mode switching via D-Bus using Feral GameMode.

**Files modified:**
- `/etc/group` (user added to gamemode group)
- `/etc/systemd/user/graphical-session.target.wants/gamemoded.service` (symlink)

### pci-realloc

**Default:** on

Adds `pci=realloc=on` to the kernel command line. Fixes firmware PCI bridge resource allocation issues that can cause devices to not be assigned addresses, particularly on systems with many PCI devices or BAR-heavy GPUs.

**Files modified:** GRUB kernel parameters.

### tb-host-reset

**Default:** on

Adds `thunderbolt.host_reset=0` to the kernel command line. Improves Thunderbolt and eGPU hotplug stability by preventing the host controller from resetting on reconnect.

**Files modified:** GRUB kernel parameters.

### resize-bar

**Default:** on

Adds `nvidia.NVreg_EnableResizableBAR=1` to the kernel command line. Enables Resizable BAR (ReBAR/SAM) for the NVIDIA GPU, allowing the CPU to access the full GPU VRAM address space. Can improve performance in some games.

**Files modified:** GRUB kernel parameters.

### fix-keyring

**Default:** on

Force-initializes the Arch Linux and Holo pacman keyrings inside the image. Useful when the frozen recovery image has a stale keyring that causes package verification failures during the build.

### skip-sigcheck

**Default:** off

Disables pacman signature verification in the build chroot. Packages are still fetched over HTTPS from Valve's and Arch's own servers. Use this if you hit persistent keyring issues that `fix-keyring` doesn't resolve.

### debug-boot

**Default:** off

Adds `rd.debug rd.log=all` to the kernel command line. Enables verbose initramfs logging for diagnosing boot failures. Logs are written to the journal and available via `journalctl -b`.

**Files modified:** GRUB kernel parameters.

### thunderbolt

**Default:** on

Installs Thunderbolt dock support: a udev rule that triggers PCI rescans when Thunderbolt devices are hotplugged, and enables the `bolt` daemon for device authorization.

**Files installed:**
- `/etc/udev/rules.d/98-thunderbolt-rescan.rules`
- `/usr/local/bin/thunderbolt-rescan.sh`
- `bolt` systemd service enabled

### logitech-hid

**Default:** on

Builds and installs Logitech HID++ kernel modules (`hid-logitech-dj`, `hid-logitech-hidpp`) from the upstream Linux source. These provide proper support for Logitech wireless receivers and HID++ protocol devices (mice, keyboards, gamepads).

The modules are compiled against the image's kernel in the build chroot.

### unset-libva-driver

**Default:** on

Removes `/etc/profile.d/libva.sh` which Valve ships to force `LIBVA_DRIVER_NAME=radeonsi`. Without this file, the browser and other VA-API clients auto-detect the correct driver (NVIDIA's `nvidia` or Intel's `iHD` instead of forcing Radeon).

**Files removed:** `/etc/profile.d/libva.sh`

### scx-lavd

**Default:** on

Enables the `scx_lavd` sched_ext scheduler in autopilot mode. LAVD (Latency-Aware Variable Deadline) provides the best frametime consistency for gaming. Requires the `scx-scheds` package to be present in the image.

**Files installed:**
- `/etc/scx_loader/config.toml` (scheduler configuration)
- `scx.service` systemd service enabled

**Scheduler modes configured:**
| Mode | Flags |
|---|---|
| Auto (default) | `--autopilot --pinned-slice-us 500` |
| Gaming | `--performance --pinned-slice-us 500` |
| Powersave | `--powersave --pinned-slice-us 500` |

### vm-tunables

**Default:** on

Tunes `vm.swappiness` based on the image's swap configuration:

- **zram present:** sets `vm.swappiness=180` (prefers compressed RAM swap over disk)
- **no zram:** sets `vm.swappiness=10` (avoids slow disk swap stalls)

SteamOS ships with zram at the kernel default of 60. A value of 180 makes the kernel much more willing to swap to compressed RAM, which is effectively free memory.

**Files installed:** `/etc/sysctl.d/99-vm-swappiness.conf`

### cpu-performance

**Default:** on

Installs a boot-time hook that sets all CPU cores to `performance` governor and `performance` energy performance preference (EPP) on every boot. Also enables CPU boost (turbo) for both AMD and Intel.

The hook is idempotent — it exits early if the CPU is already in the desired state.

**Files installed:**
- `/usr/lib/steam-perf/boot.d/30-cpu` (hook script)
- `/usr/lib/steam-perf/apply-boot` (hook runner)
- `/etc/steam-perf/config.conf` (configuration)
- `steam-perf.service` systemd service enabled

**Configurable via** `/etc/steam-perf/config.conf`:
```bash
CPU_GOVERNOR=performance
CPU_EPP=performance
```

### gpu-power-limit

**Default:** on

Installs boot-time hooks that raise the GPU power limit to the vendor-specified ceiling on every boot. Covers both NVIDIA (via `nvidia-smi`) and AMD discrete GPUs (via sysfs `power1_cap`). APUs are skipped (they have no power cap interface).

Also enables NVIDIA persistence mode so the driver stays loaded even with no GPU clients.

**Files installed:**
- `/usr/lib/steam-perf/boot.d/20-nvidia-gpu` (NVIDIA hook)
- `/usr/lib/steam-perf/boot.d/25-amd-gpu` (AMD hook)

## Use via CLI

Pass tweaks as a space-separated list in your config file:

```bash
# In your build.conf:
GAMING_ITEMS="gamemode pci-realloc resize-bar scx-lavd vm-tunables cpu-performance gpu-power-limit"
```

## Custom script hook

If you need additional tweaks beyond what the checkboxes provide, place an executable script at:

```
/home/.steamos-build/recovery/custom.sh
```

This script runs during the build and during each self-heal repatch. It receives no arguments and runs as root inside the chroot.

```bash
#!/bin/bash
# Example: install an extra package
pacman -S --noconfirm my-custom-package
```
