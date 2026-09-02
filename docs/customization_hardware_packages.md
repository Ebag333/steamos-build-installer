# Hardware Packages

The hardware support dialog lets you select which driver and firmware packages to bake into the image. All packages are defined in a single unified manifest.

## Manifest file

| File | Purpose |
|---|---|
| `lib/configs/hw-packages.conf` | All hardware packages (pacman, build-recipe, flatpak) |

## Package format

Each line follows the format:

```
TYPE|group|package|version|default|description|recipe
```

- **TYPE** — `pacman`, `build-recipe`, or `flatpak`
- **group** — category label shown in the UI (e.g. `Firmware`, `NVIDIA`, `Gaming`)
- **package** — pacman package name, flatpak app ID, or module name
- **version** — `latest` resolves at build time, or pin a specific version (git ref for build-recipe)
- **default** — `TRUE` or `FALSE` (pre-checked in the GUI)
- **description** — shown in the selection dialog
- **recipe** — directory name under `lib/configs/build_recipes/` (only for build-recipe and flatpak)

Lines starting with `#` are comments.

## Package types

### `pacman`

Standard pacman packages installed from the image's configured repos. Examples:

| Group | What it covers | Example packages |
|---|---|---|
| **Firmware** | Full Linux firmware suite | `linux-firmware`, `linux-firmware-marvell` |
| **NVIDIA** | Open kernel module + userspace drivers | `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils` |
| **Biometric** | Fingerprint reader support | `libfprint`, `fprintd` |
| **Thunderbolt** | Thunderbolt device management | `bolt` |
| **Build** | Kernel module build system | `dkms` |
| **Video** | VA-API drivers | `intel-media-driver`, `libva-utils`, `libva-nvidia-driver` |
| **Gaming** | Performance monitoring and Vulkan tools | `mangohud`, `lib32-mangohud`, `vulkan-tools` |
| **Dev** | Development tools | `git`, `python-pipx`, `qt6-base` |
| **System** | System services | `irqbalance` |

### `build-recipe`

Packages built from source via PKGBUILD. Requires a recipe directory under `lib/configs/build_recipes/`. Example:

```
build-recipe|Build|logitech-hid|5841e54418d3fa2201753773dc79f2b3b8968675|FALSE|Logitech receiver and HID++ kernel modules|logitech-hid
```

### `flatpak`

Flatpak applications installed from Flathub. Requires a recipe directory. Example:

```
flatpak|Gaming|Recol/DLSS-Updater|latest|FALSE|DLSS Updater for NVIDIA GPUs|dlss-updater
```

## Customizing

### Add a package

Add a line to the manifest:

```
pacman|MyGroup|mypackage|latest|TRUE|Description of my package|
```

### Remove a package

Either delete the line or set the default to `FALSE` so it's unchecked in the GUI:

```
pacman|Firmware|linux-firmware-qlogic|latest|FALSE|QLogic networked device firmware|
```

### Pin a version

Replace `latest` with a specific version:

```
pacman|Nvidia|nvidia-open-dkms|570.86.15|TRUE|NVIDIA open kernel module sources for DKMS|nvidia-open-dkms
```

### Use via config file

Set `HW_SUPPORT_ITEMS` in your config file:

```bash
# In your build.conf:
HW_SUPPORT_ITEMS="linux-firmware nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver"
```

## Notes

- `linux-firmware` replaces Valve's `linux-firmware-neptune-jupiter` (the Deck-specific subset). This is handled automatically during the build.
- The NVIDIA kernel module is built via DKMS against the image's exact kernel version. If the DKMS hook fails, the system retries with `dkms autoinstall`, then falls back to the build recipe at `lib/configs/build_recipes/nvidia-open-dkms/`.
- All four NVIDIA modules are validated after build: `nvidia.ko`, `nvidia-modeset.ko`, `nvidia-drm.ko`, `nvidia-uvm.ko`. Vermagic is checked against the target kernel.

## Post-install tweaking

The manifest file is copied into the installed system at `/usr/lib/steamos-build/configs/`. During self-heal updates, repatch reads from this file to determine what to install. You can edit it on the installed system to pin versions or change the package set — see [OS Updates](os_updates.md) for details.
