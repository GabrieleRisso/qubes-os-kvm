#!/bin/bash
# xen-on-kvm-test.sh — Launch a VM that thinks it's running on Xen
# THIS IS THE CORE PROOF-OF-CONCEPT for the entire architecture.
#
# Uses QEMU's built-in Xen HVM emulation (--accel kvm,xen-version=...)
# The guest OS sees Xen in CPUID, gets Xen PV block/net/console devices,
# and can use Xen hypercalls — all emulated by QEMU on top of KVM.
#
# Requirements: /dev/kvm (run inside kvm-dev qube or on Lenovo laptop)
#
# What this proves:
#   1. Existing Qubes VM agents (qrexec, GUI, qubesdb) can run unmodified
#   2. KVM handles the hardware (WiFi, GPU, USB) with full driver support
#   3. The guest gets Xen PV devices (xvda, xen-net) for Qubes compatibility
#   4. No actual Xen hypervisor is needed on the host
set -euo pipefail

DISK="${1:?Usage: $0 DISK_IMAGE [MEM_MB] [CPUS]}"
MEM="${2:-4096}"
CPUS="${3:-2}"

if [[ ! -f "$DISK" ]]; then
    echo "ERROR: Disk image not found: $DISK"
    exit 1
fi

if [[ ! -e /dev/kvm ]]; then
    echo "ERROR: /dev/kvm not found. This test requires KVM acceleration."
    echo ""
    echo "If you're in the kvm-dev qube, check:"
    echo "  1. dom0 rebooted after adding nestedhvm=1?"
    echo "  2. qvm-prefs kvm-dev virt_mode  (should be 'hvm')"
    echo "  3. qvm-prefs kvm-dev kernel     (should be empty/VM-provided)"
    exit 1
fi

echo "=== Xen-on-KVM Proof of Concept ==="
echo ""
echo "Architecture:"
echo "  L0: KVM (Linux kernel — bare metal or nested)"
echo "  L1: QEMU with Xen HVM emulation (this VM)"
echo "  Guest sees: Xen 4.19 hypervisor"
echo ""
echo "  QEMU version:  $(qemu-system-x86_64 --version | head -1)"
echo "  Disk:          $DISK"
echo "  Memory:        ${MEM}MB"
echo "  CPUs:          $CPUS"
echo ""

# The magic command: KVM + Xen emulation layer
# xen-version=0x40013 = Xen 4.19 (matches Qubes OS 4.3)
# kernel-irqchip=split is MANDATORY for Xen emulation
# xen-vapic enables virtual APIC for better performance
#
# Display: use -nographic (console on stdio) since we may be inside a
# Qubes VM without X11. Use -display gtk only if DISPLAY is set.
DISPLAY_OPTS="-nographic"
if [[ -n "${DISPLAY:-}" ]]; then
    DISPLAY_OPTS="-display gtk -device virtio-vga"
fi

qemu-system-x86_64 \
    -accel kvm,xen-version=0x40013,kernel-irqchip=split \
    -cpu host,+xen-vapic \
    -m "$MEM" \
    -smp "$CPUS" \
    -machine q35 \
    \
    -drive file="$DISK",if=xen \
    -drive file="$DISK",file.locking=off,if=ide \
    \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    \
    -chardev stdio,mux=on,id=char0,signal=off \
    -mon char0 \
    -device xen-console,chardev=char0 \
    \
    $DISPLAY_OPTS \
    -device virtio-balloon \
    -device virtio-rng-pci

# After boot, verify inside the VM:
#   cat /sys/hypervisor/type          # should say "xen"
#   ls /dev/xvd*                      # should show xvda
#   dmesg | grep -i xen               # should show Xen detection
#   cat /proc/xen/capabilities        # Xen capabilities
