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
            log "  Fedora: sudo dnf install gcc-aarch64-linux-gnu"
            log "  Arch:   sudo pacman -S aarch64-linux-gnu-gcc"
            log "  Debian: sudo apt install gcc-aarch64-linux-gnu"
        fi

        # QEMU user-mode (for running ARM64 binaries on x86)
        if command -v qemu-aarch64-static &>/dev/null || \
           command -v qemu-aarch64 &>/dev/null; then
            log "QEMU user-mode: available"
        else
            log "QEMU user-mode: NOT INSTALLED"
            log "  Fedora: sudo dnf install qemu-user-static"
            log "  Arch:   sudo pacman -S qemu-user-static"
        fi

        # QEMU system-mode (for full ARM64 VM)
        if command -v qemu-system-aarch64 &>/dev/null; then
            log "QEMU system aarch64: $(qemu-system-aarch64 --version | head -1)"
        else
            log "QEMU system aarch64: NOT INSTALLED"
            log "  Fedora: sudo dnf install qemu-system-aarch64-core"
            log "  Arch:   sudo pacman -S qemu-system-aarch64"
        fi

        # Rust ARM64 target
        if command -v rustup &>/dev/null && rustup target list --installed 2>/dev/null | grep -q aarch64; then
            log "Rust aarch64 target: installed"
        elif command -v rustc &>/dev/null; then
            log "Rust available (system package, no rustup for cross-targets)"
        else
            log "Rust: NOT INSTALLED"
        fi
        ;;

    compile-test)
        log "=== ARM64 Cross-Compilation Test ==="

        TESTDIR=$(mktemp -d)
        trap 'rm -rf "$TESTDIR"' EXIT

        # Freestanding asm test (no libc sysroot needed)
        cat > "$TESTDIR/hello.S" << 'AEOF'
.global _start
.section .text
_start:
    mov x8, #64
    mov x0, #1
    adr x1, msg
    mov x2, #28
    svc #0
    mov x8, #93
    mov x0, #0
    svc #0
.section .rodata
msg: .ascii "Hello from ARM64! (cross-compiled)\n"
AEOF

        log "Compiling for ARM64 (freestanding)..."
        aarch64-linux-gnu-gcc -nostdlib -static -o "$TESTDIR/hello-arm64" "$TESTDIR/hello.S"
        log "Binary: $(file "$TESTDIR/hello-arm64")"

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
