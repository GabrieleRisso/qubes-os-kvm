#!/bin/bash
# in-vm-tests.sh — Tests that run INSIDE the QEMU test VM
# Verifies that the KVM+Xen shim environment works correctly.
#
# Run this inside a guest VM launched with Xen HVM emulation to verify
# the full Xen-on-KVM stack is operational.
#
# Usage:
#   bash in-vm-tests.sh          # run all tests
#   bash in-vm-tests.sh --xen    # expect Xen mode (fail if not detected)
set -euo pipefail

EXPECT_XEN="${1:-}"
FAILURES=0
PASSES=0
INFOS=0

log()  { echo "[in-vm] $*"; }
pass() { PASSES=$((PASSES + 1)); echo "  PASS: $*"; }
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL: $*"; }
info() { INFOS=$((INFOS + 1)); echo "  INFO: $*"; }

log "=== In-VM Integration Tests ==="
log "Hostname: $(hostname 2>/dev/null || echo unknown)"
log "Kernel:   $(uname -r)"
log "Arch:     $(uname -m)"
log "Mode:     ${EXPECT_XEN:-auto-detect}"
log ""

# ── 1. Hypervisor detection ──────────────────────────────────────

log "--- Test 1: Hypervisor detection ---"
XEN_DETECTED=false

if [[ -f /sys/hypervisor/type ]]; then
    HV_TYPE=$(cat /sys/hypervisor/type)
    log "  /sys/hypervisor/type = $HV_TYPE"
    if [[ "$HV_TYPE" == "xen" ]]; then
        pass "Guest detects Xen hypervisor (via KVM shim)"
        XEN_DETECTED=true
    else
        if [[ "$EXPECT_XEN" == "--xen" ]]; then
            fail "Expected Xen but got '$HV_TYPE'"
        else
            info "Hypervisor is '$HV_TYPE' (non-Xen mode)"
        fi
    fi
else
    if [[ "$EXPECT_XEN" == "--xen" ]]; then
        fail "/sys/hypervisor/type missing (expected Xen hypervisor)"
    else
        info "No /sys/hypervisor/type (standard KVM mode)"
    fi
fi

# ── 2. Xen CPUID detection in dmesg ─────────────────────────────

log "--- Test 2: Xen CPUID / dmesg detection ---"
XEN_DMESG=$(dmesg 2>/dev/null | grep -i "xen" | head -10 || true)
if [[ -n "$XEN_DMESG" ]]; then
    pass "Xen references found in dmesg"
    echo "$XEN_DMESG" | while IFS= read -r line; do
        log "  dmesg: $line"
    done
else
    if [[ "$EXPECT_XEN" == "--xen" ]]; then
        fail "No Xen references in dmesg"
    else
        info "No Xen references in dmesg (standard KVM mode)"
    fi
fi

# ── 3. Xen PV block devices ─────────────────────────────────────

log "--- Test 3: Xen PV block devices ---"
XVD_DEVS=$(ls /dev/xvd* 2>/dev/null || true)
if [[ -n "$XVD_DEVS" ]]; then
    pass "Xen PV block devices present: $XVD_DEVS"
else
    if $XEN_DETECTED; then
        info "Xen detected but no xvd* devices (may use virtio fallback)"
    else
        info "No xvd* devices (virtio mode)"
    fi
fi

# ── 4. Xen PV kernel modules ────────────────────────────────────

log "--- Test 4: Xen PV kernel modules ---"
XEN_MODULES=""
for mod in xen_blkfront xen_netfront xen_scsifront xen_pcifront \
           xen_fbfront xen_kbdfront xenfs xen_privcmd; do
    if lsmod 2>/dev/null | grep -q "^${mod//-/_}"; then
        XEN_MODULES="$XEN_MODULES $mod"
    fi
done
if [[ -n "$XEN_MODULES" ]]; then
    pass "Xen PV modules loaded:$XEN_MODULES"
else
    if $XEN_DETECTED; then
        info "Xen detected but no PV modules loaded (built-in or not needed)"
        # Check if they're built into the kernel
        XEN_BUILTIN=$(grep -c "CONFIG_XEN.*=y" /boot/config-"$(uname -r)" 2>/dev/null || echo 0)
        if [[ "$XEN_BUILTIN" -gt 0 ]]; then
            info "$XEN_BUILTIN Xen configs built into kernel"
        fi
    else
        info "No Xen PV modules loaded (standard KVM mode)"
    fi
fi

# ── 5. /proc/xen directory ──────────────────────────────────────

