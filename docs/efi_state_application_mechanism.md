# Unified EFI State Application Mechanism — Comprehensive Test Plan

## 1. Overview

### Design Goal

A single function (`apply_efi_state`) that takes a scenario descriptor and applies the correct EFI state to the target, replacing four divergent code paths currently spread across `pipeline_build.sh`, `pipeline_rebuild.sh`, `flashless.sh`, and `pipeline_live.sh`.

### Scenario Descriptor Contract

```
apply_efi_state SCENARIO ROOTFS_MOUNT TARGET_EFI_MOUNT ESP_MOUNT SLOT_LABEL [SOURCE_EFI_MOUNT]
```

| Parameter | Required | Description |
|-----------|----------|-------------|
| `SCENARIO` | Yes | One of: `build`, `recovery`, `flashless`, `live` |
| `ROOTFS_MOUNT` | Yes | Path to the target rootfs mount point |
| `TARGET_EFI_MOUNT` | Yes | Path to the target EFI mount point (function owns mount/unmount) |
| `ESP_MOUNT` | Yes | Path to the shared ESP mount point (contains `/esp/SteamOS/conf/`) |
| `SLOT_LABEL` | Yes | Target slot letter (`A` or `B`); caller resolves, function verifies against mounted rootfs and target partition |
| `SOURCE_EFI_MOUNT` | No | Path to source EFI mount point (only for flashless, when copying allowlisted static artifacts) |

### Scenario Matrix

| Scenario | ROOTFS_MOUNT | TARGET_EFI_MOUNT | ESP_MOUNT | SLOT_LABEL | SOURCE_EFI_MOUNT | Mutates Opposing Slot Artifacts? |
|----------|-------------|------------------|-----------|------------|------------------|--------------------------------|
| Build | `$MNT` | loop-mounted image EFI | `$MNT/esp` | A (only — single-slot build artifact) | N/A | No — single-slot image |
| Recovery | `$NEWROOT` | current slot's EFI | `/esp` | Current | N/A | No — preserve opposing slot's EFI and `<other>.conf` |
| Flashless | temp mount of target rootfs | target (standby) slot's EFI | `/esp` | Standby (opposite of booted) | source image's EFI | Yes — write to standby slot's EFI; preserve active slot's EFI and `<other>.conf` |
| Live | `/` | currently mounted `/efi` | `/esp` | Current | N/A | No — preserve opposing slot's EFI and `<other>.conf` |

---

## 2. Preflight Validation Tests

These tests verify that the unified function refuses to proceed when preconditions are not met. Every preflight check is scenario-agnostic except where noted.

### 2.1 Rootfs Target Validation

Unless specified otherwise, every test uses a valid, mounted, writable rootfs fixture.

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-01 | Rootfs path exists | `ROOTFS_MOUNT=/nonexistent` | `die()` — "target root not found" |
| PF-02 | Rootfs path is a directory | `ROOTFS_MOUNT` points to a regular file | `die()` — "target root is not a directory" |
| PF-03 | Rootfs is actually mounted | Rootfs-looking directory with no filesystem mounted on it | `die()` — "target root is not mounted" |
| PF-04 | Rootfs contains readable os-release | Both `/etc/os-release` and `/usr/lib/os-release` are missing or unreadable | `die()` — "does not look like a rootfs" |
| PF-05 | Rootfs is writable | Valid rootfs mounted read-only or a read-only Btrfs subvolume | `die()` — "rootfs is not writable" |

**Implementation notes:**
- Canonicalize `ROOTFS_MOUNT` before checking it.
- Accept `/etc/os-release` as a symlink to `/usr/lib/os-release`.
- Don't rely only on `[[ -w ... ]]`; root can bypass ordinary permission bits. Check mount options and perform a real temporary-file creation, ideally under `$ROOTFS_MOUNT/etc`, with guaranteed cleanup.
- Use an isolated loopback/Btrfs fixture for PF-05 rather than remounting a real filesystem read-only.

### 2.2 EFI Device Validation

**Mount ownership modes:**
- **Temporary**: the function creates and owns a private mount.
- **Existing**: the function reuses an existing mount (e.g., `/efi` in Live scenario) after verifying it is the requested device and is writable.

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-06 | EFI device is a block device | `EFI_DEVICE=/dev/null` | `die()` — "EFI target is not a block device" |
| PF-07 | EFI filesystem type is supported | Block device containing ext4 or Btrfs | `die()` — "EFI target is not FAT" |
| PF-08 | EFI device matches target slot | Device does not match the target slot's expected EFI PARTUUID | `die()` — "EFI device does not belong to target slot" |
| PF-09 | Temporary mountpoint is safe | `EFIMNT` already mounted or nonempty | `die()` — "refusing to stack or hide files with EFI mount" |
| PF-10 | Device is not mounted elsewhere | Temporary mode with the same device already mounted | `die()` — "EFI device is already mounted" |
| PF-11 | Existing mount is correct | Existing mode, but `EFIMNT` is backed by a different device | `die()` — "EFI mount does not match target device" |
| PF-12 | Existing mount is writable | Existing mode with `/efi` mounted read-only | `die()` — "EFI mount is not writable" |
| PF-13 | EFI device is mountable | Valid FAT partition in temporary mode | Pass; private `EFIMNT` mounted read-write |
| PF-14 | Corrupt EFI is rejected | Zeroed or corrupt partition | `die()` — "could not mount EFI"; no mount left behind |
| PF-15 | Mounted EFI accepts writes | Mount succeeds but temporary-file creation fails | `die()` — "EFI filesystem is not writable" |

**Implementation details:**
- Canonicalize `/dev/disk/by-partsets/...` symlinks and compare devices by major/minor number or PARTUUID, not pathname.
- Use a private `mktemp -d` mountpoint in temporary mode.
- Install cleanup traps before attempting the mount.
- Do not automatically format or repair a corrupt partition during validation.
- Verify FAT with `blkid`, but treat a successful read-write mount and temporary-file test as authoritative.

### 2.3 Generation Prerequisite Validation

Source artifacts (`grub.cfg`, `grubx64.efi`, `partsets/`) are **not portable** — they contain source-specific UUIDs and PARTUUIDs. Their absence should not prevent target generation.

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-16 | Target rootfs UUID is available | `blkid` cannot resolve the deployed rootfs UUID | `die()` — "could not determine target rootfs UUID" |
| PF-17 | UUID mutation is complete | Rootfs UUID changes after boot-artifact generation begins | `die()` or ordering-test failure — generation must follow `btrfstune -u` |
| PF-18 | GRUB binary generator is available | `grub-mkimage` missing or not executable in target rootfs | `die()` — "GRUB EFI generator unavailable" |
| PF-19 | GRUB platform files are available | Required x86_64 EFI modules/configuration missing | `die()` — "GRUB EFI platform files unavailable" |
| PF-20 | GRUB config generator is available | `update-grub` missing or not executable | `die()` — "GRUB configuration generator unavailable" |
| PF-21 | Boot payload exists | No usable kernel/initramfs pair under target `/boot` | `die()` — "target boot payload incomplete" |
| PF-22 | Partset generator is available | `steamos-partsets` missing or not executable | `die()` — "partset generator unavailable" |
| PF-23 | Bootconf manager is available | `steamos-bootconf` missing or not executable when shared ESP state is managed | `die()` — "bootconf manager unavailable" |

**Optional static source artifacts (if allowlisted copy is retained):**

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-24 | Optional static source artifacts available | Source EFI missing or incomplete | Warn and skip static copy; continue with generation |
| PF-25 | Source copy follows allowlist | Source contains `grub.cfg`, `grubx64.efi`, or `partsets/` | Those target-specific paths are excluded from copy |

**Note:** Validation that the built image itself contains `grub.cfg`, `grubx64.efi`, and `partsets` still makes sense — but as Build post-generation validation, not as a prerequisite for applying EFI state in every scenario.

### 2.4 Scenario-Specific Preflight

| ID | Test | Scenario | Check | Expected Result |
|----|------|----------|-------|-----------------|
| PF-26 | Required privileges | All | `EUID != 0` | `die()` — "requires root" |
| PF-27 | Build target is unambiguous | Build | Exactly one `efi-A` cannot be identified | `die()` — "cannot uniquely identify build EFI" |
| PF-28 | Build partitions belong to same image | Build | `rootfs-A` and `efi-A` resolve to different backing images | `die()` — "build partitions do not belong to the same image" |
| PF-29 | Flashless current-slot sources agree | Flashless | `steamos-bootconf this-image` disagrees with RAUC's booted slot | `die()` — "current-slot sources disagree" |
| PF-30 | Flashless target is standby | Flashless | Target slot equals the booted slot, or target devices alias booted-slot devices | `die()` — "refusing to overwrite booted slot" |
| PF-31 | Flashless target EFI mount state | Flashless | Target EFI is already mounted while temporary-mount mode is requested | `die()` — "target EFI is already mounted" |
| PF-32 | Flashless has no pending transition | Flashless | `selected-image != this-image` | `die()` — "pending slot transition" |
| PF-33 | Flashless slot values are valid | Flashless | Current or target slot is not exactly `A` or `B` | `die()` — "invalid slot identity" |
| PF-34 | Recovery target explicitly identified | Recovery | Target installed slot cannot be resolved independently of the recovery environment | `die()` — "cannot determine recovery target slot" |
| PF-35 | Recovery target devices agree | Recovery | Target rootfs, EFI, and partset records do not identify the same installed slot/disk | `die()` — "recovery target identity mismatch" |
| PF-36 | Live identity sources agree | Live | RAUC, bootconf, mounted `/`, and mounted `/efi` do not resolve to the same slot | `die()` — "live slot identity mismatch" |

