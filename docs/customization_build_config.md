# Build Configuration

Build settings can be controlled through three layers, in order of precedence:

1. **CLI flags** (highest priority)
2. **Config file** (`--config`)
3. **Defaults** (`lib/configs/defaults.conf`)

## defaults.conf

`lib/configs/defaults.conf` is the single source of truth for all build flag defaults. It's sourced at startup by `steamos-build.sh`. If the file is missing, all flags start blank/zero.

See [defaults.conf](../lib/configs/defaults.conf) for the full list of variables and their defaults.

## Config files

A config file is a bash file that sets variables. Pass it via `--config`:

```bash
./steamos-build.sh --action build --config my-build.conf --image ...
```

### Example config

```bash
# steamos-build.conf — copy and edit as needed

# Source image
IMG="/path/to/steamdeck-repair.img.bz2"

# Update strategy: selfheal | hold | stock
UPDATE_MODE="selfheal"

# Include one-click installer (1=yes, 0=no)
ADD_INSTALLER=1

# Trim CUDA/OpenCL libs (~350 MB smaller)
TRIM_CUDA=0

# Hardware support
BUILD_HW_SUPPORT=1
THUNDERBOLT=1

# Session: "desktop", "game", or "" (stock)
DEFAULT_SESSION="desktop"

# Root partition size in MiB
ROOTFS_SIZE="10240"

# Workspace: auto | ram | disk
WORKDIR_LOCATION="auto"

# Keyring and signature
FIX_KEYRING=1
SKIP_SIG=0
```

See [steamos-build.example.conf](../steamos-build.example.conf) for a full annotated example.

## Generate Config (GUI)

The **Generate Config** action in the GUI opens the same build form and saves the selected options to a `.conf` file. This is useful for:

- Saving a configuration you use repeatedly
- Sharing a build recipe with others
- Automating builds in scripts or CI

## Variables reference

All build options are set via the config file. There are no CLI flags for build options.

| Variable | Default | Description |
|---|---|---|
| `IMG` | *(required)* | Source image path |
| `ROOTFS_SIZE` | `""` (Valve default 5120) | Root partition size in MiB |
| `TARGET_VARIANT` | `steamdeck` | Derived from `neutralize-oobe` in GAMING_ITEMS |
| `UPDATE_BRANCH` | `stable` | Update channel: stable, beta, preview, etc. |
| `DEFAULT_SESSION` | `game` | Login session: desktop or game |
| `UPDATE_MODE` | `selfheal` | Update strategy: selfheal, hold, stock |
| `WORKDIR_LOCATION` | `auto` | Build location: auto, ram, disk |
| `WORKDIR` | `""` | Explicit build directory |
| `ADD_INSTALLER` | `1` | Include one-click installer |
| `HW_SUPPORT_ITEMS` | `""` | Space-separated HW packages to install |
| `GAMING_ITEMS` | `""` | Space-separated system tweaks |
| `CUSTOM_DRIVERS` | `""` | Space-separated custom driver builds |
| `INITRAMFS_MODULES` | `""` | Kernel modules for initramfs |
| `ALLOW_SYSTEM_DISK` | `0` | Allow flashing system disk |
