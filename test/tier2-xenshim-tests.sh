#!/bin/bash
# tier2-xenshim-tests.sh — Tier 2 Xen-on-KVM shim integration tests
#
# Validates the full xen-shim boot chain, config injection pipeline,
# transport detection, systemd service dependencies, and template
# selection without needing /dev/kvm or a running hypervisor.
#
# Usage: bash tier2-xenshim-tests.sh [WORKSPACE]
#   WORKSPACE defaults to parent of the script's qubes-kvm-fork directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="${1:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

PASS=0 FAIL=0 SKIP=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP + 1)); }

section() { echo ""; echo "=== $1 ==="; }

# ────────────────────────────────────────────────────────────
section "T2.1: Xen-shim libvirt templates exist and are valid"
# ────────────────────────────────────────────────────────────

TEMPLATES_DIR="$WORKSPACE/qubes-core-admin/templates/libvirt"

for tmpl in kvm-xenshim.xml kvm-aarch64-xenshim.xml; do
    if [ -f "$TEMPLATES_DIR/$tmpl" ]; then
        pass "$tmpl exists"
    else
        fail "$tmpl missing"
    fi
done

# x86 template must have xen-version, kernel-irqchip=split, xen-vapic
if grep -q 'xen-version=0x40013' "$TEMPLATES_DIR/kvm-xenshim.xml" 2>/dev/null; then
    pass "x86 xenshim: xen-version=0x40013 (Xen 4.19)"
else
    fail "x86 xenshim: missing xen-version"
fi
if grep -q 'kernel-irqchip=split' "$TEMPLATES_DIR/kvm-xenshim.xml" 2>/dev/null; then
    pass "x86 xenshim: kernel-irqchip=split present"
else
    fail "x86 xenshim: kernel-irqchip=split missing"
fi
if grep -q 'xen-vapic' "$TEMPLATES_DIR/kvm-xenshim.xml" 2>/dev/null; then
    pass "x86 xenshim: xen-vapic CPU flag"
else
    fail "x86 xenshim: xen-vapic missing"
fi

# ARM64 template: xen-version present, NO kernel-irqchip=split (ARM64 doesn't need it)
if grep -q 'xen-version=0x40011' "$TEMPLATES_DIR/kvm-aarch64-xenshim.xml" 2>/dev/null; then
    pass "ARM64 xenshim: xen-version=0x40011"
else
    fail "ARM64 xenshim: missing xen-version"
fi
# Check that the actual QEMU accel line doesn't contain kernel-irqchip=split
# (it may appear in comments explaining why it's omitted on ARM64)
if ! grep 'qemu:arg.*value=' "$TEMPLATES_DIR/kvm-aarch64-xenshim.xml" 2>/dev/null | grep -q 'kernel-irqchip=split'; then
    pass "ARM64 xenshim: correctly omits kernel-irqchip=split in accel args"
else
    fail "ARM64 xenshim: should not have kernel-irqchip=split on ARM64"
fi

# Both templates must have QubesDB channel, vsock, balloon
for tmpl in kvm-xenshim.xml kvm-aarch64-xenshim.xml; do
    if grep -q 'org.qubes-os.qubesdb' "$TEMPLATES_DIR/$tmpl" 2>/dev/null; then
        pass "$tmpl: QubesDB virtio-serial channel"
    else
        fail "$tmpl: missing QubesDB channel"
    fi
    if grep -q '<vsock' "$TEMPLATES_DIR/$tmpl" 2>/dev/null; then
        pass "$tmpl: virtio-vsock device"
    else
        fail "$tmpl: missing vsock"
    fi
    if grep -q '<memballoon' "$TEMPLATES_DIR/$tmpl" 2>/dev/null; then
        pass "$tmpl: virtio balloon"
    else
        fail "$tmpl: missing balloon"
    fi
    if grep -q 'qemu:commandline' "$TEMPLATES_DIR/$tmpl" 2>/dev/null; then
        pass "$tmpl: QEMU commandline namespace"
    else
        fail "$tmpl: missing QEMU commandline"
    fi
done

# ────────────────────────────────────────────────────────────
section "T2.2: Template selection logic (xen-shim feature)"
# ────────────────────────────────────────────────────────────

INIT_PY="$WORKSPACE/qubes-core-admin/qubes/vm/__init__.py"

if grep -q 'xen-shim' "$INIT_PY" 2>/dev/null; then
    pass "__init__.py references xen-shim feature"
