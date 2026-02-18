#!/bin/bash
# crosvm-launch-aarch64.sh — Launch crosvm ARM64 VMs for Qubes
#
# Uses crosvm (Chrome OS VMM) for security-critical VMs on ARM64.
# crosvm provides sandboxed device processes (Rust, minijail) and a
# minimal attack surface compared to QEMU.
#
# This script is the ARM64 counterpart to vm-launch.sh (x86 QEMU).
#
# Requirements:
#   - crosvm binary built for aarch64 (cargo build --release)
#   - KVM on ARM64 host (/dev/kvm)
#   - AAVMF firmware (ARM UEFI) at /usr/share/AAVMF/AAVMF_CODE.fd
#   - Linux kernel Image for the VM

set -euo pipefail

readonly PROGNAME="crosvm-launch-aarch64"
readonly CROSVM="${CROSVM_BIN:-crosvm}"

# Defaults
ACTION="${1:?Usage: $PROGNAME <start|start-xenshim|stop|status> [options]}"
shift

MEM="2048"
CPUS="2"
ROOTFS=""
KERNEL=""
INITRD=""
CMDLINE="root=/dev/vda ro console=ttyAMA0"
VSOCK_CID=""
SOCKET_DIR="/var/run/qubes/crosvm"
VM_NAME="qubes-vm"
GPU_MODE="virtio"
NET_TAP=""
EXTRA_ARGS=""

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mem)       MEM="$2"; shift 2 ;;
        --cpus)      CPUS="$2"; shift 2 ;;
        --rootfs)    ROOTFS="$2"; shift 2 ;;
        --kernel)    KERNEL="$2"; shift 2 ;;
        --initrd)    INITRD="$2"; shift 2 ;;
        --cmdline)   CMDLINE="$2"; shift 2 ;;
        --vsock-cid) VSOCK_CID="$2"; shift 2 ;;
        --name)      VM_NAME="$2"; shift 2 ;;
        --gpu)       GPU_MODE="$2"; shift 2 ;;
        --net-tap)   NET_TAP="$2"; shift 2 ;;
        --extra)     EXTRA_ARGS="$2"; shift 2 ;;
        *)           echo "$PROGNAME: unknown option: $1" >&2; exit 1 ;;
    esac
done

# Ensure socket directory exists
mkdir -p "$SOCKET_DIR"
CONTROL_SOCKET="${SOCKET_DIR}/${VM_NAME}.sock"

# Build crosvm arguments for ARM64
build_common_args() {
    local args=()

    # Memory
    args+=("--mem" "${MEM}")

    # CPUs
    args+=("--cpus" "${CPUS}")

    # ARM64 uses GICv3 interrupt controller (auto-detected by crosvm)

    # Kernel and initrd
    if [[ -n "$KERNEL" ]]; then
        args+=("--kernel" "$KERNEL")
    fi
    if [[ -n "$INITRD" ]]; then
        args+=("--initrd" "$INITRD")
    fi

    # Kernel command line
    args+=("--params" "$CMDLINE")

    # Root filesystem (virtio-blk)
    if [[ -n "$ROOTFS" ]]; then
        args+=("--root" "$ROOTFS")
    fi

    # Virtio vsock for vchan-socket transport (critical for Qubes)
    if [[ -n "$VSOCK_CID" ]]; then
        args+=("--vsock" "${VSOCK_CID}")
    fi

    # Serial console (PL011 on ARM64)
    args+=("--serial" "type=stdout,hardware=serial,num=1")

    # Virtio RNG
    args+=("--rng")

    # Virtio balloon for memory management
    args+=("--balloon")

    # GPU configuration
    case "$GPU_MODE" in
        virtio)
            # virtio-gpu (software rendering in VM, composited in host)
            args+=("--gpu" "backend=virglrenderer")
            ;;
        cross-domain)
            # virtio-gpu with cross-domain context for Wayland
            # This is the preferred mode for Adreno on ARM64 --
            # it allows the VM to share GPU buffers with the host
            # compositor without full GPU passthrough.
            args+=("--gpu" "backend=virglrenderer,context-types=cross-domain")
            ;;
        none)
            # No GPU (headless VM like sys-net, sys-firewall)
            ;;
        *)
            echo "Unknown GPU mode: $GPU_MODE (use: virtio|cross-domain|none)" >&2
            exit 1
            ;;
    esac

    # Network (virtio-net via TAP)
    if [[ -n "$NET_TAP" ]]; then
        args+=("--net" "tap-name=${NET_TAP}")
    fi

    # Virtio-serial for QubesDB config injection
    args+=("--serial" "type=unix,path=${SOCKET_DIR}/${VM_NAME}-qubesdb.sock,hardware=virtio-console,num=1")

    # Control socket for crosvm management
    args+=("--socket" "$CONTROL_SOCKET")

    echo "${args[@]}"
}

