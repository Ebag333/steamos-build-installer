#!/usr/bin/env python3
"""verify-customizations.py — verify every steamos-nvidia-installer customization landed.

Runs a comprehensive battery of checks against a built image (offline) or a
running system (online).  Detects what's installed automatically — no feature
flags needed.  Exits 0 if all checks pass, 1 if any fail.

Usage (offline — from the build host, image still loop-mounted):
  sudo python3 tools/verify-customizations.py \
      --mnt /tmp/nvidia-build/mnt \
      --homemnt /tmp/nvidia-build/home \
      --efimnt /tmp/nvidia-build/efi

Usage (online — running on the target device):
  sudo python3 tools/verify-customizations.py --online

All checks are independent — the script runs every check and reports a summary
at the end so you can see *all* failures, not just the first one.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

# ── Helpers ────────────────────────────────────────────────────────────────────

PASS = 0
FAIL = 0
SKIP = 0
CHECK_ALL = False
FAILURES: list[str] = []


def ok(label: str):
    global PASS
    PASS += 1
    print(f"  \u2713 {label}")


def fail(label: str, detail: str = ""):
    global FAIL
    FAIL += 1
    msg = f"  \u2717 {label}"
    if detail:
        msg += f" — {detail}"
    print(msg)
    FAILURES.append(f"{label}: {detail}" if detail else label)


def skip(label: str, reason: str = ""):
    global SKIP
    SKIP += 1
    msg = f"  \u25cb SKIP {label}"
    if reason:
        msg += f" — {reason}"
    print(msg)


def section(title: str):
    print(f"\n{'─' * 60}\n{title}\n{'─' * 60}")


def file_exists(path: str, label: str = "") -> bool:
    label = label or path
    if os.path.exists(path):
        ok(f"{label} exists")
        return True
    fail(f"{label} exists", f"not found: {path}")
    return False


def symlink_points_to(link: str, expected_target: str, label: str = "") -> bool:
    label = label or link
    if not os.path.islink(link):
        fail(f"{label} is symlink", f"not a symlink: {link}")
        return False
    target = os.readlink(link)
    if target == expected_target:
        ok(f"{label} -> {expected_target}")
        return True
    fail(f"{label} -> {expected_target}", f"points to: {target}")
    return False


def file_contains(path: str, needle: str, label: str = "") -> bool:
    label = label or f"{path} contains '{needle}'"
    try:
        content = Path(path).read_text(errors="replace")
    except FileNotFoundError:
        fail(label, f"file not found: {path}")
        return False
    except PermissionError:
        skip(label, f"permission denied: {path} (run with sudo)")
        return False
    if needle in content:
        ok(label)
        return True
    fail(label, "string not found")
    return False


def file_regex_match(path: str, pattern: str, label: str = "") -> bool:
    label = label or f"{path} matches /{pattern}/"
    try:
        content = Path(path).read_text(errors="replace")
    except FileNotFoundError:
        fail(label, f"file not found: {path}")
        return False
    if re.search(pattern, content):
        ok(label)
        return True
    fail(label, "pattern not found")
    return False


def read_text(path: str) -> str | None:
    try:
        return Path(path).read_text(errors="replace")
    except (FileNotFoundError, PermissionError):
        return None


def executable(path: str, label: str = "") -> bool:
    label = label or f"{path} is executable"
    if os.path.isfile(path) and os.access(path, os.X_OK):
        ok(label)
        return True
    fail(label, f"not found or not executable: {path}")
    return False


def file_perms(path: str, expected_mode: int, label: str = "") -> bool:
    label = label or f"{path} mode {oct(expected_mode)}"
    try:
        mode = os.stat(path).st_mode & 0o7777
    except FileNotFoundError:
        fail(label, f"file not found: {path}")
        return False
    if mode == expected_mode:
        ok(label)
        return True
    fail(label, f"got {oct(mode)}, expected {oct(expected_mode)}")
    return False


def dir_exists(path: str, label: str = "") -> bool:
    label = label or path
    if os.path.isdir(path):
        ok(f"{label} exists")
        return True
    fail(f"{label} exists", f"not a directory: {path}")
    return False


def glob_match(pattern: str, label: str = "") -> list[str]:
    label = label or pattern
    matches = glob.glob(pattern)
    if matches:
        ok(f"{label} ({len(matches)} match(es))")
    else:
        fail(f"{label}", "no matches")
    return matches


def run_cmd(cmd: list[str], label: str = "") -> tuple[int, str]:
    """Run a command, return (returncode, stdout)."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return r.returncode, r.stdout.strip()
    except Exception as e:
        return -1, str(e)


def owned_by(path: str, uid: int = 1000, gid: int = 1000, label: str = "") -> bool:
    label = label or f"{path} owned by {uid}:{gid}"
    try:
        st = os.stat(path)
    except FileNotFoundError:
        fail(label, f"not found: {path}")
        return False
    if st.st_uid == uid and st.st_gid == gid:
        ok(label)
        return True
    fail(label, f"owned by {st.st_uid}:{st.st_gid}")
    return False


def is_symlink_to(link: str, target: str) -> bool:
    return os.path.islink(link) and os.readlink(link) == target