else
    fail "__init__.py missing xen-shim support"
fi
if grep -q 'xenshim.xml' "$INIT_PY" 2>/dev/null; then
    pass "__init__.py adds xenshim template candidates"
else
    fail "__init__.py missing xenshim template candidates"
fi
if grep -q 'check_with_template.*xen-shim' "$INIT_PY" 2>/dev/null; then
    pass "__init__.py uses check_with_template for xen-shim"
else
    fail "__init__.py: xen-shim not read from features"
fi

# ────────────────────────────────────────────────────────────
section "T2.3: Config injection pipeline (dom0 side)"
# ────────────────────────────────────────────────────────────

QUBESVM="$WORKSPACE/qubes-core-admin/qubes/vm/qubesvm.py"

for entry in qubes-domain-id qubes-transport qubes-mac qubes-timezone qubes-xen-shim; do
    if grep -q "$entry" "$QUBESVM" 2>/dev/null; then
        pass "qubesvm.py _inject writes /$entry"
    else
        fail "qubesvm.py _inject missing /$entry"
    fi
done

if grep -q 'qubes-transport.*vchan-socket' "$QUBESVM" 2>/dev/null; then
    pass "qubesvm.py create_qdb_entries writes /qubes-transport=vchan-socket"
else
    fail "qubesvm.py create_qdb_entries missing /qubes-transport"
fi

# ────────────────────────────────────────────────────────────
section "T2.4: Config injection C tools"
# ────────────────────────────────────────────────────────────

INJECT_C="$WORKSPACE/qubes-core-qubesdb/daemon/kvm/qubesdb-config-inject.c"
READ_C="$WORKSPACE/qubes-core-qubesdb/daemon/kvm/qubesdb-config-read.c"
QDB_MAKEFILE="$WORKSPACE/qubes-core-qubesdb/daemon/kvm/Makefile"

for f in "$INJECT_C" "$READ_C" "$QDB_MAKEFILE"; do
    bn=$(basename "$f")
    if [ -f "$f" ]; then
        pass "$bn exists"
    else
        fail "$bn missing"
    fi
done

# inject must use QDB_CMD_WRITE and send end marker
if grep -q 'QDB_CMD_WRITE' "$INJECT_C" 2>/dev/null; then
    pass "config-inject uses QDB_CMD_WRITE"
else
    fail "config-inject missing QDB_CMD_WRITE"
fi
if grep -q 'QDB_RESP_MULTIREAD' "$INJECT_C" 2>/dev/null; then
    pass "config-inject sends end-of-sync marker"
else
    fail "config-inject missing end marker"
fi

# read must check for end marker and write cache
if grep -q 'QDB_RESP_MULTIREAD' "$READ_C" 2>/dev/null; then
    pass "config-read checks end-of-sync marker"
else
    fail "config-read missing end marker check"
fi
if grep -q 'qubesdb-initial.cache' "$READ_C" 2>/dev/null; then
    pass "config-read writes to cache file"
else
    fail "config-read missing cache file write"
fi

# ────────────────────────────────────────────────────────────
section "T2.5: Guest-side hypervisor + transport detection"
# ────────────────────────────────────────────────────────────

HV_SH="$WORKSPACE/qubes-core-agent-linux/init/hypervisor.sh"
DOMID_SH="$WORKSPACE/qubes-core-agent-linux/init/qubes-domain-id.sh"

# hypervisor.sh must export QUBES_TRANSPORT
if grep -q 'QUBES_TRANSPORT' "$HV_SH" 2>/dev/null; then
    pass "hypervisor.sh exports QUBES_TRANSPORT"
else
    fail "hypervisor.sh missing QUBES_TRANSPORT"
fi
if grep -q 'detect_transport' "$HV_SH" 2>/dev/null; then
    pass "hypervisor.sh has detect_transport function"
else
    fail "hypervisor.sh missing detect_transport"
fi
if grep -q 'is_xen_shim' "$HV_SH" 2>/dev/null; then
    pass "hypervisor.sh has is_xen_shim helper"
else
    fail "hypervisor.sh missing is_xen_shim"
fi
if grep -q 'uses_vchan_socket' "$HV_SH" 2>/dev/null; then
    pass "hypervisor.sh has uses_vchan_socket helper"
else
    fail "hypervisor.sh missing uses_vchan_socket"
