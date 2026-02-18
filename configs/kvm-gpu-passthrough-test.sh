#!/bin/bash
# kvm-gpu-passthrough-test.sh — Test NVIDIA GPU passthrough via VFIO
# This is the Tier 2 test: KVM-native VM with direct hardware access
#
# Requirements:
#   - /dev/kvm
#   - IOMMU enabled (intel_iommu=on or amd_iommu=on in kernel cmdline)
#   - NVIDIA GPU bound to vfio-pci driver
#   - Run on Lenovo laptop
set -euo pipefail

DISK="${1:?Usage: $0 DISK_IMAGE GPU_PCI_ADDR [MEM_MB]}"
GPU_PCI="${2:?Specify GPU PCI address (e.g., 01:00.0)}"
MEM="${3:-8192}"

if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm not found."
    exit 1
fi

# Verify IOMMU
if ! dmesg 2>/dev/null | grep -qi "IOMMU\|DMAR"; then
    echo "WARNING: IOMMU may not be enabled."
    echo "Add to kernel cmdline: intel_iommu=on iommu=pt"
fi

# Verify GPU is bound to vfio-pci
GPU_DRIVER=$(readlink "/sys/bus/pci/devices/0000:${GPU_PCI}/driver" 2>/dev/null | xargs basename)
if [[ "$GPU_DRIVER" != "vfio-pci" ]]; then
    echo "GPU at $GPU_PCI is bound to '$GPU_DRIVER', not vfio-pci."
    echo ""
    echo "To bind GPU to vfio-pci:"
    echo "  # Get vendor:device IDs"
    echo "  lspci -n -s $GPU_PCI"
    echo "  # Unbind from current driver"
    echo "  echo '0000:$GPU_PCI' | sudo tee /sys/bus/pci/devices/0000:${GPU_PCI}/driver/unbind"
    echo "  # Bind to vfio-pci"
    echo "  echo 'VENDOR DEVICE' | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id"
    echo ""
    echo "Or add to /etc/modprobe.d/vfio.conf:"
    echo "  options vfio-pci ids=VENDOR:DEVICE"
    exit 1
fi

echo "=== GPU Passthrough Test ==="
echo "GPU: $(lspci -s "$GPU_PCI" 2>/dev/null)"
echo "Disk: $DISK"
echo "Memory: ${MEM}MB"
echo ""

qemu-system-x86_64 \
    -accel kvm \
    -cpu host \
    -m "$MEM" \
    -smp 4 \
    -machine q35 \
    \
    -drive file="$DISK",if=virtio,format=qcow2 \
    \
    -device vfio-pci,host="$GPU_PCI",multifunction=on \
    \
    -device virtio-net-pci,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    \
    -display none \
    -vga none \
    \
    -device virtio-balloon \
    -device virtio-rng-pci \
    -daemonize \
    -pidfile /tmp/qubes-kvm-gpu-test.pid

echo "VM started with GPU passthrough."
echo "SSH: ssh -p 2222 user@localhost"
echo "PID: $(cat /tmp/qubes-kvm-gpu-test.pid)"
echo ""
echo "Inside VM, verify GPU:"
echo "  lspci | grep -i nvidia"
echo "  nvidia-smi"
