# Validate Pipeline

The validate pipeline checks system configuration and installed state against the project's configuration files. It runs as a standalone action (`--action validate`) and supports two modes of operation: validating the live system or validating an offline disk image.

## What's unique to this pipeline

The validate pipeline differs from the build, flash, and flashless pipelines in several ways:

### Dual-mode operation

Validate can target either the running live system (`VALIDATE_ROOT=/`) or a loop-mounted offline image (`VALIDATE_ROOT=/tmp/steamos-validate.XXXXXX`). The discover phase detects the mode and sets `OPT_MODE` to `live` or `chroot` accordingly. All validation helpers receive the root path and adapt their checks — for example, flatpak validation uses `flatpak info` on a live system but checks for staged bundle files on an offline image.

### Result tracking system

Each check produces a structured result with a status, item name, and optional detail string:

| Status | Meaning |
|--------|---------|
| `PASS` | Check succeeded |
| `FAIL` | Check failed (only used when a config was explicitly provided) |
| `INFO` | Check failed but no config was provided — informational only |
| `SKIP` | Check was skipped (unsupported verification or missing config file) |
| `FOUND` | Item is present but not selected in the provided config |

Results are stored in the `_VALIDATE_RESULTS` array as pipe-delimited strings (`STATUS|item|detail`) and tallied into counters. The distinction between `FAIL` and `INFO` is important: without an explicit `--config`, failures are reported as informational observations rather than errors.

### Config-aware filtering

When a config file is provided via `--config`, the report phase cross-references every result against the config's selections. Items not selected in the config are handled as follows:

- If the item **passed** validation but is not selected → overridden to `FOUND` (present but irrelevant)
- If the item **failed** or was **skipped** and is not selected → overridden to `SKIP`

This means the same validation run produces different reports depending on whether a config is provided. Without a config, the report shows the full system state. With a config, it shows only the results relevant to the user's selections.

The selection logic (`_validate_is_selected`) checks different config variables depending on the item category:

- **System config** (`update-branch`, `default-session`) — always selected
- **Optimizations** — checked against `GAMING_ITEMS` and the `always` default
- **Initramfs groups** — checked against `INITRAMFS_MODULES`
- **Hardware packages** — checked against `HW_SUPPORT_ITEMS`
- **Build items** — checked against the conf file's default field

### Report phase with section-grouped output

The report phase groups results into sections based on item prefix:

- `System Config` — update-branch, default-session
- `Customizations` — optimization items
- `Initramfs` — initramfs module groups
- `Hardware Packages` — hw-prefixed items
- `Build Items` — build/ and flatpak/-prefixed items

Each section gets a header, and items are displayed with status symbols. The summary line at the bottom changes based on mode:

- **With config**: `Total: N  Passed: N  Failed: N  Skipped: N  Found: N`
- **Without config**: `Total: N  Present: N  Absent: N  Skipped: N`

### Image loop-mounting with udev guards

For offline image validation, the pipeline attaches the image as a loop device and mounts its partitions read-only. Before attaching the loop device, a udev rule is installed at `/run/udev/rules.d/89-steamos-validate.rules` that sets `UDISKS_IGNORE=1` and `SYSTEMD_READY=0` on all loop partitions. This prevents udisks2 from triggering automount popups in the desktop environment.

The mount process:

1. Install udev guard rule
2. Attach image via `losetup -f --show --partscan`
3. Wait for partition device nodes (`udevadm settle`)
4. Scan partitions by `PARTLABEL` to find `rootfs-A` (or `rootfs`) and `var-A` (or `var`)
5. Mount rootfs read-only; mount var read-only if it exists as a separate partition

Cleanup (via `validate_cleanup` on EXIT trap) reverses the process: unmount var, unmount rootfs, detach loop device, remove udev guard, reload udev rules.

## Workflow

The pipeline has three phases:

### Phase 1: Discover

`phase_validate_discover` determines the validation target and loads configuration.

1. **Detect mode** — if `VALIDATE_ROOT` is `/`, set `OPT_MODE=live`; otherwise set `OPT_MODE=chroot` with `OPT_ROOT` pointing to the mount point
2. **Load config** — three paths:
   - Explicit `--config` provided → source it and set `_VALIDATE_HAS_CONFIG=1` (enables config-aware filtering in the report)
   - Live system with persisted config at `/home/.steamos-build/build.conf` → source it for variable context but do NOT set the config flag (no filtering)
   - No config found → validate all items unconditionally

### Phase 2: Validate

`phase_validate_run` executes all validation checks via `_validate_all`. Every check runs regardless of config — config-awareness is deferred to the report phase. The checks are organized into five categories:

**System config** — verifies `update-branch` and `default-session` settings using `verify_system_config`. If a config is loaded and the check fails, the result is `FAIL`; without a config, it's `INFO`.

**Optimizations** — iterates all items from `customizations.conf` and calls `verify_optimization_for_item` for each. Exit code 0 = `PASS`, 2 = `SKIP` (verify not supported), other = `FAIL` or `INFO` depending on config presence.

**Initramfs** — iterates all groups from `initramfs.conf` and calls `verify_initramfs` with the group's module list. Results are namespaced as `initramfs/<group>`.

**Hardware packages** — iterates entries from `hw-packages.conf`, dispatching by TYPE:
- `pacman` — queries installed version from pacman DB, results namespaced as `hw/<pkg>`
- `build-recipe` — queries installed version, results namespaced as `build/<pkg>`
- `flatpak` — on live systems, checks `flatpak info`; on offline images, checks for staged `.flatpak` bundles. Recipe directory and `FLATPAK_APP_ID` are validated as prerequisites.

### Phase 3: Report

`phase_validate_report` produces the final output.

1. **Filter results** (if config was loaded) — iterate `_VALIDATE_RESULTS`, check each item against `_validate_is_selected`, and apply the override rules described above
2. **Print report** — iterate the (possibly filtered) results, group by section, print each item with its status symbol
3. **Print summary** — totals line with counts for each status category
