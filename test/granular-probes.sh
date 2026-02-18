#!/bin/bash
# granular-probes.sh — Safe, fast, granular test probes for kvm-dev
# Each probe is isolated: no network, no package installs, no long timeouts.
# Run inside kvm-dev: bash /tmp/granular-probes.sh [p0|p1|p2|p3|p4|all]
set -u

N=0; P=0; F=0; S=0
pass()  { P=$((P+1)); N=$((N+1)); echo "  [$N] PASS: $*"; }
fail()  { F=$((F+1)); N=$((N+1)); echo "  [$N] FAIL: $*"; }
skip()  { S=$((S+1)); N=$((N+1)); echo "  [$N] SKIP: $*"; }
hdr()   { echo ""; echo "=== $* ==="; }

# ── P0: Foundation ────────────────────────────────────────────────

p0() {
    hdr "P0: Foundation (KVM + QEMU core)"

    # 1. /dev/kvm
    if [[ -e /dev/kvm ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            pass "/dev/kvm exists and is read-write"
        else
            fail "/dev/kvm exists but permissions wrong: $(ls -la /dev/kvm)"
        fi
    else
        fail "/dev/kvm NOT found — nested HVM not enabled or kernel missing kvm module"
    fi

    # 2. KVM kernel module
    if lsmod | grep -q kvm_intel 2>/dev/null; then
        pass "kvm_intel module loaded"
    elif lsmod | grep -q kvm_amd 2>/dev/null; then
        pass "kvm_amd module loaded"
    elif lsmod | grep -q '^kvm ' 2>/dev/null; then
        pass "kvm module loaded (generic)"
    else
        fail "No KVM kernel module loaded"
    fi

    # 3. QEMU binary
    if command -v qemu-system-x86_64 &>/dev/null; then
        pass "qemu-system-x86_64 installed: $(qemu-system-x86_64 --version 2>&1 | head -1)"
    else
        fail "qemu-system-x86_64 not found"
    fi

    # 4. KVM acceleration
    if [[ -e /dev/kvm ]] && command -v qemu-system-x86_64 &>/dev/null; then
        KVM_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm -cpu host -m 64 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$KVM_OUT" | grep -qi "could not access\|failed\|not supported"; then
            fail "KVM acceleration rejected: $(echo "$KVM_OUT" | head -2)"
        else
            pass "KVM acceleration accepted by QEMU"
        fi
    else
        skip "KVM acceleration test — prerequisites missing"
    fi
}

# ── P1: Build Chain ───────────────────────────────────────────────

p1() {
    hdr "P1: Build Chain (compile native + cross)"

    # 5. Native C
    if command -v gcc &>/dev/null; then
        TMP=$(mktemp -d)
        echo 'int main(){return 0;}' > "$TMP/t.c"
        if gcc -o "$TMP/t" "$TMP/t.c" 2>/dev/null && "$TMP/t"; then
            pass "Native C compile + execute"
        else
            fail "Native C compile/execute failed"
        fi
        rm -rf "$TMP"
    else
        fail "gcc not found"
    fi

    # 6. Native Rust
    if command -v rustc &>/dev/null; then
        TMP=$(mktemp -d)
        echo 'fn main(){println!("OK")}' > "$TMP/t.rs"
        if rustc -o "$TMP/t" "$TMP/t.rs" 2>/dev/null && "$TMP/t" | grep -q OK; then
            pass "Native Rust compile + execute"
        else
            fail "Native Rust compile/execute failed"
        fi
        rm -rf "$TMP"
    else
        fail "rustc not found"
    fi

    # 7. ARM64 cross-compile (freestanding asm — no libc needed)
    if command -v aarch64-linux-gnu-gcc &>/dev/null; then
        TMP=$(mktemp -d)
        cat > "$TMP/hello.S" << 'ASM'
.global _start
.section .text
_start:
    mov x8, #64
    mov x0, #1
    adr x1, msg
    mov x2, #9
    svc #0
    mov x8, #93
    mov x0, #0
    svc #0
.section .rodata
msg: .ascii "ARM64_OK\n"
ASM
        if aarch64-linux-gnu-gcc -nostdlib -static -o "$TMP/hello" "$TMP/hello.S" 2>/dev/null; then
            FTYPE=$(file "$TMP/hello" 2>/dev/null)
            if echo "$FTYPE" | grep -qi "aarch64\|ARM aarch64"; then
                pass "ARM64 cross-compile produced aarch64 ELF"

                # 8. ARM64 user-mode execution
                if command -v qemu-aarch64-static &>/dev/null; then
                    ARM_OUT=$(qemu-aarch64-static "$TMP/hello" 2>/dev/null || true)
                    if echo "$ARM_OUT" | grep -q "ARM64_OK"; then
                        pass "ARM64 binary runs via qemu-aarch64-static"
                    else
                        fail "ARM64 binary execution produced: '$ARM_OUT'"
                    fi
                elif command -v qemu-aarch64 &>/dev/null; then
                    ARM_OUT=$(qemu-aarch64 "$TMP/hello" 2>/dev/null || true)
                    if echo "$ARM_OUT" | grep -q "ARM64_OK"; then
                        pass "ARM64 binary runs via qemu-aarch64"
                    else
                        fail "ARM64 binary execution produced: '$ARM_OUT'"
                    fi
                else
                    skip "No ARM64 user-mode emulator available"
                fi
            else
                fail "Cross-compile produced non-aarch64 binary: $FTYPE"
            fi
        else
            fail "ARM64 cross-compilation command failed"
        fi
        rm -rf "$TMP"
    else
        fail "aarch64-linux-gnu-gcc not found"
    fi
}

# ── P2: Xen-on-KVM Emulation ─────────────────────────────────────

p2() {
    hdr "P2: Xen-on-KVM Emulation (core architecture)"

    # 9. QEMU KVM accelerator (required for xen-version property)
    if command -v qemu-system-x86_64 &>/dev/null; then
        ACCEL=$(qemu-system-x86_64 -accel help 2>&1)
        if echo "$ACCEL" | grep -q "kvm"; then
            pass "QEMU KVM accelerator available (needed for xen-version emulation)"
        else
            fail "QEMU KVM accelerator missing"
            echo "    Available: $ACCEL"
        fi
    else
        skip "qemu-system-x86_64 missing"
    fi

    # 10. Xen HVM emulation (xen-version flag)
    if [[ -e /dev/kvm ]] && command -v qemu-system-x86_64 &>/dev/null; then
        XEN_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$XEN_OUT" | grep -qi "error\|unsupported\|invalid\|not supported"; then
            fail "QEMU rejected xen-version=0x40013"
            echo "    Output: $(echo "$XEN_OUT" | head -3)"
        else
            pass "QEMU accepted xen-version=0x40013 (Xen 4.19 HVM emulation)"
        fi
    else
        skip "Xen HVM emulation — /dev/kvm or QEMU missing"
    fi

    # 11. Xen device emulation (xen-console + xen disk)
    if [[ -e /dev/kvm ]] && command -v qemu-system-x86_64 &>/dev/null; then
        TMPIMG=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG" 256M &>/dev/null
        SOCK="/tmp/xen-probe-$$.sock"
        XEN_DEV=$(timeout 8 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host -m 128 -display none -no-reboot \
            -drive file="$TMPIMG",if=xen \
            -chardev socket,id=ch0,path="$SOCK",server=on,wait=off \
            -device xen-console,chardev=ch0 \
            -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        rm -f "$TMPIMG" "$SOCK"
        if echo "$XEN_DEV" | grep -qi "error.*xen-console\|unknown device\|unsupported"; then
            fail "Xen device emulation rejected"
            echo "    Output: $(echo "$XEN_DEV" | head -3)"
        else
            pass "Xen device emulation: xen-console + xen disk accepted"
        fi
    else
        skip "Xen device emulation — prerequisites missing"
    fi

    # 12. OVMF firmware
    OVMF=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/xen/OVMF.fd; do
        [[ -f "$f" ]] && OVMF="$f" && break
    done
    if [[ -n "$OVMF" ]]; then
        pass "OVMF UEFI firmware: $OVMF ($(du -h "$OVMF" | cut -f1))"
    else
        fail "OVMF firmware not found"
    fi
}

# ── P3: ARM64 System Emulation ───────────────────────────────────

p3() {
    hdr "P3: ARM64 System Emulation (Snapdragon target)"

    # 13. QEMU aarch64 system
    if command -v qemu-system-aarch64 &>/dev/null; then
        pass "qemu-system-aarch64: $(qemu-system-aarch64 --version 2>&1 | head -1)"
    else
        fail "qemu-system-aarch64 not installed"
    fi

    # 14. ARM64 virt machine
    if command -v qemu-system-aarch64 &>/dev/null; then
        ARM_VM=$(timeout 5 qemu-system-aarch64 \
            -M virt -cpu cortex-a76 -m 256 \
            -display none -nographic -no-reboot \
            -kernel /dev/null 2>&1 || true)
        if echo "$ARM_VM" | grep -qi "error.*machine\|unsupported"; then
            fail "ARM64 virt machine rejected"
        else
            pass "ARM64 virt machine accepted (cortex-a76 emulation)"
        fi
    else
        skip "ARM64 virt machine — qemu-system-aarch64 missing"
    fi

    # 15. ARM64 UEFI firmware
    AARM=""
    for f in /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
        [[ -f "$f" ]] && AARM="$f" && break
    done
    if [[ -n "$AARM" ]]; then
        pass "ARM64 UEFI firmware: $AARM ($(du -h "$AARM" | cut -f1))"
    else
        fail "ARM64 UEFI firmware not found"
    fi
}

# ── P4: Container + CI ───────────────────────────────────────────

p4() {
    hdr "P4: Container + CI Environment"

    # 16. Podman
    if command -v podman &>/dev/null; then
        pass "podman: $(podman --version 2>&1)"
    else
        fail "podman not found"
    fi

    # 17. libvirt
    if command -v virsh &>/dev/null; then
        pass "virsh: $(virsh --version 2>&1)"
        if systemctl is-active libvirtd &>/dev/null 2>&1 || systemctl is-active virtqemud &>/dev/null 2>&1; then
            pass "libvirt daemon running"
        else
            skip "libvirt daemon not running"
        fi
    else
        skip "virsh not installed"
    fi

    # 18. RPM tools
    command -v rpmbuild &>/dev/null && pass "rpmbuild available" || skip "rpmbuild not found"
    command -v createrepo_c &>/dev/null && pass "createrepo_c available" || skip "createrepo_c not found"

    # 19. Project structure
    PROJ="${PROJ_DIR:-/home/user/qubes-kvm-fork}"
    if [[ -d "$PROJ" ]]; then
        [[ -f "$PROJ/Makefile" ]] && pass "Project Makefile" || fail "Makefile missing"
        [[ -d "$PROJ/scripts" ]] && pass "scripts/ dir" || fail "scripts/ missing"
        [[ -d "$PROJ/test" ]] && pass "test/ dir" || fail "test/ missing"
    else
        skip "Project not deployed at $PROJ"
    fi
}

# ── Summary ───────────────────────────────────────────────────────

summary() {
    hdr "RESULTS"
    echo "  Total:   $N"
    echo "  Passed:  $P"
    echo "  Failed:  $F"
    echo "  Skipped: $S"
    echo ""
    if [[ $F -eq 0 ]]; then
        echo "  >>> ALL PROBES PASSED <<<"
    else
        echo "  >>> $F PROBE(S) FAILED <<<"
    fi
    return $F
}

# ── Main ──────────────────────────────────────────────────────────

case "${1:-all}" in
    p0) p0; summary ;;
    p1) p1; summary ;;
    p2) p2; summary ;;
    p3) p3; summary ;;
    p4) p4; summary ;;
    all) p0; p1; p2; p3; p4; summary ;;
    *)  echo "Usage: $0 [p0|p1|p2|p3|p4|all]"
        echo "  p0 = Foundation (KVM + QEMU)"
        echo "  p1 = Build Chain (native + cross)"
        echo "  p2 = Xen-on-KVM Emulation"
        echo "  p3 = ARM64 System Emulation"
        echo "  p4 = Container + CI"
        exit 1 ;;
esac
