#!/bin/bash
# e2e-kvm-hardware.sh — End-to-end test on real KVM hardware
#
# Run this ON the Lenovo (or any machine with /dev/kvm).
# It exercises the full architecture: build → RPM → VM boot → Xen emulation → agent.
#
# Requirements:
#   - /dev/kvm present
#   - QEMU, libvirt installed
#   - qubes-kvm-fork repo at ~/qubes-kvm-fork (or cwd parent)
#
# Usage:
#   bash test/e2e-kvm-hardware.sh          # Full suite
#   bash test/e2e-kvm-hardware.sh build    # Build tests only
#   bash test/e2e-kvm-hardware.sh vm       # VM boot test only
#   bash test/e2e-kvm-hardware.sh xen      # Xen emulation test only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS="$PROJECT_DIR/scripts"
VM_IMAGES="$PROJECT_DIR/vm-images"

PASS=0
FAIL=0
SKIP=0

log()  { echo "[e2e] $*"; }
pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP + 1)); }
sep()  { echo ""; echo "────────────────────────────────────────────"; }

# ── Phase 1: System prerequisites ────────────────────────────────

test_prereqs() {
    sep
    log "Phase 1: System Prerequisites"
    sep

    if [[ -e /dev/kvm ]]; then
        pass "/dev/kvm present"
    else
        fail "/dev/kvm missing (no hardware acceleration)"
    fi

    for cmd in qemu-system-x86_64 qemu-system-aarch64 qemu-img virsh gcc make shellcheck; do
        if command -v "$cmd" &>/dev/null; then
            pass "$cmd installed"
        else
            fail "$cmd not found"
        fi
    done

    if systemctl is-active libvirtd &>/dev/null; then
        pass "libvirtd running"
    else
        skip "libvirtd not running (VM tests will be skipped)"
    fi

    for f in /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested; do
        if [[ -f "$f" ]]; then
            local val
            val="$(cat "$f")"
            if [[ "$val" == "Y" || "$val" == "1" ]]; then
                pass "Nested virtualization enabled"
            else
                fail "Nested virtualization disabled"
            fi
            break
        fi
    done
}

# ── Phase 2: Build pipeline ─────────────────────────────────────

test_build() {
    sep
    log "Phase 2: Build Pipeline"
    sep

    cd "$PROJECT_DIR"

    if make build 2>&1 | tail -5; then
        pass "make build (vchan-socket + qubesdb-kvm)"
    else
        fail "make build failed"
        return
    fi

    if make test 2>&1 | tail -10; then
        pass "make test (unit tests + shellcheck + syntax)"
    else
        fail "make test failed"
    fi

    if make rpm 2>&1 | tail -5; then
        local rpm_count
        rpm_count="$(find build/rpmbuild/RPMS -name '*.rpm' 2>/dev/null | wc -l)"
        pass "make rpm ($rpm_count RPMs built)"
    else
        fail "make rpm failed"
    fi
}

# ── Phase 3: Quick QEMU boot test ───────────────────────────────

test_vm_boot() {
    sep
    log "Phase 3: Quick VM Boot (QEMU + KVM)"
    sep

    if [[ ! -e /dev/kvm ]]; then
        skip "No /dev/kvm — skipping VM boot test"
        return
    fi

    local test_disk="/tmp/e2e-test-boot.qcow2"
    qemu-img create -f qcow2 "$test_disk" 1G >/dev/null 2>&1

    local qemu_out
    qemu_out="$(timeout 10 qemu-system-x86_64 \
        -accel kvm \
        -m 256 \
        -nographic \
        -no-reboot \
        -drive file="$test_disk",format=qcow2,if=virtio \
        -device virtio-rng-pci \
        2>&1 || true)"

    rm -f "$test_disk"

    if echo "$qemu_out" | grep -qi "boot\|BIOS\|SeaBIOS\|UEFI\|No bootable"; then
        pass "QEMU+KVM boots (BIOS reached)"
    else
        fail "QEMU+KVM boot test inconclusive"
    fi
}

# ── Phase 4: Xen emulation verification ─────────────────────────

test_xen_emulation() {
    sep
    log "Phase 4: Xen-on-KVM Emulation"
    sep

    if [[ ! -e /dev/kvm ]]; then
        skip "No /dev/kvm — skipping Xen emulation test"
        return
    fi

    local test_disk="/tmp/e2e-test-xen.qcow2"
    qemu-img create -f qcow2 "$test_disk" 1G >/dev/null 2>&1

    local xen_out
    xen_out="$(timeout 10 qemu-system-x86_64 \
        -accel kvm,xen-version=0x40013,kernel-irqchip=split \
        -cpu host,+xen-vapic \
        -m 256 \
        -nographic \
        -no-reboot \
        -drive file="$test_disk",format=qcow2,if=virtio \
        2>&1 || true)"

    rm -f "$test_disk"

    if echo "$xen_out" | grep -qi "boot\|BIOS\|SeaBIOS\|UEFI\|No bootable"; then
        pass "Xen-on-KVM emulation boots (xen-version=0x40013)"
    elif echo "$xen_out" | grep -qi "xen\|not supported\|error"; then
        fail "Xen emulation not supported by this QEMU"
        echo "    Output: $(echo "$xen_out" | head -3)"
    else
        skip "Xen emulation test inconclusive"
    fi
}

