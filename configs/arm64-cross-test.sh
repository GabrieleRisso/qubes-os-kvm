#!/bin/bash
# arm64-cross-test.sh — Test ARM64 emulation and cross-compilation
# This validates Tier 3: ARM/Snapdragon support path
#
# Works on BOTH machines:
#   - Qubes AppVM: qemu-user-static for cross-compilation testing
#   - Lenovo: Full ARM64 system emulation via qemu-system-aarch64
set -euo pipefail

log() { echo "[arm64] $*"; }

ACTION="${1:-check}"

case "$ACTION" in

    check)
        log "=== ARM64 Toolchain Check ==="

        # Cross-compiler
        if command -v aarch64-linux-gnu-gcc &>/dev/null; then
            log "Cross-compiler: $(aarch64-linux-gnu-gcc --version | head -1)"
        else
            log "Cross-compiler: NOT INSTALLED"
            log "  Install: pacman -S aarch64-linux-gnu-gcc"
        fi

        # QEMU user-mode (for running ARM64 binaries on x86)
        if command -v qemu-aarch64-static &>/dev/null || \
           command -v qemu-aarch64 &>/dev/null; then
            log "QEMU user-mode: available"
        else
            log "QEMU user-mode: NOT INSTALLED"
            log "  Install: pacman -S qemu-user-static"
        fi

        # QEMU system-mode (for full ARM64 VM)
        if command -v qemu-system-aarch64 &>/dev/null; then
            log "QEMU system aarch64: $(qemu-system-aarch64 --version | head -1)"
        else
            log "QEMU system aarch64: NOT INSTALLED"
            log "  Install: pacman -S qemu-system-aarch64"
        fi

        # Rust ARM64 target
        if rustup target list --installed 2>/dev/null | grep -q aarch64; then
            log "Rust aarch64 target: installed"
        else
            log "Rust aarch64 target: NOT INSTALLED"
            log "  Install: rustup target add aarch64-unknown-linux-gnu"
        fi
        ;;

    compile-test)
        log "=== ARM64 Cross-Compilation Test ==="

        TESTDIR=$(mktemp -d)
        trap 'rm -rf "$TESTDIR"' EXIT

        # Simple C test
        cat > "$TESTDIR/hello.c" << 'CEOF'
#include <stdio.h>
int main() {
    printf("Hello from ARM64! (cross-compiled)\n");
    #ifdef __aarch64__
    printf("Architecture: aarch64 confirmed\n");
    #endif
    return 0;
}
CEOF

        log "Compiling for ARM64..."
        aarch64-linux-gnu-gcc -static -o "$TESTDIR/hello-arm64" "$TESTDIR/hello.c"
        log "Binary: $(file "$TESTDIR/hello-arm64")"

        # Try running via qemu-user if available
        if command -v qemu-aarch64-static &>/dev/null; then
            log "Running via qemu-aarch64-static..."
            qemu-aarch64-static "$TESTDIR/hello-arm64"
            log "ARM64 user-mode emulation: WORKS"
        elif command -v qemu-aarch64 &>/dev/null; then
            log "Running via qemu-aarch64..."
            qemu-aarch64 "$TESTDIR/hello-arm64"
            log "ARM64 user-mode emulation: WORKS"
        else
            log "Cannot run ARM64 binary (no qemu-user installed)"
            log "Binary compiled successfully though"
        fi
        ;;

    vm-boot)
        log "=== ARM64 System VM Boot Test ==="
        log "This boots a minimal ARM64 VM using QEMU system emulation."
        log "Performance: SLOW (no KVM on x86 host), but validates the boot path."

        DISK="${2:?Usage: $0 vm-boot DISK_IMAGE}"

        if [[ ! -f /usr/share/edk2/aarch64/QEMU_EFI.fd ]] && \
           [[ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ]]; then
            log "ERROR: UEFI firmware for ARM64 not found."
            log "Install: pacman -S edk2-aarch64  (or edk2-ovmf)"
            exit 1
        fi

        UEFI_FW=$(ls /usr/share/edk2/aarch64/QEMU_EFI.fd \
                     /usr/share/AAVMF/AAVMF_CODE.fd 2>/dev/null | head -1)

        qemu-system-aarch64 \
            -M virt \
            -cpu cortex-a76 \
            -m 2048 \
            -smp 2 \
            -bios "$UEFI_FW" \
            -drive file="$DISK",if=virtio,format=qcow2 \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0,hostfwd=tcp::2223-:22 \
            -nographic

        log "ARM64 VM exited."
        ;;

    *)
        echo "Usage: $0 <check|compile-test|vm-boot> [args...]"
        exit 1
        ;;
esac