case "$ACTION" in

    start)
        [[ -z "$KERNEL" ]] && { echo "Error: --kernel required"; exit 1; }
        [[ -z "$ROOTFS" ]] && { echo "Error: --rootfs required"; exit 1; }

        echo "=== Starting crosvm ARM64 VM ==="
        echo "VM:     $VM_NAME"
        echo "Mem:    ${MEM}MB | CPUs: $CPUS"
        echo "Kernel: $KERNEL"
        echo "RootFS: $ROOTFS"
        echo "GPU:    $GPU_MODE"
        [[ -n "$VSOCK_CID" ]] && echo "vSock:  CID $VSOCK_CID"
        echo ""

        # crosvm run automatically uses /dev/kvm on ARM64
        # GICv3 is auto-detected from the host
        $CROSVM run \
            $(build_common_args) \
            $EXTRA_ARGS &

        echo "VM started. Control socket: $CONTROL_SOCKET"
        echo "Stop with: $PROGNAME stop --name $VM_NAME"
        ;;

    start-xenshim)
        # Start a VM with Xen emulation -- uses QEMU as backend
        # instead of crosvm, since crosvm does not support Xen emulation.
        # This is for VMs that specifically need Xen hypercall interfaces.
        echo "=== Starting Xen-shim ARM64 VM (via QEMU) ==="
        echo "NOTE: Xen emulation uses QEMU, not crosvm."
        echo "For pure crosvm VMs, use 'start' instead."
        echo ""

        [[ -z "$KERNEL" ]] && { echo "Error: --kernel required"; exit 1; }
        [[ -z "$ROOTFS" ]] && { echo "Error: --rootfs required"; exit 1; }

        QEMU_BIN="${QEMU:-qemu-system-aarch64}"

        $QEMU_BIN \
            -accel kvm,xen-version=0x40011,xen-evtchn=on,xen-gnttab=on \
            -cpu host \
            -M virt,gic-version=3 \
            -m "$MEM" \
            -smp "$CPUS" \
            -kernel "$KERNEL" \
            ${INITRD:+-initrd "$INITRD"} \
            -append "$CMDLINE" \
            -drive file="$ROOTFS",if=virtio,format=raw \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0 \
            -device virtio-rng-pci \
            -nographic \
            -pidfile "/tmp/qubes-${VM_NAME}-xenshim.pid" \
            $EXTRA_ARGS

        echo "Xen-shim VM started."
        ;;

    stop)
        if [[ ! -S "$CONTROL_SOCKET" ]]; then
            echo "No control socket found at $CONTROL_SOCKET"
            echo "VM may not be running or was started differently."
            exit 1
        fi

        echo "Stopping VM: $VM_NAME"
        $CROSVM stop "$CONTROL_SOCKET"
        echo "VM stopped."
        ;;

    suspend)
        if [[ ! -S "$CONTROL_SOCKET" ]]; then
            echo "No control socket found at $CONTROL_SOCKET"
            exit 1
        fi

        echo "Suspending VM: $VM_NAME"
        $CROSVM suspend "$CONTROL_SOCKET"
        echo "VM suspended."
        ;;

    resume)
        if [[ ! -S "$CONTROL_SOCKET" ]]; then
            echo "No control socket found at $CONTROL_SOCKET"
            exit 1
        fi

        echo "Resuming VM: $VM_NAME"
        $CROSVM resume "$CONTROL_SOCKET"
        echo "VM resumed."
        ;;

    status)
        if [[ -S "$CONTROL_SOCKET" ]]; then
            echo "VM '$VM_NAME': control socket exists at $CONTROL_SOCKET"
            # Try to get balloon stats as a liveness check
            $CROSVM balloon_stats "$CONTROL_SOCKET" 2>/dev/null && echo "  Status: RUNNING" || echo "  Status: UNKNOWN"
        else
            echo "VM '$VM_NAME': not running (no control socket)"
        fi
        ;;

    *)
        echo "Unknown action: $ACTION"
        echo "Usage: $PROGNAME <start|start-xenshim|stop|suspend|resume|status> [options]"
        echo ""
        echo "Options:"
        echo "  --name NAME       VM name (default: qubes-vm)"
        echo "  --mem MB          Memory in MB (default: 2048)"
        echo "  --cpus N          Number of vCPUs (default: 2)"
        echo "  --kernel PATH     Kernel Image path (required for start)"
        echo "  --initrd PATH     Initrd path"
        echo "  --rootfs PATH     Root filesystem image (required for start)"
        echo "  --cmdline STR     Kernel command line"
        echo "  --vsock-cid N     Virtio vsock CID for vchan transport"
        echo "  --gpu MODE        GPU mode: virtio|cross-domain|none (default: virtio)"
        echo "  --net-tap TAP     TAP device name for networking"
        echo "  --extra ARGS      Extra crosvm/QEMU arguments"
        exit 1
        ;;
esac