**Notes:**
- "Active slot" means the **currently booted slot**, not RAUC's activated slot (which can differ during pending transitions).
- Recovery must **not** rely on unscoped host-side `steamos-bootconf this-image`. Either require the operator/caller to provide the target slot explicitly, or query using the mounted installed system's explicit `--conf-dir` and `--efi-dir`.
- For Build, define a policy for unexpected `efi-B`: either **strict format** (fail, since build format currently supports only A) or **scoped mutation** (permit but guarantee only `efi-A` is touched). Silently assuming it does not exist is the risky option.

### 2.5 Shared ESP Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-37 | Shared ESP identity | `/esp` does not resolve to the expected shared ESP PARTUUID | `die()` — "shared ESP identity mismatch" |
| PF-38 | Shared ESP filesystem | Shared ESP is not FAT, not mounted as expected, or not writable | `die()` — "shared ESP filesystem invalid" |
| PF-39 | EFI/ESP separation | Target per-slot EFI and shared ESP resolve to the same block device unexpectedly | `die()` — "EFI and ESP are the same device" |

### 2.6 System Identity Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-40 | SteamOS identity | `os-release` exists, but the target is not a supported SteamOS variant/architecture | `die()` — "unsupported SteamOS variant" |
| PF-41 | Complete partition topology | Required rootfs, EFI, VAR, or shared partitions are missing for that scenario | `die()` — "incomplete partition topology" |
| PF-42 | Partition consistency | `PARTLABEL`, partset name, `PARTUUID`, and actual device disagree | `die()` — "partition identity inconsistency" |
| PF-43 | Cross-slot aliasing | A and B entries resolve to the same device or PARTUUID | `die()` — "A and B resolve to same device" |
| PF-44 | Current-slot map | Current `/efi/SteamOS/partsets/{A,B,self,other}` is malformed or points at nonexistent devices | `die()` — "current partset map invalid" |

### 2.7 Rootfs Filesystem Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-45 | Rootfs filesystem | Target rootfs is not the expected Btrfs filesystem | `die()` — "rootfs is not Btrfs" |
| PF-46 | Rootfs UUID available | Target rootfs UUID cannot be resolved after deployment | `die()` — "cannot determine rootfs UUID" |
| PF-47 | Rootfs UUID uniqueness | Target rootfs UUID duplicates the current/source rootfs UUID after `btrfstune -u` | `die()` — "rootfs UUID not unique" |
| PF-48 | UUID finalization ordering | Boot generation is requested before UUID randomization is complete | `die()` — "UUID not finalized before boot generation" |

### 2.8 Chroot Mount Wiring Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-49 | Destination mount wiring | Chroot `/efi` or `/esp` is not backed by the exact expected device | `die()` — "chroot mount wiring mismatch" |

### 2.9 Command Availability Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-50 | Required commands | Target rootfs lacks `grub-mkimage`, `update-grub`, `steamos-partsets`, or `steamos-bootconf` | `die()` — "required commands unavailable" |
| PF-51 | SteamOS GRUB support | Required SteamOS GRUB modules/configuration, especially `steamenv`, are unavailable | `die()` — "SteamOS GRUB support unavailable" |
| PF-52 | Boot input coherence | No kernel/initramfs pair exists under the target `/boot` | `die()` — "boot payload incomplete" |

### 2.10 Resource and Concurrency Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-53a | Target EFI free space | Target EFI lacks space for new + temporary + rollback artifacts simultaneously | `die()` — "insufficient target EFI space" |
| PF-53b | Rootfs workspace free space | Filesystem backing generation workspace or TMPDIR lacks space | `die()` — "insufficient rootfs workspace space" |
| PF-53c | Shared ESP free space | Shared ESP lacks space for bootconf files and temporary copies | `die()` — "insufficient shared ESP space" |
| PF-54a | Exclusive installer lock acquired | Another installer invocation holds the flock | `die()` — "installer lock held by another process" |
| PF-54b | No unexpected secondary mounts | Target device is multiply mounted or mounted by unexpected users | `die()` — "unexpected secondary mount detected" |
| PF-54c | RAUC is idle and state stable | RAUC is mid-transition, mid-update, or state changes during lock acquisition | `die()` — "RAUC is not idle" |

### 2.13 Filesystem State Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-60 | No active Btrfs operations | Active balance, device replace, or UUID change in progress | `die()` — "Btrfs operation in progress" (ordinary scrub need not block) |
| PF-61 | Target verity device is inactive | Target verity device is active, mounted, or opened through device-mapper | `die()` — "verity device is active" |
| PF-62 | Verity update policy defined | Rootfs modified but no post-write verity policy selected | `die()` — "verity update policy not defined" (must choose: regenerate, disable, or leave invalid) |
| PF-63 | Kernel/initramfs pair exists | No coherent kernel/initramfs pair under target `/boot` | `die()` — "boot payload incomplete" |
| PF-64 | Source image integrity verified | Source image checksum invalid or read-only mount fails | `die()` — "source image integrity check failed" |

### 2.11 Path Safety Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-55 | Unsafe destination path | `/efi`, `/esp`, or a managed destination is a symlink or escapes its expected mount | `die()` — "unsafe destination path" |
| PF-56 | Interrupted transaction | Stale `.new`, backup, or transaction-marker files exist without a defined recovery policy | `die()` — "stale transaction detected" |

### 2.12 Bootconf Policy Validation

| ID | Test | Input | Expected Result |
|----|------|-------|-----------------|
| PF-57 | Bootconf reset policy | Target `<slot>.conf` exists but the requested operation is only `steamos-bootconf create` | `die()` — "create will not reset existing config" |
| PF-58 | Current bootconf health | Current-slot config is missing or cannot be parsed | `die()` — "current bootconf invalid" |
| PF-59 | Secure Boot compatibility | Secure Boot is enabled but the regenerated binary cannot be appropriately signed | `die()` — "Secure Boot signing unavailable" |

**Key enforcement points:**

**UUID generation barrier** — The function must enforce this ordering:
```
rootfs copied → btrfstune UUID change → new UUID independently read →
UUID uniqueness confirmed → GRUB generation permitted
```
Treat "UUID finalized" as an explicit phase transition, not merely an assumption by the caller.

**Chroot mount wiring** — Before executing anything in the target rootfs, verify:
- `$ROOTFS_MOUNT/efi` → target slot EFI device
- `$ROOTFS_MOUNT/esp` → shared ESP device
- `$ROOTFS_MOUNT/` → target rootfs device

Compare actual device identities, not directory names. A successful chroot with an incorrectly mounted `/efi` is one of the easiest ways to update the wrong slot.

**Bootconf create trap** — This deserves its own preflight:
- `target conf exists + create-only plan = refuse to continue`

The caller must select an intentional reset/update policy before mutation begins.

**Execution-order requirements** (not preflights, but must be enforced during generation):
```
btrfstune completes → udevadm settle --timeout=... completes →
devices and UUIDs are re-resolved → GRUB generation begins
```

**Cleanup traps and signal handling** — These are mandatory transaction tests, not runtime preflights. They should be verified through code structure and failure-injection testing.

### 3.1 Scenario: Build

**Context:** Chroot into an offline image containing one bootable slot: rootfs-A, its per-slot efi-A, and a shared ESP. The rootfs UUID is finalized. The build generates slot-A metadata but performs no A/B selection or RAUC activation.

```
apply_efi_state \
  --scenario build \
  --root "$MNT" \
  --efi-device "$EFI_LOOP" \
  --esp-device "$ESP_LOOP" \
  --slot A
```