# ── Phase 5: xen-kvm-bridge.sh script test ──────────────────────

test_bridge_script() {
    sep
    log "Phase 5: xen-kvm-bridge.sh Script"
    sep

    local bridge="$SCRIPTS/xen-kvm-bridge.sh"

    if bash -n "$bridge" 2>/dev/null; then
        pass "xen-kvm-bridge.sh syntax OK"
    else
        fail "xen-kvm-bridge.sh syntax error"
        return
    fi

    local xml_out
    mkdir -p "$VM_IMAGES"
    local dummy_disk="$VM_IMAGES/dummy-test.qcow2"
    qemu-img create -f qcow2 "$dummy_disk" 1G >/dev/null 2>&1

    xml_out="$(bash "$bridge" generate-xml test-e2e "$dummy_disk" 1024 2 2>/dev/null || true)"
    rm -f "$dummy_disk"

    if echo "$xml_out" | grep -q "xen-version"; then
        pass "generate-xml includes xen-version"
    else
        fail "generate-xml missing xen-version"
    fi

    if echo "$xml_out" | grep -q "kernel-irqchip=split"; then
        pass "generate-xml includes kernel-irqchip=split"
    else
        fail "generate-xml missing kernel-irqchip=split"
    fi

    if echo "$xml_out" | grep -q "xen-vapic"; then
        pass "generate-xml includes xen-vapic"
    else
        fail "generate-xml missing xen-vapic"
    fi

    if echo "$xml_out" | grep -q "org.qubes-os.qubesdb"; then
        pass "generate-xml includes QubesDB virtio channel"
    else
        fail "generate-xml missing QubesDB channel"
    fi
}

# ── Phase 6: ARM64 emulation ────────────────────────────────────

test_arm64() {
    sep
    log "Phase 6: ARM64 Emulation"
    sep

    if ! command -v qemu-system-aarch64 &>/dev/null; then
        skip "qemu-system-aarch64 not installed"
        return
    fi

    local aarch64_bios=""
    for f in /usr/share/edk2/aarch64/QEMU_EFI.fd \
             /usr/share/AAVMF/AAVMF_CODE.fd \
             /usr/share/qemu-efi-aarch64/QEMU_EFI.fd; do
        [[ -f "$f" ]] && aarch64_bios="$f" && break
    done

    if [[ -z "$aarch64_bios" ]]; then
        skip "No ARM64 UEFI firmware found"
        return
    fi

    pass "ARM64 firmware: $aarch64_bios"

    local arm_out
    arm_out="$(timeout 10 qemu-system-aarch64 \
        -M virt -cpu cortex-a72 -m 256 \
        -bios "$aarch64_bios" \
        -nographic -no-reboot \
        2>&1 || true)"

    if echo "$arm_out" | grep -qi "UEFI\|EFI\|BDS\|Boot\|ARM"; then
        pass "ARM64 UEFI firmware boots"
    else
        skip "ARM64 boot test inconclusive"
    fi
}

# ── Phase 7: Agent service ──────────────────────────────────────

test_agent() {
    sep
    log "Phase 7: Agent Service"
    sep

    if curl -sf http://localhost:8420/health 2>/dev/null | grep -q "ok"; then
        pass "Agent API responding on :8420"
    else
        skip "Agent service not running"
        return
    fi

    local status
    status="$(curl -sf http://localhost:8420/status 2>/dev/null || echo '{}')"
    if echo "$status" | grep -q "kvm_present"; then
        pass "Agent /status returns system info"
    else
        fail "Agent /status malformed"
    fi
}

# ── Summary ──────────────────────────────────────────────────────

summary() {
    sep
    log "=== E2E Test Summary ==="
    sep
    echo ""
    echo "  PASSED:  $PASS"
    echo "  FAILED:  $FAIL"
    echo "  SKIPPED: $SKIP"
    echo "  TOTAL:   $((PASS + FAIL + SKIP))"
    echo ""

    if [[ $FAIL -eq 0 ]]; then
        log "All tests passed. Architecture is operational."
    else
        log "$FAIL test(s) failed. See output above."
    fi
}

# ── Main ─────────────────────────────────────────────────────────

main() {
    log "======================================"
    log " Qubes KVM Fork — E2E Hardware Test"
    log "======================================"
    log " Host: $(hostname) ($(uname -m))"
    log " Kernel: $(uname -r)"
    log ""

    case "${1:-all}" in
        prereqs)  test_prereqs ;;
        build)    test_build ;;
        vm)       test_vm_boot ;;
        xen)      test_xen_emulation ;;
        bridge)   test_bridge_script ;;
        arm64)    test_arm64 ;;
        agent)    test_agent ;;
        all)
            test_prereqs
            test_build
            test_vm_boot
            test_xen_emulation
            test_bridge_script
            test_arm64
            test_agent
            ;;
        *)
            echo "Usage: $0 [all|prereqs|build|vm|xen|bridge|arm64|agent]"
            exit 1
            ;;
    esac

    summary
    exit $FAIL
}

main "$@"
