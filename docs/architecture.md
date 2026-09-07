# Architecture

This document covers the build pipeline internals and library structure. It's aimed at contributors and anyone wanting to understand how the tool works under the hood.

## Directory structure

```
steamos-build.sh              # Frontend: CLI arg parsing + YAD GUI
lib/
├── backend.sh                 # Build/flash policy & orchestration
├── common.sh                  # Logging, failure reporting, loop/mount primitives
├── common_drivers.sh          # Driver helpers: kernel discovery, headers, payload, gaming tweaks
├── common_modules.sh          # Module helpers: kernel discovery, module verification, initramfs
├── common_system.sh           # System helpers: chroot mounts, depmod, ldconfig, nvidia services
├── setup.sh                   # Stage 1: workspace, image copy, loop mount, kernel discovery
├── overlay.sh                 # OverlayFS chroot management
├── rootfs-etc.sh              # Effective /etc overlay for SteamOS runtime
├── install-hw-libs.sh         # Package installation (Valve + Arch manifests)
├── installer.sh               # One-click desktop installer + boot log collector
├── grub.sh                    # GRUB/kernel command line management
├── update-strategy.sh         # selfheal / hold / stock update configuration
├── update-wrapper.sh          # Wrapper around steamos-update (logging)
├── atomupd-wrapper.sh         # Wrapper around steamos-atomupd-client (self-heal trigger)
├── repatch.sh                 # On-device driver rebuild after OS update
├── finalize.sh                # Sanity checks, cleanup, publish image
├── flash.sh                   # USB flash: device scanning, dd write, verification
├── flashless.sh               # Flashless install to inactive A/B slot
├── scan-hardware.sh           # PCI hardware scanning for diagnostics
├── check-deps.sh              # Host dependency checker/installer
├── pci-discovery.sh           # PCI device discovery for initramfs module selection
├── configs/                   # Configuration files bundled into the image
│   ├── defaults.conf          # Build flag defaults
│   ├── hw-packages.conf       # Hardware packages (pacman, build-recipe, flatpak)
│   ├── pipx-packages.conf    # Pipx package definitions
│   ├── pacman-arch.conf       # Arch pacman repo config (for tools)
│   ├── 99-nvidia-patch.conf   # modprobe: blacklist nouveau, enable KMS
│   ├── scx_loader_config.toml # scx_lavd scheduler config
│   ├── swappiness-zram.conf   # vm.swappiness=180
│   ├── swappiness-disk.conf   # vm.swappiness=10
│   ├── NVIDIA Setup.desktop   # Desktop shortcut
│   ├── thunderbolt-rescan.sh  # Thunderbolt PCI rescan script
│   ├── 98-thunderbolt-rescan.rules  # Thunderbolt udev rule
│   └── boot/                  # Boot-time performance hooks
│       ├── apply-boot         # Hook runner
│       ├── config.conf        # Hook configuration
│       ├── 20-nvidia-gpu      # GPU power limit hook
│       ├── 25-amd-gpu         # AMD GPU power limit hook
│       ├── 30-cpu             # CPU governor/EPP hook
│       └── steam-perf.service # systemd service
tools/                         # Development/analysis utilities
```

## Build pipeline

The build is orchestrated by `lib/backend.sh` (`backend_build()`), which calls library functions in order:

### Stage 1: Setup (`lib/setup.sh`)

1. **Resolve workspace** — auto-detect RAM vs disk based on available space and image size (parses GPT header for decompressed size)
2. **Copy/decompress image** — decompress `.img.bz2/.gz/.xz/.zst` to a `.building` working copy (original is never modified)
3. **Loop mount** — attach as loop device, install udev quarantine rule (prevents partset collision with running SteamOS)
4. **Mount partitions** — rootfs-A (btrfs), efi-A, home
5. **Discover kernel** — find neptune kernel version, locate exact-match headers URL from Valve's pool

### Stage 2: Prepare Rootfs

- Make the btrfs rootfs writable (clear RO property, handle seeding filesystem)
- Create a writable overlay for modifications

### Stage 3: Overlay Chroot (`lib/overlay.sh`)

