# Troubleshooting

## Build issues

### Black screen on first boot of the installed system

Power-cycle once before digging deeper. SteamOS hides its boot console (it lives on tty4-6), so a working boot can look black for a while. If it persists:

1. Press `Ctrl+Alt+F3`
2. Log in as `deck`
3. Run `steamos-session-select plasma` to get a desktop for diagnosis

### "No repair_device.sh in image home"

The `.img` you fed it isn't the recovery/repair image. Use the recovery image from:
https://help.steampowered.com/en/faqs/view/65B4-2AA3-5F37-4227#install

### pacman signature errors during the build

Rerun with `--skip-sigcheck` or enable `fix-keyring` in system tweaks. Packages come from Valve's and Arch's own servers over HTTPS.

### "glibc version mismatch" or package compatibility errors

The build verifies that every Arch package is compatible with the image's glibc. If you see this, the recovery image may be too old for the current Arch packages. Try a newer recovery image.

### Build fails with "loop device busy"

The build uses a private mount namespace to avoid this, but if it happens:

1. Check for leftover mounts: `mount | grep loop`
2. Unmount them: `sudo umount /dev/loopX`
3. Retry

### Build takes very long or runs out of disk space

- With `--workdir-location ram`, the build uses `/dev/shm` (RAM disk). Needs ~3x the image size in free RAM.
- With `--workdir-location disk`, ensure at least 20 GB free in the workspace directory.
- `auto` mode picks ram if enough free memory exists, otherwise disk.

## Installed system issues

### NVIDIA driver not loaded after boot

Check if the module is loaded:

```bash
lsmod | grep nvidia
```

If missing, check if the module was built correctly:

```bash
ls /lib/modules/$(uname -r)/updates/nvidia*
```

If the directory is empty, the DKMS build may have failed during install. Rebuild and reinstall using the Upgrade icon.

### Updates not working (self-heal mode)

Check the self-heal logs:

```bash
cat /home/.steamos-nvidia/logs/atomupd-latest.log
```

Look for errors from `repatch.sh`. Common issues:
- Network failure during package download
- DKMS build failure (kernel headers mismatch)
- Disk space exhaustion on the inactive slot

### Updates not working (hold mode)

This is expected. In hold mode, Steam always reports "up to date". To update, rebuild with `selfheal` or `stock` mode and reinstall.

### Driver removed after OS update (stock mode)

This is expected in stock mode. The OS update installs a stock SteamOS rootfs. Rebuild and reinstall to get the driver back, or switch to `selfheal` mode.

### Fingerprint reader not working

Ensure `libfprint` and `fprintd` were selected in the hardware packages dialog. Check:

```bash
systemctl status fprintd
fprintd-list $USER
```

### Thunderbolt dock not detected

Ensure `bolt` and Thunderbolt support were selected. Check:

```bash
boltctl list
systemctl status bolt
```

If devices show as not authorized, authorize them:

```bash
boltctl authorize <device-uuid>
```

### Gamescope/Game Mode not starting

Check the session:

```bash
steamos-session-select game
```

If it fails, check the journal:

```bash
journalctl -u gamescope-session -b
```

### scx_lavd scheduler not running

Check if the service is active:

```bash
systemctl status scx.service
```

Verify the config:

```bash
cat /etc/scx_loader/config.toml
```

If `scx_lavd` is not installed, the `scx-scheds` package may not have been in the image.

## Log locations

### On the installed system

| Path | Contents |
|---|---|
| `/home/.steamos-nvidia/logs/atomupd-latest.log` | Most recent self-heal log |
| `/home/.steamos-nvidia/logs/update-latest.log` | Most recent update wrapper log |
| `/home/.steamos-nvidia/logs/atomupd-*.log` | All self-heal logs (timestamped) |
| `/home/.steamos-nvidia/logs/update-*.log` | All update wrapper logs (timestamped) |
| `/usr/lib/steamos-nvidia/build.conf` | Build manifest (flags, versions, timestamp) |

### During the build (host machine)

The GUI shows the log path when the build completes. Logs are in `/tmp/steamos-nvidia.XXXXXX/backend.log`.

### Verbose boot logging

If you enabled `debug-boot` during the build, kernel command line includes `rd.debug rd.log=all`. Boot logs are available via:

```bash
journalctl -b
```

## Diagnostics

### Built-in diagnostics (GUI)

The **Diagnostics** action in the main menu can collect:
- Hardware info (PCI devices, drivers)
- Boot logs
- Driver state
- Package manifest

### Standalone diagnostics script

Run `steamos-recovery-update-diagnostics.sh` to collect a comprehensive diagnostic tarball:

```bash
bash steamos-recovery-update-diagnostics.sh
```

This creates a `.tar.gz` in the current directory with system state snapshots, boot configs, journal logs, and more. Useful for filing bug reports.

### Build manifest

Check what was installed and how:

```bash
cat /usr/lib/steamos-nvidia/build.conf
```

This shows the exact build flags, driver version, kernel version, and timestamp.

## Security note

The installed system ships a passwordless-sudo drop-in for the `deck` user (the desktop installer needs it). Once you've set a password, remove it:

```bash
sudo rm /etc/sudoers.d/zz-deck-nopasswd
```
