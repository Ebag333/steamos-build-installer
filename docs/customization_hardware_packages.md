# Hardware Packages

The hardware support dialog lets you select which driver and firmware packages to bake into the image. Packages are defined in two manifest files and grouped by category.

## Manifest files

| File | Source | Purpose |
|---|---|---|
| `lib/configs/hw-packages-arch.conf` | Official Arch repos | NVIDIA drivers, firmware, VA-API |
| `lib/configs/hw-packages-valve.conf` | Valve's pacman repo | Biometrics, Thunderbolt, gaming tools, dev utilities |

## Package format

Each line follows the format:

```
group|package|version|default|description
```

- **group** — category label shown in the UI (e.g. `Firmware`, `NVIDIA`, `Gaming`)
- **package** — pacman package name
- **version** — `latest` resolves at build time, or pin a specific version
- **default** — `TRUE` or `FALSE` (pre-checked in the GUI)
- **description** — shown in the selection dialog

Lines starting with `#` are comments.

## Package groups

### Arch manifest (`hw-packages-arch.conf`)

| Group | What it covers | Example packages |
|---|---|---|
| **Firmware** | Full Linux firmware suite replacing Valve's Deck subset | `linux-firmware`, `linux-firmware-marvell` |
| **NVIDIA** | Open kernel module + userspace drivers | `nvidia-open-dkms`, `nvidia-utils`, `lib32-nvidia-utils` |
| **Video** | NVIDIA VA-API acceleration | `libva-nvidia-driver` |

### Valve manifest (`hw-packages-valve.conf`)

| Group | What it covers | Example packages |
|---|---|---|
| **Biometric** | Fingerprint reader support | `libfprint`, `fprintd` |
| **Thunderbolt** | Thunderbolt device management | `bolt` |
| **Build** | Kernel module build system | `dkms` |
| **Video** | Intel VA-API drivers | `intel-media-driver`, `libva-utils` |
| **Gaming** | Performance monitoring and Vulkan tools | `mangohud`, `lib32-mangohud`, `vulkan-tools` |
| **Dev** | Development tools | `git`, `python-pipx`, `qt6-base` |
| **System** | System services | `irqbalance` |

## Customizing

### Add a package

Add a line to the appropriate manifest:

```
# In hw-packages-arch.conf for Arch packages:
MyGroup|mypackage|latest|TRUE|Description of my package

# In hw-packages-valve.conf for Valve repo packages:
MyGroup|mypackage|latest|TRUE|Description of my package
```

### Remove a package

Either delete the line or set the default to `FALSE` so it's unchecked in the GUI:

```
Firmware|linux-firmware-qlogic|latest|FALSE|QLogic networked device firmware
```

### Pin a version

Replace `latest` with a specific version:

```
NVIDIA|nvidia-open-dkms|570.86.15|TRUE|NVIDIA open kernel module sources for DKMS
```

### Use via config file

Set `HW_SUPPORT_ITEMS` in your config file:

```bash
# In your build.conf:
HW_SUPPORT_ITEMS="linux-firmware nvidia-open-dkms nvidia-utils lib32-nvidia-utils libva-nvidia-driver"
```

## Notes

- `linux-firmware` replaces Valve's `linux-firmware-neptune-jupiter` (the Deck-specific subset). This is handled automatically during the build.
- The NVIDIA kernel module is built via DKMS against the image's exact kernel version in a throwaway chroot.
- All packages are verified for glibc compatibility with the image before installation.

## Post-install tweaking

The manifest files are copied into the installed system at `/usr/lib/steamos-nvidia/configs/`. During self-heal updates, repatch reads from these files to determine what to install. You can edit them on the installed system to pin versions or change the package set — see [OS Updates](os_updates.md) for details.