log "--- Test 5: /proc/xen interface ---"
if [[ -d /proc/xen ]]; then
    pass "/proc/xen directory exists"
    for f in capabilities privcmd xenbus xsd_port; do
        if [[ -e "/proc/xen/$f" ]]; then
            if [[ -r "/proc/xen/$f" && "$f" == "capabilities" ]]; then
                local_caps=$(cat "/proc/xen/$f" 2>/dev/null || true)
                pass "  /proc/xen/$f = '$local_caps'"
            else
                pass "  /proc/xen/$f present"
            fi
        fi
    done
else
    if $XEN_DETECTED; then
        info "/proc/xen not mounted (xenfs not loaded?)"
        info "  Try: modprobe xenfs && mount -t xenfs xenfs /proc/xen"
    else
        info "No /proc/xen (standard KVM mode)"
    fi
fi

# ── 6. Xen sysfs entries ────────────────────────────────────────

log "--- Test 6: Xen sysfs entries ---"
if [[ -d /sys/hypervisor ]]; then
    for entry in type version/major version/minor extra; do
        if [[ -f "/sys/hypervisor/$entry" ]]; then
            val=$(cat "/sys/hypervisor/$entry" 2>/dev/null || true)
            pass "/sys/hypervisor/$entry = '$val'"
        fi
    done
else
    if $XEN_DETECTED; then
        fail "/sys/hypervisor directory missing despite Xen detection"
    else
        info "No /sys/hypervisor (standard KVM mode)"
    fi
fi

# ── 7. Virtio devices (KVM-native devices alongside Xen) ────────

log "--- Test 7: Virtio devices ---"
VIRTIO_DEVS=$(find /sys/bus/virtio/devices/ -maxdepth 1 -mindepth 1 2>/dev/null | wc -l || echo 0)
if [[ "$VIRTIO_DEVS" -gt 0 ]]; then
    pass "$VIRTIO_DEVS virtio device(s) on bus"
    for vdev in /sys/bus/virtio/devices/virtio*; do
        [[ -d "$vdev" ]] || continue
        modalias=$(cat "$vdev/modalias" 2>/dev/null || echo "?")
        log "  $(basename "$vdev"): $modalias"
    done
else
    info "No virtio devices found"
fi

# ── 8. Network connectivity ─────────────────────────────────────

log "--- Test 8: Network ---"
if ip link show 2>/dev/null | grep -q "state UP"; then
    pass "At least one network interface is UP"
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        pass "External network connectivity OK (8.8.8.8)"
    elif ping -c 1 -W 3 10.0.2.2 &>/dev/null; then
        pass "QEMU SLIRP gateway reachable (10.0.2.2)"
    else
        fail "No network connectivity"
    fi
else
    fail "No network interfaces in UP state"
fi

# ── 9. vchan-socket availability ────────────────────────────────

log "--- Test 9: vchan-socket ---"
if [[ -d /var/run/vchan ]] || command -v vchan-socket-test &>/dev/null; then
    pass "vchan-socket infrastructure present"
else
    info "vchan-socket not installed yet (expected in early dev)"
fi

# ── 10. qrexec agent ────────────────────────────────────────────

log "--- Test 10: qrexec agent ---"
if command -v qrexec-agent &>/dev/null; then
    pass "qrexec-agent installed"
    if systemctl is-active qubes-qrexec-agent &>/dev/null; then
        pass "qubes-qrexec-agent service running"
    else
        info "qubes-qrexec-agent not running"
    fi
else
    info "qrexec-agent not installed (expected in base VM)"
fi

# ── 11. qubesdb agent ───────────────────────────────────────────

log "--- Test 11: qubesdb agent ---"
if command -v qubesdb-read &>/dev/null; then
    pass "qubesdb-read available"
    VM_NAME=$(qubesdb-read /name 2>/dev/null || true)
    if [[ -n "$VM_NAME" ]]; then
        pass "QubesDB /name = '$VM_NAME'"
    else
        info "QubesDB not reachable (qubesdb-daemon may not be running)"
    fi
else
    info "qubesdb not installed (expected in base VM)"
fi

# ── 12. Nested virt capability ──────────────────────────────────

log "--- Test 12: Nested virt capability ---"
if [[ -e /dev/kvm ]]; then
    pass "/dev/kvm available inside VM (nested virt works)"
else
    info "/dev/kvm not in VM (nested virt not configured)"
fi

# ── Summary ──────────────────────────────────────────────────────

log ""
log "=== Results ==="
log "Passed: $PASSES"
log "Failed: $FAILURES"
log "Info:   $INFOS"
if $XEN_DETECTED; then
    log "Xen HVM emulation: DETECTED"
else
    log "Xen HVM emulation: NOT detected (standard KVM mode)"
fi
log ""
[[ $FAILURES -eq 0 ]] && log "RESULT: ALL TESTS PASSED" || log "RESULT: $FAILURES TEST(S) FAILED"
exit $FAILURES