def grub_cfg_params(grub_cfg: str) -> list[str]:
    """Extract kernel params from the steamenv_boot linux line in grub.cfg."""
    content = read_text(grub_cfg)
    if not content:
        return []
    for line in content.splitlines():
        if "steamenv_boot" in line and "linux" in line and "/boot/vmlinuz" in line:
            # Strip comments
            line = line.split("#", 1)[0]
            # Return everything after /boot/vmlinuz as params
            m = re.search(r'/boot/vmlinuz\b(.*)', line)
            if m:
                return m.group(1).split()
    return []


def grub_default_params(grub_default: str) -> list[str]:
    """Extract kernel params from GRUB_CMDLINE_LINUX_DEFAULT."""
    content = read_text(grub_default)
    if not content:
        return []
    m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', content, re.MULTILINE)
    if m:
        return m.group(1).split()
    return []


def grub_steamos_params(grub_steamos: str) -> list[str]:
    """Extract kernel params from GRUB_CMDLINE_LINUX in grub-steamos."""
    content = read_text(grub_steamos)
    if not content:
        return []
    m = re.search(r'^GRUB_CMDLINE_LINUX="([^"]*)"', content, re.MULTILINE)
    if m:
        return m.group(1).split()
    return []


# ── Mount points / context ────────────────────────────────────────────────────

MNT = ""
HOMEMNT = ""
EFIMNT = ""
KVER = ""
UPDATE_MODE = ""


def resolve_paths():
    """In online mode, set MNT/HOMEMNT/EFIMNT to /."""
    global MNT, HOMEMNT, EFIMNT
    if MNT == "/":
        HOMEMNT = HOMEMNT or "/"
        EFIMNT = EFIMNT or "/"
    MNT = os.path.realpath(MNT)
    HOMEMNT = os.path.realpath(HOMEMNT)
    EFIMNT = os.path.realpath(EFIMNT)


def detect_kver():
    global KVER
    modules_dir = os.path.join(MNT, "usr/lib/modules")
    if not os.path.isdir(modules_dir):
        return
    for d in sorted(os.listdir(modules_dir)):
        if "neptune" in d:
            KVER = d
            return


def detect_update_mode():
    global UPDATE_MODE
    steamos_update = os.path.join(MNT, "usr/bin/steamos-update")
    content = read_text(steamos_update)
    if content is None:
        UPDATE_MODE = "unknown"
        return
    if "self-healing" in content:
        UPDATE_MODE = "selfheal"
    elif "OS updates are held" in content:
        UPDATE_MODE = "hold"
    else:
        UPDATE_MODE = "stock"


# ── Feature detection ─────────────────────────────────────────────────────────
# Each returns True if the feature appears to be installed/configured.

def has_thunderbolt() -> bool:
    if CHECK_ALL:
        return True
    return os.path.isfile(os.path.join(MNT, "etc/udev/rules.d/98-thunderbolt-rescan.rules"))


def has_hid_modules() -> bool:
    if CHECK_ALL:
        return True
    if not KVER:
        return False
    return bool(glob.glob(os.path.join(
        MNT, f"usr/lib/modules/{KVER}/updates/logitech/hid-logitech-dj.ko*")))


def has_hid_source_bundle() -> bool:
    if CHECK_ALL:
        return True
    return os.path.isdir(os.path.join(HOMEMNT, ".driver-packages/hid"))


def has_cuda_trimmed() -> bool:
    """CUDA was trimmed if the nvidia-utils package is present but libcuda is absent."""
    if CHECK_ALL:
        return True
    pacman_db = os.path.join(MNT, "usr/lib/holo/pacmandb/local")
    if not glob.glob(os.path.join(pacman_db, "nvidia-utils-*")):
        return False  # no nvidia installed at all — can't tell
    libcuda = glob.glob(os.path.join(MNT, "usr/lib/libcuda*"))
    return len(libcuda) == 0


def has_gamemode() -> bool:
    if CHECK_ALL:
        return True
    rc, out = run_cmd(["chroot", MNT, "id", "deck"])
    return rc == 0 and "gamemode" in out


def has_pci_realloc() -> bool:
    grub = os.path.join(MNT, "etc/default/grub-steamos")
    content = read_text(grub)
    return bool(content and "pci=realloc=on" in content)


def has_tb_host_reset() -> bool:
    grub = os.path.join(MNT, "etc/default/grub-steamos")
    content = read_text(grub)
    return bool(content and "thunderbolt.host_reset=0" in content)


def has_resize_bar() -> bool:
    grub = os.path.join(MNT, "etc/default/grub-steamos")
    content = read_text(grub)
    return bool(content and "nvidia.NVreg_EnableResizableBar=1" in content)


def has_debug_boot() -> bool:
    grub_cfg = os.path.join(EFIMNT, "EFI/steamos/grub.cfg")
    params = grub_cfg_params(grub_cfg)
    return "rd.debug" in params


def has_one_click_installer() -> bool:
    if CHECK_ALL:
        return True
    return os.path.isfile(os.path.join(HOMEMNT, "deck/tools/install_to_hd.sh"))


def pkg_installed(pkg: str) -> bool:
    pacman_db = os.path.join(MNT, "usr/lib/holo/pacmandb")
    rc, _ = run_cmd(["pacman", "-Q", "--dbpath", pacman_db, pkg])
    return rc == 0


# ── Check functions ───────────────────────────────────────────────────────────

