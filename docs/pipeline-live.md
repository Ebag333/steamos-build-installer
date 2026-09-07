# Live Pipeline

The live pipeline configures a running SteamOS system (or an offline mounted rootfs) with NVIDIA drivers, hardware packages, customizations, and system configuration. It uses the same config file format and shared functions as the build pipeline, operating sequentially through six phases.

## What it does

Given a standard `.conf` file (same format as build — generated via **Generate Config** in the GUI or written manually), the live pipeline:

1. Validates root privileges, offline target if specified, loads and validates the config
2. Disables the SteamOS read-only filesystem layer
3. Optionally upgrades the base OS via `pacman -Syu` (when `BASE_OS_MODE=upgrade`)
4. Installs hardware packages, kernel modules, flatpaks, and applies customizations
5. Reconciles initramfs modules, enables services, configures the desktop session
6. Regenerates initramfs for offline targets and re-enables read-only mode

The pipeline supports two target modes:

- **Live system** (`config_root=/` or unset) — modifies the currently running rootfs directly, using `steamos-readonly` to toggle writability.
- **Offline target** (`config_root=/some/path`) — modifies a mounted rootfs at an arbitrary path, using btrfs property manipulation to ensure writability.

## What's unique to this pipeline

The live pipeline handles concerns that do not exist in the build, flash, flashless, or validate pipelines:

### Live system operation

Unlike build (which assembles a raw disk image) or flashless (which writes to an inactive A/B slot), the live pipeline modifies the running system in-place. There is no chroot — commands execute directly on the target. The running kernel version (`uname -r`) is used instead of discovering it from an image.

### SteamOS read-only filesystem handling

SteamOS uses a read-only rootfs by default. The pipeline manages this automatically:

- **Prepare phase**: Disables read-only mode via `steamos-readonly disable` (live system) or sets the btrfs `ro` property to `false` (offline target).
- **Verify phase**: Re-enables read-only mode via `steamos-readonly enable` (live system only — offline targets are left as-is since the caller controls their lifecycle).

### No image writing or slot management

Unlike flash and flashless, there is no `dd`, no loop mounting, no A/B slot detection, no UUID randomization, and no boot environment rebuild. The pipeline operates on a filesystem tree, not a block device.

### Shared config format

The live pipeline uses the same `.conf` file as build. Generate one via **Generate Config** in the GUI (select "Live OS" mode) or write it manually. Key variables:

| Variable | Purpose |
|---|---|
| `GAMING_ITEMS` | Optimization customizations to apply |
| `HW_SUPPORT_ITEMS` | Hardware support packages to install |
| `INITRAMFS_MODULES` | Initramfs module groups to include |
| `DEFAULT_SESSION` | Desktop session to configure |
| `UPDATE_BRANCH` | SteamOS update channel |
| `UPDATE_MODE` | Update strategy (selfheal / hold / stock) |
| `BASE_OS_MODE` | `additive` (default) or `upgrade` — whether to run `pacman -Syu` first |
| `TARGET_VARIANT` | Image variant identifier |
| `PACMAN_REPO` | Package repository source (valve / main) |

## Workflow

The pipeline has six phases, registered via `register_live_pipeline()`:

### 1. Validate

`phase_live_validate` — Pre-flight checks and config loading.

- Verifies the process is running as root (EUID 0).
- If an offline target is specified (`config_root` set and not `/`), checks that the directory exists and contains an `/etc/os-release` file.
- Loads the standard config file, populating `GAMING_ITEMS`, `HW_SUPPORT_ITEMS`, `INITRAMFS_MODULES`, and other shared variables.
- Validates `DEFAULT_SESSION`, `UPDATE_MODE`, and `BASE_OS_MODE` values.
- Logs the full configuration summary.
- Derives `FIX_KEYRING` and `SKIP_SIG` flags from the loaded config.

### 2. Prepare

`phase_live_prepare` — Makes the target rootfs writable.

- **Live system**: Calls `steamos-readonly disable` if the command is available.
- **Offline target**: Calls `ensure_rootfs_writable` which checks the btrfs `ro` property and sets it to `false` if needed.

### 3. System Upgrade

`phase_live_sysupgrade` — Optional base OS upgrade via `pacman -Syu`.

- Skipped unless `BASE_OS_MODE=upgrade` is set in the config.
- **Live system**: Runs `pacman_upgrade_all` with pre-flight conflict/dep-breakage checks. Interactive prompts allow the user to skip or cancel.
- **Offline target**: Runs `system_upgrade` with up to 3 retries.

### 4. Install

`phase_live_install` — Installs packages, modules, and customizations.

1. Installs hardware packages via `install_hw_libs` (supports live context — no chroot).
2. Builds custom kernel modules from recipes defined in the config.
3. Installs flatpak packages.
4. Applies all customizations via `apply_customizations` (iterates `GAMING_ITEMS`).
5. Configures the update channel via `configure_update_channel`.

### 5. Configure

`phase_live_configure` — System configuration and service setup.

1. Reconciles initramfs modules — compares config selections against currently installed modules and rebuilds as needed.
2. Enables NVIDIA power management services.
3. Installs modprobe configuration for NVIDIA kernel modules.
4. Configures the desktop session from `DEFAULT_SESSION`.
5. Runs the user custom script if present at `<root>/home/.steamos-build/recovery/custom.sh`.
6. Persists project files to `/home` via `ensure_project_persisted` so the installer can be re-run later without the original source.

### 6. Verify

`phase_live_verify` — Post-configuration cleanup and restoration.

- If the target is an offline rootfs (not `/`), regenerates initramfs to pick up any module changes from the install and configure phases.
- If the target is the live system, re-enables SteamOS read-only mode via `steamos-readonly enable`.
