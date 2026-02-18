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

# Detect host architecture
HOST_ARCH="$(uname -m)"

# Build QEMU acceleration flags
accel_flags() {
    if [[ "$ACCEL" == "kvm" ]]; then
        echo "-accel kvm -cpu host"
    else
        if [[ "$HOST_ARCH" == "aarch64" ]]; then
            echo "-accel tcg -cpu cortex-a76"
        else
            echo "-accel tcg -cpu max"
        fi
    fi
}

# Build Xen emulation flags (for testing Qubes components)
xen_accel_flags() {
    if [[ "$ACCEL" == "kvm" ]]; then
        if [[ "$HOST_ARCH" == "aarch64" ]]; then
            echo "-accel kvm,xen-version=0x40011,xen-evtchn=on,xen-gnttab=on -cpu host"
        else
            echo "-accel kvm,xen-version=0x40013,kernel-irqchip=split -cpu host,+xen-vapic"
        fi
    else
        if [[ "$HOST_ARCH" == "aarch64" ]]; then
            echo "-accel tcg -cpu cortex-a76"
        else
            echo "-accel tcg -cpu max"
        fi
    fi
}

# Architecture-specific QEMU binary and machine configuration
if [[ "$HOST_ARCH" == "aarch64" ]]; then
    QEMU_BIN="${QEMU:-qemu-system-aarch64}"
    MACHINE_TYPE="virt,gic-version=3"
    # ARM64 UEFI firmware
    AAVMF=""
    for _fw in /usr/share/edk2/aarch64/QEMU_EFI.fd \
               /usr/share/AAVMF/AAVMF_CODE.fd; do
        [[ -f "$_fw" ]] && AAVMF="$_fw" && break
    done
    MACHINE_ARGS="${AAVMF:+-bios $AAVMF}"
else
    QEMU_BIN="${QEMU:-qemu-system-x86_64}"
    MACHINE_TYPE="q35"
    MACHINE_ARGS=""
fi

case "$ACTION" in

    install)
        [[ -z "$DISK" ]] && { echo "Error: --disk required"; exit 1; }
        [[ -z "$ISO" ]]  && { echo "Error: --iso required"; exit 1; }

        echo "=== Installing from ISO ==="
        echo "Arch:  $HOST_ARCH | Accel: $ACCEL | Mem: ${MEM}MB | CPUs: $CPUS"
        echo "Disk:  $DISK"
        echo "ISO:   $ISO"
        echo ""

        $QEMU_BIN \
            $(accel_flags) \
            -m "$MEM" \
            -smp "$CPUS" \
            -machine "$MACHINE_TYPE" \
            $MACHINE_ARGS \
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
        echo "Arch:  $HOST_ARCH | Accel: $ACCEL | Mem: ${MEM}MB | CPUs: $CPUS"
        echo "Disk:  $DISK"
        echo "SSH:   localhost:$SSH_PORT"
        echo ""

        $QEMU_BIN \
            $(accel_flags) \
            -m "$MEM" \
            -smp "$CPUS" \
            -machine "$MACHINE_TYPE" \
            $MACHINE_ARGS \
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
        # Boot a VM with QEMU's Xen HVM emulation.
        # The guest thinks it's running on Xen, but it's actually on KVM.
        [[ -z "$DISK" ]] && { echo "Error: --disk required"; exit 1; }

        if [[ "$ACCEL" != "kvm" ]]; then
            echo "WARNING: Xen emulation requires KVM acceleration."
            echo "This test only works on the Lenovo laptop (or any KVM host)."
            echo "On Qubes AppVM, use 'make test' for container-based unit tests."
            exit 1
        fi

        echo "=== Xen-on-KVM Test VM ==="
        echo "Arch:  $HOST_ARCH"
        echo "This VM appears as Xen 4.17+ to the guest OS"
        echo "Accel: KVM + Xen HVM shim | Mem: ${MEM}MB | CPUs: $CPUS"
        echo "Disk:  $DISK"
        echo "SSH:   localhost:$SSH_PORT"
        echo ""

        XEN_CONSOLE_SOCK="/tmp/qubes-kvm-xen-console-$$.sock"

        if [[ "$HOST_ARCH" == "aarch64" ]]; then
            # ARM64: use virt machine with Xen acceleration flags
            $QEMU_BIN \
                $(xen_accel_flags) \
                -m "$MEM" \
                -smp "$CPUS" \
                -M virt,gic-version=3 \
                $MACHINE_ARGS \
                -drive file="$DISK",if=virtio,format=qcow2 \
                -device virtio-net-pci,netdev=net0 \
                -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
                -device virtio-rng-pci \
                -nographic \
                -pidfile /tmp/qubes-kvm-xen-test.pid \
                $EXTRA_ARGS

            echo ""
            echo "Xen-on-KVM ARM64 VM started."
            echo "Guest will see: Xen emulation via QEMU on ARM64"
        else
            # x86: use q35 machine with Xen PV devices
            OVMF=""
            for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
                     /usr/share/OVMF/OVMF_CODE.fd \
                     /usr/share/edk2/xen/OVMF.fd; do
                [[ -f "$f" ]] && OVMF="$f" && break
            done
            OVMF_ARGS=""
            if [[ -n "$OVMF" ]]; then
                echo "OVMF:  $OVMF"
                OVMF_ARGS="-drive if=pflash,format=raw,readonly=on,file=$OVMF"
            fi

            $QEMU_BIN \
                $(xen_accel_flags) \
                -m "$MEM" \
                -smp "$CPUS" \
                -machine q35 \
                $OVMF_ARGS \
                -drive file="$DISK",if=xen,format=qcow2 \
                -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
                -device virtio-net-pci,netdev=net0 \
                -chardev socket,id=char0,path="$XEN_CONSOLE_SOCK",server=on,wait=off \
                -device xen-console,chardev=char0 \
                -device virtio-balloon \
                -device virtio-rng-pci \
                -display none \
                -daemonize \
                -pidfile /tmp/qubes-kvm-xen-test.pid \
                -monitor telnet:127.0.0.1:${MONITOR_PORT},server,nowait \
                $EXTRA_ARGS

            echo ""
            echo "Xen-on-KVM x86 VM started."
            echo "Guest will see: Xen 4.19 hypervisor in CPUID"
            echo "PV devices: xvda (block), xen-net (network), xen-console"
        fi
        echo "  PID:          $(cat /tmp/qubes-kvm-xen-test.pid 2>/dev/null)"
        echo "  SSH:          ssh -p $SSH_PORT user@localhost"
        ;;

    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $PROGNAME <install|start|xen-test> [options]"
        exit 1
        ;;
esac