def check_nvidia_kernel_modules():
    section("NVIDIA kernel modules")
    if not KVER:
        skip("nvidia.ko", "kernel version not detected")
        return

    nvidia_ko = os.path.join(MNT, f"usr/lib/modules/{KVER}/updates/dkms/nvidia.ko*")
    matches = glob.glob(nvidia_ko)
    if matches:
        ok(f"nvidia.ko in /usr/lib/modules/{KVER}/updates/dkms/")
    else:
        fail("nvidia.ko exists", f"no match for {nvidia_ko}")

    rc, out = run_cmd(["chroot", MNT, "modinfo", "-k", KVER, "-n", "nvidia"])
    if rc == 0 and "/updates/" in out:
        ok("modinfo nvidia resolves to /updates/")
    elif rc == 0:
        fail("modinfo nvidia resolves to /updates/", f"resolves to: {out}")
    else:
        skip("modinfo nvidia resolution", "chroot modinfo failed")

    rc, out = run_cmd(["chroot", MNT, "modinfo", "-k", KVER, "-F", "vermagic", "nvidia"])
    if rc == 0 and out.startswith(KVER + " "):
        ok(f"nvidia vermagic matches {KVER}")
    elif rc == 0:
        fail(f"nvidia vermagic matches {KVER}", f"got: {out}")
    else:
        skip("nvidia vermagic", "chroot modinfo failed")


def check_nvidia_firmware():
    section("NVIDIA firmware")
    glob_match(os.path.join(MNT, "usr/lib/firmware/nvidia/*/gsp_*.bin"), "GSP firmware")


def check_vulkan_icd():
    section("Vulkan ICD")
    file_exists(os.path.join(MNT, "usr/share/vulkan/icd.d/nvidia_icd.json"),
                "nvidia_icd.json")


def check_modprobe_config():
    section("modprobe configuration")
    conf = os.path.join(MNT, "etc/modprobe.d/99-nvidia-patch.conf")
    if not file_exists(conf, "99-nvidia-patch.conf"):
        return
    file_contains(conf, "blacklist nouveau", "blacklists nouveau")
    file_contains(conf, "options nouveau modeset=0", "nouveau modeset=0")
    file_contains(conf, "nvidia-drm", "nvidia-drm options present")
    file_contains(conf, "modeset=1", "nvidia-drm modeset=1")
    file_contains(conf, "fbdev=1", "nvidia-drm fbdev=1")
    file_contains(conf, "options nvidia NVreg_PreserveVideoMemoryAllocations=1",
                  "NVreg_PreserveVideoMemoryAllocations=1")


def check_grub_config():
    section("GRUB / kernel command line")

    nvidia_params = [
        "rd.driver.blacklist=nouveau",
        "modprobe.blacklist=nouveau",
        "nvidia-drm.modeset=1",
        "nvidia-drm.fbdev=1",
    ]

    grub_cfg = os.path.join(EFIMNT, "EFI/steamos/grub.cfg")
    if os.path.isfile(grub_cfg):
        params = grub_cfg_params(grub_cfg)
        for param in nvidia_params:
            if param in params:
                ok(f"grub.cfg has {param}")
            else:
                fail(f"grub.cfg has {param}", "not on kernel line")

        if "quiet" in params:
            fail("grub.cfg kernel line has no 'quiet'", "quiet still present")
        else:
            ok("grub.cfg kernel line has no 'quiet'")

        # Check gaming params that are actually on the line
        for param in ("pci=realloc=on", "thunderbolt.host_reset=0",
                       "nvidia.NVreg_EnableResizableBar=1"):
            if param in params:
                ok(f"grub.cfg has {param}")

        if "rd.debug" in params:
            ok("grub.cfg has rd.debug (debug-boot)")
    else:
        skip("EFI grub.cfg checks", f"not found: {grub_cfg}")

    # /etc/default/grub: we only strip quiet here now.  Params live in
    # grub-steamos (checked by check_grub_steamos).
    grub_default = os.path.join(MNT, "etc/default/grub")
    if os.path.isfile(grub_default):
        params = grub_default_params(grub_default)
        if "quiet" in params:
            fail("/etc/default/grub has no 'quiet'", "quiet still present")
        else:
            ok("/etc/default/grub: quiet removed")
    else:
        skip("/etc/default/grub checks", "file not found")


def check_grub_steamos():
    section("grub-steamos + atomic-update keep-list")
    grub_steamos = os.path.join(MNT, "etc/default/grub-steamos")
    keep_file = os.path.join(MNT, "etc/atomic-update.conf.d/steamos-nvidia-installer.conf")

    if not os.path.isfile(grub_steamos):
        skip("grub-steamos", "file not found")
        skip("atomic-update keep-list", "grub-steamos not found")
        return

    content = read_text(grub_steamos)
    if not content:
        skip("grub-steamos", "could not read file")
        return

    # All nvidia-related params this installer can add
    all_nvidia_params = [
        "rd.driver.blacklist=nouveau",
        "modprobe.blacklist=nouveau",
        "nvidia-drm.modeset=1",
        "nvidia-drm.fbdev=1",
        "pci=realloc=on",
        "thunderbolt.host_reset=0",
        "nvidia.NVreg_EnableResizableBar=1",
    ]

    found_any = False
    for param in all_nvidia_params:
        if param in content:
            ok(f"grub-steamos has {param}")
            found_any = True

    # If grub-steamos was patched at all, the keep-list must exist
    if found_any:
        if os.path.isfile(keep_file):
            file_contains(keep_file, "/etc/default/grub-steamos",
                          "keep-list has grub-steamos")
        else:
            fail("atomic-update keep-list exists", f"not found: {keep_file}")
    else:
        skip("atomic-update keep-list", "no nvidia params in grub-steamos")