| ID | Test | Preconditions | Actions | Assertions |
|----|------|--------------|---------|------------|
| B-01 | Happy path | Valid finalized rootfs-A, efi-A, and shared ESP | Apply build state | All generated artifacts pass semantic validation |
| B-02 | EFI binary generated correctly | Target rootfs contains SteamOS GRUB toolchain | Apply | Binary is nonempty, valid x86-64 EFI, and contains finalized target rootfs UUID |
| B-03 | GRUB configuration generated correctly | Known kernel, initramfs, UUID, and added parameters | Apply | Entries use target UUID; referenced boot files exist; every Linux entry contains each required parameter exactly once |
| B-04 | Partsets contain target identities | Known image GPT layout | Apply | Partsets are regular files containing exact target PARTUUIDs; no source or unknown PARTUUID remains |
| B-05 | Slot-A bootconf created | Fresh shared ESP | Apply | `A.conf` exists, is parseable by `steamos-bootconf`, and contains the defined build-state values |
| B-06 | Persistent defaults patched | Existing GRUB defaults | Apply | All required parameters appear exactly once; unrelated settings remain unchanged; file remains valid shell syntax |
| B-07 | Atomic-update keep-list populated | Existing keep-list entries | Apply | Required GRUB files are retained exactly once and unrelated entries remain unchanged |
| B-08 | Function-owned EFI/ESP mounts cleaned | Function creates temporary mounts | Apply | EFI and ESP temporary mountpoints are gone; caller-owned `$MNT` remains mounted |
| B-09 | Function-owned chroot mounts cleaned | No preexisting chroot bind mounts | Apply | `$MNT/{proc,sys,dev,dev/pts,run}` contain no function-created mounts |
| B-10 | Runtime GRUB failure cleans up | Executable `grub-mkimage` shim exits 42 | Apply | Nonzero result, all function-owned mounts removed, partial outputs removed or rolled back |
| B-11 | Application is idempotent | Successful initial application | Apply a second time | No duplicated parameters or keep-list entries; semantic state and artifact hashes remain stable where reproducibility permits |
| B-12 | Existing state survives failed replacement | Valid existing EFI artifacts; injected failure after staging | Apply | Previously valid files remain intact; no truncated final-path file appears |
| B-13 | Host isolation | Record host GRUB/default-file hashes | Apply to image | No host `/etc`, `/boot`, `/efi`, or `/esp` artifact changes |
| B-14 | Unmanaged EFI files preserved | EFI contains unrelated sentinel files | Apply | Sentinel files remain byte-identical |
| B-15 | No nonexistent slot emitted | Single-slot build fixture | Apply | No partset or bootconf entry incorrectly references a nonexistent B slot |

**Note:** For B-02, the critical assertion is: finalized target UUID present in `grubx64.efi`, old/source UUID absent. The same old-UUID-absent assertion belongs in B-03 for `grub.cfg`.

### 3.2 Scenario: Recovery (Repatch)

**Context:** Chroot into the offline rootfs staged by an OS update. The target is the selected inactive slot, while the currently booted slot remains untouched. The update has already finalized the target rootfs UUID. Repatch regenerates target boot artifacts but does not activate, mark-good, or reset bootconf state; the outer update workflow owns those transitions.

```
apply_efi_state \
  --scenario recovery \
  --root "$STAGED_ROOT" \
  --efi-device "$TARGET_EFI" \
  --esp-device "$ESP_DEVICE" \
  --slot B
```

| ID | Test | Preconditions | Actions | Assertions |
|----|------|--------------|---------|------------|
| R-01 | Staged-slot happy path | Current=A, staged=B, target rootfs and EFI available | Apply recovery state | B binary/config match B UUID and kernel; parameters present |
| R-02 | Rollback slot preserved | Current=A, both slots exist | Apply to B | `efi-A` and `A.conf` byte-identical |
| R-03a | Validated update-grub fallback | `update-grub` fails; existing config has target UUID and current kernel/initramfs paths | Apply | Direct parameter patch succeeds; complete final validation passes |
| R-03b | Stale existing config rejected | `update-grub` fails; existing config references old UUID or kernel | Apply | Hard fail; previous artifacts retained; slot not activated |
| R-03c | Missing tool caught early | `update-grub` absent before mutation | Preflight | No mounts or files changed |
| R-04 | Target binary regenerated | Recovery with complete chroot | Apply | Valid EFI binary contains B rootfs UUID and not A's UUID |
| R-05 | Target GRUB config regenerated | Known kernel, initramfs, UUID | Apply | B UUID and kernel paths correct; every Linux entry contains required parameters |
| R-06 | Target partsets regenerated | Known GPT layout | Apply | `self` resolves to B, `other` to A, and all PARTUUIDs match actual partitions |
| R-07 | Persistent defaults reconciled | Existing GRUB defaults | Apply | Only B rootfs files changed; parameters present exactly once |
| R-08 | Bootconf ownership respected | Existing `B.conf` | Apply | Target config preserved unless caller explicitly authorizes a state transition |
| R-09 | Filesystems flushed | Recovery with writes | Apply | Rootfs, target EFI, and shared ESP flushed independently before normal unmount |
| R-10 | Runtime failure rolls back | Injected failure after staging | Apply | Prior artifacts survive; no partial final-path files; no slot-state transition |
| R-11 | Non-target isolation | Current=A, target=B | Apply to B | No writes to A rootfs, `efi-A`, or `A` bootconf |
| R-12 | Repatch idempotency | Successful initial application | Apply a second time | No duplicate parameters or bootconf mutations |

**Bootconf ownership model:**
- Preferred: `apply_efi_state` preserves `B.conf`; the outer repatch workflow clears `image-invalid` or activates B only after all validation succeeds.
- Alternative: `apply_efi_state` owns finalization and changes `image-invalid: 1` to `0` as its final transactional step.

It should not silently leave `image-invalid: 1` while reporting the whole deployment complete, nor clear it before boot artifacts have passed validation.

**Verity assertion:** Modifying an OTA-staged rootfs may invalidate its paired verity data. This scenario must assert that verity is regenerated, deliberately disabled, or left invalid with activation blocked.

### 3.3 Scenario: Flashless

**Context:** Deploy to the standby slot after its rootfs UUID has been randomized and finalized. Reuse the existing target EFI filesystem when it is valid. Formatting is an explicit fallback for an invalid/unusable FAT filesystem. Modify only the target slot's rootfs/EFI and its shared-ESP bootconf entry. Activation remains outside `apply_efi_state`.

```
apply_efi_state \
  --scenario flashless \
  --root "$STAGED_ROOT" \
  --efi-device "$TARGET_EFI" \
  --esp-device "$ESP_DEVICE" \
  --slot B \
  --source-efi "$SOURCE_EFI"
```

| ID | Test | Preconditions | Actions | Assertions |
|----|------|--------------|---------|------------|
| F-01 | Standby deployment happy path | Current=A, staged=B, valid efi-B exists | Apply flashless state | B binary/config, partsets, persistent defaults, and bootconf reach the intended state |
| F-02 | Active-slot isolation | Current=A, both slots exist | Apply to B | A rootfs, `efi-A`, and `A.conf` remain content-identical |
| F-03 | Target partsets correct | Known GPT layout | Apply | Regular files contain exact target PARTUUIDs; `self`=B, `other`=A; no source-image identifiers remain |
| F-04 | Target EFI binary valid | Target rootfs with finalized UUID | Apply | Valid x86-64 EFI executable; contains B rootfs UUID; contains neither A nor source-image UUID |
| F-05 | Target GRUB configuration valid | Known kernel, initramfs, UUID | Apply | Every search/menu entry uses B UUID; kernel/initramfs paths exist; required parameters occur exactly once |
| F-06 | Missing B bootconf initialized | No prior `B.conf` | Apply | New `B.conf` is parseable and begins in the defined non-bootable staging state |
| F-07 | Existing B bootconf handled explicitly | Prior `B.conf` exists | Apply | Existing file is backed up and deliberately reset/updated; stale fields cannot survive through `create` |
| F-08 | Valid target EFI preserved | Valid existing efi-B | Apply | No `mkfs` invocation; unmanaged sentinel files remain unchanged |
| F-09 | Formatting fallback constrained | Invalid target FAT plus explicit format authorization | Apply | Formats only `efi-B`; GPT PARTUUID remains unchanged |
| F-10 | Activation occurs last | All validations pass | Apply + activate | Only after all validations pass is B made valid/active; RAUC's B mapping is verified before invoking activation |
| F-11 | Validation failure blocks activation | Injected validation failure | Attempt activation | No `mark-active` call; selected slot remains A; B remains invalid; A remains untouched |
| F-12 | On-disk partsets independently verified | Apply completes | Mount `efi-B` and inspect | `$TARGET_EFI_MOUNT/SteamOS/partsets/{B,self,other,all,shared}` parsed; contained PARTUUIDs resolved through `/dev/disk/by-partuuid` |
| F-13 | Btrfs property restored | Target rootfs had `ro=true` | Apply (success or failure) | Original read-only property restored after success and every injected failure |
| F-14 | Verity policy completed | Target verity device | Apply + activate | B's verity data regenerated/disabled as designed before activation |
| F-15 | Runtime failure preserves rollback | Injected failure after staging | Apply | Previous valid B artifacts restored or B left explicitly invalid; temporary mounts/files removed |

**Bootconf staging sequence:**
```
Create/reset B.conf as invalid
→ generate all B artifacts
→ validate binary, config, partsets, kernel, UUID and verity
→ make B.conf bootable
→ activate B through RAUC
```
This prevents a partially generated slot from becoming selectable.

