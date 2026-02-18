#!/bin/bash
# vm-launch.sh — Launch QEMU test VMs with auto-detected acceleration
# Works in both KVM mode (Lenovo) and TCG mode (Qubes AppVM)
set -euo pipefail

readonly PROGNAME="vm-launch"

# Defaults
ACTION="${1:?Usage: $PROGNAME <install|start|xen-test> [options]}"
shift

ACCEL="tcg"
MEM="4096"
CPUS="2"
DISK=""
ISO=""
XEN_SHIM=""
SSH_PORT="2222"
MONITOR_PORT="4444"
SPICE_PORT="5900"
EXTRA_ARGS=""

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --accel)  ACCEL="$2"; shift 2 ;;
        --mem)    MEM="$2"; shift 2 ;;
        --cpus)   CPUS="$2"; shift 2 ;;
        --disk)   DISK="$2"; shift 2 ;;
        --iso)    ISO="$2"; shift 2 ;;
        --xen)    XEN_SHIM="$2"; shift 2 ;;
        --ssh-port) SSH_PORT="$2"; shift 2 ;;
        --extra)  EXTRA_ARGS="$2"; shift 2 ;;
        *)        echo "$PROGNAME: unknown option: $1" >&2; exit 1 ;;
    esac
done

# Build QEMU acceleration flags
accel_flags() {
    if [[ "$ACCEL" == "kvm" ]]; then
        echo "-accel kvm -cpu host"
    else
        echo "-accel tcg -cpu max"
    fi
}

# Build Xen emulation flags (for testing Qubes components)
xen_accel_flags() {
    if [[ "$ACCEL" == "kvm" ]]; then
        # KVM with Xen HVM emulation — the core of the architecture
        echo "-accel kvm,xen-version=0x40013,kernel-irqchip=split -cpu host,+xen-vapic"
    else
        # TCG cannot do Xen emulation, use plain emulation
        echo "-accel tcg -cpu max"
    fi
}

# QEMU binary (allow override via environment)
QEMU_BIN="${QEMU:-qemu-system-x86_64}"

case "$ACTION" in

    install)
        [[ -z "$DISK" ]] && { echo "Error: --disk required"; exit 1; }
        [[ -z "$ISO" ]]  && { echo "Error: --iso required"; exit 1; }

        echo "=== Installing from ISO ==="
        echo "Accel: $ACCEL | Mem: ${MEM}MB | CPUs: $CPUS"
        echo "Disk:  $DISK"
        echo "ISO:   $ISO"
        echo ""

        # Install runs in foreground with display (not daemonized)
        $QEMU_BIN \
            $(accel_flags) \
            -m "$MEM" \
            -smp "$CPUS" \
            -machine q35 \
            -drive file="$DISK",if=virtio,format=qcow2 \
            -cdrom "$ISO" \
            -boot d \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
            -device virtio-balloon \
            -device virtio-rng-pci \
            -display gtk \
            $EXTRA_ARGS

        echo "Installation finished."
        ;;

    start)
        [[ -z "$DISK" ]] && { echo "Error: --disk required"; exit 1; }

        echo "=== Starting Test VM ==="
        echo "Accel: $ACCEL | Mem: ${MEM}MB | CPUs: $CPUS"
        echo "Disk:  $DISK"
        echo "SSH:   localhost:$SSH_PORT"
        echo ""

        $QEMU_BIN \
            $(accel_flags) \
            -m "$MEM" \
            -smp "$CPUS" \
            -machine q35 \
            -drive file="$DISK",if=virtio,format=qcow2 \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
            -device virtio-balloon \
            -device virtio-rng-pci \
            -display none \
            -daemonize \
            -monitor telnet:127.0.0.1:${MONITOR_PORT},server,nowait \
            -pidfile /tmp/qubes-kvm-test-vm.pid \
            $EXTRA_ARGS

        echo "VM started. PID: $(cat /tmp/qubes-kvm-test-vm.pid 2>/dev/null)"
        echo "SSH:     ssh -p $SSH_PORT user@localhost"
        echo "Monitor: telnet 127.0.0.1 $MONITOR_PORT"
        ;;

    xen-test)
        # THIS IS THE KEY TEST: boot a VM with QEMU's Xen HVM emulation
        # The guest thinks it's running on Xen, but it's actually on KVM
        [[ -z "$DISK" ]] && { echo "Error: --disk required"; exit 1; }

        if [[ "$ACCEL" != "kvm" ]]; then
            echo "WARNING: Xen emulation requires KVM acceleration."
            echo "This test only works on the Lenovo laptop (or any KVM host)."
            echo "On Qubes AppVM, use 'make test' for container-based unit tests."
            exit 1
        fi

        echo "=== Xen-on-KVM Test VM ==="
        echo "This VM appears as Xen 4.19 to the guest OS"
        echo "Accel: KVM + Xen HVM shim | Mem: ${MEM}MB | CPUs: $CPUS"
        echo ""

        $QEMU_BIN \
            $(xen_accel_flags) \
            -m "$MEM" \
            -smp "$CPUS" \
            -machine q35 \
            -drive file="$DISK",if=xen \
            -drive file="$DISK",file.locking=off,if=ide \
            -device xen-net-device \
            -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
            -chardev stdio,mux=on,id=char0,signal=off \
            -mon char0 \
            -device xen-console,chardev=char0 \
            -display none \
            -daemonize \
            -pidfile /tmp/qubes-kvm-xen-test.pid \
            $EXTRA_ARGS

        echo "Xen-on-KVM VM started."
        echo "Guest will see: Xen 4.19 hypervisor in CPUID"
        echo "PV devices: xvda (block), xen-net (network), xen-console"
        echo "PID: $(cat /tmp/qubes-kvm-xen-test.pid 2>/dev/null)"
        ;;

    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $PROGNAME <install|start|xen-test> [options]"
        exit 1
        ;;
esac