def check_nvidia_power_services():
    section("NVIDIA power management services")
    for svc in ("nvidia-suspend", "nvidia-resume", "nvidia-hibernate"):
        enabled_path = os.path.join(MNT, f"etc/systemd/system/multi-user.target.wants/{svc}.service")
        if os.path.islink(enabled_path):
            ok(f"{svc}.service enabled")
        else:
            rc, out = run_cmd(["chroot", MNT, "systemctl", "is-enabled", svc])
            if rc == 0 and "enabled" in out:
                ok(f"{svc}.service enabled")
            else:
                skip(f"{svc}.service", "could not determine enabled state")


def check_depmod_ldconfig():
    section("depmod + ldconfig")
    if not KVER:
        skip("modules.dep", "kernel version not detected")
        return
    modules_dep = os.path.join(MNT, f"usr/lib/modules/{KVER}/modules.dep")
    if os.path.isfile(modules_dep):
        content = read_text(modules_dep)
        if content and "nvidia" in content:
            ok("modules.dep contains nvidia entries")
        else:
            fail("modules.dep contains nvidia entries", "no nvidia entries found")
    else:
        fail("modules.dep exists", f"not found: {modules_dep}")


def check_initramfs():
    section("initramfs configuration")

    dracut_conf = os.path.join(MNT, "etc/dracut.conf.d/99-steamos-nvidia.conf")
    mkinitcpio_conf = os.path.join(MNT, "etc/mkinitcpio.conf")

    if os.path.isfile(dracut_conf):
        ok("dracut config exists")
        file_contains(dracut_conf, "nvidia", "dracut config has nvidia modules")
    elif os.path.isfile(mkinitcpio_conf):
        ok("mkinitcpio.conf exists")
        # Check main config and any drop-ins for nvidia modules
        mkinitcpio_content = read_text(mkinitcpio_conf) or ""
        dropin_dir = mkinitcpio_conf + ".d"
        if os.path.isdir(dropin_dir):
            for f in sorted(os.listdir(dropin_dir)):
                if f.endswith(".conf"):
                    dropin_content = read_text(os.path.join(dropin_dir, f))
                    if dropin_content:
                        mkinitcpio_content += "\n" + dropin_content
        if "nvidia" in mkinitcpio_content:
            ok("mkinitcpio config has nvidia modules")
        else:
            fail("mkinitcpio config has nvidia modules", "not found in main config or drop-ins")
        if "bash" in mkinitcpio_content:
            ok("bash in mkinitcpio config")
    else:
        skip("initramfs config", "neither dracut nor mkinitcpio config found")


def check_update_strategy_selfheal():
    section("Update strategy — self-heal mode")

    steamos_update = os.path.join(MNT, "usr/bin/steamos-update")
    if file_exists(steamos_update, "steamos-update wrapper"):
        file_contains(steamos_update, "self-healing", "wrapper has self-healing marker")

    file_exists(os.path.join(MNT, "usr/bin/steamos-update.orig"),
                "steamos-update.orig")

    driver_conf = os.path.join(MNT, "usr/lib/steamos-nvidia/driver.conf")
    if file_exists(driver_conf, "driver.conf"):
        pass

    repatch = os.path.join(MNT, "usr/lib/steamos-nvidia/repatch.sh")
    if file_exists(repatch, "repatch.sh"):
        file_contains(repatch, "repatch", "repatch.sh has content")

        content = read_text(repatch)
        if content:
            # Verify GRUB reconciliation is called (reconcile_grub orchestrates
            # patch_persistent_defaults → update-grub → patch_kernel_cmdline → finalize_grub).
            if "reconcile_grub" in content:
                ok("repatch.sh: calls reconcile_grub (full GRUB flow)")
            elif "patch_kernel_cmdline" in content:
                ok("repatch.sh: patch_kernel_cmdline present")
            else:
                fail("repatch.sh: has reconcile_grub or patch_kernel_cmdline", "not found")

            # Verify the early-exit was replaced with skip-rebuild
            if "DRIVER_NEEDS_REBUILD" in content:
                ok("repatch.sh: uses DRIVER_NEEDS_REBUILD (no early exit)")
            elif "exit 0" in content and "already present" in content:
                fail("repatch.sh: early-exit removed",
                     "still has 'exit 0' when driver is present — GRUB will be skipped")

            # Verify EXTRA_CMDLINE_ADD is read from driver.conf
            if "EXTRA_CMDLINE_ADD" in content:
                ok("repatch.sh: restores EXTRA_CMDLINE_ADD from driver.conf")
            else:
                skip("repatch.sh: EXTRA_CMDLINE_ADD",
                     "not found (gaming params may not survive self-heal)")

    # Verify driver.conf has EXTRA_CMDLINE_ADD
    driver_conf = os.path.join(MNT, "usr/lib/steamos-nvidia/driver.conf")
    if os.path.isfile(driver_conf):
        dc = read_text(driver_conf)
        if dc and "EXTRA_CMDLINE_ADD" in dc:
            ok("driver.conf has EXTRA_CMDLINE_ADD")
        else:
            skip("driver.conf EXTRA_CMDLINE_ADD",
                 "not found (gaming params won't persist)")

    file_exists(os.path.join(MNT, "usr/lib/steamos-nvidia/overlay.sh"),
                "overlay.sh")

    for lib in ("common_system.sh", "common_modules.sh", "common_drivers.sh", "grub.sh"):
        file_exists(os.path.join(MNT, f"usr/lib/steamos-nvidia/{lib}"),
                    f"bundled {lib}")

    oobe = os.path.join(MNT, "etc/systemd/system/steamos-finish-oobe-migration.service")
    if os.path.islink(oobe):
        symlink_points_to(oobe, "/dev/null",
                          "steamos-finish-oobe-migration masked")
    else:
        skip("steamos-finish-oobe-migration masking", "not a symlink")

    atomupd = os.path.join(MNT, "etc/systemd/system/atomupd.service")
    if os.path.islink(atomupd):
        if os.readlink(atomupd) == "/dev/null":
            fail("atomupd NOT masked in selfheal",
                 "atomupd.service is masked — should NOT be in selfheal mode")
        else:
            ok("atomupd NOT masked in selfheal")
    else:
        ok("atomupd NOT masked in selfheal (not a symlink)")