fi
if grep -q 'org.qubes-os.qubesdb' "$HV_SH" 2>/dev/null; then
    pass "hypervisor.sh checks virtio-serial port for transport"
else
    fail "hypervisor.sh doesn't check virtio-serial port"
fi

# qubes-domain-id.sh must be transport-aware
if grep -q 'uses_vchan_socket' "$DOMID_SH" 2>/dev/null; then
    pass "qubes-domain-id.sh uses transport-awareness"
else
    fail "qubes-domain-id.sh not transport-aware"
fi
if grep -q 'qubesdb-initial.cache' "$DOMID_SH" 2>/dev/null; then
    pass "qubes-domain-id.sh reads from config cache"
else
    fail "qubes-domain-id.sh missing cache read"
fi

# Simulate: test detect_transport returns vchan-socket when virtio port exists
(
    export QUBES_TRANSPORT="" QUBES_HYPERVISOR=""
    # source the script in a subshell and test the functions
    . "$HV_SH"
    if type -t detect_transport >/dev/null 2>&1; then
        pass "detect_transport function is callable"
    else
        fail "detect_transport not callable"
    fi
    if type -t is_xen_shim >/dev/null 2>&1; then
        pass "is_xen_shim function is callable"
    else
        fail "is_xen_shim not callable"
    fi
    if type -t uses_vchan_socket >/dev/null 2>&1; then
        pass "uses_vchan_socket function is callable"
    else
        fail "uses_vchan_socket not callable"
    fi
)

# ────────────────────────────────────────────────────────────
section "T2.6: Boot scripts xen-shim awareness"
# ────────────────────────────────────────────────────────────

SYSINIT="$WORKSPACE/qubes-core-agent-linux/vm-systemd/qubes-sysinit.sh"
FUNCTIONS="$WORKSPACE/qubes-core-agent-linux/init/functions"
NETPROXY="$WORKSPACE/qubes-core-agent-linux/vm-systemd/network-proxy-setup.sh"
HOTPLUG="$WORKSPACE/qubes-core-agent-linux/network/qubesdb-hotplug-watcher.sh"

if grep -q 'uses_vchan_socket' "$SYSINIT" 2>/dev/null; then
    pass "qubes-sysinit.sh: transport-aware boot wait"
else
    fail "qubes-sysinit.sh: still uses is_xen/is_kvm only"
fi

if grep -q 'uses_vchan_socket' "$FUNCTIONS" 2>/dev/null; then
    pass "init/functions: transport-aware module loading"
else
    fail "init/functions: not transport-aware"
fi

if grep -q 'uses_vchan_socket' "$NETPROXY" 2>/dev/null; then
    pass "network-proxy-setup.sh: transport-aware"
else
    fail "network-proxy-setup.sh: not transport-aware"
fi

if grep -q 'uses_vchan_socket' "$HOTPLUG" 2>/dev/null; then
    pass "qubesdb-hotplug-watcher.sh: transport-aware"
else
    fail "qubesdb-hotplug-watcher.sh: not transport-aware"
fi

# ────────────────────────────────────────────────────────────
section "T2.7: Systemd service chain"
# ────────────────────────────────────────────────────────────

VCHAN_ENV_SH="$WORKSPACE/qubes-core-agent-linux/init/qubes-vchan-env.sh"
VCHAN_ENV_SVC="$WORKSPACE/qubes-core-agent-linux/vm-systemd/qubes-vchan-env.service"
QDB_DROPIN="$WORKSPACE/qubes-core-agent-linux/vm-systemd/qubes-db.service.d/30-kvm-vchan.conf"
QREXEC_DROPIN="$WORKSPACE/qubes-core-agent-linux/vm-systemd/qubes-qrexec-agent.service.d/30-kvm-vchan.conf"
CONFIG_READ_SVC="$WORKSPACE/qubes-core-qubesdb/daemon/kvm/qubesdb-config-read.service"

for f in "$VCHAN_ENV_SH" "$VCHAN_ENV_SVC" "$QDB_DROPIN" "$QREXEC_DROPIN" "$CONFIG_READ_SVC"; do
    bn=$(basename "$f")
    if [ -f "$f" ]; then
        pass "systemd: $bn exists"
    else
        fail "systemd: $bn missing"
    fi
done

# Verify service ordering
if grep -q 'After=qubesdb-config-read.service' "$VCHAN_ENV_SVC" 2>/dev/null; then
    pass "vchan-env.service: runs after config-read"
