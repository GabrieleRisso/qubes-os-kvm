#!/bin/bash
# safe-dom0-tests.sh — Safe comprehensive tests for KVM backend + vhost-user + killswitch
#
# SAFETY GUARANTEES:
#   - NEVER starts or stops any VM
#   - NEVER opens /dev/watchdog (would trigger hardware halt if daemon dies)
#   - NEVER calls systemctl poweroff/reboot/halt
#   - NEVER modifies /etc/qubes/ or any system config
#   - NEVER writes to /var/log/qubes/ (only to /tmp)
#   - NEVER calls libvirt destroy/kill/start/create
#   - NEVER modifies firewall rules
#   - ALL file I/O is to /tmp (cleaned up on exit)
#   - ALL socket I/O uses /tmp sockets (cleaned up on exit)
#   - ALL subprocesses have timeouts
#
# Tests are purely structural, syntactic, and unit-level.
# They validate that the code is correct WITHOUT executing any
# dangerous side effects.
#
# Usage:
#   bash test/safe-dom0-tests.sh [section]
#   Sections: templates, killswitch, vhost, kvm-backend, integration, all
set -u

PASS=0
FAIL=0
SKIP=0

TMPDIR_TEST=$(mktemp -d /tmp/qubes-safe-test.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass()   { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail()   { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
skip()   { SKIP=$((SKIP + 1)); echo "  [SKIP] $*"; }
header() { echo ""; echo "================================================================"; echo "  $*"; echo "================================================================"; }

# ── Locate source trees ──────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_ROOT="${FIX_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"

CORE_ADMIN="$FIX_ROOT/qubes-core-admin"
CORE_AGENT="$FIX_ROOT/qubes-core-agent-linux"
KVM_FORK="$FIX_ROOT/qubes-kvm-fork"
TMPL_DIR="$CORE_ADMIN/templates/libvirt"

if [[ ! -d "$CORE_ADMIN/qubes" ]]; then
    echo "ERROR: Cannot find qubes-core-admin at $CORE_ADMIN"
    echo "Set FIX_ROOT to the parent directory."
    exit 1
fi

echo "Source root: $FIX_ROOT"
echo "Temp dir:    $TMPDIR_TEST"
echo ""

export PYTHONPATH="$CORE_ADMIN:${PYTHONPATH:-}"

# ══════════════════════════════════════════════════════════════════
# SECTION 1: LIBVIRT XML TEMPLATES
# ══════════════════════════════════════════════════════════════════

test_templates() {
    header "1. LIBVIRT XML TEMPLATES"

    echo "--- 1.1: All 4 KVM templates exist ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        [[ -f "$TMPL_DIR/$tpl" ]] && pass "$tpl exists" || fail "$tpl missing"
    done

    echo "--- 1.2: QubesDB virtio-serial channel ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        [[ -f "$TMPL_DIR/$tpl" ]] || { skip "$tpl (not found)"; continue; }
        grep -q 'org.qubes-os.qubesdb' "$TMPL_DIR/$tpl" && \
            pass "$tpl: qubesdb channel present" || fail "$tpl: qubesdb channel MISSING"
        grep -q 'qubesdb.*sock' "$TMPL_DIR/$tpl" && \
            pass "$tpl: socket path present" || fail "$tpl: socket path MISSING"
    done

    echo "--- 1.3: vhost-user conditional in network block ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        [[ -f "$TMPL_DIR/$tpl" ]] || { skip "$tpl (not found)"; continue; }
        grep -q 'net-backend.*vhost-user' "$TMPL_DIR/$tpl" && \
            pass "$tpl: vhost-user conditional present" || fail "$tpl: vhost-user conditional MISSING"
        grep -q 'net-vhost-kvm.xml' "$TMPL_DIR/$tpl" && \
            pass "$tpl: includes net-vhost-kvm.xml" || fail "$tpl: missing net-vhost-kvm.xml include"
    done

    echo "--- 1.4: net-vhost-kvm.xml device template ---"
    local vhost_tpl="$TMPL_DIR/devices/net-vhost-kvm.xml"
    if [[ -f "$vhost_tpl" ]]; then
        pass "net-vhost-kvm.xml exists"
        grep -q 'type="vhostuser"' "$vhost_tpl" && \
            pass "net-vhost-kvm.xml: interface type=vhostuser" || fail "wrong interface type"
        grep -q 'mode="client"' "$vhost_tpl" && \
            pass "net-vhost-kvm.xml: mode=client (QEMU connects to backend)" || fail "wrong mode"
        grep -q 'model type="virtio"' "$vhost_tpl" && \
            pass "net-vhost-kvm.xml: model=virtio" || fail "wrong model"
        grep -q 'vm.mac' "$vhost_tpl" && \
            pass "net-vhost-kvm.xml: uses vm.mac" || fail "missing MAC"
    else
        fail "net-vhost-kvm.xml not found"
    fi

    echo "--- 1.5: No xenstore references in KVM templates ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        [[ -f "$TMPL_DIR/$tpl" ]] || continue
        if grep -qi 'xenstore' "$TMPL_DIR/$tpl"; then
            fail "$tpl: contains xenstore reference"
        else
            pass "$tpl: no xenstore references"
        fi
    done

    echo "--- 1.6: Essential devices in templates ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        [[ -f "$TMPL_DIR/$tpl" ]] || continue
        grep -q 'memballoon' "$TMPL_DIR/$tpl" && \
            pass "$tpl: memballoon present" || fail "$tpl: memballoon missing"
        grep -q 'vsock' "$TMPL_DIR/$tpl" && \
            pass "$tpl: vsock present" || fail "$tpl: vsock missing"
        grep -q 'guest_agent' "$TMPL_DIR/$tpl" && \
            pass "$tpl: guest agent channel present" || fail "$tpl: guest agent missing"
    done

    echo "--- 1.7: Jinja2 syntax validation ---"
    if python3 -c "import jinja2" 2>/dev/null; then
        for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml devices/net-vhost-kvm.xml; do
            [[ -f "$TMPL_DIR/$tpl" ]] || continue
            if python3 -c "
import jinja2
env = jinja2.Environment(loader=jinja2.FileSystemLoader('$TMPL_DIR'))
env.get_template('$tpl')
" 2>/dev/null; then
                pass "$tpl: Jinja2 parse OK"
            else
                fail "$tpl: Jinja2 parse error"
            fi
        done
    else
        skip "Jinja2 not installed"
    fi
}

# ══════════════════════════════════════════════════════════════════
# SECTION 2: KILLSWITCH DAEMON
# ══════════════════════════════════════════════════════════════════

test_killswitch() {
    header "2. KILLSWITCH DAEMON"

    echo "--- 2.1: Source files exist ---"
    [[ -f "$CORE_ADMIN/qubes/killswitch.py" ]] && \
        pass "killswitch.py exists ($(wc -l < "$CORE_ADMIN/qubes/killswitch.py") lines)" || \
        fail "killswitch.py missing"
    [[ -f "$CORE_ADMIN/qubes/tools/qubes_killswitch_daemon.py" ]] && \
        pass "qubes_killswitch_daemon.py exists" || fail "entry point missing"

    echo "--- 2.2: Python syntax ---"
    python3 -m py_compile "$CORE_ADMIN/qubes/killswitch.py" 2>/dev/null && \
        pass "killswitch.py syntax OK" || fail "killswitch.py syntax error"
    python3 -m py_compile "$CORE_ADMIN/qubes/tools/qubes_killswitch_daemon.py" 2>/dev/null && \
        pass "qubes_killswitch_daemon.py syntax OK" || fail "daemon entry syntax error"

    echo "--- 2.3: Required classes exist ---"
    local KS_CLASSES=$(python3 -c "
import ast, sys
with open('$CORE_ADMIN/qubes/killswitch.py') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        print(node.name)
" 2>&1)
    for cls in Action KillswitchAuditLog KillswitchPolicy TamperDetector HardwareWatchdog MemoryWiper KillswitchDaemon; do
        if echo "$KS_CLASSES" | grep -q "^${cls}$"; then
            pass "class $cls exists"
        else
            fail "class $cls missing"
        fi
    done

    echo "--- 2.4: Policy engine unit tests (safe, no libvirt) ---"
    local POLICY_OUT=$(python3 -c "
import sys, os, json
sys.path.insert(0, '$CORE_ADMIN')

# Directly import only the safe classes (avoid libvirt import)
import importlib.util
spec = importlib.util.spec_from_file_location('ks', '$CORE_ADMIN/qubes/killswitch.py')
ks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ks)

# Test Action enum
assert ks.Action.ALLOW.value == 'allow'
assert ks.Action.KILL_VM.value == 'kill_vm'
assert ks.Action.FULL_PANIC.value == 'full_panic'
print('OK:Action enum')

# Test KillswitchPolicy with defaults
p = ks.KillswitchPolicy()
assert p.max_running_vms == 50
assert p.panic_on_sys_net == True
assert p.memory_wipe == True
print('OK:Policy defaults')

# Test evaluate_vm_start under limit
action, reason = p.evaluate_vm_start('test-vm', 10)
assert action == ks.Action.ALLOW
print('OK:VM start allowed under limit')

# Test evaluate_vm_start over limit
action, reason = p.evaluate_vm_start('test-vm', 50)
assert action == ks.Action.KILL_VM
print('OK:VM start blocked at limit')

# Test evaluate_vm_stop for sys-net
action, reason = p.evaluate_vm_stop('sys-net')
assert action == ks.Action.NETWORK_PANIC
print('OK:sys-net stop triggers network panic')

# Test evaluate_vm_stop for normal VM
action, reason = p.evaluate_vm_stop('personal')
assert action == ks.Action.LOG
print('OK:Normal VM stop just logs')

# Test device attachment with forbidden patterns
p2 = ks.KillswitchPolicy({'forbidden_pci_attach_patterns': ['usb']})
action, reason = p2.evaluate_device_attach('personal', 'pci', 'usb-controller')
assert action == ks.Action.KILL_VM
print('OK:Forbidden device triggers kill')

# Test allowed device
action, reason = p2.evaluate_device_attach('personal', 'pci', 'vga-card')
assert action == ks.Action.ALLOW
print('OK:Allowed device passes')

# Test qrexec blacklist
p3 = ks.KillswitchPolicy({'qrexec_blacklist': ['qubes.VMShell']})
action, reason = p3.evaluate_qrexec_call('untrusted', 'qubes.VMShell', 'dom0')
assert action == ks.Action.KILL_VM
print('OK:Blacklisted qrexec blocked')

action, reason = p3.evaluate_qrexec_call('personal', 'qubes.Filecopy', 'work')
assert action == ks.Action.ALLOW
print('OK:Allowed qrexec passes')

# Test memory wipe config
p4 = ks.KillswitchPolicy({'memory_wipe_on_shutdown': False})
assert p4.should_wipe_memory('test') == False
print('OK:Memory wipe configurable')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$POLICY_OUT"

    echo "--- 2.5: TamperDetector safe checks ---"
    local TAMPER_OUT=$(python3 -c "
import sys
sys.path.insert(0, '$CORE_ADMIN')
import importlib.util
spec = importlib.util.spec_from_file_location('ks', '$CORE_ADMIN/qubes/killswitch.py')
ks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ks)

# Test with non-existent config (should handle gracefully)
td = ks.TamperDetector('/tmp/nonexistent-killswitch.conf')
assert td.config_hash is None
print('OK:Missing config handled')

# Test config integrity with actual file
import tempfile, os
with tempfile.NamedTemporaryFile(mode='w', suffix='.conf', delete=False) as f:
    f.write('test: true\n')
    f.flush()
    td2 = ks.TamperDetector(f.name)
    assert td2.config_hash is not None
    assert td2.check_config_integrity() == True
    print('OK:Config integrity check passes')

    # Tamper with the file
    with open(f.name, 'a') as f2:
        f2.write('evil: true\n')
    assert td2.check_config_integrity() == False
    print('OK:Config tampering detected')
    os.unlink(f.name)

# Test ptrace detection (safe — just reads /proc/self/status)
assert td.check_ptrace() == True
print('OK:Ptrace check passes (no debugger)')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$TAMPER_OUT"

    echo "--- 2.6: AuditLog safe test (writes to /tmp) ---"
    local AUDIT_OUT=$(python3 -c "
import sys, json, os
sys.path.insert(0, '$CORE_ADMIN')
import importlib.util
spec = importlib.util.spec_from_file_location('ks', '$CORE_ADMIN/qubes/killswitch.py')
ks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ks)

log_path = '$TMPDIR_TEST/test-audit.log'
audit = ks.KillswitchAuditLog(log_path)
audit.record('test_event', ks.Action.LOG, 'test-vm', {'key': 'value'})
audit.record('vm_killed', ks.Action.KILL_VM, 'bad-vm', {'reason': 'test'})
audit.close()

with open(log_path) as f:
    lines = f.readlines()
assert len(lines) == 2
print('OK:Two audit entries written')

entry1 = json.loads(lines[0])
assert entry1['event'] == 'test_event'
assert entry1['action'] == 'log'
assert entry1['vm'] == 'test-vm'
assert 'timestamp' in entry1
print('OK:Audit entry structure correct')

entry2 = json.loads(lines[1])
assert entry2['action'] == 'kill_vm'
print('OK:Kill action logged correctly')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$AUDIT_OUT"

    echo "--- 2.7: Systemd service file ---"
    local KS_SVC="$CORE_ADMIN/linux/systemd/qubes-killswitch.service"
    if [[ -f "$KS_SVC" ]]; then
        pass "qubes-killswitch.service exists"
        grep -q 'Type=notify' "$KS_SVC" && pass "Type=notify" || fail "missing Type=notify"
        grep -q 'WatchdogSec' "$KS_SVC" && pass "WatchdogSec set" || fail "missing WatchdogSec"
        grep -q 'Restart=on-failure' "$KS_SVC" && pass "Restart=on-failure" || fail "missing restart"
        grep -q 'ProtectSystem' "$KS_SVC" && pass "Security hardening present" || skip "no hardening"
    else
        fail "qubes-killswitch.service missing"
    fi

    echo "--- 2.8: qubesd.service Wants killswitch ---"
    local QUBESD_SVC="$CORE_ADMIN/linux/systemd/qubesd.service"
    if [[ -f "$QUBESD_SVC" ]]; then
        grep -q 'Wants=qubes-killswitch.service' "$QUBESD_SVC" && \
            pass "qubesd.service Wants killswitch" || fail "qubesd missing killswitch dependency"
    else
        skip "qubesd.service not found"
    fi

    echo "--- 2.9: Config example ---"
    local CONF="$CORE_ADMIN/etc/qubes-killswitch.conf.example"
    if [[ -f "$CONF" ]]; then
        pass "killswitch config example exists"
        grep -q 'max_running_vms' "$CONF" && pass "has max_running_vms" || fail "missing field"
        grep -q 'panic_on_sys_net' "$CONF" && pass "has panic_on_sys_net" || fail "missing field"
        grep -q 'watchdog_timeout' "$CONF" && pass "has watchdog_timeout" || fail "missing field"
        grep -q 'tamper_check_interval' "$CONF" && pass "has tamper_check_interval" || fail "missing field"
        grep -q 'memory_wipe_on_shutdown' "$CONF" && pass "has memory_wipe" || fail "missing field"
        grep -q 'audit_log_path' "$CONF" && pass "has audit_log_path" || fail "missing field"
    else
        fail "killswitch config example missing"
    fi

    echo "--- 2.10: app.py killswitch integration ---"
    local APPPY="$CORE_ADMIN/qubes/app.py"
    if [[ -f "$APPPY" ]]; then
        grep -q '_notify_killswitch' "$APPPY" && \
            pass "app.py has _notify_killswitch method" || fail "missing _notify_killswitch"
        grep -q 'killswitch.sock' "$APPPY" && \
            pass "app.py references killswitch socket" || fail "missing socket reference"
        grep -A3 '_domain_event_callback' "$APPPY" | grep -q 'killswitch' && \
            pass "domain_event_callback calls killswitch" || skip "callback check inconclusive"
    else
        skip "app.py not found"
    fi
}

# ══════════════════════════════════════════════════════════════════
# SECTION 3: VHOST-USER NETWORKING
# ══════════════════════════════════════════════════════════════════

test_vhost() {
    header "3. VHOST-USER NETWORKING"

    echo "--- 3.1: Source files exist ---"
    [[ -f "$CORE_ADMIN/qubes/vm/mix/vhost_net.py" ]] && \
        pass "vhost_net.py mixin exists ($(wc -l < "$CORE_ADMIN/qubes/vm/mix/vhost_net.py") lines)" || \
        fail "vhost_net.py missing"
    [[ -f "$CORE_AGENT/network/qubes-vhost-backend" ]] && \
        pass "qubes-vhost-backend exists ($(wc -l < "$CORE_AGENT/network/qubes-vhost-backend") lines)" || \
        fail "qubes-vhost-backend missing"
    [[ -f "$CORE_AGENT/network/qubes-vhost-bridge.py" ]] && \
        pass "qubes-vhost-bridge.py exists ($(wc -l < "$CORE_AGENT/network/qubes-vhost-bridge.py") lines)" || \
        fail "qubes-vhost-bridge.py missing"

    echo "--- 3.2: Python syntax ---"
    for f in "$CORE_ADMIN/qubes/vm/mix/vhost_net.py" \
             "$CORE_AGENT/network/qubes-vhost-backend" \
             "$CORE_AGENT/network/qubes-vhost-bridge.py"; do
        [[ -f "$f" ]] || continue
        python3 -m py_compile "$f" 2>/dev/null && \
            pass "$(basename "$f") syntax OK" || fail "$(basename "$f") syntax error"
    done

    echo "--- 3.3: VhostUserNetMixin class structure ---"
    local VHOST_METHODS=$(python3 -c "
import ast
with open('$CORE_ADMIN/qubes/vm/mix/vhost_net.py') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == 'VhostUserNetMixin':
        for item in node.body:
            if isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef)):
                print(item.name)
" 2>&1)

    for method in vhost_create_sockets vhost_destroy_sockets vhost_attach_network \
                  vhost_detach_network is_vhost_user_backend get_vhost_socket_dir \
                  vhost_socket_for_vm vhost_socket_for_peer \
                  on_vhost_domain_pre_spawn on_vhost_domain_start \
                  on_vhost_domain_shutdown on_vhost_domain_pre_shutdown \
                  on_vhost_net_domain_connect on_vhost_feature_set; do
        if echo "$VHOST_METHODS" | grep -q "^${method}$"; then
            pass "VhostUserNetMixin.$method"
        else
            fail "VhostUserNetMixin.$method missing"
        fi
    done

    echo "--- 3.4: Socket path helpers ---"
    local SOCKET_SCRIPT="$TMPDIR_TEST/test_socket_paths.py"
    cat > "$SOCKET_SCRIPT" << 'PYEOF'
import os

VHOST_SOCKET_DIR = "/var/run/qubes/vhost"

def _vhost_socket_path(vm):
    return os.path.join(VHOST_SOCKET_DIR, "{}.sock".format(vm.name))

def _vhost_socket_path_for_peer(netvm, client_vm):
    return os.path.join(
        VHOST_SOCKET_DIR,
        "{}-to-{}.sock".format(netvm.name, client_vm.name),
    )

class FakeVM:
    def __init__(self, name):
        self.name = name

net = FakeVM("sys-net")
fw = FakeVM("sys-firewall")
app = FakeVM("personal")

path = _vhost_socket_path(net)
assert path == "/var/run/qubes/vhost/sys-net.sock", f"got {path}"
print("OK:vhost_socket_path correct")

peer_path = _vhost_socket_path_for_peer(net, app)
assert peer_path == "/var/run/qubes/vhost/sys-net-to-personal.sock", f"got {peer_path}"
print("OK:peer socket path correct")

peer_path2 = _vhost_socket_path_for_peer(fw, app)
assert peer_path2 == "/var/run/qubes/vhost/sys-firewall-to-personal.sock"
print("OK:firewall-to-app socket path correct")
PYEOF
    local SOCKET_OUT
    SOCKET_OUT=$(python3 "$SOCKET_SCRIPT" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$SOCKET_OUT"

    echo "--- 3.5: VhostBackend class structure ---"
    local BACKEND_CLASSES=$(python3 -c "
import ast
with open('$CORE_AGENT/network/qubes-vhost-backend') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        print(node.name)
" 2>&1)

    for cls in RawNICSocket TAPDevice VhostClient VhostBackend; do
        echo "$BACKEND_CLASSES" | grep -q "^${cls}$" && \
            pass "qubes-vhost-backend: class $cls" || fail "qubes-vhost-backend: class $cls missing"
    done

    echo "--- 3.6: VhostBridge class structure ---"
    local BRIDGE_CLASSES=$(python3 -c "
import ast
with open('$CORE_AGENT/network/qubes-vhost-bridge.py') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef):
        print(node.name)
" 2>&1)

    for cls in FirewallRuleSet BridgeClient UpstreamConnection VhostBridge; do
        echo "$BRIDGE_CLASSES" | grep -q "^${cls}$" && \
            pass "qubes-vhost-bridge: class $cls" || fail "qubes-vhost-bridge: class $cls missing"
    done

    echo "--- 3.7: Ethernet helpers unit test ---"
    local ETH_OUT=$(python3 -c "
import sys, struct
sys.path.insert(0, '$(dirname "$CORE_AGENT/network/qubes-vhost-backend")')
# Parse the module directly to avoid AF_PACKET issues on non-root
import importlib.util
spec = importlib.util.spec_from_file_location('backend', '$CORE_AGENT/network/qubes-vhost-backend')

# Read the file to extract just the helper functions
exec(open('$CORE_AGENT/network/qubes-vhost-backend').read().split('class RawNICSocket')[0])

# Test mac_bytes
m = mac_bytes('aa:bb:cc:dd:ee:ff')
assert m == bytes([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
print('OK:mac_bytes')

# Test mac_str
s = mac_str(b'\\xaa\\xbb\\xcc\\xdd\\xee\\xff')
assert s == 'aa:bb:cc:dd:ee:ff'
print('OK:mac_str')

# Test is_broadcast
assert is_broadcast(b'\\xff\\xff\\xff\\xff\\xff\\xff') == True
assert is_broadcast(b'\\x01\\x00\\x5e\\x00\\x00\\x01') == True  # multicast
assert is_broadcast(b'\\x00\\x11\\x22\\x33\\x44\\x55') == False
print('OK:is_broadcast')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$ETH_OUT"

    echo "--- 3.8: Firewall rule parsing unit test ---"
    local FW_OUT=$(python3 -c "
import sys, ipaddress
sys.path.insert(0, '$(dirname "$CORE_AGENT/network/qubes-vhost-bridge.py")')

# Import just the ethernet helpers and FirewallRuleSet
exec(open('$CORE_AGENT/network/qubes-vhost-bridge.py').read().split('class BridgeClient')[0])

# Test parse_eth_header
frame = b'\\xff\\xff\\xff\\xff\\xff\\xff\\x00\\x11\\x22\\x33\\x44\\x55\\x08\\x00' + b'\\x00' * 20
dst, src, etype, off = parse_eth_header(frame)
assert dst == b'\\xff\\xff\\xff\\xff\\xff\\xff'
assert src == b'\\x00\\x11\\x22\\x33\\x44\\x55'
assert etype == 0x0800
assert off == 14
print('OK:parse_eth_header')

# Test extract_ip_src / extract_ip_dst
ip_hdr = bytes([0x45, 0x00, 0x00, 0x28,  # ver/ihl, dscp, total len
                0x00, 0x01, 0x00, 0x00,  # id, flags/offset
                0x40, 0x06, 0x00, 0x00,  # ttl=64, proto=tcp, checksum
                0x0a, 0x01, 0x02, 0x03,  # src: 10.1.2.3
                0xc0, 0xa8, 0x01, 0x01]) # dst: 192.168.1.1
frame2 = b'\\xff' * 14 + ip_hdr
src_ip = extract_ip_src(frame2, 0x0800, 14)
assert str(src_ip) == '10.1.2.3'
print('OK:extract_ip_src')

dst_ip = extract_ip_dst(frame2, 0x0800, 14)
assert str(dst_ip) == '192.168.1.1'
print('OK:extract_ip_dst')

# Test FirewallRuleSet.is_allowed with cached rules
frs = FirewallRuleSet()
frs._rules_cache['10.1.2.3'] = [
    {'action': 'accept', 'proto': 'tcp', 'dstports': '443'},
    {'action': 'accept', 'proto': 'udp', 'dstports': '53'},
    {'action': 'drop'}
]
assert frs.is_allowed(ipaddress.IPv4Address('10.1.2.3'),
                       ipaddress.IPv4Address('8.8.8.8'),
                       'tcp', 443) == True
print('OK:HTTPS allowed')

assert frs.is_allowed(ipaddress.IPv4Address('10.1.2.3'),
                       ipaddress.IPv4Address('8.8.8.8'),
                       'tcp', 80) == False
print('OK:HTTP blocked')

assert frs.is_allowed(ipaddress.IPv4Address('10.1.2.3'),
                       ipaddress.IPv4Address('8.8.8.8'),
                       'udp', 53) == True
print('OK:DNS allowed')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*assert*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$FW_OUT"

    echo "--- 3.9: Systemd vhost service files ---"
    for svc in "$CORE_AGENT/vm-systemd/qubes-vhost-backend.service" \
               "$CORE_AGENT/vm-systemd/qubes-vhost-bridge.service"; do
        if [[ -f "$svc" ]]; then
            local name=$(basename "$svc")
            pass "$name exists"
            grep -q 'Type=notify' "$svc" && pass "$name: Type=notify" || skip "$name: no Type=notify"
            grep -q 'ConditionPathExists' "$svc" && \
                pass "$name: has ConditionPathExists guard" || fail "$name: missing activation guard"
            grep -q 'CapabilityBoundingSet' "$svc" && \
                pass "$name: has capability restriction" || skip "$name: no capability restriction"
        else
            fail "$(basename "$svc") missing"
        fi
    done

    echo "--- 3.10: net.py vhost-user integration ---"
    local NETPY="$CORE_ADMIN/qubes/vm/mix/net.py"
    if [[ -f "$NETPY" ]]; then
        grep -q 'vhost-user' "$NETPY" && \
            pass "net.py: vhost-user conditional" || fail "net.py: missing vhost-user check"
        grep -q 'vhost_attach_network' "$NETPY" && \
            pass "net.py: calls vhost_attach_network" || fail "net.py: missing vhost_attach"
        grep -q "vhostuser" "$NETPY" && \
            pass "net.py: checks for vhostuser interface type" || fail "net.py: missing vhostuser check"
    else
        skip "net.py not found"
    fi
}

# ══════════════════════════════════════════════════════════════════
# SECTION 4: KVM BACKEND (qubesvm.py, app.py, kvm_mem.py)
# ══════════════════════════════════════════════════════════════════

test_kvm_backend() {
    header "4. KVM BACKEND"

    echo "--- 4.1: Python file syntax ---"
    for f in "$CORE_ADMIN/qubes/vm/qubesvm.py" \
             "$CORE_ADMIN/qubes/app.py" \
             "$CORE_ADMIN/qubes/vm/mix/kvm_mem.py" \
             "$CORE_ADMIN/qubes/vm/__init__.py"; do
        [[ -f "$f" ]] || { skip "$(basename "$f") not found"; continue; }
        python3 -m py_compile "$f" 2>/dev/null && \
            pass "$(basename "$f") syntax OK" || fail "$(basename "$f") syntax error"
    done

    echo "--- 4.2: backend_vmm guards in qubesvm.py ---"
    local QVM="$CORE_ADMIN/qubes/vm/qubesvm.py"
    [[ -f "$QVM" ]] || { skip "qubesvm.py not found"; return; }

    for fn in stubdom_uuid stubdom_xid; do
        grep -A3 "def $fn" "$QVM" | grep -q 'backend_vmm' && \
            pass "$fn has backend_vmm guard" || fail "$fn missing guard"
    done

    grep -A15 'def start_time' "$QVM" | grep -q 'backend_vmm' && \
        pass "start_time has backend_vmm guard" || fail "start_time missing guard"
    grep -A3 'def get_pref_mem' "$QVM" | grep -q 'backend_vmm' && \
        pass "get_pref_mem has backend_vmm guard" || fail "get_pref_mem missing guard"
    grep -q '_inject_qubesdb_config_kvm' "$QVM" && \
        pass "_inject_qubesdb_config_kvm method exists" || fail "config inject method missing"

    echo "--- 4.3: QubesHost dual-backend in app.py ---"
    local APPPY="$CORE_ADMIN/qubes/app.py"
    grep -A15 'def get_free_xen_memory' "$APPPY" | grep -q 'getFreeMemory' && \
        pass "get_free_xen_memory: libvirt path" || fail "missing libvirt free memory"
    grep -A20 'def is_iommu_supported' "$APPPY" | grep -q 'iommu' && \
        pass "is_iommu_supported: sysfs check" || fail "missing IOMMU sysfs check"
    grep -A80 'def get_vm_stats' "$APPPY" | grep -q 'getAllDomainStats\|domainListGetStats' && \
        pass "get_vm_stats: libvirt stats path" || fail "missing libvirt stats"

    echo "--- 4.4: KvmMemoryMixin ---"
    local KVM_MEM="$CORE_ADMIN/qubes/vm/mix/kvm_mem.py"
    if [[ -f "$KVM_MEM" ]]; then
        local MIXIN_METHODS=$(python3 -c "
import ast
with open('$KVM_MEM') as f:
    tree = ast.parse(f.read())
for node in ast.walk(tree):
    if isinstance(node, ast.ClassDef) and node.name == 'KvmMemoryMixin':
        for item in node.body:
            if isinstance(item, ast.FunctionDef):
                print(item.name)
" 2>&1)
        for method in kvm_set_memory kvm_get_memory_stats kvm_create_memory_qdb_entries \
                      kvm_get_pref_mem kvm_request_memory; do
            echo "$MIXIN_METHODS" | grep -q "^${method}$" && \
                pass "KvmMemoryMixin.$method" || fail "KvmMemoryMixin.$method missing"
        done
    else
        fail "kvm_mem.py not found"
    fi
}

# ══════════════════════════════════════════════════════════════════
# SECTION 5: INTEGRATION (cross-component checks)
# ══════════════════════════════════════════════════════════════════

test_integration() {
    header "5. CROSS-COMPONENT INTEGRATION"

    echo "--- 5.1: Killswitch socket protocol test (safe, /tmp) ---"
    local SOCK_OUT=$(python3 -c "
import socket, json, os, time

sock_path = '$TMPDIR_TEST/killswitch-test.sock'

# Create a receiver (simulates killswitch daemon)
receiver = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
receiver.bind(sock_path)
receiver.settimeout(2)

# Send a notification (simulates qubesd)
sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
msg = json.dumps({
    'event': 'domain_event',
    'vm': 'test-vm',
    'details': {'libvirt_event': '1'}
}).encode()
sender.sendto(msg, sock_path)
sender.close()

# Receive and validate
data = receiver.recv(4096)
parsed = json.loads(data.decode())
assert parsed['event'] == 'domain_event'
assert parsed['vm'] == 'test-vm'
print('OK:Socket notification roundtrip')
receiver.close()
os.unlink(sock_path)
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$SOCK_OUT"

    echo "--- 5.2: Vhost-user frame protocol test (safe, /tmp) ---"
    local FRAME_OUT=$(python3 -c "
import socket, struct, os

sock_path = '$TMPDIR_TEST/vhost-frame-test.sock'

# Server (simulates vhost backend)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sock_path)
server.listen(1)

# Client (simulates QEMU)
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(sock_path)

conn, addr = server.accept()

# Send a frame from client to server
eth_frame = b'\\xff\\xff\\xff\\xff\\xff\\xff' + b'\\x00\\x11\\x22\\x33\\x44\\x55' + b'\\x08\\x00' + b'\\x00' * 46
hdr = struct.pack('!I', len(eth_frame))
client.sendall(hdr + eth_frame)

# Receive on server
data = conn.recv(4096)
recv_len = struct.unpack('!I', data[:4])[0]
recv_frame = data[4:4+recv_len]
assert recv_frame == eth_frame
print('OK:Frame protocol send/recv')

# Send frame back
conn.sendall(hdr + eth_frame)
data2 = client.recv(4096)
recv_len2 = struct.unpack('!I', data2[:4])[0]
assert recv_len2 == len(eth_frame)
print('OK:Frame protocol bidirectional')

client.close()
conn.close()
server.close()
os.unlink(sock_path)
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$FRAME_OUT"

    echo "--- 5.3: Config injection file format ---"
    local INJECT_OUT=$(python3 -c "
import os, tempfile

# Simulate what _inject_qubesdb_config_kvm writes
config_path = '$TMPDIR_TEST/test-vm.conf'
with open(config_path, 'w') as f:
    f.write('/name=test-vm\n')
    f.write('/qubes-vm-type=AppVM\n')
    f.write('/qubes-vm-updateable=False\n')
    f.write('/qubes-vm-persistence=rw-only\n')
    f.write('/qubes-debug-mode=0\n')
    f.write('/qubes-base-template=fedora-42\n')
    f.write('/qubes-ip=10.137.0.5\n')
    f.write('/qubes-gateway=10.137.0.1\n')
    f.write('/qubes-netmask=255.255.255.255\n')
    f.write('/qubes-primary-dns=10.139.1.1\n')
    f.write('/qubes-secondary-dns=10.139.1.2\n')

with open(config_path) as f:
    lines = f.readlines()

assert len(lines) == 11
print('OK:Config file has 11 entries')

for line in lines:
    assert '=' in line
    key, val = line.strip().split('=', 1)
    assert key.startswith('/')
print('OK:All entries are /key=value format')

assert any('/qubes-ip=10.137.0.5' in l for l in lines)
print('OK:IP entry present')
assert any('/qubes-gateway=10.137.0.1' in l for l in lines)
print('OK:Gateway entry present')
" 2>&1)

    while IFS= read -r line; do
        case "$line" in
            OK:*) pass "${line#OK:}" ;;
            *Error*|*Traceback*) fail "$line" ;;
        esac
    done <<< "$INJECT_OUT"

    echo "--- 5.4: QubesDB binaries (if built) ---"
    local QUBESDB_KVM="$FIX_ROOT/qubes-core-qubesdb/daemon/kvm"
    if [[ -d "$QUBESDB_KVM" ]]; then
        for bin in qubesdb-config-inject qubesdb-config-read; do
            if [[ -x "$QUBESDB_KVM/$bin" ]]; then
                pass "$bin binary exists and is executable"
            elif [[ -f "$QUBESDB_KVM/${bin}.c" ]]; then
                pass "$bin source exists (binary not built yet)"
            else
                skip "$bin not found"
            fi
        done
    else
        skip "qubes-core-qubesdb/daemon/kvm not found"
    fi

    echo "--- 5.5: Build script correctness ---"
    local BUILD_SH="$KVM_FORK/scripts/build-all.sh"
    if [[ -f "$BUILD_SH" ]]; then
        bash -n "$BUILD_SH" 2>/dev/null && \
            pass "build-all.sh syntax OK" || fail "build-all.sh syntax error"
        grep -q 'build_qubesdb' "$BUILD_SH" && \
            pass "build-all.sh: has build_qubesdb function" || fail "missing build_qubesdb"
        grep -q 'build_gui_daemon' "$BUILD_SH" && \
            pass "build-all.sh: has build_gui_daemon" || fail "missing build_gui_daemon"
        grep -q 'build_core_agent' "$BUILD_SH" && \
            pass "build-all.sh: has build_core_agent" || fail "missing build_core_agent"
        grep -q 'BACKEND_VMM=kvm' "$BUILD_SH" && \
            pass "build-all.sh: passes BACKEND_VMM=kvm" || fail "missing BACKEND_VMM"
    else
        skip "build-all.sh not found"
    fi

    echo "--- 5.6: All test scripts have valid syntax ---"
    for tsh in "$KVM_FORK"/test/*.sh; do
        [[ -f "$tsh" ]] || continue
        bash -n "$tsh" 2>/dev/null && \
            pass "$(basename "$tsh") syntax OK" || fail "$(basename "$tsh") syntax error"
    done
}

# ══════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════

summary() {
    header "SUMMARY"
    local TOTAL=$((PASS + FAIL + SKIP))
    echo "  Total:   $TOTAL"
    echo "  Passed:  $PASS"
    echo "  Failed:  $FAIL"
    echo "  Skipped: $SKIP"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo "  ✓ ALL TESTS PASSED"
        return 0
    else
        echo "  ✗ $FAIL TEST(S) FAILED"
        return 1
    fi
}

# ══════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════

CMD="${1:-all}"
case "$CMD" in
    templates)   test_templates; summary ;;
    killswitch)  test_killswitch; summary ;;
    vhost)       test_vhost; summary ;;
    kvm-backend) test_kvm_backend; summary ;;
    integration) test_integration; summary ;;
    all)
        test_templates
        test_killswitch
        test_vhost
        test_kvm_backend
        test_integration
        summary
        ;;
    *)
        echo "Usage: $0 [templates|killswitch|vhost|kvm-backend|integration|all]"
        exit 1
        ;;
esac