**F-04/F-05 assertion detail:** Instead of checking `root=` parameter, assert:
- All `search --fs-uuid` entries use the B rootfs UUID
- All UUID-bearing menu IDs use the B rootfs UUID
- B rootfs UUID is embedded in `grubx64.efi`
- Old/source/A UUIDs are absent from both artifacts

**F-12 methodology:** Do not validate using the live `/dev/disk/by-partsets/B` tree. Mount the target EFI directly and inspect:
- `$TARGET_EFI_MOUNT/SteamOS/partsets/B`
- `$TARGET_EFI_MOUNT/SteamOS/partsets/self`
- `$TARGET_EFI_MOUNT/SteamOS/partsets/other`
- `$TARGET_EFI_MOUNT/SteamOS/partsets/all`
- `$TARGET_EFI_MOUNT/SteamOS/partsets/shared`

Then resolve each recorded PARTUUID independently. That proves the newly written state rather than merely proving the active A environment already knows where B is.

### 3.4 Scenario: Live

**Context:** Operate directly on the currently booted slot after verifying that `/`, `/efi`, RAUC, and bootconf all identify the same slot. Reuse the existing `/efi` and `/esp` mounts and leave them mounted. Modify current-slot GRUB state only; do not modify partsets, bootconf selection state, RAUC state, or the opposing slot.

```
apply_efi_state \
  --scenario live \
  --root / \
  --efi-device /efi \
  --esp-device /esp \
  --slot A
```

**Recommended flow:**
```
Patch persistent defaults
→ run update-grub directly
→ authoritatively patch generated EFI grub.cfg
→ validate grub.cfg and grubx64.efi
→ flush modified filesystems
```

Whether Live mode regenerates `grubx64.efi` should be an explicit policy:
- Rebuild it atomically if GRUB packages changed.
- Otherwise preserve it, but validate that it contains the current rootfs UUID.

| ID | Test | Preconditions | Actions | Assertions |
|----|------|--------------|---------|------------|
| L-01 | Current-slot happy path | Running system, `/efi` and `/esp` mounted, slot identity verified | Apply live state | Current `grub.cfg` contains correct UUID, kernel paths, and required parameters |
| L-02 | Opposing slot isolation | Current=A, both slots exist | Apply to A | Opposing rootfs and EFI remain unchanged; opposing bootconf remains byte-identical |
| L-03 | No chroot operations | Live scenario | Apply | No chroot, proc mount, sys bind, dev bind, or temporary EFI mount occurs |
| L-04 | Persistent defaults patched | Existing GRUB defaults | Apply | `/etc/default/grub` and `grub-steamos` contain every required parameter exactly once |
| L-05 | Atomic-update persistence maintained | Existing keep-list entries | Apply | Required defaults appear exactly once in the keep-list |
| L-06 | update-grub runs directly | Defaults patched | Apply | Called against the running root after defaults are patched |
| L-07 | Authoritative config patch follows generation | `update-grub` completes | Apply | Every `steamenv_boot linux` line contains the required parameters exactly once |
| L-08 | Complete validation runs | Config generated | Apply | Defaults, generated config, current UUID, kernel paths, and EFI binary are valid |
| L-09 | Existing mounts preserved | `/efi` and `/esp` mounted | Apply | `/efi` and `/esp` remain mounted from the same devices with their original mount ownership |
| L-10 | Partsets and bootconf unchanged | Live scenario | Apply | `/efi/SteamOS/partsets` and `/esp/SteamOS/conf` remain content-identical |
| L-11 | Validated fallback after update-grub failure | `update-grub` fails | Apply | Direct patch permitted only if existing config already matches current UUID and kernel/initramfs |
| L-12 | Stale fallback rejected | `update-grub` fails; stale UUID/kernel references | Apply | Rollback and hard failure |
| L-13 | Atomic replacement protects current boot | Injected failure | Apply | Cannot leave a missing, empty, or truncated `grub.cfg`/binary |
| L-14 | Idempotency | Successful initial application | Apply a second time | No duplicate parameters or keep-list entries |
| L-15 | Read-only state restored | Function temporarily disables SteamOS read-only mode | Apply (success or failure) | Original state is restored |
| L-16 | No boot-selection mutation | Live scenario | Apply | No RAUC activation, selected-image, boot attempts, or image-invalid changes |

**Vacuous success prevention:** For L-07 and L-08, first assert that at least one `steamenv_boot linux` line exists, then verify every matching line.

**`finalize_grub` validation scope:** Should validate:
- `/etc/default/grub`
- `/etc/default/grub-steamos`
- `/efi/EFI/steamos/grub.cfg`
- `/efi/EFI/steamos/grubx64.efi`

Including the current rootfs UUID and referenced kernel/initramfs files — not merely the NVIDIA parameters.

---

## 4. Idempotency Tests

These verify that running `apply_efi_state` twice produces **semantic convergence**, not necessarily byte-identical output. `grub-mkimage`, `update-grub`, FAT timestamps, and bootconf comments may contain nondeterministic metadata.

**Measurement methodology:**
- Capture a deterministic manifest: `find "$EFIMNT" -type f -printf '%P\t%s\n' | sort`
- Check explicitly for transaction residue: `*.new`, `*.tmp`, `*.bak`, `.transaction-*`
- Backups intentionally retained by policy should be excluded or subject to a fixed retention limit.
- Parameter assertions must be **token-aware**: for each managed key, assert exactly one token with the intended value and zero tokens with conflicting values.

| ID | Test | Actions | Assertions |
|----|------|---------|------------|
| ID-01 | Managed parameters normalized in grub.cfg | Apply twice | At least one Linux line exists; every managed key appears exactly once with its canonical value |
| ID-02 | Persistent defaults normalized | Apply twice | Effective `GRUB_CMDLINE_LINUX` contains each managed key exactly once; no conflicting values |
| ID-03 | GRUB configuration converges | Apply, capture normalized semantics, apply again | UUIDs, kernel paths, entry count, and effective command lines are unchanged |
| ID-04 | EFI binary remains semantically valid | Apply twice | Both outputs are valid EFI binaries containing the target UUID and no stale UUID; byte-identical hashes are not required |
| ID-05 | Bootconf lifecycle state preserved | Flashless apply twice before activation | Boot attempts, boot count, requested time, validity, and selection fields are unchanged by the second application |
| ID-06 | Partsets converge | Apply twice | Parsed regular-file mappings are identical; `self`, `other`, `all`, and `shared` contain the same PARTUUID mappings |
| ID-07 | Managed EFI footprint does not grow | Apply five or more times | Stable managed-file count and total apparent bytes; no accumulating temporary or backup files |
| ID-08 | Atomic-update keep-list converges | Apply twice | Every required retained path appears exactly once; unrelated entries and ordering policy remain intact |
| ID-09 | Unrelated persistent argument preserved | Add a custom argument to persistent defaults, then apply | Custom argument remains in defaults and generated configuration |
| ID-10 | Duplicate managed argument repaired | Add a duplicate managed argument, then apply | Duplicate is reduced to one canonical token |
| ID-11 | Conflicting managed value repaired | Replace `nvidia-drm.modeset=1` with `nvidia-drm.modeset=0`, then apply | Only the canonical `=1` value remains |
| ID-12 | Removed managed argument restored | Remove a managed argument, then apply | Missing argument is restored exactly once |
| ID-13 | Reapplication has no boot-state side effects | Apply twice | No additional RAUC activation, boot selection, attempt counter, or validity transition occurs |
| ID-14 | Reapplication leaves no resources | Apply twice | No leaked mounts, locks, temporary directories, or loop devices |
| ID-15 | Convergence after interrupted application | Inject failure after staging, then apply normally | Previous state is recovered and final state equals an uninterrupted successful application |

**Manual edit expectations:**
- A direct edit to `/efi/EFI/steamos/grub.cfg` is disposable because `update-grub` may regenerate the file completely.
- The useful tests are:
  - An unrelated argument added to `/etc/default/grub-steamos` survives and reaches generated entries.
  - A direct modification to generated `grub.cfg` is either regenerated from persistent state or deliberately discarded.
  - Required managed parameters are restored regardless of the manual generated-file edit.

---

## 5. Failure and Recovery Tests

These verify that failures during EFI state application do not leave the system in an unbootable state. Final-path artifacts should always be either the complete previous version or the complete validated replacement — never partially written.

**Transaction model:**
```
Acquire lock
→ make standby target non-bootable
→ write same-filesystem staging files
→ validate staged state
→ fsync staged files
→ atomically replace final paths
→ sync modified filesystems
→ validate committed state
→ make target bootable
→ activate target
→ cleanup
```

FAT cannot atomically replace the entire multi-file state, so retain backups plus a transaction marker until every replacement and directory sync succeeds.