def check_update_strategy_hold():
    section("Update strategy — hold mode")

    atomupd = os.path.join(MNT, "etc/systemd/system/atomupd.service")
    if os.path.islink(atomupd):
        symlink_points_to(atomupd, "/dev/null", "atomupd.service masked")
    else:
        fail("atomupd.service masked", "not a symlink to /dev/null")

    for bin_name in ("steamos-update", "steamos-update-os", "steamos-atomupd-client"):
        path = os.path.join(MNT, f"usr/bin/{bin_name}")
        if file_exists(path, f"{bin_name} stub"):
            file_contains(path, "OS updates are held", f"{bin_name} is a stub")

    oobe = os.path.join(MNT, "etc/systemd/system/steamos-finish-oobe-migration.service")
    if os.path.islink(oobe):
        symlink_points_to(oobe, "/dev/null",
                          "steamos-finish-oobe-migration masked")
    else:
        skip("steamos-finish-oobe-migration masking", "not a symlink")


def check_update_strategy_stock():
    section("Update strategy — stock mode")
    steamos_update = os.path.join(MNT, "usr/bin/steamos-update")
    content = read_text(steamos_update)
    if content:
        if "self-healing" in content:
            fail("stock mode: steamos-update is stock",
                 "wrapper has self-healing marker — should be stock")
        else:
            ok("stock mode: steamos-update is stock (no self-healing)")

    oobe = os.path.join(MNT, "etc/systemd/system/steamos-finish-oobe-migration.service")
    if os.path.islink(oobe):
        if os.readlink(oobe) == "/dev/null":
            fail("OOBE migration NOT masked in stock",
                 "steamos-finish-oobe-migration is masked — should NOT be in stock mode")
        else:
            ok("OOBE migration NOT masked in stock")
    else:
        ok("OOBE migration NOT masked in stock (not a symlink)")


def check_thunderbolt():
    section("Thunderbolt support")
    if not has_thunderbolt():
        skip("Thunderbolt checks", "not installed (no udev rule)")
        return

    udev_rule = os.path.join(MNT, "etc/udev/rules.d/98-thunderbolt-rescan.rules")
    if file_exists(udev_rule, "thunderbolt udev rule"):
        file_contains(udev_rule, "thunderbolt-rescan.sh",
                      "udev rule references rescan script")
        file_contains(udev_rule, 'ATTR{authorized}=="1"',
                      "udev rule matches authorized devices")

    rescan = os.path.join(MNT, "usr/local/bin/thunderbolt-rescan.sh")
    if file_exists(rescan, "thunderbolt-rescan.sh"):
        executable(rescan, "thunderbolt-rescan.sh executable")
        file_contains(rescan, "/sys/bus/pci/rescan", "rescan script writes to pci rescan")

    bolt = os.path.join(MNT, "etc/systemd/system/multi-user.target.wants/bolt.service")
    if os.path.islink(bolt):
        symlink_points_to(bolt, "/usr/lib/systemd/system/bolt.service",
                          "bolt.service enabled")
    else:
        fail("bolt.service enabled", f"not a symlink: {bolt}")


def check_hid_modules():
    section("Logitech HID kernel modules")
    if not has_hid_modules():
        skip("HID module checks", "not installed (modules not found)")
        return

    for mod in ("hid-logitech-dj", "hid-logitech-hidpp"):
        path = os.path.join(MNT, f"usr/lib/modules/{KVER}/updates/logitech/{mod}.ko*")
        matches = glob.glob(path)
        if matches:
            ok(f"{mod}.ko exists")
        else:
            fail(f"{mod}.ko exists", f"no match for {path}")

    rc, out = run_cmd(["chroot", MNT, "modinfo", "-F", "alias",
                        f"/usr/lib/modules/{KVER}/updates/logitech/hid-logitech-dj.ko"])
    if rc == 0 and "v0000046Dp0000C547" in out.upper():
        ok("hid-logitech-dj has 046d:c547 alias")
    elif rc == 0:
        fail("hid-logitech-dj has 046d:c547 alias", f"aliases: {out}")
    else:
        skip("hid-logitech-dj alias check", "modinfo failed")


def check_hardware_packages():
    section("Hardware support packages")
    pkgs = ("linux-firmware", "libfprint", "fprintd", "bolt", "dkms")
    found_any = False
    for pkg in pkgs:
        if pkg_installed(pkg):
            ok(f"{pkg} installed")
            found_any = True

    if not found_any:
        skip("HW packages", "none of the expected packages found in pacman db")


