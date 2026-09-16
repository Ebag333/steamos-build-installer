# Flashless Pipeline

The flashless pipeline writes a built NVIDIA image directly to the device's inactive A/B slot without requiring a USB stick. It operates entirely on the internal NVMe, making it the fastest path from build to bootable system.

## What it does

Given a completed build image, the flashless pipeline:

1. Identifies which A/B slot is currently active and which is inactive
2. Loop-mounts the built image and verifies it is a patched build
3. Formats the inactive slot's EFI and var partitions
4. Raw-copies the rootfs via `dd`, then randomizes its Btrfs UUID
5. Restores `/etc` state (update channel, user passwords) from the running system
6. Rebuilds the boot environment (GRUB, partsets, boot configuration) inside the target slot
7. Activates the target slot via RAUC so it boots on next restart

The running system is never interrupted. If the new slot fails to boot, SteamOS automatically falls back to the previous slot.

## What's unique to this pipeline

The flashless pipeline handles concerns that do not exist in the flash, live, or validate pipelines:

### A/B slot detection

The pipeline cross-checks two independent sources to determine which slot is active:

- `steamos-bootconf this-image` — the boot configuration layer
- `rauc status --output-format=json` — the RAUC update framework

If they disagree, or if RAUC reports an unrecognizable state, the pipeline refuses to proceed. The inactive slot becomes the target. All target device paths are resolved to canonical `/dev/...` paths immediately, before any loop device is created.

### Safety gates

Before any write occurs, the pipeline verifies:

- Current and target rootfs resolve to different block devices
- The currently booted slot is also the next-boot slot (no pending transition)
- None of the target partitions are currently mounted

### Loop-mount and build verification

The built image is attached as a loop device with `--partscan`. A udev guard rule is installed before the loop exists to prevent udisks2 from seeing the partitions. The pipeline identifies `rootfs-A` by GPT PARTLABEL, mounts it read-only, and verifies:

- The manifest variant matches the expected target variant
- The NVIDIA payload marker (`steamos-atomupd-client` wrapper) is present
- The source image's update branch is captured for later preservation

### Partset symlink management

When `--partscan` exposes the image's partitions, they temporarily compete with the real target partitions in `/dev/disk/by-partsets/`. The pipeline:

1. Freezes canonical device paths for the real target *before* creating the loop
2. Detaches the loop immediately after the rootfs write and verification
3. Retriggers udev on the real target partitions
4. Verifies that all partset symlinks (`rootfs`, `efi`, `var`) point back to the real target devices

### Btrfs UUID randomization

After the raw `dd` write and SHA256 verification pass, `btrfstune -f -u` randomizes the target rootfs UUID. This prevents two partitions on the same disk from sharing a UUID, which would confuse Btrfs device scanning. A `btrfs check --readonly` follows to confirm filesystem integrity.

### Password migration

The pipeline copies password hashes from `/etc/shadow` on the running system into the target rootfs via `chroot usermod`. This covers the `deck` account and any other UID >= 1000 users. Without this, the user would need to re-set their password after booting into the new slot.

### Boot environment rebuild

The target slot's EFI partition is freshly formatted and empty. The pipeline uses `steamos-chroot --no-overlay --partset <target>` to enter the target rootfs and:

1. Creates the EFI directory structure (`/efi/SteamOS`, `/esp/SteamOS/conf`)
2. Runs `steamos-partsets` to create partset symlinks
3. Runs `steamos-bootconf create` to write the slot's boot configuration
4. Rebuilds the GRUB binary via `grub-mkimage`
5. Runs `reconcile_grub` for authoritative kernel command line patching

### Btrfs ro property lifecycle

The freshly written rootfs may have the Btrfs `ro` property set to `true` (inherited from the source image). The pipeline clears it before any modifications, tracks that it was set, and restores it after all writes to the rootfs are complete. This ensures the rootfs returns to its expected read-only state for the running system.

### Cleanup trap machinery

Every temporary mountpoint, directory, and cleanup command is registered in ordered arrays. An EXIT trap handler tears everything down in reverse registration order:

- Mounts are unmounted (with `umount -R`, falling back to `umount -Rl`)
- Registered cleanup commands execute (e.g., removing udev rules)
- The loop device is detached
- Temporary directories are removed

Normal phase completion unmounts explicitly and unregisters from the arrays. The trap is the failure safety net.

## Workflow

The orchestrator `flashless_install()` runs 11 phases in sequence:

```
Phase 1   Detect + Safety
            ├─ flashless_detect_slots()
            │    Cross-check steamos-bootconf + RAUC
            │    Resolve canonical /dev paths for target partitions
            └─ flashless_safety_checks()
                 Verify current != target device
                 Verify no pending slot transition
                 Verify target partitions are not mounted

Phase 2   Extract Image
            ├─ flashless_extract_image()
            │    Install udev guard
            │    Loop-mount built image with --partscan
            │    Find rootfs-A by PARTLABEL
            │    Mount read-only, verify variant + NVIDIA markers
            │    Capture source update branch
            └─ flashless_check_sizes()
                 Source rootfs must fit in target partition

Phase 3   Format Target
            └─ flashless_format_target()
                 mkfs.vfat on target EFI
                 mkfs.ext4 on target var

Phase 4   Write Rootfs
            └─ flashless_write_rootfs()
                 SHA256 hash source
                 dd source → target (128M blocks, fsync)
                 SHA256 verify written data
                 btrfstune -f -u (randomize UUID)
                 btrfs check --readonly
                 Resize to fill partition if source was smaller

Phase 5   Detach Loop
            losetup -d (detach source image)
            udevadm trigger + settle (re-expose real target partitions)

Phase 6   Verify Partsets
            └─ flashless_verify_partsets()
                 Confirm /dev/disk/by-partsets/<target>/* symlink
                 back to the real target devices

Phase 7   Restore /etc
            └─ flashless_restore_etc()
                 Mount target rootfs rw
                 Clear Btrfs ro property (track for later restore)
                 Configure update channel (preserve source branch)
                 Migrate user passwords from running system
                 Persist project files to /home

Phase 8   Rebuild Boot
            └─ flashless_rebuild_boot()
                 steamos-chroot --no-overlay --partset <target>
                 Create EFI directory structure
                 steamos-partsets (partset symlinks)
                 steamos-bootconf create (boot entry)
                 grub-mkimage (EFI binary)
                 reconcile_grub (kernel command line)

Phase 9   Restore Btrfs ro
            └─ flashless_restore_rootfs_ro()
                 Re-mount target rootfs
                 Set Btrfs ro=true if it was originally set

Phase 10  Final Verify
            └─ flashless_verify_final()
                 Mount target rootfs ro, check variant
                 Mount target EFI ro, check grub.cfg + grubx64.efi + partsets
                 Check /esp/SteamOS/conf/<target>.conf exists

Phase 11  Activate Slot
            └─ flashless_activate_slot()
                 rauc status mark-active <rootfs.N>
                 Verify steamos-bootconf selected-image == target
```

After activation, the EXIT trap is cleared and the pipeline logs the final RAUC status. A reboot will boot into the newly written slot.