| ID | Test | Failure Point | Expected Behavior |
|----|------|--------------|-------------------|
| FR-01 | grub-mkimage fails | During chroot rebuild | Previous final binary intact; staged output removed; B remains invalid/unselected; A remains bootable |
| FR-02 | steamos-partsets fails | In chroot | Previous final partsets intact or absent; no incomplete directory committed; activation blocked |
| FR-03 | steamos-bootconf create fails | Before boot artifacts committed where possible | `A.conf` unchanged; B remains invalid/unselected |
| FR-04 | reconcile_grub fails (patching) | Recovery | Previous configuration restored or validated old version in place; lazy unmount does not count as successful cleanup |
| FR-05 | reconcile_grub fails (validation) | Any | Staged artifacts discarded or committed replacements rolled back; invalid configuration never made selectable |
| FR-06 | EFI mount fails mid-flow | Before target mutation | Function-owned chroot mounts cleaned; no automatic format attempted |
| FR-07 | btrfs/filesystem sync fails | After commit | Persistence marked indeterminate; activation blocked; backups and transaction marker retained for recovery |
| FR-08a | update-grub fails; existing config valid | Recovery | Existing grub.cfg fully matches target → direct patch and full validation |
| FR-08b | update-grub fails; config stale | Recovery | UUID/kernel/initramfs mismatch → hard failure and rollback |
| FR-09 | Source loop detach fails | Flashless, before target identity resolution | Early abort with no target writes |
| FR-10a | RAUC activation fails after bootconf selects B | Flashless | Restore bootconf selection to A |
| FR-10b | Bootconf selection fails after RAUC activates B | Flashless | Restore RAUC activation to A |
| FR-10c | Both succeed but states disagree | Flashless | Treat as failure; restore consistent A-selected state |
| FR-11 | Normal unmount returns EBUSY | Any | Cleanup proceeds in reverse acquisition order; touches only function-owned mounts; lazy unmount reported as cleanup failure |
| FR-12 | Ownership-based cleanup | Any | Function-created resources removed; caller-created resources preserved; delegated cleanup waits for explicit owner confirmation |

**Additional failure injections:**

| ID | Test | Failure Point | Expected Behavior |
|----|------|--------------|-------------------|
| FR-13 | ENOSPC writing EFI/ESP staging files | Staging phase | No final-path mutation; staging cleaned up; previous state intact |
| FR-14 | rename() failure during commit | Atomic replace | Transaction marker retained; staged files preserved; previous state intact |
| FR-15 | fsync()/directory-sync failure after rename | Post-commit | Persistence indeterminate; activation blocked; backups retained |
| FR-16 | SIGINT at transaction phases | Any phase | Transaction marker left; next invocation detects and recovers |
| FR-17 | SIGTERM at transaction phases | Any phase | Transaction marker left; next invocation detects and recovers |
| FR-18 | Process death leaving transaction marker | Mid-transaction | Stale marker detected on next invocation; state recovered or rolled back |
| FR-19 | Stale transaction recovery | Next invocation | Previous transaction completed or rolled back cleanly |
| FR-20 | Shared-ESP failure while updating B.conf | Flashless | B.conf unchanged or restored; A.conf untouched; activation blocked |
| FR-21 | Btrfs read-only-state restoration failure | Post-write | Failure reported; slot marked invalid; activation blocked |
| FR-22 | udevadm settle timeout after UUID changes | Post-btrfstune | Devices re-resolved or operation aborted; no stale device references used |
| FR-23 | Verity regeneration/validation failure | Post-rootfs-write | Slot left invalid; activation blocked; verity state documented |
| FR-24 | Rollback itself failing | During recovery | Best-effort containment; transaction marker retained; manual recovery required |
| FR-25 | Activation succeeding in only RAUC or bootconf | Flashless | Detect inconsistency; restore consistent A-selected state |
| FR-26 | Cleanup preserving caller-owned mounts | Any | Caller mounts remain; function mounts removed; no orphan mounts |
| FR-27 | Failure after EFI commit but before activation | Flashless | EFI committed but B remains invalid/unselected; A remains bootable |

---

## 6. Validation Tests (Feature-Agnostic GRUB Checks)

These tests verify the structural integrity of the EFI state without checking specific feature parameters. They form the "finalize_grub" equivalent for the unified mechanism.

### 6.1 Structural Integrity Checks

All offline checks must use explicit `$ROOTFSMNT`, `$EFIMNT`, and `$ESPMNT` paths — never the host's currently booted configuration.

| ID | Check | What It Verifies | Method |
|----|-------|-----------------|--------|
| V-01 | grub.cfg is a regular, nonempty file | Final artifact exists | Test final target path and reject unexpected file type |
| V-02 | GRUB syntax is valid | Configuration is syntactically parseable | `grub-script-check`; success proves syntax only |
| V-03 | At least one Linux boot entry exists | Validation cannot pass vacuously | Count anchored `steamenv_boot[[:space:]]+linux` commands, excluding comments |
| V-04 | Root-search UUID is correct | GRUB locates the intended rootfs | Parse `search --fs-uuid --set=root` commands and compare with target Btrfs UUID |
| V-05 | Stale root UUIDs are absent | No source/current/opposing rootfs reference remains | Search configuration for known forbidden UUIDs |
| V-06 | UUID-bearing menu IDs are correct | Generated menu identifiers match the target rootfs | Parse applicable `gnulinux-*` IDs |
| V-07 | Kernel paths are valid | Every menu entry references an installed kernel | Resolve each kernel path beneath the target root and require a regular, nonempty file |
| V-08 | Initramfs association is valid | Every Linux entry has an initrd in the same menu entry | Parse menu-entry boundaries and validate every referenced initrd/microcode file |
| V-09 | EFI binary is structurally valid | Correct executable format and architecture | Validate PE32+, x86-64 machine type, and EFI-application subsystem |
| V-10 | EFI binary contains target identity | Embedded GRUB configuration uses the deployed rootfs | Target UUID present; known source/opposing UUIDs absent |
| V-11 | Required SteamOS binary support exists | Binary contains expected SteamOS boot functionality | Validate required embedded module/config indicators such as `steamenv_boot` |
| V-12 | Partsets directory exists | Partition mapping state is present | Require a real directory at the target EFI path |
| V-13 | Partset files follow valid schema | Files contain role/PARTUUID pairs | Parse regular files; reject malformed lines, duplicate roles, and invalid UUIDs |
| V-14 | Partset PARTUUIDs resolve correctly | Mappings identify real target partitions | Resolve through `/dev/disk/by-partuuid` and require matching block devices |
| V-15 | Partset slot semantics are correct | `self`, `other`, `shared`, and slot files have correct meaning | Compare parsed mappings against expected target topology |
| V-16 | Target bootconf exists on the shared ESP | Correct config location is populated | Check `$ESPMNT/SteamOS/conf/${SLOT}.conf`, not unconditionally host `/esp` |
| V-17 | Bootconf is parseable | SteamOS tooling accepts the complete file | Invoke `steamos-bootconf` with explicit target `--conf-dir`, `--efi-dir`, and `--image` |
| V-18 | Bootconf schema is valid | Required fields exist with valid types/ranges | Validate against the schema expected from the installed `steamos-bootconf` version |
| V-19 | Bootconf state matches transaction phase | Invalid staging state is not confused with activated state | Check `image-invalid`, selection, and attempt fields against the current phase |
| V-20 | Required static-artifact manifest satisfied | Required portable files were installed | Validate against a declared artifact manifest, not "whatever existed in the source" |
| V-21 | Committed state is readable from storage | Validation did not inspect only cached/staged data | Flush and reread; offline scenarios can remount read-only before final validation |

**Partset file format:**
```
SteamOS/partsets/A       regular text file
SteamOS/partsets/B       regular text file, when B exists
SteamOS/partsets/self    regular text file
SteamOS/partsets/other   regular text file when an opposing slot exists
SteamOS/partsets/shared  regular text file
SteamOS/partsets/all     regular text file
```

Example record:
```
rootfs d0549c73-81c5-4f65-af3f-d87a1a9a26e3
```

The validator should independently resolve that PARTUUID to a block device and verify its PARTLABEL/expected slot.

**EFI binary validation:**
Checking only `[[ -s "$binary" ]]` and MZ bytes can accept corrupt or wrong-architecture executables. Use an actual PE parser or tools such as:
- `grub-file --is-x86_64-efi "$binary"`
- `file "$binary"`
- `objdump -p "$binary"`

The semantic validator should additionally confirm the embedded target rootfs UUID. If Secure Boot is enabled, signature validation is another conditional requirement.

**Bootconf title:**
`title` is human-readable text, not authoritative slot identity. Require a valid/nonempty title matching the project's naming policy — not exact equality with A or B.

### 6.2 Consistency Checks

Keep the two UUID domains distinct:
- **GRUB `search --fs-uuid`** → Btrfs filesystem UUID
- **Partset records** → GPT partition PARTUUID

Do not accidentally compare against Btrfs `UUID_SUB`.

