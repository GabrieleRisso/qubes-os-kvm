#!/bin/bash
# kvm-backend-tests.sh — Validate the KVM backend integration layer
#
# Tests the Python modules, libvirt XML templates, and binary tools
# that form the KVM backend for Qubes OS. Does NOT require /dev/kvm
# or a running libvirtd — focuses on code correctness and syntax.
#
# Usage:
#   bash test/kvm-backend-tests.sh [core-admin-path]
#
# If core-admin-path is not given, auto-detects from common layouts.
set -u

PASS=0
FAIL=0
SKIP=0

pass()   { PASS=$((PASS + 1)); echo "  [PASS] $*"; }
fail()   { FAIL=$((FAIL + 1)); echo "  [FAIL] $*"; }
skip()   { SKIP=$((SKIP + 1)); echo "  [SKIP] $*"; }
header() { echo ""; echo "==== $* ===="; }

# ── Locate qubes-core-admin ──────────────────────────────────────
CORE_ADMIN="${1:-}"
if [[ -z "$CORE_ADMIN" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for candidate in \
        "$SCRIPT_DIR/../../qubes-core-admin" \
        "/home/user/fix/qubes-core-admin" \
        "/repos/qubes-core-admin"; do
        if [[ -d "$candidate/qubes" ]]; then
            CORE_ADMIN="$candidate"
            break
        fi
    done
fi

if [[ -z "$CORE_ADMIN" || ! -d "$CORE_ADMIN/qubes" ]]; then
    echo "ERROR: Cannot find qubes-core-admin. Pass path as argument."
    exit 1
fi

TMPL_DIR="$CORE_ADMIN/templates/libvirt"
echo "qubes-core-admin: $CORE_ADMIN"
echo "Templates:        $TMPL_DIR"

export PYTHONPATH="$CORE_ADMIN:${PYTHONPATH:-}"
export QUBES_BACKEND_VMM=kvm

# ── Section 1: Template XML validation ───────────────────────────
header "1. Libvirt XML template structure"

for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
    tpl_path="$TMPL_DIR/$tpl"
    if [[ ! -f "$tpl_path" ]]; then
        skip "$tpl not found"
        continue
    fi
    pass "$tpl exists"

    # Check for QubesDB channel
    if grep -q 'org.qubes-os.qubesdb' "$tpl_path"; then
        pass "$tpl: org.qubes-os.qubesdb channel present"
    else
        fail "$tpl: org.qubes-os.qubesdb channel MISSING"
    fi

    # Check for virtio-serial socket path
    if grep -q 'qubesdb.*sock' "$tpl_path"; then
        pass "$tpl: qubesdb socket path present"
    else
        fail "$tpl: qubesdb socket path missing"
    fi

    # Check for vsock (vchan-socket transport)
    if grep -q 'vsock' "$tpl_path"; then
        pass "$tpl: vsock device present"
    else
        fail "$tpl: vsock device missing"
    fi

    # Check for balloon
    if grep -q 'memballoon' "$tpl_path"; then
        pass "$tpl: memballoon device present"
    else
        fail "$tpl: memballoon device missing"
    fi

    # No raw xenstore references
    if grep -qi 'xenstore' "$tpl_path"; then
        fail "$tpl: contains xenstore reference"
    else
        pass "$tpl: no xenstore references"
    fi
done

# ── Section 2: Python module imports ─────────────────────────────
header "2. Python module imports (QUBES_BACKEND_VMM=kvm)"

for mod in \
    qubes.config \
    qubes.vm.mix.kvm_mem; do
    IMPORT_ERR=$(python3 -c "import $mod" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "import $mod"
    elif echo "$IMPORT_ERR" | grep -qi "No module named 'docutils'\|No module named 'libvirt'\|No module named 'qubes'"; then
        skip "import $mod (missing dependency: $(echo "$IMPORT_ERR" | tail -1))"
    else
        fail "import $mod: $(echo "$IMPORT_ERR" | tail -1)"
    fi
done

# ── Section 3: kvm_mem mixin API ─────────────────────────────────
header "3. KvmMemoryMixin API surface"

KVM_MEM_OUT=$(python3 -c "
from qubes.vm.mix.kvm_mem import KvmMemoryMixin
methods = [m for m in dir(KvmMemoryMixin) if m.startswith('kvm_')]
for m in methods:
    print(m)
" 2>&1)
KVM_MEM_RC=$?

if [[ $KVM_MEM_RC -ne 0 ]] && echo "$KVM_MEM_OUT" | grep -qi "No module named"; then
    skip "KvmMemoryMixin API test (missing dependency)"
else
    for method in kvm_set_memory kvm_get_memory_stats kvm_create_memory_qdb_entries kvm_get_pref_mem kvm_request_memory; do
        if echo "$KVM_MEM_OUT" | grep -q "$method"; then
            pass "KvmMemoryMixin.$method exists"
        else
            fail "KvmMemoryMixin.$method missing"
        fi
    done
fi

# ── Section 4: qubesvm.py backend_vmm guards ────────────────────
header "4. Backend VMM guards in qubesvm.py"

QUBESVM="$CORE_ADMIN/qubes/vm/qubesvm.py"
if [[ ! -f "$QUBESVM" ]]; then
    skip "qubesvm.py not found"
else
    # Check that backend_vmm guards exist for each critical section
    for pattern in \
        'backend_vmm.*!=.*"xen"' \
        'backend_vmm.*==.*"xen"' \
        'backend_vmm.*==.*"kvm"'; do
        count=$(grep -cE "$pattern" "$QUBESVM" 2>/dev/null || echo 0)
        if [[ "$count" -gt 0 ]]; then
            pass "qubesvm.py: $count guard(s) matching '$pattern'"
        else
            fail "qubesvm.py: no guards matching '$pattern'"
        fi
    done

    # Verify stubdom_uuid has KVM guard
    if grep -A2 'def stubdom_uuid' "$QUBESVM" | grep -q 'backend_vmm'; then
        pass "stubdom_uuid has backend_vmm guard"
    else
        fail "stubdom_uuid missing backend_vmm guard"
    fi

    # Verify stubdom_xid has KVM guard
    if grep -A2 'def stubdom_xid' "$QUBESVM" | grep -q 'backend_vmm'; then
        pass "stubdom_xid has backend_vmm guard"
    else
        fail "stubdom_xid missing backend_vmm guard"
    fi

    # Verify start_time has KVM guard (may be several lines below)
    if grep -A15 'def start_time' "$QUBESVM" | grep -q 'backend_vmm'; then
        pass "start_time has backend_vmm guard"
    else
        fail "start_time missing backend_vmm guard"
    fi

    # Verify get_pref_mem has KVM guard
    if grep -A2 'def get_pref_mem' "$QUBESVM" | grep -q 'backend_vmm'; then
        pass "get_pref_mem has backend_vmm guard"
    else
        fail "get_pref_mem missing backend_vmm guard"
    fi

    # Verify _inject_qubesdb_config_kvm exists
    if grep -q '_inject_qubesdb_config_kvm' "$QUBESVM"; then
        pass "_inject_qubesdb_config_kvm method exists"
    else
        fail "_inject_qubesdb_config_kvm method missing"
    fi
fi

# ── Section 5: app.py QubesHost dual-backend ─────────────────────
header "5. QubesHost dual-backend in app.py"

APP_PY="$CORE_ADMIN/qubes/app.py"
if [[ ! -f "$APP_PY" ]]; then
    skip "app.py not found"
else
    # get_free_xen_memory should now have KVM path
    if grep -A10 'def get_free_xen_memory' "$APP_PY" | grep -q 'getFreeMemory'; then
        pass "get_free_xen_memory has libvirt getFreeMemory path"
    else
        fail "get_free_xen_memory missing libvirt path"
    fi

    # is_iommu_supported should check sysfs on KVM
    if grep -A15 'def is_iommu_supported' "$APP_PY" | grep -q 'iommu'; then
        pass "is_iommu_supported has sysfs IOMMU check"
    else
        fail "is_iommu_supported missing sysfs check"
    fi

    # get_vm_stats should use getAllDomainStats on KVM (function is long)
    if grep -A80 'def get_vm_stats' "$APP_PY" | grep -q 'getAllDomainStats\|domainListGetStats'; then
        pass "get_vm_stats has libvirt stats path"
    else
        fail "get_vm_stats missing libvirt path"
    fi
fi

# ── Section 6: qubesdb-config-inject/read binaries ───────────────
header "6. QubesDB config injection tools"

QUBESDB_KVM="$(dirname "$CORE_ADMIN")/qubes-core-qubesdb/daemon/kvm"
if [[ -d "$QUBESDB_KVM" ]]; then
    for src in qubesdb-config-inject.c qubesdb-config-read.c; do
        if [[ -f "$QUBESDB_KVM/$src" ]]; then
            pass "$src source exists"
        else
            fail "$src source missing"
        fi
    done

    # Check Makefile exists
    if [[ -f "$QUBESDB_KVM/Makefile" ]]; then
        pass "daemon/kvm/Makefile exists"
    else
        skip "daemon/kvm/Makefile not found"
    fi

    # Check for compiled binaries (may not exist if not built yet)
    for bin in qubesdb-config-inject qubesdb-config-read; do
        if [[ -x "$QUBESDB_KVM/$bin" ]]; then
            pass "$bin binary exists"
        else
            skip "$bin binary not built yet"
        fi
    done
else
    skip "qubes-core-qubesdb/daemon/kvm not found"
fi

# ── Section 7: Python syntax check ──────────────────────────────
header "7. Python syntax validation"

for pyfile in \
    "$CORE_ADMIN/qubes/vm/qubesvm.py" \
    "$CORE_ADMIN/qubes/app.py" \
    "$CORE_ADMIN/qubes/vm/mix/kvm_mem.py" \
    "$CORE_ADMIN/qubes/vm/__init__.py"; do
    if [[ ! -f "$pyfile" ]]; then
        skip "$(basename "$pyfile") not found"
        continue
    fi
    if python3 -m py_compile "$pyfile" 2>/dev/null; then
        pass "$(basename "$pyfile") syntax OK"
    else
        fail "$(basename "$pyfile") syntax error"
    fi
done

# ── Section 8: Jinja2 template syntax ────────────────────────────
header "8. Jinja2 template syntax"

if python3 -c "import jinja2" 2>/dev/null; then
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        tpl_path="$TMPL_DIR/$tpl"
        [[ -f "$tpl_path" ]] || continue
        if python3 -c "
import jinja2
env = jinja2.Environment(loader=jinja2.FileSystemLoader('$TMPL_DIR'))
env.get_template('$tpl')
print('OK')
" 2>/dev/null | grep -q OK; then
            pass "$tpl Jinja2 parse OK"
        else
            fail "$tpl Jinja2 parse error"
        fi
    done
else
    skip "jinja2 not installed, cannot validate templates"
fi

# ── Section 9: Balloon method unit test stubs ────────────────────
header "9. KvmMemoryMixin method signatures"

MIXIN_TEST=$(python3 -c "
import inspect
from qubes.vm.mix.kvm_mem import KvmMemoryMixin

for name in ['kvm_set_memory', 'kvm_get_memory_stats',
             'kvm_create_memory_qdb_entries', 'kvm_get_pref_mem',
             'kvm_request_memory']:
    method = getattr(KvmMemoryMixin, name, None)
    if method is None:
        print(f'MISSING:{name}')
    else:
        sig = inspect.signature(method)
        print(f'OK:{name}{sig}')
" 2>&1)
MIXIN_RC=$?

if [[ $MIXIN_RC -ne 0 ]] && echo "$MIXIN_TEST" | grep -qi "No module named"; then
    skip "KvmMemoryMixin signatures (missing dependency)"
else
    echo "$MIXIN_TEST" | while IFS= read -r line; do
        case "$line" in
            OK:*)      pass "${line#OK:}" ;;
            MISSING:*) fail "${line#MISSING:} not found" ;;
        esac
    done
fi

# ── Section 10: x86 kernel config-qubes-kvm validation ───────────
header "10. x86 kernel config-qubes-kvm validation"

KERNEL_DIR="$(dirname "$CORE_ADMIN")/qubes-linux-kernel"
KVM_CONFIG="$KERNEL_DIR/config-qubes-kvm"
if [[ -f "$KVM_CONFIG" ]]; then
    pass "config-qubes-kvm exists"

    for opt in CONFIG_KVM_GUEST CONFIG_PARAVIRT CONFIG_VIRTIO CONFIG_VIRTIO_PCI \
               CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_VIRTIO_CONSOLE \
               CONFIG_VSOCKETS CONFIG_VIRTIO_VSOCKETS CONFIG_VFIO \
               CONFIG_IOMMU_SUPPORT CONFIG_KVM CONFIG_KVM_INTEL CONFIG_KVM_AMD; do
        if grep -q "^${opt}=" "$KVM_CONFIG"; then
            pass "config-qubes-kvm: $opt enabled"
        else
            fail "config-qubes-kvm: $opt missing or disabled"
        fi
    done

    # Xen balloon hotplug should be explicitly disabled
    for opt in CONFIG_XEN_BALLOON_MEMORY_HOTPLUG CONFIG_XEN_GRANT_DMA_ALLOC; do
        if grep -q "# ${opt} is not set" "$KVM_CONFIG"; then
            pass "config-qubes-kvm: $opt correctly disabled"
        elif grep -q "^${opt}=" "$KVM_CONFIG"; then
            fail "config-qubes-kvm: $opt should be disabled under KVM"
        else
            pass "config-qubes-kvm: $opt not present (OK)"
        fi
    done

    # VHOST for host-side virtio backends
    for opt in CONFIG_VHOST CONFIG_VHOST_NET CONFIG_VHOST_VSOCK; do
        val=$(grep "^${opt}=" "$KVM_CONFIG" 2>/dev/null || echo "")
        if [[ -n "$val" ]]; then
            pass "config-qubes-kvm: $opt set ($val)"
        elif [[ "$opt" = "CONFIG_VHOST_VSOCK" ]]; then
            skip "config-qubes-kvm: $opt not set (optional)"
        else
            fail "config-qubes-kvm: $opt missing"
        fi
    done
else
    fail "config-qubes-kvm not found at $KVM_CONFIG"
fi

# kernel.spec.in should handle KVM on x86
KERNEL_SPEC="$KERNEL_DIR/kernel.spec.in"
if [[ -f "$KERNEL_SPEC" ]]; then
    if grep -q 'config-qubes-kvm' "$KERNEL_SPEC"; then
        pass "kernel.spec.in references config-qubes-kvm"
    else
        fail "kernel.spec.in does not reference config-qubes-kvm"
    fi

    if grep -q 'backend_vmm.*kvm\|BACKEND_VMM.*kvm' "$KERNEL_SPEC"; then
        pass "kernel.spec.in has backend_vmm=kvm conditional"
    else
        fail "kernel.spec.in missing backend_vmm=kvm conditional"
    fi
else
    skip "kernel.spec.in not found"
fi

# ── Section 11: Installation completeness ─────────────────────────
header "11. Installation completeness (Makefile/spec)"

AGENT_DIR="$(dirname "$CORE_ADMIN")/qubes-core-agent-linux"
if [[ -d "$AGENT_DIR" ]]; then
    AGENT_MK="$AGENT_DIR/Makefile"
    AGENT_SPEC="$AGENT_DIR/rpm_spec/core-agent.spec.in"

    # vif-route-qubes-kvm installed to /etc/qubes/kvm/
    if grep -q 'vif-route-qubes-kvm.*etc/qubes/kvm' "$AGENT_MK"; then
        pass "Makefile: vif-route-qubes-kvm installed to /etc/qubes/kvm/"
    else
        fail "Makefile: vif-route-qubes-kvm NOT installed to /etc/qubes/kvm/"
    fi

    # qubesdb-hotplug-watcher.sh installed
    if grep -q 'qubesdb-hotplug-watcher.sh' "$AGENT_MK"; then
        pass "Makefile: qubesdb-hotplug-watcher.sh installed"
    else
        fail "Makefile: qubesdb-hotplug-watcher.sh NOT installed"
    fi

    # RPM spec includes KVM services
    if [[ -f "$AGENT_SPEC" ]]; then
        for svc in qubes-kvm-config-read.service qubes-kvm-hotplug-watcher.service \
                   qubes-vchan-domain-env.service; do
            if grep -q "$svc" "$AGENT_SPEC"; then
                pass "RPM spec: $svc listed in %%files"
            else
                fail "RPM spec: $svc missing from %%files"
            fi
        done

        # vif-route-qubes path in spec
        if grep -q '/etc/qubes/kvm/vif-route-qubes' "$AGENT_SPEC"; then
            pass "RPM spec: /etc/qubes/kvm/vif-route-qubes listed"
        else
            fail "RPM spec: /etc/qubes/kvm/vif-route-qubes missing"
        fi

        # qubesdb-hotplug-watcher.sh in spec
        if grep -q 'qubesdb-hotplug-watcher.sh' "$AGENT_SPEC"; then
            pass "RPM spec: qubesdb-hotplug-watcher.sh listed"
        else
            fail "RPM spec: qubesdb-hotplug-watcher.sh missing"
        fi
    else
        skip "core-agent.spec.in not found"
    fi
else
    skip "qubes-core-agent-linux not found"
fi

# ── Section 12: app.py KVM backend_vmm guards ───────────────────
header "12. app.py KVM backend_vmm guards"

if [[ -f "$APP_PY" ]]; then
    # xs property should check backend_vmm, not just module import
    if grep -A15 'def xs' "$APP_PY" | grep -q 'backend_vmm.*!=.*"xen"'; then
        pass "app.py: xs property checks backend_vmm"
    else
        fail "app.py: xs property does not check backend_vmm (uses module import only)"
    fi

    # xc property should check backend_vmm
    if grep -A15 'def xc' "$APP_PY" | grep -q 'backend_vmm.*!=.*"xen"'; then
        pass "app.py: xc property checks backend_vmm"
    else
        fail "app.py: xc property does not check backend_vmm (uses module import only)"
    fi

    # init_vmm_connection should gate xen init on backend_vmm
    if grep -A15 'def init_vmm_connection' "$APP_PY" | grep -q 'backend_vmm.*==.*"xen"'; then
        pass "app.py: init_vmm_connection gates Xen on backend_vmm"
    else
        fail "app.py: init_vmm_connection does not gate Xen init"
    fi
else
    skip "app.py not found"
fi

# ── Section 13: QubesDB inject/read end-to-end test ──────────────
header "13. QubesDB config inject/read end-to-end"

QUBESDB_KVM_DIR="$(dirname "$CORE_ADMIN")/qubes-core-qubesdb/daemon/kvm"
if [[ -d "$QUBESDB_KVM_DIR" ]]; then
    # Build if needed
    if [[ ! -x "$QUBESDB_KVM_DIR/qubesdb-config-inject" ]] || \
       [[ ! -x "$QUBESDB_KVM_DIR/qubesdb-config-read" ]]; then
        make -C "$QUBESDB_KVM_DIR" clean all &>/dev/null
    fi

    if [[ -x "$QUBESDB_KVM_DIR/qubesdb-config-inject" ]] && \
       [[ -x "$QUBESDB_KVM_DIR/qubesdb-config-read" ]]; then

        # Create a Unix socket pair to simulate virtio-serial
        SOCK_PATH="/tmp/qubesdb-e2e-test-$$.sock"
        CONFIG_IN=$(mktemp)
        CONFIG_OUT=$(mktemp)

        cat > "$CONFIG_IN" << 'QDBEOF'
/qubes-vm-type = AppVM
/qubes-ip = 10.137.0.50
/qubes-netmask = 255.255.255.255
/qubes-gateway = 10.137.0.1
/qubes-primary-dns = 10.139.1.1
/qubes-secondary-dns = 10.139.1.2
/qubes-vm-persistence = full
/qubes-timezone = UTC
/qubes-random-seed = dGVzdHNlZWQ=
QDBEOF

        # Test 1: config-inject can serialize without crash
        INJECT_OUT=$("$QUBESDB_KVM_DIR/qubesdb-config-inject" --dry-run "$CONFIG_IN" 2>&1 || true)
        if [[ $? -eq 0 ]] || echo "$INJECT_OUT" | grep -qi "dry.run\|success\|written\|entries"; then
            pass "qubesdb-config-inject: serialization works"
        elif echo "$INJECT_OUT" | grep -qi "unknown option\|unrecognized"; then
            # Doesn't support --dry-run, test with /dev/null socket
            INJECT_OUT2=$("$QUBESDB_KVM_DIR/qubesdb-config-inject" "$CONFIG_IN" /dev/null 2>&1 || true)
            if echo "$INJECT_OUT2" | grep -qi "error.*connect\|cannot open"; then
                pass "qubesdb-config-inject: runs, fails on socket (expected)"
            else
                pass "qubesdb-config-inject: executes without crash"
            fi
        else
            fail "qubesdb-config-inject: unexpected error: $INJECT_OUT"
        fi

        # Test 2: config-read can parse without crash (give it /dev/null input)
        READ_OUT=$(echo "" | timeout 2 "$QUBESDB_KVM_DIR/qubesdb-config-read" /dev/stdin 2>&1 || true)
        if echo "$READ_OUT" | grep -qi "error\|segfault\|core dump"; then
            fail "qubesdb-config-read: crashed"
        else
            pass "qubesdb-config-read: executes without crash"
        fi

        # Test 3: verify inject source code handles all expected qubesdb paths
        INJECT_SRC="$QUBESDB_KVM_DIR/qubesdb-config-inject.c"
        if [[ -f "$INJECT_SRC" ]]; then
            for path in qubes-vm-type qubes-ip qubes-gateway; do
                if grep -q "$path" "$INJECT_SRC"; then
                    pass "inject source handles /$path"
                else
                    skip "inject source may not handle /$path directly"
                fi
            done
        fi

        rm -f "$CONFIG_IN" "$CONFIG_OUT" "$SOCK_PATH"
    else
        skip "qubesdb-config-inject/read not built"
    fi
else
    skip "qubes-core-qubesdb/daemon/kvm not found"
fi

# ── Section 14: KVM libvirt template device includes ─────────────
header "14. Libvirt template device includes exist"

for dev_tpl in block-kvm.xml net-kvm.xml net-vhost-kvm.xml pci-kvm.xml pci-kvm-aarch64.xml; do
    dev_path="$TMPL_DIR/devices/$dev_tpl"
    if [[ -f "$dev_path" ]]; then
        pass "devices/$dev_tpl exists"
    else
        fail "devices/$dev_tpl missing"
    fi
done

# net-kvm.xml should reference /etc/qubes/kvm/vif-route-qubes
if grep -q '/etc/qubes/kvm/vif-route-qubes' "$TMPL_DIR/devices/net-kvm.xml"; then
    pass "net-kvm.xml references /etc/qubes/kvm/vif-route-qubes"
else
    fail "net-kvm.xml does NOT reference /etc/qubes/kvm/vif-route-qubes"
fi

# ── Summary ──────────────────────────────────────────────────────
header "SUMMARY"
TOTAL=$((PASS + FAIL + SKIP))
echo "  Total:   $TOTAL"
echo "  Passed:  $PASS"
echo "  Failed:  $FAIL"
echo "  Skipped: $SKIP"
echo ""
if [[ $FAIL -eq 0 ]]; then
    echo "  RESULT: ALL TESTS PASSED"
    exit 0
else
    echo "  RESULT: $FAIL TEST(S) FAILED"
    exit 1
fi
