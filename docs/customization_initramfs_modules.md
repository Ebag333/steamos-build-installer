# Initramfs Modules

The initramfs dialog lets you select which kernel modules are force-loaded into the initramfs for early boot. This is important for hardware that needs to be available before the root filesystem is mounted.

## How it works

1. The tool scans PCI devices on the build machine using `lspci` and `modinfo`
2. Matching kernel modules are shown in a checklist grouped by category
3. Boot-critical modules are pre-checked based on PCI class codes (storage, USB) and known-critical names
4. Selected modules are written into the image's initramfs configuration

## Categories

| Category | Pre-checked? | Examples |
|---|---|---|
| **boot-path** | Yes | Storage controllers, USB host controllers, Thunderbolt |
| **graphics** | Manual | NVIDIA modules (`nvidia`, `nvidia_modeset`, `nvidia_drm`, `nvidia_uvm`) |
| **network** | Manual | Ethernet and Wi-Fi drivers |
| **bluetooth** | Manual | `btusb` |
| **other** | Manual | Anything else detected |

## Default behavior

Modules checked by default include:

- Storage: `nvme`, `ahci`, `btrfs`
- USB: `xhci_hcd`, `xhci_pci`, `usbhid`, `hid_generic`
- Thunderbolt: `thunderbolt`, `typec`

NVIDIA GPU modules are shown but **not** pre-checked. For desktop installs (not eGPU), you typically want to check them.

## When to customize

- **Standard desktop with NVIDIA GPU** — check the NVIDIA modules
- **eGPU setup** — leave display/video drivers unchecked in initramfs; they'll load later from the rootfs
- **Exotic storage** — ensure your storage controller module is checked if boot hangs waiting for root device
- **Minimal initramfs** — uncheck everything except storage; faster boot, modules load from rootfs later

## Use via CLI

Pass a space-separated module list:

```bash
# In your build.conf:
INITRAMFS_MODULES="nvme ahci xhci_hcd xhci_pci nvidia nvidia_modeset nvidia_drm nvidia_uvm"
```

An empty string means stock initramfs (no modifications):

```bash
INITRAMFS_MODULES=""
```