| ID | Check | What It Verifies | Method |
|----|-------|-----------------|--------|
| V-22 | Root-search UUID matches rootfs | GRUB and target rootfs agree | Resolve the device backing `$ROOTFSMNT`, read its Btrfs UUID, and compare every applicable `search --fs-uuid --set=root` value |
| V-23 | Kernel paths resolve safely | Referenced kernels exist inside the target | Resolve every `steamenv_boot linux` path beneath `$ROOTFSMNT`; reject escape outside the root; require nonempty files |
| V-24 | Initramfs paths resolve safely | Every referenced initrd/microcode image exists | Parse every path on each initrd line and validate it beneath `$ROOTFSMNT` |
| V-25 | Partset PARTUUIDs match mounted targets | Partsets identify the actual deployment devices | Resolve each PARTUUID uniquely and compare canonical device identity/major-minor with the rootfs, EFI, VAR, and ESP devices |
| V-26 | Persistent kernel defaults reached every entry | Generated entries reflect persistent policy | Parse the effective managed tokens from `/etc/default/grub` and `grub-steamos`; require each token exactly once on every Linux entry |
| V-27 | EFI binary UUID matches rootfs | Embedded binary configuration agrees with generated config | Require the target Btrfs UUID in `grubx64.efi`; reject known source/opposing UUIDs |
| V-28 | UUID agreement across GRUB artifacts | Binary and configuration identify the same rootfs | Compare rootfs UUID, binary UUID set, root-search UUIDs, and UUID-bearing menu IDs |
| V-29 | Partset relationships are internally consistent | Named views describe one topology | `self` matches the target slot file; `other` matches the opposing slot; `all` is the expected union; `shared` contains only shared roles |
| V-30 | No ambiguous PARTUUID resolution | A duplicate cloned partition cannot be selected accidentally | Require every recorded PARTUUID to resolve to exactly one visible block device |
| V-31 | Bootconf state agrees with transaction phase | Filesystem state and boot-selection state are coherent | Before activation target is invalid/unselected; afterward bootconf, selected-image, and RAUC agree |
| V-32 | Persistent files are retained across OTA | Generated behavior will survive an atomic update | Every persistent defaults file used by V-26 appears exactly once in the atomic-update keep-list |

**V-22 details:**
```
find mounted rootfs device
→ read TYPE and UUID with blkid
→ require TYPE=btrfs
→ compare UUID with all applicable GRUB root searches
```
Require at least one applicable root search so an empty extraction cannot pass.

**V-23/V-24 path safety:**
An existence check alone can follow a malicious or accidental symlink outside the target root. For every extracted path:
- Resolve it relative to `$ROOTFSMNT`.
- Canonicalize the result.
- Require that it remains beneath `$ROOTFSMNT`.
- Require a readable, nonempty final file.
- Associate each kernel with an initrd in the same menu entry.

Remember that an initrd command can contain multiple files:
```
initrd /boot/amd-ucode.img /boot/initramfs-linux-neptune-618.img
```
Every referenced file must pass.

**V-25 uniqueness:**
`/dev/disk/by-partuuid` alone is insufficient when cloned devices expose duplicate PARTUUIDs — the symlink may point to only one candidate. Query all matching devices and require exactly one match before comparing it with the expected mounted device.

**V-26 token semantics:**
Validate only the effective managed kernel arguments, using token-aware comparisons:
- required key appears exactly once
- required value is correct
- no conflicting value for that key exists

Do not require every setting in `grub-steamos` to appear in a kernel line; settings such as GRUB behavior flags affect generation without becoming kernel parameters.

### 6.3 Negative Validation Tests

| ID | Test | Corrupted State | Expected Detection |
|----|------|----------------|-------------------|
| V-37 | GRUB syntax error | Unbalanced brace, quote, or malformed command | Syntax validation fails |
| V-38 | Comment-only Linux entry | `steamenv_boot linux` appears only in a comment | "No Linux boot entries" |
| V-39 | Mixed root UUIDs | One menu entry uses target UUID; another uses a different UUID | "Inconsistent root-search UUIDs" |
| V-40 | One invalid entry among valid entries | Primary entry valid; fallback entry references old kernel | Complete-entry validation fails |
| V-41 | Missing kernel | Referenced vmlinuz absent or empty | "Referenced kernel missing" |
| V-42 | Kernel path escapes target | Path or symlink resolves outside `$ROOTFSMNT` | "Boot path escapes target root" |
| V-43 | Missing secondary initrd file | Microcode exists but main initramfs is absent | "Referenced initrd missing" |
| V-44 | Initrd associated with wrong entry | Linux command has no initrd before its menu block closes | "Linux entry has no associated initrd" |
| V-45 | Valid PE but not EFI application | x86-64 Windows executable substituted for GRUB | "Wrong PE subsystem" |
| V-46 | EFI binary missing target UUID | Structurally valid binary embeds another rootfs UUID | "EFI binary root identity mismatch" |
| V-47 | EFI binary contains stale UUID | Binary contains both target and old/source UUID | "Stale embedded UUID detected" |
| V-48 | Partset roles reversed | `self` contains A while target is B, or `other` contains B | "Partset slot relationship invalid" |
| V-49 | Partset points to wrong role | rootfs PARTUUID resolves to `efi-B` | "Partset role/device mismatch" |
| V-50 | Duplicate PARTUUID resolution | Two visible devices expose the recorded PARTUUID | "PARTUUID resolution is ambiguous" |
| V-51 | Partset points to another disk | Correct-looking PARTLABEL on the wrong backing disk | "Partition topology mismatch" |
| V-52 | Prematurely bootable config | Target has `image-invalid: 0` before artifact validation completes | "Bootconf state invalid for staging phase" |
| V-53 | Bootconf/RAUC disagreement | Bootconf selects B while RAUC still selects A | "Boot-selection state inconsistent" |
| V-54 | Persistent defaults not reflected | Defaults contain a managed token missing from one generated entry | "Persistent/generated command line mismatch" |
| V-55 | Conflicting generated parameter | Defaults specify `modeset=1`; one entry contains `modeset=0` | "Conflicting managed value" |
| V-56 | Validator reads host state | Host files valid; offline target deliberately corrupt | Validation must fail against the target |
| V-57 | Committed artifact differs from staged | Final file replaced with older valid-looking artifact | Semantic digest mismatch |
| V-58 | Commit not durable | Cached read passes; read after flush/remount differs or fails | Persistence validation fails |
| V-59 | Required static artifact missing | Required manifest entry removed | Artifact-manifest validation fails |

**V-39/V-40/V-56 importance:** These prove that validation checks every entry on the correct target, rather than succeeding because it found one valid-looking line somewhere.

**Semantic manifest for V-36/V-57/V-58:** Keep a normalized semantic manifest before commit containing:
- target rootfs UUID
- kernel and initrd paths
- effective kernel command lines
- EFI binary identity
- partset mappings
- bootconf phase/state
- required artifact hashes

After commit and readback, regenerate the manifest from the final target and compare it. This is stronger than comparing raw bytes when generators may include nondeterministic metadata.

---

## 7. Edge Cases

| ID | Test | Scenario | Edge Condition | Expected Behavior |
|----|------|----------|---------------|-------------------|
| EC-01 | Empty feature parameters | Any | No feature-specific params to add | No feature-specific command-line mutation; GRUB generation still runs; feature-agnostic validation (UUID, binary, partsets, bootconf, persistence) still runs |
| EC-02 | DEBUG_BOOT=1 strips quiet | All scenarios | `DEBUG_BOOT=1` set | Remove only the exact `quiet` token from all scenarios supporting DEBUG_BOOT (including Live and Flashless) |
| EC-03 | Multiple steamenv_boot entries | Any | grub.cfg has 2+ boot menu entries | Params added to ALL entries; also test fixture where only fallback entry is malformed — every entry is checked |
| EC-04 | Multiline grub-steamos | Build/Recovery | `GRUB_CMDLINE_LINUX` uses `\` continuation | Parse continuation syntax rather than manipulating physical lines independently |
| EC-05 | Single-line grub-steamos | Build/Recovery | `GRUB_CMDLINE_LINUX="existing params"` | Policy choice: either preserve existing style or explicitly canonicalize once and require subsequent stability |
| EC-06 | grub-steamos missing entirely | Build/Recovery | File doesn't exist | Create the supported file or use another verified persistent source; fail if no persistent mechanism exists |
| EC-07 | atomic-update.conf.d missing | Build | Directory doesn't exist | For atomic-update-enabled SteamOS, create the directory/file or fail; warning knowingly permits fix to disappear after OTA |
| EC-08 | Valid existing EFI reused | Flashless | Valid efi-B exists | Normally reused; if content appears immediately after explicitly authorized format, treat as wrong-device/mount/race evidence and fail |
| EC-09 | btrfstune -u timing | Flashless | UUID randomization ordering | Enforce: `btrfstune -u` → `udevadm settle` → reread UUID → verify uniqueness → then grub-mkimage → update-grub → patch → validate |
| EC-10 | Single-slot build topology | Build | Image only has efi-A | Validate declared single-slot topology; define whether `other` is absent or empty |
| EC-11 | Live requires root | Live | `config_root=/` not set | Live mode must require `config_root=/`; offline targets are Recovery scenarios |
| EC-12 | Ownership-based cleanup | Any | Function-created resources | Cleanup must be ownership-based: function-created → function removes; caller-created → function preserves |
| EC-13 | Persistent defaults reconciliation | All scenarios | Defaults not present | Applies wherever persistent defaults are reconciled (including Live and Flashless); remove conflicting assignments |
| EC-14 | GRUB_DISABLE_UUID policy | Build/Recovery | Not present in grub-default | Keep if Valve policy; do not infer GRUB becomes UUID-independent — binary and config still contain rootfs UUIDs |
| EC-15 | Exact quiet removal | Any | `quiet` on kernel line | Assert exact-token removal so `quietfoo` or a value containing `quiet` is preserved |
| EC-16 | Duplicate rootfs UUID detection | Flashless | Two filesystems share UUID | Enumerate visible Btrfs devices and require unique UUID resolution; structurally healthy filesystem can still have duplicate UUID |
| EC-17 | Stale bootconf reset | Flashless | Prior B.conf exists | Safe sequence: confirm B inactive → rename to transaction backup → create new B.conf in invalid staging → build/validate → make bootable → remove backup only after activation |
| EC-18 | Commented steamenv_boot | Any | `# steamenv_boot linux ...` | Validate behavior; cover leading whitespace and decoy text in quoted strings |
| EC-19 | Param with embedded spaces | Any | Param like `rd.luks.name=abc def` | Reject whitespace inside requested parameter or use key-aware handling for managed key=value arguments |
| EC-20 | Managed key normalization | Any | `foo=1` when `foo=10` present | Unique managed keys normalized to only `foo=1`; conflicting values removed |

