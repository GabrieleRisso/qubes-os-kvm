#!/bin/bash
# run-tests.sh — Run all tests (inside builder container or locally)
set -euo pipefail

WORKSPACE="${1:-/workspace}"
cd "$WORKSPACE"

log() { echo "[test] $*"; }
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0
TESTS=0

# ── Test 1: Project structure ─────────────────────────────────────
log "=== Test 1: Project structure ==="
TESTS=$((TESTS + 1))
for dir in scripts test patches configs; do
    [[ -d "$dir" ]] && pass "$dir/ exists" || fail "$dir/ missing"
done
[[ -f Makefile ]] && pass "Makefile exists" || fail "Makefile missing"
[[ -f Containerfile.builder ]] && pass "Containerfile.builder exists" || fail "Containerfile.builder missing"

# ── Test 2: Script syntax ────────────────────────────────────────
log "=== Test 2: Script syntax ==="
TESTS=$((TESTS + 1))
for script in scripts/*.sh test/*.sh; do
    [[ -f "$script" ]] || continue
    if bash -n "$script" 2>/dev/null; then
        pass "$script syntax OK"
    else
        fail "$script syntax error"
    fi
done

# ── Test 3: Makefile targets ─────────────────────────────────────
log "=== Test 3: Makefile targets ==="
TESTS=$((TESTS + 1))
for target in help info setup clone build test vm-create vm-start clean; do
    if make -n "$target" &>/dev/null; then
        pass "make $target (dry-run OK)"
    else
        fail "make $target (dry-run failed)"
    fi
done

# ── Test 4: QEMU Xen emulation support ──────────────────────────
log "=== Test 4: QEMU Xen HVM emulation ==="
TESTS=$((TESTS + 1))
if command -v qemu-system-x86_64 &>/dev/null; then
    # Check if QEMU supports xen-version property
    if qemu-system-x86_64 -accel help 2>&1 | grep -q kvm; then
        pass "QEMU supports KVM accelerator"
    else
        fail "QEMU KVM accelerator not listed"
    fi
    pass "QEMU available: $(qemu-system-x86_64 --version | head -1)"
else
    fail "qemu-system-x86_64 not found"
fi

# ── Test 5: Container engine ────────────────────────────────────
log "=== Test 5: Container engine ==="
TESTS=$((TESTS + 1))
if command -v podman &>/dev/null; then
    pass "podman $(podman --version 2>&1 | grep -oP '[\d.]+')"
elif command -v docker &>/dev/null; then
    pass "docker $(docker --version 2>&1 | grep -oP '[\d.]+')"
else
    fail "No container engine (podman or docker)"
fi

# ── Test 6: KVM availability ────────────────────────────────────
log "=== Test 6: KVM availability ==="
TESTS=$((TESTS + 1))
if [[ -e /dev/kvm ]]; then
    pass "/dev/kvm present — full VM testing available"
    # Check nested VMX
    nested=$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || \
             cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo "N/A")
    if [[ "$nested" == "Y" || "$nested" == "1" ]]; then
        pass "Nested virtualization: ENABLED"
    else
        log "  INFO: Nested virtualization: DISABLED (needed for Xen-in-KVM)"
        log "        Run: sudo modprobe kvm_intel nested=1"
    fi
else
    log "  INFO: /dev/kvm not present (Qubes AppVM or no KVM support)"
    log "        VM testing limited to TCG mode (slow)"
    log "        Use Lenovo laptop for full testing"
fi

# ── Summary ──────────────────────────────────────────────────────
log ""
log "=== Summary ==="
log "Tests run: $TESTS"
log "Failures:  $FAILURES"

if [[ $FAILURES -gt 0 ]]; then
    log "RESULT: SOME TESTS FAILED"
    exit 1
else
    log "RESULT: ALL TESTS PASSED"
    exit 0
fi
