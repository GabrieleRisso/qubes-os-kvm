#!/bin/bash
# in-vm-tests.sh — Tests that run INSIDE the QEMU test VM
# Verifies that the KVM+Xen shim environment works correctly
set -euo pipefail

log() { echo "[in-vm] $*"; }
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAILURES=$((FAILURES + 1)); }

FAILURES=0

log "=== In-VM Integration Tests ==="
log "Hostname: $(hostname)"
log "Kernel:   $(uname -r)"
log ""

# Test 1: Check if guest sees Xen hypervisor (when running xen-test mode)
log "--- Test: Hypervisor detection ---"
if [[ -f /sys/hypervisor/type ]]; then
    HV_TYPE=$(cat /sys/hypervisor/type)
    log "  Hypervisor type: $HV_TYPE"
    if [[ "$HV_TYPE" == "xen" ]]; then
        pass "Guest detects Xen hypervisor (via KVM shim)"
    else
        log "  INFO: Hypervisor is '$HV_TYPE' (expected in non-Xen mode)"
    fi
else
    log "  INFO: No /sys/hypervisor/type (running in standard KVM mode)"
fi

# Test 2: Check for Xen PV devices
log "--- Test: Xen PV devices ---"
if ls /dev/xvd* 2>/dev/null; then
    pass "Xen PV block devices present"
else
    log "  INFO: No xvd* devices (running in virtio mode)"
fi

# Test 3: Check vchan-socket availability
log "--- Test: vchan-socket ---"
if [[ -d /var/run/vchan ]] || command -v vchan-socket-test &>/dev/null; then
    pass "vchan-socket infrastructure present"
else
    log "  INFO: vchan-socket not installed yet (expected in early dev)"
fi

# Test 4: Check qrexec-agent
log "--- Test: qrexec agent ---"
if command -v qrexec-agent &>/dev/null; then
    pass "qrexec-agent installed"
elif systemctl is-active qubes-qrexec-agent &>/dev/null; then
    pass "qrexec-agent running"
else
    log "  INFO: qrexec-agent not installed (expected in base VM)"
fi

# Test 5: Network connectivity
log "--- Test: Network ---"
if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
    pass "Network connectivity OK"
else
    fail "No network connectivity"
fi

# Test 6: Check virtualization capabilities (for nested testing)
log "--- Test: Nested virt capability ---"
if [[ -e /dev/kvm ]]; then
    pass "/dev/kvm available inside VM (nested virt works)"
else
    log "  INFO: /dev/kvm not in VM (nested virt not configured or not needed)"
fi

# Summary
log ""
log "=== Results ==="
log "Failures: $FAILURES"
[[ $FAILURES -eq 0 ]] && log "ALL PASSED" || log "SOME FAILED"
exit $FAILURES