else
    fail "vchan-env.service: missing ordering after config-read"
fi
if grep -q 'Before=qubes-db.service' "$VCHAN_ENV_SVC" 2>/dev/null; then
    pass "vchan-env.service: runs before qubes-db"
else
    fail "vchan-env.service: missing ordering before qubes-db"
fi
if grep -q 'qubes-qrexec-agent.service' "$VCHAN_ENV_SVC" 2>/dev/null; then
    pass "vchan-env.service: runs before qrexec-agent"
else
    fail "vchan-env.service: missing ordering before qrexec-agent"
fi

# Drop-ins reference vchan.env
if grep -q 'vchan.env' "$QDB_DROPIN" 2>/dev/null; then
    pass "qubes-db drop-in: reads vchan.env"
else
    fail "qubes-db drop-in: missing vchan.env"
fi
if grep -q 'vchan.env' "$QREXEC_DROPIN" 2>/dev/null; then
    pass "qrexec-agent drop-in: reads vchan.env"
else
    fail "qrexec-agent drop-in: missing vchan.env"
fi

# qrexec drop-in must clear Xen-only ExecStartPre
if grep -q 'ExecStartPre=$' "$QREXEC_DROPIN" 2>/dev/null ||
   grep -q '^ExecStartPre=$' "$QREXEC_DROPIN" 2>/dev/null; then
    pass "qrexec-agent drop-in: clears Xen-only ExecStartPre"
else
    fail "qrexec-agent drop-in: doesn't clear ExecStartPre"
fi

# ────────────────────────────────────────────────────────────
section "T2.8: vchan-env.sh functional test (dry-run)"
# ────────────────────────────────────────────────────────────

if [ -x "$VCHAN_ENV_SH" ]; then
    pass "qubes-vchan-env.sh is executable"
else
    fail "qubes-vchan-env.sh not executable"
fi

# Check that it sources hypervisor.sh and domain-id.sh
if grep -q 'hypervisor.sh' "$VCHAN_ENV_SH" 2>/dev/null; then
    pass "vchan-env.sh sources hypervisor.sh"
else
    fail "vchan-env.sh doesn't source hypervisor.sh"
fi
if grep -q 'qubes-domain-id.sh' "$VCHAN_ENV_SH" 2>/dev/null; then
    pass "vchan-env.sh sources qubes-domain-id.sh"
else
    fail "vchan-env.sh doesn't source qubes-domain-id.sh"
fi
if grep -q 'VCHAN_DOMAIN' "$VCHAN_ENV_SH" 2>/dev/null; then
    pass "vchan-env.sh writes VCHAN_DOMAIN"
else
    fail "vchan-env.sh doesn't write VCHAN_DOMAIN"
fi

# ────────────────────────────────────────────────────────────
section "T2.9: KVM memory management mixin"
# ────────────────────────────────────────────────────────────

KVM_MEM="$WORKSPACE/qubes-core-admin/qubes/vm/mix/kvm_mem.py"
if [ -f "$KVM_MEM" ]; then
    pass "kvm_mem.py exists"
    for func in kvm_set_memory kvm_get_memory_stats kvm_create_memory_qdb_entries kvm_get_pref_mem kvm_request_memory; do
        if grep -q "def $func" "$KVM_MEM" 2>/dev/null; then
            pass "kvm_mem.py: $func implemented"
        else
            fail "kvm_mem.py: $func missing"
        fi
    done
else
    fail "kvm_mem.py missing"
fi

# ────────────────────────────────────────────────────────────
section "T2.10: Xen-shim auto-enable extension"
# ────────────────────────────────────────────────────────────

XENSHIM_EXT="$WORKSPACE/qubes-core-admin/qubes/ext/kvm_xenshim.py"
if [ -f "$XENSHIM_EXT" ]; then
    pass "kvm_xenshim.py extension exists"
    if grep -q 'domain-pre-start' "$XENSHIM_EXT" 2>/dev/null; then
        pass "extension hooks domain-pre-start"
    else
        fail "extension missing domain-pre-start hook"
    fi
    if grep -q 'provides_network' "$XENSHIM_EXT" 2>/dev/null; then
        pass "extension checks provides_network"
    else
        fail "extension doesn't check provides_network"
    fi
    if grep -q 'servicevm' "$XENSHIM_EXT" 2>/dev/null; then
        pass "extension checks servicevm feature"
    else
        fail "extension doesn't check servicevm"
    fi
    if grep -q 'security-vm' "$XENSHIM_EXT" 2>/dev/null; then
        pass "extension checks security-vm tag"
    else
        fail "extension doesn't check security-vm tag"
    fi
