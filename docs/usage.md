# Usage

## GUI Mode

Run with no arguments to launch the YAD-based graphical interface:

```bash
./steamos-build.sh
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
| Branch | `stable` | Update channel: `stable`, `beta`, `preview`, or others |
| Rootfs size | `10240` | Root partition size in MiB (or use K/M/G suffixes) |
| Default session | `game` | `game` or `desktop` |
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
./steamos-build.sh --action build --image FILE [build options]
./steamos-build.sh --action flash --image FILE --device /dev/sdX
./steamos-build.sh --action flashless --image FILE
./steamos-build.sh --action configure
./steamos-build.sh --action reboot
./steamos-build.sh --action list-images
./steamos-build.sh --action list-devices
./steamos-build.sh --action is-system-disk --device /dev/sdX
./steamos-build.sh --action preflight --image FILE --device /dev/sdX
```

> **Note:** If you haven't set a sudo password yet, run `passwd` first. Without a password, the tool can't elevate to root for build/flash operations.

### Setup

Install host dependencies (Arch/SteamOS only):

```bash
./steamos-build.sh --setup
```

### Named arguments

| Argument | Description |
|---|---|
| `--action ACTION` | One of: `build`, `flash`, `flashless`, `configure`, `reboot`, `list-images`, `list-devices`, `is-system-disk`, `preflight` |
| `--image FILE` | Source or completed image path |
| `--device DEVICE` | Target block device for flashing (e.g. `/dev/sda`) |
| `--config FILE` | Load settings from a config file (see [Build Config](customization_build_config.md)) |
| `--output-dir DIR` | Where to write the output image |

### Flash options

| Flag | Description |
|---|---|
| `--allow-system-disk` | Permit flashing to the disk the host is running from |

All build options (rootfs size, session, update mode, packages, tweaks, etc.)
are set via `--config`. See [Build Config](customization_build_config.md) for
the full list.

### Examples

```bash
# Build with config file
./steamos-build.sh --action build \
    --image /path/to/steamdeck-repair.img \
    --config my-build.conf

# Flash to USB
./steamos-build.sh --action flash \
    --image /path/to/steamdeck-repair-nvidia-usbinstall.img \
    --device /dev/sda

# Flashless install
./steamos-build.sh --action flashless \
    --image /path/to/steamdeck-repair-nvidia-usbinstall.img
```