**Additional edge cases:**

| ID | Test | Scenario | Edge Condition | Expected Behavior |
|----|------|----------|---------------|-------------------|
| EC-21 | Tabs, CRLF, whitespace in GRUB defaults | Any | Non-Unix line endings or leading whitespace | Handle gracefully or reject with clear error |
| EC-22 | Multiple GRUB_CMDLINE_LINUX assignments | Any | Multiple active assignments | Detect and handle consistently |
| EC-23 | Conflicting managed values across grub and grub-steamos | Build/Recovery | grub has `modeset=1`, grub-steamos has `modeset=0` | Resolve conflict per defined policy |
| EC-24 | FAT case-fold collisions | Any | `EFI/SteamOS` vs `EFI/steamos` | Handle case-insensitive FAT naming consistently |
| EC-25 | Target paths escaping mounted root | Any | Symlink escapes `$ROOTFSMNT` | Reject with clear error |
| EC-26 | Source loop devices exposing duplicate UUIDs | Flashless | Source loop still active during target validation | Detach source loops before resolving target devices |

**Kernel-parameter representation (EC-19/EC-20):**

Define parameter classes:
- **Flag**: `quiet`
- **Unique key/value**: `nvidia-drm.modeset=1`
- **Mergeable list**: `rd.driver.blacklist=nouveau,foo`
- **Repeatable key**: potentially `console=...`

A generic whitespace-based `_has_token` cannot correctly normalize all four classes. At minimum, reject whitespace inside a requested parameter and use key-aware handling for managed key=value arguments.

---

## 8. Shared Test Logic (Scenario-Agnostic Helpers)

### 8.1 Boot-State Fixture Factory

Produce three separate roots — shared ESP must not be nested under per-slot EFI.

```
create_mock_boot_fixture(base, scenario, target_slot)

base/
├── rootfs/
│   ├── boot/
│   │   ├── vmlinuz-linux-test
│   │   ├── initramfs-linux-test.img
│   │   └── amd-ucode.img
│   ├── etc/default/
│   │   ├── grub
│   │   └── grub-steamos
│   └── etc/atomic-update.conf.d/
│
├── efi/
│   ├── EFI/steamos/
│   │   ├── grub.cfg
│   │   ├── grubx64.efi
│   │   └── declared-static-artifacts/
│   └── SteamOS/partsets/
│       ├── A
│       ├── B
│       ├── self
│       ├── other
│       ├── shared
│       └── all
│
├── esp/
│   └── SteamOS/conf/
│       ├── A.conf
│       └── B.conf
│
└── metadata/
    ├── topology.json
    ├── artifact-manifest.json
    └── expected-state.json
```

**Fixture metadata must be stored outside simulated filesystems.** `declared-static-artifacts/` should not appear inside `efi/` unless that is a real boot path.

### 8.2 Topology Metadata

`topology.json` is the test oracle — production code must discover identity from fixture devices, not read this file.

```json
{
  "scenario": "flashless",
  "current_slot": "A",
  "target_slot": "B",
  "partitions": {
    "rootfs-A": {
      "type": "btrfs",
      "uuid": "aaaaaaaa-...",
      "partuuid": "11111111-...",
      "partlabel": "rootfs-A"
    },
    "efi-A": {
      "type": "vfat",
      "partuuid": "22222222-...",
      "partlabel": "efi-A"
    },
    "rootfs-B": {
      "type": "btrfs",
      "uuid": "bbbbbbbb-...",
      "partuuid": "33333333-...",
      "partlabel": "rootfs-B"
    },
    "efi-B": {
      "type": "vfat",
      "partuuid": "44444444-...",
      "partlabel": "efi-B"
    },
    "esp": {
      "type": "vfat",
      "partuuid": "55555555-...",
      "partlabel": "esp"
    }
  }
}
```

`artifact-manifest.json` lists real target paths such as `EFI/steamos/example.mod` — it should not itself be copied to EFI.

### 8.3 Namespace Deterministic Identifiers

Fixed deterministic UUIDs will collide when tests run in parallel, a previous loop device leaks, or source/target fixtures coexist.

Derive reproducible UUIDs from the test ID and worker ID:
```
fixture namespace + role → deterministic unique UUID
```

Then run `udevadm settle` and explicitly require unique resolution.

### 8.4 EFI Binary Fixture

Do not call a hand-built file with an `MZ` header a "valid PE32+ GRUB binary." Use one of:
- an actual binary generated by the SteamOS `grub-mkimage`
- a known-good real test fixture for binary-validator unit tests
- a stub only in tests where binary validation itself is mocked

Keep these claims separate:
```
syntactically valid PE/EFI fixture
actual GRUB EFI binary
SteamOS GRUB binary with embedded target UUID
boot-tested SteamOS GRUB binary
```

A fixture satisfying the first does not necessarily satisfy the other three.

**A known-good `grubx64.efi` fixture must embed the UUID declared by that fixture's topology.** Do not rewrite arbitrary bytes in the binary merely to make the UUID match.

### 8.5 Two Fixture Levels

#### Directory fixture

Appropriate for:
- GRUB configuration parsing
- Kernel/initramfs path validation
- Parameter normalization
- Partset schema parsing
- Bootconf schema parsing
- Transaction-manifest comparisons

Not sufficient for:
- `blkid`
- PARTUUID resolution
- VFAT case folding
- mount ownership
- filesystem sync
- loop-device cleanup
- filesystem-full behavior
- atomic replacement behavior on FAT

#### Loopback integration fixture

Create an actual GPT image with loop devices and formatted partitions:
```
shared ESP
efi-A
rootfs-A
var-A
efi-B
rootfs-B
var-B
```

The Build variant can omit B partitions if that is the declared image format.

This fixture should use:
- FAT for ESP and per-slot EFI partitions
- Btrfs for rootfs partitions
- deterministic PARTUUIDs (namespaced)
- distinct rootfs filesystem UUIDs (namespaced)
- cleanup registration before `losetup` or mounting

**Loopback test isolation:**
```
parent harness creates cleanup registry
→ enter private mount namespace
→ make mount propagation private
→ create loop/GPT fixture
→ run test
→ parent verifies and tears down every resource
```

The parent harness should own emergency cleanup because a child terminated by SIGKILL cannot run its traps.

Loop devices and udev state are still host-global, so unique identifiers and parent cleanup remain necessary even with mount namespaces.

### 8.6 Scenario-Aware Partsets

The factory derives expected relationships automatically:
```
target B:
  self   = B
  other  = A
  all    = A + B + shared
  shared = shared partitions
```

For a single-slot Build fixture, explicitly define the expected representation of `other`: absent, empty, or tool-generated placeholder. Do not let individual tests invent different interpretations.

### 8.7 Parameterized Test Runner

**Runner context:**
```
SCENARIO
CURRENT_SLOT
TARGET_SLOT
ROOTFS_DEVICE
EFI_DEVICE
ESP_DEVICE
ROOTFSMNT
EFIMNT
ESPMNT
MOUNT_POLICY
EXPECTED_UUID
```

`SOURCE_EFI_MOUNT` should exist only for an explicitly tested static-artifact-copy mode. It is no longer required for GRUB binary, configuration, or partset generation.

If production code depends on globals, run every test in a fresh subshell and clear the complete variable set afterward. Otherwise one scenario's slot, mount path, or device can contaminate the next test.

