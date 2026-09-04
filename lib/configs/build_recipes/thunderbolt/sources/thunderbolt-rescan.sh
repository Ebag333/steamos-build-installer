#!/bin/bash
# Trigger PCI bus rescan when a Thunderbolt device is added.
# Fixes cases where the dock's PCI devices don't appear on hot-plug.
[[ -w /sys/bus/pci/rescan ]] && echo 1 >/sys/bus/pci/rescan