def check_gamemode():
    section("Gaming tweaks")
    if not has_gamemode():
        skip("gamemode group", "deck not in gamemode group (not installed)")
        return
    ok("deck user in gamemode group")

    gamemoded_link = os.path.join(
        MNT, "etc/systemd/user/graphical-session.target.wants/gamemoded.service")
    if os.path.islink(gamemoded_link):
        symlink_points_to(gamemoded_link, "/usr/lib/systemd/user/gamemoded.service",
                          "gamemoded user service enabled")
    elif os.path.isfile(os.path.join(MNT, "usr/lib/systemd/user/gamemoded.service")):
        fail("gamemoded user service enabled",
             f"symlink not found: {gamemoded_link}")
    else:
        skip("gamemoded user service", "gamemoded.service not installed")

    # Check gaming kernel params that may be present
    if has_pci_realloc():
        ok("pci=realloc=on in grub-steamos")
    if has_tb_host_reset():
        ok("thunderbolt.host_reset=0 in grub-steamos")
    if has_resize_bar():
        ok("nvidia.NVreg_EnableResizableBar=1 in grub-steamos")

    libva = os.path.join(MNT, "etc/profile.d/libva.sh")
    if not os.path.exists(libva):
        ok("/etc/profile.d/libva.sh removed (not forcing radeonsi)")
    else:
        content = read_text(libva) or ""
        if "LIBVA_DRIVER_NAME" not in content:
            ok("/etc/profile.d/libva.sh neutralized (no LIBVA_DRIVER_NAME)")
        else:
            fail("/etc/profile.d/libva.sh neutralized",
                 "LIBVA_DRIVER_NAME still set — expected file removed or variable stripped")

    # scx_lavd scheduler
    scx_lavd_bin = os.path.join(MNT, "usr/bin/scx_lavd")
    scx_config = os.path.join(MNT, "etc/scx_loader/config.toml")
    wants_link = os.path.join(MNT, "etc/systemd/system/multi-user.target.wants/scx.service")

    if not os.path.isfile(scx_config):
        skip("scx_lavd scheduler", "scx_loader config.toml not found (not configured)")
    else:
        content = read_text(scx_config) or ""
        if "scx_lavd" in content and "--autopilot" in content:
            ok("scx_loader config: scx_lavd --autopilot")
        else:
            fail("scx_loader config configured",
                 "config.toml missing scx_lavd --autopilot")

        if os.path.islink(wants_link):
            ok("scx.service enabled")
        else:
            fail("scx.service enabled", f"symlink not found: {wants_link}")

        if os.path.isfile(scx_lavd_bin):
            ok("/usr/bin/scx_lavd installed")
        else:
            fail("/usr/bin/scx_lavd installed", "binary not found")

    # vm.swappiness tuning
    sysctl_conf = os.path.join(MNT, "etc/sysctl.d/99-vm-swappiness.conf")
    if not os.path.isfile(sysctl_conf):
        skip("vm.swappiness tuning", "99-vm-swappiness.conf not found")
    else:
        content = read_text(sysctl_conf) or ""
        if "vm.swappiness" in content:
            ok("99-vm-swappiness.conf sets vm.swappiness")
        else:
            fail("99-vm-swappiness.conf sets vm.swappiness", "vm.swappiness not found")

    # Boot-time performance hooks
    apply_boot = os.path.join(MNT, "usr/lib/steam-perf/apply-boot")
    boot_service = os.path.join(MNT, "etc/systemd/system/steam-perf.service")
    boot_wants = os.path.join(MNT, "etc/systemd/system/multi-user.target.wants/steam-perf.service")
    boot_conf = os.path.join(MNT, "etc/steam-perf/config.conf")

    if os.path.isfile(apply_boot):
        ok("apply-boot installed")
        executable(apply_boot, "apply-boot is executable")
    else:
        skip("Boot framework", "apply-boot not found")
        return

    if os.path.isfile(boot_conf):
        ok("steam-perf config.conf installed")
    else:
        fail("steam-perf config.conf installed", "not found")

    if os.path.isfile(boot_service):
        ok("steam-perf.service installed")
    else:
        fail("steam-perf.service installed", "not found")

    if os.path.islink(boot_wants):
        ok("steam-perf.service enabled")
    else:
        fail("steam-perf.service enabled", f"symlink not found: {boot_wants}")

    boot_d = os.path.join(MNT, "usr/lib/steam-perf/boot.d")
    if os.path.isdir(boot_d):
        hooks = [f for f in os.listdir(boot_d) if os.path.isfile(os.path.join(boot_d, f))]
        if hooks:
            ok(f"boot.d hooks: {', '.join(sorted(hooks))}")
        else:
            fail("boot.d has hooks", "directory is empty")
    else:
        fail("boot.d exists", f"not found: {boot_d}")


def check_nvidia_setup_desktop():
    section("NVIDIA Setup desktop shortcut")
    desktop = os.path.join(HOMEMNT, "deck/Desktop/NVIDIA Setup.desktop")
    if file_exists(desktop, "NVIDIA Setup.desktop"):
        file_contains(desktop, "steamos-nvidia-post-install",
                      "shortcut references post-install script")
        owned_by(desktop, 1000, 1000, "NVIDIA Setup.desktop owned by deck")


