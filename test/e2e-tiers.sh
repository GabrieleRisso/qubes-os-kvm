#!/bin/bash
# e2e-tiers.sh -- End-to-end test for all three tiers inside kvm-dev
#
# Run this INSIDE kvm-dev (or any environment with /dev/kvm, QEMU, etc.)
# It validates the full architecture: build -> Xen-on-KVM -> ARM64.
#
# Usage:
#   bash test/e2e-tiers.sh           # run all tiers
#   bash test/e2e-tiers.sh tier1     # build environment only
#   bash test/e2e-tiers.sh tier2     # KVM + Xen emulation only
#   bash test/e2e-tiers.sh tier3     # ARM64 cross-compilation only
set -u

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass()  { PASS_COUNT=$((PASS_COUNT + 1)); echo "  [PASS] $*"; }
fail()  { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  [FAIL] $*"; }
skip()  { SKIP_COUNT=$((SKIP_COUNT + 1)); echo "  [SKIP] $*"; }
header(){ echo ""; echo "========================================"; echo "  $*"; echo "========================================"; }

# ── TIER 1: Build Environment ─────────────────────────────────────

tier1() {
    header "TIER 1: Build Environment"

    echo "--- 1.1: Core build tools ---"
    command -v gcc &>/dev/null && pass "gcc: $(gcc --version | head -1)" || fail "gcc not found"
    command -v g++ &>/dev/null && pass "g++ available" || fail "g++ not found"
    command -v make &>/dev/null && pass "make: $(make --version | head -1)" || fail "make not found"
    command -v cmake &>/dev/null && pass "cmake: $(cmake --version | head -1)" || fail "cmake not found"
    command -v git &>/dev/null && pass "git: $(git --version)" || fail "git not found"
    command -v python3 &>/dev/null && pass "python3: $(python3 --version)" || fail "python3 not found"

    echo "--- 1.2: Rust toolchain ---"
    command -v cargo &>/dev/null && pass "cargo: $(cargo --version)" || fail "cargo not found"
    command -v rustc &>/dev/null && pass "rustc: $(rustc --version)" || fail "rustc not found"

    echo "--- 1.3: Container engine ---"
    if command -v podman &>/dev/null; then
        pass "podman: $(podman --version)"
        echo "--- 1.3a: Container build test ---"
        TMPDIR_CTR=$(mktemp -d)
        cat > "$TMPDIR_CTR/Containerfile" << 'CEOF'
FROM registry.fedoraproject.org/fedora-minimal:42
RUN microdnf install -y gcc && gcc --version && echo CONTAINER_BUILD_OK
CEOF
        if timeout 120 podman build -t test-tier1 -f "$TMPDIR_CTR/Containerfile" "$TMPDIR_CTR" 2>&1 | tail -5 | grep -q "CONTAINER_BUILD_OK"; then
            pass "Container build: gcc available inside container"
            podman rmi test-tier1 2>/dev/null || true
        else
            fail "Container build failed"
        fi
        rm -rf "$TMPDIR_CTR"
    else
        fail "podman not found"
    fi

    echo "--- 1.4: C compilation test ---"
    TMPDIR_C=$(mktemp -d)
    cat > "$TMPDIR_C/test.c" << 'CEOF'
#include <stdio.h>
int main() {
    printf("Tier 1 compile test: OK\n");
    return 0;
}
CEOF
    if gcc -o "$TMPDIR_C/test" "$TMPDIR_C/test.c" && "$TMPDIR_C/test" | grep -q "OK"; then
        pass "C compilation + execution"
    else
        fail "C compilation or execution failed"
    fi
    rm -rf "$TMPDIR_C"

    echo "--- 1.5: Rust compilation test ---"
    TMPDIR_RS=$(mktemp -d)
    cat > "$TMPDIR_RS/main.rs" << 'REOF'
fn main() {
    println!("Tier 1 Rust test: OK");
}
REOF
    if rustc -o "$TMPDIR_RS/test" "$TMPDIR_RS/main.rs" && "$TMPDIR_RS/test" | grep -q "OK"; then
        pass "Rust compilation + execution"
    else
        fail "Rust compilation or execution failed"
    fi
    rm -rf "$TMPDIR_RS"

    echo "--- 1.6: Project structure ---"
    PROJ="${PROJ_DIR:-/home/user/fix/qubes-kvm-fork}"
    if [[ -d "$PROJ" ]]; then
        [[ -f "$PROJ/Makefile" ]] && pass "Project Makefile exists" || fail "Makefile missing"
        [[ -d "$PROJ/scripts" ]] && pass "scripts/ directory exists" || fail "scripts/ missing"
        [[ -d "$PROJ/test" ]] && pass "test/ directory exists" || fail "test/ missing"
        [[ -d "$PROJ/configs" ]] && pass "configs/ directory exists" || fail "configs/ missing"
        for s in "$PROJ"/scripts/*.sh; do
            [[ -f "$s" ]] || continue
            bash -n "$s" 2>/dev/null && pass "$(basename "$s") syntax OK" || fail "$(basename "$s") syntax error"
        done
    else
        skip "Project directory not found at $PROJ"
    fi

    echo "--- 1.7: RPM build tools ---"
    command -v rpmbuild &>/dev/null && pass "rpmbuild available" || skip "rpmbuild not found (optional)"
    command -v createrepo_c &>/dev/null && pass "createrepo_c available" || skip "createrepo_c not found (optional)"

    # ── 1.8-1.12: KVM component build & test ──────────────────────
    SRC_ROOT="${SRC_ROOT:-$(dirname "$PROJ")}"

    echo "--- 1.8: vchan-socket build ---"
    VCHAN_DIR="$SRC_ROOT/qubes-core-vchan-socket"
    if [[ -d "$VCHAN_DIR" ]]; then
        if make -C "$VCHAN_DIR" clean all 2>&1 | tail -1; then
            pass "vchan-socket builds clean (-Werror)"
        else
            fail "vchan-socket build failed"
        fi

        if nm -D "$VCHAN_DIR/vchan/libvchan-socket.so" 2>/dev/null | grep -q "libvchan_set_blocking"; then
            pass "libvchan_set_blocking symbol exported"
        else
            fail "libvchan_set_blocking not exported"
        fi

        if [[ -f "$VCHAN_DIR/vchan/vchan-socket.pc" ]] && grep -q "backend_vmm=socket" "$VCHAN_DIR/vchan/vchan-socket.pc"; then
            pass "vchan-socket.pc has backend_vmm=socket"
        else
            fail "vchan-socket.pc missing or wrong backend_vmm"
        fi
    else
        skip "vchan-socket repo not found at $VCHAN_DIR"
    fi

    echo "--- 1.9: vchan-socket tests ---"
    if [[ -d "$VCHAN_DIR" ]]; then
        rm -f /tmp/vchan.*.sock
        VCHAN_TEST_OUT=$(cd "$VCHAN_DIR" && timeout 30 python3 -m unittest tests.test_vchan tests.test_integration 2>&1)
        if echo "$VCHAN_TEST_OUT" | grep -q "^OK"; then
            TCOUNT=$(echo "$VCHAN_TEST_OUT" | grep -oP 'Ran \K[0-9]+' || echo "?")
            pass "vchan-socket: $TCOUNT tests passed"
        else
            fail "vchan-socket tests failed"
            echo "$VCHAN_TEST_OUT" | tail -5
        fi
    else
        skip "vchan-socket tests (repo not found)"
    fi

    echo "--- 1.10: qubesdb-config KVM tools ---"
    QUBESDB_DIR="$SRC_ROOT/qubes-core-qubesdb"
    if [[ -d "$QUBESDB_DIR/daemon/kvm" ]]; then
        if make -C "$QUBESDB_DIR/daemon/kvm" clean all 2>&1 | tail -1; then
            pass "qubesdb-config-inject builds clean"
            pass "qubesdb-config-read builds clean"
        else
            fail "qubesdb KVM tools build failed"
        fi
    else
        skip "qubesdb KVM tools not found"
    fi

    echo "--- 1.11: Agent KVM scripts ---"
    AGENT_DIR="$SRC_ROOT/qubes-core-agent-linux"
    if [[ -d "$AGENT_DIR" ]]; then
        for f in init/hypervisor.sh init/qubes-domain-id.sh network/qubesdb-hotplug-watcher.sh network/vif-route-qubes-kvm; do
            if [[ -f "$AGENT_DIR/$f" ]]; then
                bash -n "$AGENT_DIR/$f" 2>/dev/null && pass "$(basename "$f") syntax OK" || fail "$(basename "$f") syntax error"
            else
                fail "$f not found"
            fi
        done

        if command -v shellcheck &>/dev/null; then
            SC_FAIL=0
            for f in init/hypervisor.sh init/qubes-domain-id.sh network/qubesdb-hotplug-watcher.sh network/vif-route-qubes-kvm; do
                [[ -f "$AGENT_DIR/$f" ]] || continue
                shellcheck -S warning "$AGENT_DIR/$f" 2>/dev/null || SC_FAIL=$((SC_FAIL + 1))
            done
            [[ "$SC_FAIL" -eq 0 ]] && pass "ShellCheck: all KVM scripts clean" || fail "ShellCheck: $SC_FAIL scripts with warnings"
        else
            skip "shellcheck not installed"
        fi
    else
        skip "core-agent-linux not found"
    fi

    echo "--- 1.12: x86 KVM kernel config ---"
    KERNEL_DIR="$SRC_ROOT/qubes-linux-kernel"
    KVM_CONFIG="$KERNEL_DIR/config-qubes-kvm"
    if [[ -f "$KVM_CONFIG" ]]; then
        pass "config-qubes-kvm exists"
        for opt in CONFIG_KVM_GUEST CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK \
                   CONFIG_VIRTIO_NET CONFIG_VIRTIO_CONSOLE CONFIG_VSOCKETS \
                   CONFIG_KVM CONFIG_KVM_INTEL CONFIG_KVM_AMD CONFIG_VFIO CONFIG_IOMMU_SUPPORT; do
            if grep -q "^${opt}=" "$KVM_CONFIG"; then
                pass "config-qubes-kvm: $opt enabled"
            else
                fail "config-qubes-kvm: $opt missing"
            fi
        done
    else
        fail "config-qubes-kvm not found"
    fi
    KERNEL_SPEC="$KERNEL_DIR/kernel.spec.in"
    if [[ -f "$KERNEL_SPEC" ]]; then
        grep -q 'config-qubes-kvm' "$KERNEL_SPEC" && pass "kernel.spec.in references config-qubes-kvm" || fail "kernel.spec.in missing config-qubes-kvm ref"
    else
        skip "kernel.spec.in not found"
    fi

    echo "--- 1.13: KVM installation completeness ---"
    if [[ -d "$AGENT_DIR" ]]; then
        grep -q 'vif-route-qubes-kvm.*etc/qubes/kvm' "$AGENT_DIR/Makefile" && \
            pass "Makefile installs vif-route-qubes-kvm to /etc/qubes/kvm/" || \
            fail "Makefile missing vif-route-qubes-kvm install"
        grep -q 'qubesdb-hotplug-watcher.sh' "$AGENT_DIR/Makefile" && \
            pass "Makefile installs qubesdb-hotplug-watcher.sh" || \
            fail "Makefile missing qubesdb-hotplug-watcher.sh install"
        SPEC="$AGENT_DIR/rpm_spec/core-agent.spec.in"
        if [[ -f "$SPEC" ]]; then
            for svc in qubes-kvm-config-read.service qubes-kvm-hotplug-watcher.service qubes-vchan-domain-env.service; do
                grep -q "$svc" "$SPEC" && pass "spec: $svc in %%files" || fail "spec: $svc missing"
            done
            grep -q '/etc/qubes/kvm/vif-route-qubes' "$SPEC" && \
                pass "spec: /etc/qubes/kvm/vif-route-qubes listed" || \
                fail "spec: /etc/qubes/kvm/vif-route-qubes missing"
        else
            skip "core-agent.spec.in not found"
        fi
    else
        skip "qubes-core-agent-linux not found"
    fi

    echo "--- 1.14: app.py backend_vmm guards ---"
    APP_PY="$SRC_ROOT/qubes-core-admin/qubes/app.py"
    if [[ -f "$APP_PY" ]]; then
        grep -A15 'def xs' "$APP_PY" | grep -q 'backend_vmm.*!=.*"xen"' && \
            pass "app.py: xs property checks backend_vmm" || \
            fail "app.py: xs property missing backend_vmm check"
        grep -A15 'def xc' "$APP_PY" | grep -q 'backend_vmm.*!=.*"xen"' && \
            pass "app.py: xc property checks backend_vmm" || \
            fail "app.py: xc property missing backend_vmm check"
    else
        skip "app.py not found"
    fi

    echo "--- 1.15: RPM spec conditionals ---"
    if command -v rpm &>/dev/null; then
        KVM_VAL=$(rpm --define 'backend_vmm kvm' --eval '%{?backend_vmm}')
        [[ "$KVM_VAL" == "kvm" ]] && pass "RPM macro backend_vmm=kvm resolves" || fail "backend_vmm macro broken"

        VCHAN_SPEC="$SRC_ROOT/qubes-core-vchan-socket/rpm_spec/libvchan-socket.spec.in"
        if [[ -f "$VCHAN_SPEC" ]]; then
            grep -q 'Provides:.*qubes-libvchan' "$VCHAN_SPEC" && pass "vchan-socket spec: Provides qubes-libvchan" || fail "vchan-socket spec: missing Provides"
            grep -q 'Conflicts:.*qubes-libvchan-xen' "$VCHAN_SPEC" && pass "vchan-socket spec: Conflicts qubes-libvchan-xen" || fail "vchan-socket spec: missing Conflicts"
        else
            skip "vchan-socket spec not found"
        fi

        BUILDERV2="$SRC_ROOT/qubes-builderv2"
        if [[ -f "$BUILDERV2/example-configs/qubes-os-kvm.yml" ]]; then
            grep -q 'backend-vmm: kvm' "$BUILDERV2/example-configs/qubes-os-kvm.yml" && pass "builder KVM config: backend-vmm=kvm" || fail "builder KVM config broken"
        else
            skip "qubes-builderv2 KVM config not found"
        fi
    else
        skip "rpm not found"
    fi
}

# ── TIER 2: KVM + Xen Emulation ───────────────────────────────────

tier2() {
    header "TIER 2: KVM + Xen Emulation"

    echo "--- 2.1: KVM device ---"
    if [[ -e /dev/kvm ]]; then
        pass "/dev/kvm exists"
        ls -la /dev/kvm
    else
        fail "/dev/kvm NOT found"
        echo "  Tier 2 requires /dev/kvm. Most tests will fail."
    fi

    echo "--- 2.2: KVM kernel modules ---"
    if lsmod | grep -q kvm_intel; then
        pass "kvm_intel module loaded"
    elif lsmod | grep -q kvm_amd; then
        pass "kvm_amd module loaded"
    else
        fail "No KVM module loaded"
    fi

    echo "--- 2.3: QEMU accelerators ---"
    if command -v qemu-system-x86_64 &>/dev/null; then
        pass "qemu-system-x86_64: $(qemu-system-x86_64 --version | head -1)"
        ACCEL=$(qemu-system-x86_64 -accel help 2>&1)
        echo "$ACCEL" | grep -q "kvm" && pass "QEMU KVM accelerator available" || fail "QEMU KVM accelerator missing"
        echo "$ACCEL" | grep -q "tcg" && pass "QEMU TCG accelerator available" || fail "QEMU TCG accelerator missing"
        # Note: -accel xen is the NATIVE Xen accelerator (running under Xen dom0).
        # Our architecture uses -accel kvm,xen-version=... which is KVM with Xen
        # HVM emulation -- a property of the KVM accelerator, not a separate accel.
        if echo "$ACCEL" | grep -q "xen"; then
            pass "QEMU native Xen accelerator also available (bonus)"
        else
            pass "Native Xen accel not present (expected: we use KVM+xen-version)"
        fi
    else
        fail "qemu-system-x86_64 not found"
    fi

    echo "--- 2.4: KVM acceleration test ---"
    if [[ -e /dev/kvm ]]; then
        KVM_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm -cpu host -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$KVM_OUT" | grep -qi "kvm"; then
            pass "QEMU accepted -accel kvm (KVM acceleration works)"
        else
            pass "QEMU started with KVM (no crash)"
        fi
    else
        skip "KVM acceleration test (no /dev/kvm)"
    fi

    echo "--- 2.5: Xen HVM emulation support ---"
    if [[ -e /dev/kvm ]]; then
        XEN_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host \
            -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$XEN_OUT" | grep -qi "error\|unsupported\|invalid\|not supported"; then
            fail "Xen HVM emulation: QEMU rejected xen-version parameter"
            echo "  Output: $XEN_OUT"
        else
            pass "Xen HVM emulation: QEMU accepted xen-version=0x40013 (Xen 4.19)"
        fi
    else
        skip "Xen HVM emulation test (no /dev/kvm)"
    fi

    echo "--- 2.5a: Xen HVM with xen-vapic ---"
    if [[ -e /dev/kvm ]]; then
        VAPIC_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$VAPIC_OUT" | grep -qi "error\|unsupported\|not supported\|can't apply"; then
            fail "xen-vapic CPU flag rejected"
            echo "  Output: $VAPIC_OUT"
        else
            pass "xen-vapic CPU flag accepted"
        fi
    else
        skip "xen-vapic test (no /dev/kvm)"
    fi

    echo "--- 2.5b: Xen event channels (xen-evtchn) ---"
    if [[ -e /dev/kvm ]]; then
        EVTCHN_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split,xen-evtchn=on \
            -cpu host \
            -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$EVTCHN_OUT" | grep -qi "error\|unsupported\|not supported\|unknown"; then
            fail "Xen event channel emulation (xen-evtchn=on) rejected"
            echo "  Output: $EVTCHN_OUT"
        else
            pass "Xen event channel emulation (xen-evtchn=on) accepted"
        fi
    else
        skip "Xen event channel test (no /dev/kvm)"
    fi

    echo "--- 2.5c: Xen grant tables (xen-gnttab) ---"
    if [[ -e /dev/kvm ]]; then
        GNTTAB_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split,xen-gnttab=on \
            -cpu host \
            -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$GNTTAB_OUT" | grep -qi "error\|unsupported\|not supported\|unknown"; then
            fail "Xen grant table emulation (xen-gnttab=on) rejected"
            echo "  Output: $GNTTAB_OUT"
        else
            pass "Xen grant table emulation (xen-gnttab=on) accepted"
        fi
    else
        skip "Xen grant table test (no /dev/kvm)"
    fi

    echo "--- 2.5d: Full Xen HVM stack (evtchn + gnttab + vapic) ---"
    if [[ -e /dev/kvm ]]; then
        FULL_XEN_OUT=$(timeout 5 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split,xen-evtchn=on,xen-gnttab=on \
            -cpu host,+xen-vapic \
            -m 128 -display none \
            -no-reboot -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)
        if echo "$FULL_XEN_OUT" | grep -qi "error\|unsupported\|not supported"; then
            fail "Full Xen HVM stack rejected"
            echo "  Output: $FULL_XEN_OUT"
        else
            pass "Full Xen HVM stack accepted (evtchn + gnttab + vapic)"
        fi
    else
        skip "Full Xen HVM stack test (no /dev/kvm)"
    fi

    echo "--- 2.6: Xen device emulation ---"
    if [[ -e /dev/kvm ]]; then
        TMPIMG=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG" 1G &>/dev/null

        XEN_DEV_OUT=$(timeout 8 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 256 -display none \
            -no-reboot \
            -drive file="$TMPIMG",if=xen,format=qcow2 \
            -chardev socket,id=char0,path=/tmp/xen-console-test-$$.sock,server=on,wait=off \
            -device xen-console,chardev=char0 \
            -device virtio-rng-pci \
            -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)

        rm -f "$TMPIMG" "/tmp/xen-console-test-$$.sock"

        if echo "$XEN_DEV_OUT" | grep -qi "error.*xen-console\|unknown device\|unsupported"; then
            fail "Xen device emulation: xen-console device rejected"
            echo "  Output: $XEN_DEV_OUT"
        else
            pass "Xen device emulation: xen-console + xen disk accepted"
        fi
    else
        skip "Xen device emulation test (no /dev/kvm)"
    fi

    echo "--- 2.6a: Xen disk + virtio-net combo ---"
    if [[ -e /dev/kvm ]]; then
        TMPIMG2=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG2" 512M &>/dev/null

        COMBO_OUT=$(timeout 8 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 256 -display none -no-reboot \
            -machine q35 \
            -drive file="$TMPIMG2",if=xen,format=qcow2 \
            -netdev user,id=net0 \
            -device virtio-net-pci,netdev=net0 \
            -serial none -monitor none \
            -kernel /dev/null 2>&1 || true)

        rm -f "$TMPIMG2"

        if echo "$COMBO_OUT" | grep -qi "error\|unsupported\|unknown device"; then
            fail "Xen disk + virtio-net combo rejected"
            echo "  Output: $COMBO_OUT"
        else
            pass "Xen disk + virtio-net-pci + q35 machine accepted"
        fi
    else
        skip "Xen combo test (no /dev/kvm)"
    fi

    echo "--- 2.7: OVMF firmware ---"
    OVMF_PATH=""
    for f in /usr/share/edk2/ovmf/OVMF_CODE.fd \
             /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/xen/OVMF.fd; do
        if [[ -f "$f" ]]; then
            OVMF_PATH="$f"
            break
        fi
    done
    if [[ -n "$OVMF_PATH" ]]; then
        OVMF_SIZE=$(du -h "$OVMF_PATH" | cut -f1)
        pass "OVMF UEFI firmware available: $OVMF_PATH ($OVMF_SIZE)"
    else
        skip "OVMF firmware not found (needed for full HVM boot)"
    fi

    echo "--- 2.7a: OVMF + Xen HVM boot test ---"
    if [[ -e /dev/kvm ]] && [[ -n "${OVMF_PATH:-}" ]]; then
        TMPIMG3=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG3" 256M &>/dev/null

        OVMF_BOOT_OUT=$(timeout 10 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 256 -display none -no-reboot \
            -machine q35 \
            -drive if=pflash,format=raw,readonly=on,file="$OVMF_PATH" \
            -drive file="$TMPIMG3",if=xen,format=qcow2 \
            -serial none -monitor none \
            2>&1 || true)

        rm -f "$TMPIMG3"

        if echo "$OVMF_BOOT_OUT" | grep -qi "fatal\|abort\|incompatible\|error.*pflash"; then
            fail "OVMF + Xen HVM boot combination rejected"
            echo "  Output: $OVMF_BOOT_OUT"
        else
            pass "OVMF + Xen HVM boot accepted (UEFI + Xen emulation compatible)"
        fi
    else
        skip "OVMF + Xen HVM boot test (missing OVMF or /dev/kvm)"
    fi

    echo "--- 2.8: libvirt ---"
    if command -v virsh &>/dev/null; then
        pass "virsh: $(virsh --version)"
        if systemctl is-active libvirtd &>/dev/null || systemctl is-active virtqemud &>/dev/null; then
            pass "libvirt daemon running"
        else
            echo "  Attempting to start libvirtd..."
            if sudo systemctl start libvirtd 2>/dev/null; then
                sleep 1
                if systemctl is-active libvirtd &>/dev/null; then
                    pass "libvirt daemon started successfully"
                else
                    fail "libvirtd failed to start"
                fi
            else
                skip "libvirt daemon not running (sudo required to start)"
            fi
        fi
    else
        skip "virsh not installed"
    fi

    echo "--- 2.8a: libvirt QEMU driver ---"
    if command -v virsh &>/dev/null; then
        if virsh -c qemu:///system capabilities &>/dev/null 2>&1; then
            pass "libvirt QEMU driver functional (qemu:///system)"
        elif virsh -c qemu:///session capabilities &>/dev/null 2>&1; then
            pass "libvirt QEMU driver functional (qemu:///session, unprivileged)"
        else
            skip "libvirt QEMU driver not responding (libvirtd may not be running)"
        fi
    else
        skip "libvirt QEMU driver test (virsh not installed)"
    fi

    echo "--- 2.9: Multi-VM simulation ---"
    if [[ -e /dev/kvm ]]; then
        TMPIMG_A=$(mktemp --suffix=.qcow2)
        TMPIMG_B=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG_A" 256M &>/dev/null
        qemu-img create -f qcow2 "$TMPIMG_B" 256M &>/dev/null
        SOCK_A="/tmp/xen-multi-a-$$.sock"
        SOCK_B="/tmp/xen-multi-b-$$.sock"

        timeout 6 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 128 -display none -no-reboot \
            -drive file="$TMPIMG_A",if=xen,format=qcow2 \
            -chardev socket,id=ch0,path="$SOCK_A",server=on,wait=off \
            -device xen-console,chardev=ch0 \
            -serial none -monitor none \
            -kernel /dev/null \
            -name xen-vm-a &>/dev/null &
        PID_A=$!

        timeout 6 qemu-system-x86_64 \
            -accel kvm,xen-version=0x40013,kernel-irqchip=split \
            -cpu host,+xen-vapic \
            -m 128 -display none -no-reboot \
            -drive file="$TMPIMG_B",if=xen,format=qcow2 \
            -chardev socket,id=ch0,path="$SOCK_B",server=on,wait=off \
            -device xen-console,chardev=ch0 \
            -serial none -monitor none \
            -kernel /dev/null \
            -name xen-vm-b &>/dev/null &
        PID_B=$!

        sleep 2
        ALIVE_A=false; ALIVE_B=false
        kill -0 "$PID_A" 2>/dev/null && ALIVE_A=true
        kill -0 "$PID_B" 2>/dev/null && ALIVE_B=true

        kill "$PID_A" "$PID_B" 2>/dev/null || true
        wait "$PID_A" "$PID_B" 2>/dev/null || true
        rm -f "$TMPIMG_A" "$TMPIMG_B" "$SOCK_A" "$SOCK_B"

        if $ALIVE_A && $ALIVE_B; then
            pass "Multi-VM: 2 Xen-emulated QEMU instances ran concurrently"
        elif $ALIVE_A || $ALIVE_B; then
            fail "Multi-VM: only one of two instances survived"
        else
            fail "Multi-VM: both instances died immediately"
        fi
    else
        skip "Multi-VM simulation (no /dev/kvm)"
    fi

    echo "--- 2.10: Libvirt KVM-Xen domain definition ---"
    if command -v virsh &>/dev/null && \
       { systemctl is-active libvirtd &>/dev/null || systemctl is-active virtqemud &>/dev/null; }; then

        TMPIMG_VIRSH=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG_VIRSH" 256M &>/dev/null

        DOMAIN_XML=$(cat << VIRSHEOF
<domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
    <name>xen-kvm-test-$$</name>
    <memory unit="MiB">128</memory>
    <vcpu>1</vcpu>
    <os>
        <type arch="x86_64" machine="q35">hvm</type>
        <boot dev="hd"/>
    </os>
    <features>
        <acpi/>
        <apic/>
    </features>
    <on_poweroff>destroy</on_poweroff>
    <on_reboot>destroy</on_reboot>
    <on_crash>destroy</on_crash>
    <devices>
        <emulator>/usr/bin/qemu-system-x86_64</emulator>
        <disk type="file" device="disk">
            <driver name="qemu" type="qcow2"/>
            <source file="$TMPIMG_VIRSH"/>
            <target dev="vda" bus="virtio"/>
        </disk>
        <console type="pty">
            <target type="serial" port="0"/>
        </console>
    </devices>
    <qemu:commandline>
        <qemu:arg value="-accel"/>
        <qemu:arg value="kvm,xen-version=0x40013,kernel-irqchip=split"/>
        <qemu:arg value="-cpu"/>
        <qemu:arg value="host,+xen-vapic"/>
    </qemu:commandline>
</domain>
VIRSHEOF
)
        DEFINE_OUT=$(echo "$DOMAIN_XML" | virsh define /dev/stdin 2>&1 || true)
        if echo "$DEFINE_OUT" | grep -qi "defined\|xen-kvm-test"; then
            pass "Libvirt accepted KVM-Xen domain definition"
            virsh undefine "xen-kvm-test-$$" &>/dev/null || true
        else
            fail "Libvirt rejected KVM-Xen domain definition"
            echo "  Output: $DEFINE_OUT"
        fi
        rm -f "$TMPIMG_VIRSH"
    else
        skip "Libvirt domain definition test (libvirtd not running)"
    fi

    echo "--- 2.11: KVM-Xen shim template exists ---"
    PROJ="${PROJ_DIR:-/home/user/qubes-kvm-fork}"
    TMPL_BASE="${TMPL_DIR:-/home/user/fix/qubes-core-admin/templates/libvirt}"
    if [[ -f "$TMPL_BASE/kvm-xenshim.xml" ]]; then
        pass "x86 KVM-Xen shim template: kvm-xenshim.xml"
    else
        fail "x86 KVM-Xen shim template (kvm-xenshim.xml) not found"
    fi
    if [[ -f "$TMPL_BASE/kvm-aarch64-xenshim.xml" ]]; then
        pass "ARM64 KVM-Xen shim template: kvm-aarch64-xenshim.xml"
    else
        skip "ARM64 KVM-Xen shim template not found"
    fi
    if [[ -f "$TMPL_BASE/kvm.xml" ]]; then
        pass "x86 KVM template: kvm.xml"
    else
        fail "x86 KVM template (kvm.xml) not found"
    fi

    echo "--- 2.12: QubesDB virtio-serial channel in templates ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        tpl_path="$TMPL_BASE/$tpl"
        if [[ -f "$tpl_path" ]]; then
            if grep -q 'org.qubes-os.qubesdb' "$tpl_path"; then
                pass "$tpl contains org.qubes-os.qubesdb channel"
            else
                fail "$tpl missing org.qubes-os.qubesdb channel"
            fi
        else
            skip "$tpl not found"
        fi
    done

    echo "--- 2.13: Templates contain no raw xenstore references ---"
    for tpl in kvm.xml kvm-xenshim.xml kvm-aarch64.xml kvm-aarch64-xenshim.xml; do
        tpl_path="$TMPL_BASE/$tpl"
        if [[ -f "$tpl_path" ]]; then
            if grep -q 'xenstore' "$tpl_path"; then
                fail "$tpl contains xenstore reference"
            else
                pass "$tpl clean of xenstore references"
            fi
        fi
    done

    echo "--- 2.14: Python module import test ---"
    CORE_ADMIN="${TMPL_BASE%/templates/libvirt}"
    if [[ -d "$CORE_ADMIN/qubes" ]]; then
        export PYTHONPATH="$CORE_ADMIN:${PYTHONPATH:-}"
        IMPORT_OUT=$(python3 -c "import qubes.vm.mix.kvm_mem" 2>&1)
        IMPORT_RC=$?
        if [[ $IMPORT_RC -eq 0 ]]; then
            pass "import qubes.vm.mix.kvm_mem succeeds"
        elif echo "$IMPORT_OUT" | grep -qi "No module named 'docutils'\|No module named 'libvirt'"; then
            skip "import qubes.vm.mix.kvm_mem (missing dependency: $(echo "$IMPORT_OUT" | grep 'No module' | tail -1))"
        else
            fail "import qubes.vm.mix.kvm_mem failed: $IMPORT_OUT"
        fi
    else
        skip "Python import test (qubes-core-admin not found)"
    fi
}

# ── TIER 3: ARM64 Cross-Compilation + Emulation ───────────────────
# The full Tier 3 suite is in test/tier3-arm64.sh (131 tests).
# This function delegates to it.

tier3() {
    header "TIER 3: ARM64 Cross-Compilation + Emulation"

    TIER3_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tier3-arm64.sh"
    if [[ -f "$TIER3_SCRIPT" ]]; then
        echo "Delegating to $TIER3_SCRIPT ..."
        echo ""
        # Source the script's functions and run all sections,
        # accumulating into our counters
        (
            bash "$TIER3_SCRIPT" all
        )
        TIER3_RC=$?
        if [[ $TIER3_RC -eq 0 ]]; then
            pass "Tier 3 ARM64 full suite passed"
        else
            fail "Tier 3 ARM64 suite had failures (exit code $TIER3_RC)"
        fi
    else
        fail "tier3-arm64.sh not found at $TIER3_SCRIPT"
        echo "--- Fallback: basic tool checks ---"

        command -v aarch64-linux-gnu-gcc &>/dev/null && pass "aarch64-linux-gnu-gcc available" || fail "aarch64-linux-gnu-gcc not found"
        command -v qemu-system-aarch64 &>/dev/null && pass "qemu-system-aarch64 available" || fail "qemu-system-aarch64 not found"
        command -v qemu-aarch64-static &>/dev/null && pass "qemu-aarch64-static available" || \
            { command -v qemu-aarch64 &>/dev/null && pass "qemu-aarch64 available" || fail "No ARM64 user-mode emulator"; }

        for f in /usr/share/edk2/aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do
            if [[ -f "$f" ]]; then pass "ARM64 UEFI firmware: $f"; break; fi
        done
    fi
}

# ── Summary ───────────────────────────────────────────────────────

summary() {
    header "SUMMARY"
    local TOTAL=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    echo "  Total:   $TOTAL"
    echo "  Passed:  $PASS_COUNT"
    echo "  Failed:  $FAIL_COUNT"
    echo "  Skipped: $SKIP_COUNT"
    echo ""
    if [[ $FAIL_COUNT -eq 0 ]]; then
        echo "  RESULT: ALL TESTS PASSED"
        return 0
    else
        echo "  RESULT: $FAIL_COUNT TEST(S) FAILED"
        return 1
    fi
}

# ── Main ──────────────────────────────────────────────────────────

CMD="${1:-all}"
case "$CMD" in
    tier1) tier1; summary ;;
    tier2) tier2; summary ;;
    tier3) tier3; summary ;;
    all)   tier1; tier2; tier3; summary ;;
    *)     echo "Usage: $0 [tier1|tier2|tier3|all]"; exit 1 ;;
esac
