# Usage

## GUI Mode

Run with no arguments to launch the YAD-based graphical interface:

```bash
./steamos-nvidia.sh
```

The tool will prompt for your password when root is needed (build, flash, etc.). It tries `sudo` first, then falls back to `pkexec`. If you haven't set a sudo password yet, do that first:

```bash
passwd
```

The main menu presents these actions:

| Action | Description |
|---|---|
| **Build** | Patch a SteamOS recovery image with NVIDIA drivers |
| **Generate Config** | Save a build configuration file for later or automated use |
| **Flash** | Write a completed image to a USB drive |
| **Flashless** | Install a built image to the inactive A/B slot (no USB needed) |
| **Diagnostics** | System diagnostics and hardware reporting |
| **Configure** | Post-install configuration checklist |
| **Reboot** | Reboot helper |
| **Quit** | Exit |

### Build flow

Selecting **Build** opens a form with these fields:

| Field | Default | Description |
|---|---|---|
| Base image | *(required)* | Path to a clean SteamOS repair `.img` (or `.img.bz2`/`.gz`/`.xz`/`.zst`) |
| OOBE | `steamdeck` | `steamdeck` (keep user data) or `steamdeck-oobe` (factory reset) |
| Branch | `stable` | Update channel: `stable`, `beta`, `preview`, or others |
| Rootfs size | `10240` | Root partition size in MiB (or use K/M/G suffixes) |
| Default session | `stock` | `stock`, `game`, or `desktop` |
| Update mode | `selfheal` | `selfheal`, `hold`, or `stock` — see [Update Modes](customization_update_modes.md) |
| Workspace location | `auto` | `auto`, `ram`, or `disk` |
| Working directory | `automatic` | Explicit build directory, or leave automatic |

Checkboxes open sub-dialogs for:

- **Hardware support** — [hardware packages](customization_hardware_packages.md)
- **Initramfs support** — [kernel module selection](customization_initramfs_modules.md)
- **System tweaks** — [optimizations and tunables](customization_system_tweaks.md)
- **One-click installer** — adds desktop icon for installing to internal drive
- **Pipx packages** — [Python applications](customization_pipx_packages.md)

After confirming, the build runs with a progress dialog. A typical build takes 10-20 minutes. The output image is written beside the original with a `-nvidia-usbinstall` suffix and a `.build-complete` marker file.

Once installed, OS updates are handled automatically in `selfheal` mode. See [OS Updates](os_updates.md) for what happens on the installed system.

### Flash flow

Selecting **Flash** to write a completed image to USB. The dialog shows removable devices with size and model. After confirming, the image is written with `dd` and verified with a SHA256 read-back.

### Flashless flow

Selecting **Flashless** installs directly to the inactive A/B slot without needing a USB drive. The tool detects the current and target slots, verifies the image is an NVIDIA build, and writes it to the inactive partition.

---

## CLI Mode

Pass named arguments (no positional parameters). Root is requested automatically when needed — you don't need to run with `sudo`.

```bash
./steamos-nvidia.sh --action build --image FILE [build options]
./steamos-nvidia.sh --action flash --image FILE --device /dev/sdX
./steamos-nvidia.sh --action flashless --image FILE
./steamos-nvidia.sh --action configure
./steamos-nvidia.sh --action reboot
./steamos-nvidia.sh --action list-images
./steamos-nvidia.sh --action list-devices
./steamos-nvidia.sh --action is-system-disk --device /dev/sdX
./steamos-nvidia.sh --action preflight --image FILE --device /dev/sdX
```

> **Note:** If you haven't set a sudo password yet, run `passwd` first. Without a password, the tool can't elevate to root for build/flash operations.

### Setup

Install host dependencies (Arch/SteamOS only):

```bash
./steamos-nvidia.sh --setup
```

### Named arguments

| Argument | Description |
|---|---|
| `--action ACTION` | One of: `build`, `flash`, `flashless`, `configure`, `reboot`, `list-images`, `list-devices`, `is-system-disk`, `preflight` |
| `--image FILE` | Source or completed image path |
| `--device DEVICE` | Target block device for flashing (e.g. `/dev/sda`) |
| `--config FILE` | Load settings from a config file (see [Build Config](customization_build_config.md)) |

### Build options

| Flag | Description |
|---|---|
| `--workingdir DIR` | Build cache location (~3 GB, speeds up reruns) |
| `--workdir-location MODE` | `auto`, `ram`, or `disk` |
| `--rootfs-size SIZE` | Root partition size in MiB |
| `--session MODE` | `desktop` or `game` (omit for stock) |
| `--hold-updates` | Hard-hold OS updates (see [Update Modes](customization_update_modes.md)) |
| `--no-hold-updates` | Stock update behaviour (driver removed on update) |
| `--no-installer` | Skip the one-click desktop installer |
| `--trim-cuda` | Drop CUDA/OpenCL/OptiX libraries (~350 MB smaller) |
| `--thunderbolt` | Enable Thunderbolt dock support |
| `--hw-support` | Enable hardware support packages |
| `--hw-support-items ITEMS` | Space-separated package list (e.g. `linux-firmware libfprint fprintd bolt`) |
| `--initramfs MODULES` | Space-separated kernel module list for initramfs |
| `--gaming-items ITEMS` | Space-separated system tweaks (see [System Tweaks](customization_system_tweaks.md)) |
| `--debug-boot` | Add `rd.debug rd.log=all` to kernel cmdline |
| `--skip-sigcheck` | Disable pacman signature checks in build chroot |
| `--fix-keyring` | Force-initialize pacman keyrings |
| `--oobe-variant VARIANT` | `steamdeck` or `steamdeck-oobe` |
| `--branch BRANCH` | Update channel: `stable`, `beta`, `preview`, etc. |

### Flash options

| Flag | Description |
|---|---|
| `--allow-system-disk` | Permit flashing to the disk the host is running from |

### Examples

```bash
# Build with defaults
./steamos-nvidia.sh --action build \
    --image /path/to/steamdeck-repair.img

# Build with custom config, trim CUDA, 10 GiB root
./steamos-nvidia.sh --action build \
    --image /path/to/steamdeck-repair.img.bz2 \
    --config my-build.conf \
    --trim-cuda \
    --rootfs-size 10240

# Flash to USB
./steamos-nvidia.sh --action flash \
    --image /path/to/steamdeck-repair-nvidia-usbinstall.img \
    --device /dev/sda

# Flashless install
./steamos-nvidia.sh --action flashless \
    --image /path/to/steamdeck-repair-nvidia-usbinstall.img
```