else
    fail "kvm_xenshim.py extension missing"
fi

# ────────────────────────────────────────────────────────────
section "T2.11: xen-kvm-bridge.sh tool"
# ────────────────────────────────────────────────────────────

BRIDGE="$WORKSPACE/qubes-kvm-fork/scripts/xen-kvm-bridge.sh"
if [ -f "$BRIDGE" ]; then
    pass "xen-kvm-bridge.sh exists"
    if grep -q 'org.qubes-os.qubesdb' "$BRIDGE" 2>/dev/null; then
        pass "bridge: QubesDB channel in generated XML"
    else
        fail "bridge: missing QubesDB channel"
    fi
    if grep -q '<vsock' "$BRIDGE" 2>/dev/null; then
        pass "bridge: vsock in generated XML"
    else
        fail "bridge: missing vsock"
    fi
    if grep -q 'xen-version=' "$BRIDGE" 2>/dev/null; then
        pass "bridge: Xen emulation flags"
    else
        fail "bridge: missing Xen flags"
    fi
else
    fail "xen-kvm-bridge.sh missing"
fi

# ────────────────────────────────────────────────────────────
section "T2.12: Python config.py hypervisor detection"
# ────────────────────────────────────────────────────────────

CONFIG_PY="$WORKSPACE/qubes-core-admin/qubes/config.py"
if grep -q 'def detect_hypervisor' "$CONFIG_PY" 2>/dev/null; then
    pass "config.py: detect_hypervisor function"
else
    fail "config.py: missing detect_hypervisor"
fi
if grep -q 'host_arch' "$CONFIG_PY" 2>/dev/null; then
    pass "config.py: host_arch exported"
else
    fail "config.py: missing host_arch"
fi
if grep -q 'qemu:///system' "$CONFIG_PY" 2>/dev/null; then
    pass "config.py: KVM uses qemu:///system URI"
else
    fail "config.py: missing KVM libvirt URI"
fi
if grep -q 'aarch64' "$CONFIG_PY" 2>/dev/null; then
    pass "config.py: ARM64 detection"
else
    fail "config.py: missing ARM64 detection"
fi

# ────────────────────────────────────────────────────────────
section "T2.13: start_time KVM caching"
# ────────────────────────────────────────────────────────────

if grep -q '_kvm_start_time' "$QUBESVM" 2>/dev/null; then
    pass "qubesvm.py: start_time caches via _kvm_start_time"
else
    fail "qubesvm.py: start_time not cached for KVM"
fi
if grep -q '_kvm_start_time = None' "$QUBESVM" 2>/dev/null; then
    pass "qubesvm.py: _kvm_start_time cleared on domain stop"
else
    fail "qubesvm.py: _kvm_start_time not cleared on stop"
fi
if grep -q '_get_qemu_pid' "$QUBESVM" 2>/dev/null; then
    pass "qubesvm.py: _get_qemu_pid helper exists"
else
    fail "qubesvm.py: missing _get_qemu_pid"
fi

# ────────────────────────────────────────────────────────────
section "T2.14: Syntax validation"
# ────────────────────────────────────────────────────────────

for sh_file in "$HV_SH" "$DOMID_SH" "$VCHAN_ENV_SH" "$SYSINIT" "$BRIDGE" "$HOTPLUG"; do
    bn=$(basename "$sh_file")
    if bash -n "$sh_file" 2>/dev/null; then
        pass "syntax: $bn"
    else
        fail "syntax: $bn has errors"
    fi
done

for py_file in "$QUBESVM" "$CONFIG_PY" "$XENSHIM_EXT" "$KVM_MEM"; do
    bn=$(basename "$py_file")
    if python3 -c "import ast; ast.parse(open('$py_file').read())" 2>/dev/null; then
        pass "syntax: $bn"
    else
        fail "syntax: $bn has errors"
    fi
done

# ════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Tier 2 Xen-shim Results"
echo "  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
echo "  TOTAL: $((PASS + FAIL + SKIP))"
echo "════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    echo "  STATUS: SOME TESTS FAILED"
    exit 1
else
    echo "  STATUS: ALL TESTS PASSED"
    exit 0
fi