def check_installed_utilities():
    section("Installed utilities")
    executable(os.path.join(MNT, "usr/local/bin/diagnostics/scan-hardware"),
               "scan-hardware")
    executable(os.path.join(MNT, "usr/local/bin/steamos-nvidia-post-install"),
               "steamos-nvidia-post-install")
    executable(os.path.join(MNT, "usr/local/bin/collect-boot-logs"),
               "collect-boot-logs")


def check_boot_log_collector():
    section("Boot log collector")

    collect_script = os.path.join(MNT, "usr/local/bin/collect-boot-logs")
    if not file_exists(collect_script, "collect-boot-logs script"):
        return
    executable(collect_script, "collect-boot-logs executable")

    service = os.path.join(MNT, "etc/systemd/system/collect-boot-logs.service")
    if file_exists(service, "collect-boot-logs.service"):
        file_contains(service, "After=local-fs.target", "service After=local-fs.target")
        file_contains(service, "Before=display-manager.service",
                      "service Before=display-manager.service")
        file_contains(service, "/usr/local/bin/collect-boot-logs",
                      "service ExecStart points to script")

    enabled = os.path.join(MNT, "etc/systemd/system/multi-user.target.wants/collect-boot-logs.service")
    if os.path.islink(enabled):
        symlink_points_to(enabled, "../collect-boot-logs.service",
                          "collect-boot-logs.service enabled")
    else:
        fail("collect-boot-logs.service enabled",
             f"not a symlink: {enabled}")

    file_exists(os.path.join(HOMEMNT, ".steamos-nvidia/usb-marker"),
                "USB marker file")
    dir_exists(os.path.join(HOMEMNT, "deck/logs/boot"),
               "boot logs directory")


def check_boot_logs_symlink():
    section("Boot logs convenience symlink")
    link = os.path.join(MNT, "boot-logs")
    if os.path.islink(link):
        symlink_points_to(link, "/home/deck/logs/boot", "/boot-logs symlink")
    elif os.path.isdir(os.path.join(HOMEMNT, "deck/logs/boot")):
        skip("/boot-logs symlink", "not created (boot logs dir exists)")
    else:
        skip("/boot-logs symlink", "boot logs dir not found")


def check_config_bundle():
    section("Bundled config files")
    configs_dir = os.path.join(MNT, "usr/lib/steamos-nvidia/configs")
    if not dir_exists(configs_dir, "configs bundle dir"):
        return

    for cfg in ("99-nvidia-patch.conf", "98-thunderbolt-rescan.rules",
                "thunderbolt-rescan.sh", "hw-packages-arch.conf",
                "hw-packages-valve.conf", "NVIDIA Setup.desktop"):
        file_exists(os.path.join(configs_dir, cfg), f"bundled {cfg}")


def check_pacman_db():
    section("Pacman database entries")
    pacman_db = os.path.join(MNT, "usr/lib/holo/pacmandb/local")
    if not os.path.isdir(pacman_db):
        skip("pacman db entries", f"dir not found: {pacman_db}")
        return

    nvidia_entries = glob.glob(os.path.join(pacman_db, "nvidia-utils-*"))
    if nvidia_entries:
        ok(f"nvidia-utils registered in pacman db ({len(nvidia_entries)} entry)")
    else:
        fail("nvidia-utils registered in pacman db", "no entries found")


def check_one_click_installer():
    section("One-click installer")
    if not has_one_click_installer():
        skip("One-click installer", "install_to_hd.sh not found (not installed)")
        return

    tools_dir = os.path.join(HOMEMNT, "deck/tools")
    desktop_dir = os.path.join(HOMEMNT, "deck/Desktop")

    repair = os.path.join(tools_dir, "repair_device.sh")
    if os.path.isfile(repair):
        file_contains(repair, "STEAMOS_TARGET_DISK",
                      "repair_device.sh has STEAMOS_TARGET_DISK")
        file_contains(repair, "sanitize failed or unsupported",
                      "repair_device.sh has NVMe sanitize fallback")
    else:
        skip("repair_device.sh patches", "file not found")

    install_hd = os.path.join(tools_dir, "install_to_hd.sh")
    if file_exists(install_hd, "install_to_hd.sh"):
        executable(install_hd, "install_to_hd.sh executable")

    for icon in ("Install SteamOS NVIDIA.desktop",
                 "Upgrade SteamOS NVIDIA.desktop"):
        path = os.path.join(desktop_dir, icon)
        if file_exists(path, icon):
            owned_by(path, 1000, 1000, f"{icon} owned by deck")

    sudoers = os.path.join(MNT, "etc/sudoers.d/zz-deck-nopasswd")
    if file_exists(sudoers, "sudoers NOPASSWD drop-in"):
        file_contains(sudoers, "nvidia-install-run", "sudoers grants nvidia-install-run")
        file_perms(sudoers, 0o440, "sudoers mode 0440")


def check_session_default():
    section("Desktop session default")
    state_toml = os.path.join(HOMEMNT, "deck/.config/steamos-manager/state.toml")
    content = read_text(state_toml)
    if not content:
        skip("session default", "state.toml not found")
        return

    if "default_login_mode" in content:
        m = re.search(r'default_login_mode\s*=\s*"(\w+)"', content)
        mode = m.group(1) if m else "unknown"
        ok(f"state.toml has default_login_mode = \"{mode}\"")
    else:
        fail("state.toml has default_login_mode", "not found in file")


