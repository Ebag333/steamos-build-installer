# Build Configuration

Build settings can be controlled through three layers, in order of precedence:

1. **CLI flags** (highest priority)
2. **Config file** (`--config`)
3. **Defaults** (`lib/configs/defaults.conf`)

## defaults.conf

`lib/configs/defaults.conf` is the single source of truth for all build flag defaults. It's sourced at startup by `steamos-nvidia.sh`. If the file is missing, all flags start blank/zero.

See [defaults.conf](../lib/configs/defaults.conf) for the full list of variables and their defaults.

## Config files

A config file is a bash file that sets variables. Pass it via `--config`:

```bash
./steamos-nvidia.sh --action build --config my-build.conf --image ...
```

### Example config

```bash
# steamos-nvidia.conf — copy and edit as needed

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

See [steamos-nvidia.example.conf](../steamos-nvidia.example.conf) for a full annotated example.

## Generate Config (GUI)

The **Generate Config** action in the GUI opens the same build form and saves the selected options to a `.conf` file. This is useful for:

- Saving a configuration you use repeatedly
- Sharing a build recipe with others
- Automating builds in scripts or CI

## Variables reference

| Variable | CLI flag | Default | Description |
|---|---|---|---|
| `IMG` | `--image` | *(required)* | Source image path |
| `UPDATE_MODE` | `--hold-updates` / `--no-hold-updates` | `selfheal` | Update strategy |
| `ADD_INSTALLER` | `--no-installer` | `1` | Include one-click installer |
| `TRIM_CUDA` | `--trim-cuda` | `0` | Drop CUDA/OpenCL libs |
| `BUILD_HW_SUPPORT` | `--hw-support` | `1` | Enable HW packages |
| `HW_SUPPORT_ITEMS` | `--hw-support-items` | `linux-firmware libfprint fprintd bolt dkms` | Which HW packages |
| `THUNDERBOLT` | `--thunderbolt` | `0` | Thunderbolt dock support |
| `DEBUG_BOOT` | `--debug-boot` | `0` | Verbose initramfs logging |
| `DEFAULT_SESSION` | `--session` | `""` | Login session mode |
| `ROOTFS_SIZE` | `--rootfs-size` | `""` (Valve default 5120) | Root partition size in MiB |
| `WORKDIR` | `--workingdir` | `""` | Explicit build directory |
| `WORKDIR_LOCATION` | `--workdir-location` | `auto` | Build location |
| `SKIP_SIG` | `--skip-sigcheck` | `0` | Disable pacman sig checks |
| `FIX_KEYRING` | `--fix-keyring` | `0` | Force-init pacman keyring |
| `INITRAMFS_MODULES` | `--initramfs` | `""` | Kernel modules for initramfs |
| `GAMING_ITEMS` | `--gaming-items` | *(see defaults.conf)* | System tweaks list |
| `ALLOW_SYSTEM_DISK` | `--allow-system-disk` | `0` | Allow flashing system disk |