- Create an ext4 loopback workspace image (8 GB)
- Mount OverlayFS with the image rootfs as lower, ext4 workspace as upper
- Mount proc/sys/dev/tmp for chroot operations
- Set up pacman config with persistent package cache

### Stage 4: Install Drivers (`lib/install-hw-libs.sh`)

- Install packages from Valve manifest (Valve repos)
- Install packages from Arch manifest (official Arch repos) with glibc compatibility check
- NVIDIA kernel module built via DKMS hook (or forced `dkms autoinstall`)
- Build custom Logitech HID modules if selected (from upstream Linux source)

### Stage 5: Gaming Tweaks & Configuration (`lib/common_drivers.sh`)

- Apply kernel parameters via `add_kernel_param()`
- Configure gamemode, scx_lavd scheduler, vm.swappiness
- Install boot-time performance hooks (CPU governor, GPU power limit)
- Install Thunderbolt support (udev rule + bolt service)
- Configure update channel (variant + branch, OOBE suppression)
- Install pipx packages
- Run custom script if present at `/home/.steamos-build/recovery/custom.sh`

### Stage 6: Payload & Installer (`lib/installer.sh`)

- Compute payload (diff before/after package snapshots)
- Copy payload from overlay to image rootfs
- Register packages in image's pacman database
- Configure initramfs if user selected custom modules
- Inject boot log collector (systemd service)
- Install one-click desktop installer
- Write build manifest into rootfs

### Stage 7: GRUB & Update Strategy

- **GRUB** (`lib/grub.sh`): Patch `/etc/default/grub-steamos` (persistent defaults) and directly patch EFI `grub.cfg` (authoritative). Validates all params landed.
- **Update Strategy** (`lib/update-strategy.sh`): Configure selfheal, hold, or stock mode.

### Stage 8: Finalize (`lib/finalize.sh`)

- Verify nvidia-utils, lib32-nvidia-utils, linux-firmware in pacman DB
- Verify all nvidia kernel modules resolve to `/updates/` (not stock)
- Cross-check module version matches pacman package
- Verify self-heal machinery is in place
- Sync filesystems, unmount everything
- Rename `.building` to final output, write `.build-complete` marker

## Key design decisions

### Mount namespace isolation

Builds run in a private mount namespace (`unshare --mount --propagation private`) so loop devices, OverlayFS, and chroot mounts never leak into the desktop session.

### Image immutability

The original recovery image is never modified. A `.building` copy is created and worked on; it's renamed to the final output only after all stages pass.

### Self-heal interception

The self-heal mechanism works by replacing `steamos-atomupd-client` with a wrapper. The wrapper:
1. Runs Valve's original client
2. Detects if a new OS version was staged on the inactive A/B slot
3. Runs `repatch.sh` to rebuild the NVIDIA driver on the staged rootfs
4. If repatch fails, invalidates the staged update (fail-safe)

The wrapper propagates itself into the new slot so the next update is also intercepted.

### Build manifest

A manifest is written to `/usr/lib/steamos-build/build.conf` inside the image. It records:
- Build timestamp
- NVIDIA driver version
- Kernel version
- All build flags used
- Source image fingerprint

This manifest is used by the flashless installer to verify the image is an NVIDIA build, and by repatch to know what to reconcile.

## Log files

### Build-time (host machine)

Logs are written to a temporary directory under `/tmp/steamos-build.XXXXXX/`. The GUI shows the log path when the build completes.

### Runtime (installed system)

| Path | Contents |
|---|---|
| `/home/.steamos-build/logs/atomupd-*.log` | Self-heal atomupd wrapper logs |
| `/home/.steamos-build/logs/atomupd-latest.log` | Symlink to most recent atomupd log |
| `/home/.steamos-build/logs/update-*.log` | steamos-update wrapper logs |
| `/home/.steamos-build/logs/update-latest.log` | Symlink to most recent update log |
| `/home/.steamos-build/recovery/custom.sh` | User custom script (runs during build + repatch) |
| `/usr/lib/steamos-build/build.conf` | Build manifest |