**Runner order:**
```
run_efi_state_test(context, expected)
  1. Install parent-level cleanup
  2. Create directory or loopback fixture
  3. Resolve actual devices and mounts
  4. Capture pre-state:
       - protected/non-target hashes
       - unmanaged-file hashes
       - boot-selection state
  5. Invoke apply_efi_state in an isolated subprocess
  6. Capture exit status without allowing set -e to terminate harness
  7. Verify function-owned mounts and temporary resources were cleaned
  8. For offline scenarios, remount target filesystems read-only
  9. Run validator profiles (see 8.8)
 10. Capture post-state semantic manifest
 11. Compare:
       - post-state against expected post-state
       - protected state against pre-state
       - first successful post-state against second post-state (idempotency)
 12. Unmount readback mounts
 13. Run final leak checks
```

Do not generally compare complete pre- and post-manifests for equality — a successful application is supposed to change state. Compare:
- actual post-state against expected post-state
- protected/non-target state against pre-state
- first successful post-state against second post-state for idempotency

### 8.8 Validator Profiles

Prefer named profiles over numeric ranges:

```
validate_grub_structure
validate_binary_structure
validate_boot_paths
validate_partsets
validate_bootconf
validate_cross_artifact_consistency
validate_transaction_phase
```

The numeric IDs can then change without breaking the harness.

---

## 9. Test Execution Order and Dependencies

### Phase 0: Static and Fixture Validation

- shellcheck and syntax checks
- Fixture JSON/schema validation
- Required test-tool detection
- Destructive-command guard validation
- Test harness cleanup self-test

### Phase 1: Pure Unit Tests

- GRUB text parsing
- Kernel-command-line normalization
- Persistent-default parsing
- Partset schema parsing
- Bootconf schema parsing
- Semantic manifest generation
- Transaction state-machine logic
- Preflight logic with mocked system probes
- Negative fixtures requiring no real filesystems

### Phase 2: Directory-Fixture Integration

- Root-relative path resolution
- Symlink escape rejection
- Generated-file atomic replacement
- Idempotency of text/config transformations
- Mocked Build/Recovery/Flashless/Live dispatch
- Deterministic command-failure injection

### Phase 3: Loopback Filesystem Integration

- GPT/PARTUUID discovery
- FAT and Btrfs validation
- udev settling and unique resolution
- Build scenario
- Recovery/Repatch staged-slot scenario
- Flashless standby-slot scenario
- Mount ownership and cleanup
- Filesystem-full and sync failures
- Read-only property lifecycle
- Durable readback after remount

### Phase 4: Transaction and Process-Failure Tests

- SIGINT/SIGTERM at every transaction phase
- SIGKILL followed by next-run recovery
- Stale transaction marker recovery
- Commit/rename/fsync failures
- Rollback failure
- Bootconf/RAUC partial activation
- Cleanup ownership
- Parent-harness emergency cleanup

### Phase 5: Cross-Scenario Invariants

- Equivalent normalized GRUB state
- Target UUID consistency
- Scenario-specific allowed-mutation sets
- Protected/opposing-slot preservation
- Persistent-default convergence
- No simultaneously visible UUID/PARTUUID collisions

### Phase 6: Disposable VM/OVMF Boot Tests

- Boot generated Build image
- Boot flashless-installed standby slot
- Verify kernel/initramfs loading
- Run Live application inside booted VM
- Reboot after Live application
- Exercise A→B activation
- Exercise failed-B rollback to A
- Optional Secure Boot profile

### Phase 7: Optional Hardware Smoke Tests

- Real Steam Deck A/B transition
- Power interruption during standby deployment
- NVIDIA-specific boot and driver verification

### Capability Tags

Use tags rather than numeric ranges to gate expensive phases:

```
unit
directory
loopback
root
udev
btrfs
vfat
failure-injection
signal
vm
secure-boot
hardware
```

Gate expensive phases on earlier success:
```
static → unit → directory → loopback → transaction → VM → hardware
```

### Validator Profiles by Capability

Split validators by capability level:

**validate_partsets:**
- unit: parse regular files, validate roles, validate UUID syntax, validate self/other/all relationships
- loopback: resolve every PARTUUID, require unique resolution, compare major/minor identities, verify PARTLABEL and parent disk

**validate_boot_paths:**
- directory: safe path resolution and file existence
- loopback: correct mounted rootfs/device relationship

**validate_consistency:**
- unit: compare supplied semantic identities
- loopback: independently discover identities from real devices

### Live-Mode Safety

Do not run directly during integration:
```
apply_efi_state live / /efi
```
unless `/` belongs to a disposable VM.

A private mount namespace plus pivot_root can provide intermediate coverage, but a chroot is not sufficient for testing the defining Live property that commands execute directly against the running root. The final Live test should:
```
boot disposable VM
→ run Live apply inside VM
→ verify opposing slot unchanged
→ reboot
→ confirm the same slot remains bootable
```

### Dependency Rules

- Each test creates and destroys its own fixture
- Phases determine cost and required capabilities, not shared state between tests
- Run loopback tests serially unless UUIDs, PARTUUIDs, loop devices, mountpoints, and temporary directories are all namespaced uniquely
- A leaked loop device from one test must cause the next fixture's uniqueness check to fail safely, not silently point at the wrong partition

---

## 10. Acceptance Criteria

The mechanism is test-complete when the defined software failure model is covered. This cannot guarantee survival from arbitrary storage hardware failure, firmware bugs, or total filesystem destruction — those conditions should produce an explicit **state indeterminate; activation prohibited** result rather than an impossible promise of automatic recovery.

1. **Required test matrix passes** — all required capability profiles pass with no unexpected skips or expected failures.

2. **Preflight enforcement passes** — every defined invalid precondition is rejected before persistent mutation, and every valid fixture is allowed to proceed.

3. **Scenario behavior passes** — Build, staged-slot Repatch, Flashless, and Live produce their documented scenario-specific state and mutate only their allowed resource sets.

4. **Semantic idempotency passes** — repeated application converges without duplicated parameters, accumulating files, altered boot lifecycle counters, repeated activation, or leaked resources.

5. **Failure safety passes within the defined failure model:**
   - Build artifacts are not published after failure.
   - Flashless/Repatch leave the current slot bootable and the target invalid/unselected.
   - Live retains a complete previous or complete replacement artifact.
   - Indeterminate I/O durability always blocks activation.
   - Rollback metadata is not deleted prematurely.

6. **Structural validation passes** — every committed GRUB configuration, EFI binary, boot path, partset, bootconf, and required static artifact satisfies its validator profile.

7. **Cross-artifact consistency passes** — rootfs UUID, GRUB root searches, UUID-bearing menu IDs, embedded EFI binary identity, kernel/initramfs paths, partsets, and bootconf phase describe one coherent target.

8. **Identity uniqueness passes** — every filesystem UUID and PARTUUID resolves unambiguously among all devices visible in the execution namespace, including source loops and leaked fixtures.

9. **Manifest comparisons pass:**
   - staged desired manifest equals durable post-commit readback
   - protected pre-state equals protected post-state
   - first and second successful applications are semantically equivalent
   - generated artifact hashes are compared only where byte identity is expected

10. **Partset consistency passes** — `A`, `B`, `self`, `other`, `all`, and `shared` match the independently discovered topology, with a separately defined single-slot Build policy.

11. **Protected-resource preservation passes:**
   - Flashless/Repatch never modify the current rootfs, current EFI, or current bootconf
   - Live never modifies the opposing rootfs, EFI, or bootconf
   - unmanaged files within preserved filesystems remain content-identical
   - protected EFI devices are never opened or mounted read-write

12. **Boot-selection consistency passes** — after every successful activation, RAUC, bootconf, `selected-image`, and the expected target slot agree. Every partial activation failure is compensated back to a consistent current-slot state.

13. **Activation ordering passes** — no target becomes valid or selectable until staged artifacts are validated, committed, flushed, reread, and validated again.

14. **Transaction durability passes** — rename, sync, readback, interruption, and restart tests demonstrate that transaction markers support deterministic completion or rollback. Multi-file FAT updates remain protected by invalid-slot gating until completion.

15. **Cleanup ownership passes:**
   - function-created resources are cleaned after normal return, handled failure, SIGINT, and SIGTERM
   - caller-created resources are preserved
   - SIGKILL leaves recoverable ownership records
   - the parent harness removes test resources
   - the next invocation detects and resolves or safely rejects stale production state

16. **Edge-policy tests pass** — every documented edge case produces its specified no-op, warning, fallback, or hard failure without unintended mutation.

17. **VM boot tests pass:**
   - Build image boots through the generated EFI path
   - Flashless system actually boots the newly generated standby slot rather than falling back to the old slot
   - the booted rootfs UUID and slot identity match expectations
   - Live application survives reboot
   - A→B activation succeeds
   - deliberately failed B boot returns to A through the intended rollback mechanism

18. **Conditional security profiles pass** — when Secure Boot is supported/enabled, signing and signature validation pass; otherwise the mode is explicitly rejected rather than silently producing an unbootable image.
