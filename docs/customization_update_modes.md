# Update Modes

The update mode controls what happens when SteamOS applies an OS update. There are three modes.

## selfheal (default)

OS updates work normally. When Valve stages a new OS version on the inactive A/B slot, the NVIDIA driver is automatically rebuilt for the new kernel before the reboot prompt appears.

**How it works:**

1. Steam downloads the OS update via `steamos-atomupd-client`
2. The tool's wrapper intercepts the update after it stages on the inactive slot
3. `repatch.sh` mounts the staged rootfs, rebuilds the NVIDIA driver via DKMS, reconciles initramfs and GRUB, and propagates the self-heal machinery to the new slot
4. If the rebuild fails, the staged update is invalidated (marked `image-invalid=1`) and the machine keeps booting the current working system

**Added time:** 10-20 minutes per OS update.

**Files installed:**
- `/usr/bin/steamos-atomupd-client` (wrapper around Valve's original)
- `/usr/bin/steamos-update` (wrapper around Valve's original, logging only)
- `/usr/lib/steamos-nvidia/repatch.sh` (the actual repatch logic)
- `/usr/lib/steamos-nvidia/build.conf` (build manifest)

**Log files:**
- `/home/.steamos-nvidia/logs/atomupd-*.log` (atomupd wrapper logs)
- `/home/.steamos-nvidia/logs/atomupd-latest.log` (symlink to most recent)
- `/home/.steamos-nvidia/logs/update-*.log` (steamos-update wrapper logs)

## hold

OS updates are blocked. Steam always shows "up to date". The updater services are masked and the CLI tools are stubbed.

Use this if you want to freeze the OS version and manually rebuild when you're ready.

**What gets masked:**
- `steamos-update` service
- `steamos-atomupd-client` service

## stock

No modifications to the update system. OS updates work normally but will **remove the NVIDIA driver** — the update installs a stock SteamOS rootfs without the patched driver.

Use this only if you plan to rebuild and reinstall after every OS update.

## Selecting a mode

### GUI

Choose from the **Update mode** dropdown in the build form.

### CLI

```bash
# In your build.conf:

# selfheal (default)
UPDATE_MODE="selfheal"

# hold
UPDATE_MODE="hold"

# stock
UPDATE_MODE="stock"
```

### Config file

```bash
# In your .conf file:
UPDATE_MODE="selfheal"   # or "hold" or "stock"
```

## Changing the driver version

To move to a different NVIDIA driver version, rebuild the USB image with the desired driver version and reinstall using the **Upgrade** icon (preserves games and data). The installed system stays on the driver it was built with — updates never drift it to another version.

## Self-heal failure behavior

If the repatch fails for any reason:

1. The staged update slot is marked `image-invalid=1`
2. `boot-attempts` and `boot-requested-at` are reset to 0
3. The machine continues booting the current working system
4. Details are logged to `/home/.steamos-nvidia/logs/atomupd-latest.log`

This is a **fail-safe** design — a failed update never leaves the machine unbootable.

## Further reading

See [OS Updates](os_updates.md) for details on the repatch mechanism, what gets preserved across updates, and how to tweak the installed system (pin driver versions, add packages, run custom scripts).
