# Flash Pipeline

This document covers the flash pipeline — the path that writes a built image to a USB device. It's aimed at contributors and anyone wanting to understand the flash workflow internals.

## What it does

The flash pipeline takes a completed `.img` file and writes it byte-for-byte to a removable USB device using `dd`. It handles device discovery, safety validation, the write itself, post-write verification, GPT fixup, and partition discovery — all as a single orchestrated sequence.

Unlike the other pipelines (build, flashless, live, validate), flash does not mount, chroot into, or modify the image contents. It operates purely at the block-device level.

## What's unique to this pipeline

| Concern | Flash | Other pipelines |
|---|---|---|
| Writes raw bytes to a block device | Yes | No |
| Device scanning (`lsblk`) | Yes | No |
| System-disk safety check | Yes | No |
| Pre-flight image-vs-device comparison | Yes | No |
| SHA256 read-back verification | Yes | No |
| GPT backup header relocation | Yes | No |
| Post-flash partition discovery + mount | Yes | No |
| Loop/mount/chroot of the image | No | Yes (build, validate) |
| Package installation | No | Yes (build, live) |
| OverlayFS workspace | No | Yes (build) |

The flash pipeline is the only one that is inherently destructive — it overwrites the target device. Every other pipeline works on a copy or in an isolated namespace.

## Workflow

The flash pipeline is not a registered pipeline (no `register_*_pipeline` / `run_pipeline` loop). It's a linear sequence of function calls orchestrated by `backend_flash()` in `lib/backend.sh`, with the heavy lifting in `lib/flash.sh`.

### 1. Gate checks

`backend_flash()` enforces hard prerequisites before any work begins:

- **Root required** — `EUID` must be 0.
- **Explicit confirmation** — `--confirm` flag must be present. The flash action is destructive; the backend refuses to proceed without it.
- **Image and device specified** — both `--image` and `--device` are required.
- **Image validation** — `flash_validate_image()` checks the file exists. If the filename matches the `*nvidia*usbinstall*.img` pattern, a `.build-complete` sidecar marker must also exist; without it the image is rejected as incomplete.
- **System-disk protection** — `flash_is_system_disk()` walks the block-device ancestry of the running root filesystem (handling btrfs subvolumes, LUKS, LVM, device-mapper) and refuses to flash if the target is the system disk. Override with `--allow-system-disk`.

### 2. Device scanning

`flash_scan_devices()` enumerates all block devices via `lsblk --json` and filters to whole disks, excluding loop, zram, sr, nbd, and ram devices. For each candidate it prints a TSV line: device path, human-readable size, transport type, model name, and a `[removable]` tag if the kernel reports the device as removable.

This is exposed as the `list-devices` backend action and is used by the GUI to populate the device picker.

### 3. Image discovery

`flash_discover_images()` scans a set of well-known directories for completed images:

- Project directory
- `/home/image`
- `/dev/shm/steamos-build` (RAM build output)
- `~/Downloads`
- Explicit `OUTPUT_DIR` if set

It looks for files matching `*nvidia*usbinstall*.img` that have a corresponding `.build-complete` marker. Results are returned as TSV sorted by modification time (newest first), with location labels (e.g. "RAM build", "Persistent output").

This is exposed as the `list-images` backend action.

### 4. Pre-flight checks

`flash_preflight()` runs a comprehensive comparison between the image and the target device. It sets `IMG_BYTES`, `TARGET_BYTES`, and `TARGET_SERIAL` for downstream use.

**Image checks:**

- **Loop attachment** — detects if the image is currently attached to a loop device. Mounted children cause a hard stop. RW loops with no mounts are auto-detached. RO loops with no mounts are informational only.
- **GPT validation** — runs `sgdisk -v` against the image to verify the partition table is well-formed.
- **Partition identity** — expects exactly five named partitions: `esp`, `efi-A`, `rootfs-A`, `var-A`, `home`. Missing partitions cause a failure.
- **Quiesce** — `sync` is called to flush pending I/O before reading.

**Target checks:**

- **No mounts** — verifies neither the device nor any of its child partitions are mounted.
- **No holders** — checks for swap, LVM, dm-crypt, or RAID usage on the target.
- **Not the system disk** — re-verifies the target doesn't contain `/`, `/boot`, `/efi`, `/home`, or the build workspace.

**Capacity check:**

- Compares image size to device size. Fails if the image doesn't fit. Reports headroom if it does.

**Summary:**

- Prints a pass/fail count. If any check fails, the flash is aborted.

### 5. The write operation

`flash_write()` performs the actual `dd` write:

1. **Unmount** — all mountpoints on the target device and its child partitions are unmounted. No lazy unmounts — a lazy umount can leave the filesystem alive while processes still hold it, and `dd` would write over a live filesystem. A final recheck confirms nothing is still mounted.

2. **Source checksum** — `sha256sum` is computed on the image *before* writing, so verification compares against the exact source state intended to be flashed.

3. **Write** — `dd` writes the image with `bs=4M`, `conv=fsync`, and `oflag=sync`. Progress is reported via `@@PROGRESS:XX@@` markers for the GUI:
   - If `pv` is available: `pv` reads the image and pipes to `dd`, with progress percentages captured via a named pipe.
   - Fallback: `dd status=progress` output is parsed for byte counts and converted to percentages.

4. **Flush** — `sync` and `blockdev --flushbufs` ensure all data reaches the device before verification.

### 6. Read-back verification

`flash_verify_raw()` reads back exactly the image's byte count from the device and compares the SHA256 against the precomputed source hash. This runs *before* any post-write modifications (like GPT relocation) so it verifies the raw write was faithful.

### 7. GPT fixup

When the target device is larger than the image, the backup GPT header sits at the image-size boundary instead of the physical end of the disk. `sgdisk --move-second-header` relocates it to the correct position.

After relocation:
- `sync` and `blockdev --flushbufs` flush the changes.
- `blockdev --rereadpt` asks the kernel to re-read the partition table (advisory, not fatal).
- `udevadm settle` waits for udev to process the changes.
- `sgdisk -v` validates the relocated GPT.

If `sgdisk` is unavailable, a warning is printed with manual instructions.

### 8. Post-flash partition discovery

After the write and GPT fixup:

1. `udevadm settle` waits for the kernel to see the new partitions.
2. If no partitions appear, `partx -u` forces a partition table re-read.
3. Each partition is inspected via `blkid -s PARTLABEL` to confirm the kernel sees the expected labels.
4. The `home` partition is mounted at `/run/media/<user>/home` for immediate access.

If no partition labels are found at all, the function fails with a suggestion to run `partx -u` manually.

## Entry points

The flash pipeline is accessible through several backend actions:

| Action | Function | Purpose |
|---|---|---|
| `flash` | `backend_flash()` | Full write workflow (gates → write → verify → fixup → discover) |
| `list-devices` | `flash_scan_devices()` | Enumerate available USB targets |
| `list-images` | `flash_discover_images()` | Find completed images ready to flash |
| `is-system-disk` | `flash_is_system_disk()` | Check if a device is the running system |
| `preflight` | `flash_preflight()` | Run pre-flight checks without writing |