def check_hid_selfheal_bundle():
    section("HID self-heal source bundle")
    if not has_hid_source_bundle():
        skip("HID source bundle", "not present (not installed or not selfheal)")
        return
    if UPDATE_MODE != "selfheal":
        skip("HID source bundle", f"not in selfheal mode (detected: {UPDATE_MODE})")
        return

    hid_dir = os.path.join(HOMEMNT, ".driver-packages/hid")
    dir_exists(hid_dir, "HID source bundle dir")
    for f in ("hid-logitech-dj.c", "hid-logitech-hidpp.c", "hid-ids.h",
              "usbhid/usbhid.h", "Makefile"):
        file_exists(os.path.join(hid_dir, f), f"HID source: {f}")


def check_cuda_trim():
    section("CUDA trimming")
    if not has_cuda_trimmed():
        skip("CUDA trim check", "CUDA libs present (not trimmed or no nvidia installed)")
        return

    ok("CUDA libs trimmed (libcuda absent)")

    # Double-check none of the other trimmed libs snuck in
    trimmed_libs = ("libcudadebugger", "libnvidia-nvvm",
                    "libnvidia-opencl", "libnvoptix", "nvidia-cuda-mps")
    found = []
    for lib in trimmed_libs:
        matches = glob.glob(os.path.join(MNT, f"usr/lib/{lib}*"))
        if matches:
            found.extend(matches)

    if found:
        fail("CUDA trim completeness",
             f"found {len(found)} still present: "
             + ", ".join(os.path.basename(f) for f in found[:5]))
    else:
        ok("CUDA trim completeness (all trimmed libs absent)")


def check_rootfs_rw():
    section("Rootfs writability")
    test_file = os.path.join(MNT, ".rw-test-verify")
    try:
        Path(test_file).touch()
        os.remove(test_file)
        ok("rootfs is writable")
    except PermissionError:
        skip("rootfs is writable", "needs root (run with sudo)")
    except Exception as e:
        fail("rootfs is writable", str(e))


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global MNT, HOMEMNT, EFIMNT, KVER, UPDATE_MODE, ONLINE, CHECK_ALL

    parser = argparse.ArgumentParser(
        description="Verify steamos-nvidia-installer customizations (auto-detects everything)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--mnt", default="/",
                        help="Image rootfs mount point (default: /)")
    parser.add_argument("--homemnt", default=None,
                        help="Home partition mount point (default: same as --mnt)")
    parser.add_argument("--efimnt", default=None,
                        help="EFI partition mount point (default: same as --mnt)")
    parser.add_argument("--online", action="store_true",
                        help="Verify a running system (sets all mounts to /)")
    parser.add_argument("--all", action="store_true",
                        help="Run all checks regardless of auto-detection (no early skips)")

    args = parser.parse_args()

    MNT = args.mnt
    HOMEMNT = args.homemnt or MNT
    EFIMNT = args.efimnt or MNT
    ONLINE = args.online
    CHECK_ALL = getattr(args, 'all')

    if ONLINE:
        MNT = HOMEMNT = EFIMNT = "/"

    resolve_paths()

    # Auto-detect everything
    detect_kver()
    detect_update_mode()

    print(f"\nsteamos-nvidia-installer — customization verification")
    print(f"{'─' * 60}")
    print(f"  MNT:          {MNT}")
    print(f"  HOMEMNT:      {HOMEMNT}")
    print(f"  EFIMNT:       {EFIMNT}")
    print(f"  KVER:         {KVER or '(not detected)'}")
    print(f"  UPDATE MODE:  {UPDATE_MODE}")
    print(f"  THUNDERBOLT:  {'yes' if has_thunderbolt() else 'no'}")
    print(f"  HID MODULES:  {'yes' if has_hid_modules() else 'no'}")
    print(f"  GAMEMODE:     {'yes' if has_gamemode() else 'no'}")
    print(f"  ONE-CLICK:    {'yes' if has_one_click_installer() else 'no'}")
    print(f"{'─' * 60}")

    # Run all checks — each auto-detects whether its feature is installed
    check_nvidia_kernel_modules()
    check_nvidia_firmware()
    check_vulkan_icd()
    check_modprobe_config()
    check_grub_config()
    check_grub_steamos()
    check_nvidia_power_services()
    check_depmod_ldconfig()
    check_initramfs()

    # Update strategy — auto-detected
    if UPDATE_MODE == "selfheal":
        check_update_strategy_selfheal()
    elif UPDATE_MODE == "hold":
        check_update_strategy_hold()
    elif UPDATE_MODE == "stock":
        check_update_strategy_stock()
    else:
        skip("Update strategy", "could not detect mode")

    check_thunderbolt()
    check_hid_modules()
    check_hardware_packages()
    check_gamemode()
    check_nvidia_setup_desktop()
    check_installed_utilities()
    check_boot_log_collector()
    check_boot_logs_symlink()
    check_config_bundle()
    check_pacman_db()
    check_one_click_installer()
    check_session_default()
    check_hid_selfheal_bundle()
    check_cuda_trim()
    check_rootfs_rw()

    # ── Summary ────────────────────────────────────────────────────────────────
    print(f"\n{'═' * 60}")
    total = PASS + FAIL + SKIP
    print(f"  Results: {PASS} passed, {FAIL} FAILED, {SKIP} skipped ({total} total)")
    print(f"{'═' * 60}")

    if FAILURES:
        print(f"\nFailed checks:")
        for f in FAILURES:
            print(f"  \u2717 {f}")
        print()
        sys.exit(1)
    else:
        print(f"\nAll checks passed!")
        sys.exit(0)


if __name__ == "__main__":
    main()
