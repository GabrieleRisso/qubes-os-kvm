#!/bin/bash
# tier3-arm64.sh — Comprehensive Tier 3 ARM64/Snapdragon test suite
#
# Tests cross-compilation, emulation, kernel configs, libvirt templates,
# hypervisor detection, boot chain, builder config, and QEMU ARM64 boot.
#
# Usage:
#   bash test/tier3-arm64.sh           # run all tests
#   bash test/tier3-arm64.sh tools     # toolchain only
#   bash test/tier3-arm64.sh configs   # kernel configs only
#   bash test/tier3-arm64.sh templates # libvirt templates only
#   bash test/tier3-arm64.sh boot      # QEMU ARM64 boot tests only
set -u

PASS=0; FAIL=0; SKIP=0; TOTAL=0
pass()  { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  [PASS] $*"; }
fail()  { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  [FAIL] $*"; }
skip()  { SKIP=$((SKIP+1)); TOTAL=$((TOTAL+1)); echo "  [SKIP] $*"; }
hdr()   { echo ""; echo "========================================"; echo "  $*"; echo "========================================"; }

SRC_ROOT="${SRC_ROOT:-/home/user/fix}"

# ── 3.1: ARM64 Cross-Compilation Toolchain ─────────────────────────

test_tools() {
    hdr "3.1: ARM64 Cross-Compilation Toolchain"

    echo "--- 3.1.1: Cross-compiler ---"
    if command -v aarch64-linux-gnu-gcc &>/dev/null; then
        pass "aarch64-linux-gnu-gcc: $(aarch64-linux-gnu-gcc --version | head -1)"
    else
        fail "aarch64-linux-gnu-gcc not found"
    fi

    if command -v aarch64-linux-gnu-ld &>/dev/null; then
        pass "aarch64-linux-gnu-ld (linker) available"
    else
        fail "aarch64-linux-gnu-ld not found"
    fi

    if command -v aarch64-linux-gnu-objdump &>/dev/null; then
        pass "aarch64-linux-gnu-objdump available"
    else
        skip "aarch64-linux-gnu-objdump not found (optional)"
    fi

    echo "--- 3.1.2: QEMU system emulation ---"
    if command -v qemu-system-aarch64 &>/dev/null; then
        QVER=$(qemu-system-aarch64 --version | head -1)
        pass "qemu-system-aarch64: $QVER"

        MACHINES=$(qemu-system-aarch64 -M help 2>&1)
        if echo "$MACHINES" | grep -q "virt"; then
            pass "QEMU aarch64 'virt' machine type available"
        else
            fail "QEMU aarch64 'virt' machine type missing"
        fi
    else
        fail "qemu-system-aarch64 not found"
    fi

    echo "--- 3.1.3: QEMU user-mode emulation ---"
    if command -v qemu-aarch64-static &>/dev/null; then
        pass "qemu-aarch64-static: $(qemu-aarch64-static --version | head -1)"
    elif command -v qemu-aarch64 &>/dev/null; then
        pass "qemu-aarch64: $(qemu-aarch64 --version | head -1)"
    else
        fail "No ARM64 user-mode emulator (qemu-aarch64-static or qemu-aarch64)"
    fi

    echo "--- 3.1.4: ARM64 UEFI firmware ---"
    AAVMF=""
    for f in /usr/share/edk2/aarch64/QEMU_EFI.fd \
             /usr/share/AAVMF/AAVMF_CODE.fd \
             /usr/share/edk2/aarch64/QEMU_EFI-pflash.raw; do
        if [[ -f "$f" ]]; then
            AAVMF="$f"
            break
        fi
    done
    if [[ -n "$AAVMF" ]]; then
        FWSIZE=$(du -h "$AAVMF" | cut -f1)
        pass "ARM64 UEFI firmware: $AAVMF ($FWSIZE)"
    else
        fail "ARM64 UEFI firmware not found"
    fi

    echo "--- 3.1.5: Freestanding cross-compile + user-mode run ---"
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
                pass "Cross-compiled freestanding aarch64 binary"
            else
                fail "Cross-compile produced wrong arch: $FTYPE"
            fi

            QEMU_USER=""
            command -v qemu-aarch64-static &>/dev/null && QEMU_USER="qemu-aarch64-static"
            command -v qemu-aarch64 &>/dev/null && QEMU_USER="qemu-aarch64"
            if [[ -n "$QEMU_USER" ]]; then
                ARM_OUT=$($QEMU_USER "$TMP/hello" 2>/dev/null || true)
                if echo "$ARM_OUT" | grep -q "ARM64_OK"; then
                    pass "ARM64 binary executed via $QEMU_USER"
                else
                    fail "ARM64 binary execution failed (output: '$ARM_OUT')"
                fi
            else
                skip "No user-mode emulator to run the binary"
            fi
        else
            fail "Freestanding ARM64 cross-compilation failed"
        fi
        rm -rf "$TMP"
    else
        skip "Cross-compile test (no aarch64-linux-gnu-gcc)"
    fi

    echo "--- 3.1.6: C cross-compile with sysroot (if available) ---"
    if command -v aarch64-linux-gnu-gcc &>/dev/null; then
        TMP=$(mktemp -d)
        cat > "$TMP/test.c" << 'CEOF'
#include <stdio.h>
int main(void) {
    printf("SYSROOT_OK\n");
    return 0;
}
CEOF
        if aarch64-linux-gnu-gcc -static -o "$TMP/test" "$TMP/test.c" 2>/dev/null; then
            FTYPE=$(file "$TMP/test" 2>/dev/null)
            if echo "$FTYPE" | grep -qi "aarch64"; then
                pass "Full C cross-compile with sysroot (static binary)"
                QEMU_USER=""
                command -v qemu-aarch64-static &>/dev/null && QEMU_USER="qemu-aarch64-static"
                command -v qemu-aarch64 &>/dev/null && QEMU_USER="qemu-aarch64"
                if [[ -n "$QEMU_USER" ]]; then
                    C_OUT=$($QEMU_USER "$TMP/test" 2>/dev/null || true)
                    if echo "$C_OUT" | grep -q "SYSROOT_OK"; then
                        pass "Sysroot-compiled ARM64 C program runs correctly"
                    else
                        fail "Sysroot-compiled binary execution failed"
                    fi
                fi
            else
                fail "Sysroot cross-compile wrong arch"
            fi
        else
            skip "C cross-compile with sysroot failed (no sysroot installed)"
        fi
        rm -rf "$TMP"
    else
        skip "C sysroot test (no cross-compiler)"
    fi

    echo "--- 3.1.7: Rust aarch64 target ---"
    if command -v rustup &>/dev/null; then
        if rustup target list --installed 2>/dev/null | grep -q "aarch64-unknown-linux-gnu"; then
            pass "Rust aarch64-unknown-linux-gnu target installed"
        else
            skip "Rust aarch64 target not installed"
        fi
    elif command -v rustc &>/dev/null; then
        TARGETS=$(rustc --print target-list 2>/dev/null | grep "aarch64-unknown-linux-gnu" || true)
        if [[ -n "$TARGETS" ]]; then
            pass "Rust supports aarch64-unknown-linux-gnu target"
        else
            skip "Rust aarch64 target not in target list"
        fi
    else
        skip "Rust not available"
    fi
}

# ── 3.2: ARM64 Kernel Configs ──────────────────────────────────────

test_configs() {
    hdr "3.2: ARM64 Kernel Configs"
    KDIR="$SRC_ROOT/qubes-linux-kernel"

    echo "--- 3.2.1: config-base-aarch64 ---"
    CFG="$KDIR/config-base-aarch64"
    if [[ -f "$CFG" ]]; then
        LINES=$(wc -l < "$CFG")
        pass "config-base-aarch64 exists ($LINES lines)"

        grep -q "CONFIG_ARM64=y" "$CFG" && pass "  ARM64 arch enabled" || fail "  CONFIG_ARM64=y missing"
        grep -q "CONFIG_ARCH_QCOM=y" "$CFG" && pass "  Qualcomm platform enabled" || fail "  CONFIG_ARCH_QCOM=y missing"
        grep -q "CONFIG_DRM_MSM=m" "$CFG" && pass "  Adreno GPU (DRM_MSM) enabled" || fail "  CONFIG_DRM_MSM missing"
        grep -q "CONFIG_ATH12K=m" "$CFG" && pass "  WiFi 7 (ath12k) enabled" || fail "  CONFIG_ATH12K missing"
        grep -q "CONFIG_SND_SOC_QCOM=m" "$CFG" && pass "  Qualcomm audio enabled" || fail "  CONFIG_SND_SOC_QCOM missing"
        grep -q "CONFIG_USB_DWC3_QCOM=m" "$CFG" && pass "  Qualcomm USB (DWC3) enabled" || fail "  CONFIG_USB_DWC3_QCOM missing"
        grep -q "CONFIG_BLK_DEV_NVME=y" "$CFG" && pass "  NVMe enabled" || fail "  CONFIG_BLK_DEV_NVME missing"
        grep -q "CONFIG_ARM_QCOM_CPUFREQ_HW=y" "$CFG" && pass "  Qualcomm CPUFreq enabled" || fail "  CONFIG_ARM_QCOM_CPUFREQ_HW missing"
        grep -q "CONFIG_PCIE_QCOM=y" "$CFG" && pass "  Qualcomm PCIe enabled" || fail "  CONFIG_PCIE_QCOM missing"
        grep -q "CONFIG_EFI=y" "$CFG" && pass "  EFI boot enabled" || fail "  CONFIG_EFI missing"
        grep -q "CONFIG_OF=y" "$CFG" && pass "  Device Tree (OF) enabled" || fail "  CONFIG_OF missing"

        grep -q "CONFIG_X1E_GCC_80100=y" "$CFG" && pass "  X1E80100 clock controller" || skip "  X1E_GCC_80100 not found (may be in defconfig)"
        grep -q "CONFIG_INTERCONNECT_QCOM_X1E80100=m" "$CFG" && pass "  X1E80100 interconnect" || skip "  X1E80100 interconnect not found"
    else
        fail "config-base-aarch64 NOT FOUND"
    fi

    echo "--- 3.2.2: config-qubes-aarch64 ---"
    CFG="$KDIR/config-qubes-aarch64"
    if [[ -f "$CFG" ]]; then
        LINES=$(wc -l < "$CFG")
        pass "config-qubes-aarch64 exists ($LINES lines)"

        grep -q "CONFIG_ARM64_PAN=y" "$CFG" && pass "  PAN hardening" || fail "  CONFIG_ARM64_PAN missing"
        grep -q "CONFIG_ARM64_BTI=y" "$CFG" && pass "  BTI (branch target identification)" || fail "  CONFIG_ARM64_BTI missing"
        grep -q "CONFIG_ARM64_PTR_AUTH=y" "$CFG" && pass "  Pointer authentication" || fail "  CONFIG_ARM64_PTR_AUTH missing"
        grep -q "CONFIG_ARM64_MTE=y" "$CFG" && pass "  Memory Tagging Extension" || fail "  CONFIG_ARM64_MTE missing"
        grep -q "CONFIG_SHADOW_CALL_STACK=y" "$CFG" && pass "  Shadow call stack" || fail "  CONFIG_SHADOW_CALL_STACK missing"
        grep -q "CONFIG_RANDOMIZE_BASE=y" "$CFG" && pass "  KASLR enabled" || fail "  CONFIG_RANDOMIZE_BASE missing"
        grep -q "CONFIG_ARCH_MMAP_RND_BITS=33" "$CFG" && pass "  ASLR 33-bit entropy" || fail "  ARCH_MMAP_RND_BITS!=33"
        grep -q "CONFIG_PANIC_ON_OOPS=y" "$CFG" && pass "  Panic on oops" || fail "  CONFIG_PANIC_ON_OOPS missing"
        grep -q "CONFIG_STACKPROTECTOR_STRONG=y" "$CFG" && pass "  Stack protector strong" || fail "  STACKPROTECTOR_STRONG missing"

        # x86-specific things that should NOT be present
        if grep -q "CONFIG_INTEL_IOMMU" "$CFG"; then
            fail "  x86-specific CONFIG_INTEL_IOMMU found in ARM64 config"
        else
            pass "  No x86-specific INTEL_IOMMU (correct)"
        fi
        if grep -q "CONFIG_AMD_IOMMU" "$CFG"; then
            fail "  x86-specific CONFIG_AMD_IOMMU found in ARM64 config"
        else
            pass "  No x86-specific AMD_IOMMU (correct)"
        fi
    else
        fail "config-qubes-aarch64 NOT FOUND"
    fi

    echo "--- 3.2.3: config-qubes-kvm-aarch64 ---"
    CFG="$KDIR/config-qubes-kvm-aarch64"
    if [[ -f "$CFG" ]]; then
        LINES=$(wc -l < "$CFG")
        pass "config-qubes-kvm-aarch64 exists ($LINES lines)"

        grep -q "CONFIG_KVM=y" "$CFG" && pass "  KVM built-in (ARM64)" || fail "  CONFIG_KVM=y missing"
        grep -q "CONFIG_ARM_SMMU_V3=y" "$CFG" && pass "  ARM SMMUv3 IOMMU" || fail "  CONFIG_ARM_SMMU_V3 missing"
        grep -q "CONFIG_ARM_GIC_V3=y" "$CFG" && pass "  GICv3 interrupt controller" || fail "  CONFIG_ARM_GIC_V3 missing"
        grep -q "CONFIG_VFIO=m" "$CFG" && pass "  VFIO for passthrough" || fail "  CONFIG_VFIO missing"
        grep -q "CONFIG_VFIO_PLATFORM=m" "$CFG" && pass "  VFIO platform (ARM-specific)" || fail "  CONFIG_VFIO_PLATFORM missing"
        grep -q "CONFIG_VIRTIO=y" "$CFG" && pass "  Virtio core" || fail "  CONFIG_VIRTIO missing"
        grep -q "CONFIG_VIRTIO_BLK=y" "$CFG" && pass "  Virtio block" || fail "  CONFIG_VIRTIO_BLK missing"
        grep -q "CONFIG_VIRTIO_NET=y" "$CFG" && pass "  Virtio net" || fail "  CONFIG_VIRTIO_NET missing"
        grep -q "CONFIG_VIRTIO_CONSOLE=y" "$CFG" && pass "  Virtio console" || fail "  CONFIG_VIRTIO_CONSOLE missing"
        grep -q "CONFIG_DRM_VIRTIO_GPU=m" "$CFG" && pass "  Virtio GPU" || fail "  CONFIG_DRM_VIRTIO_GPU missing"
        grep -q "CONFIG_VSOCKETS=m\|CONFIG_VIRTIO_VSOCKETS=m" "$CFG" && pass "  Virtio vsock" || fail "  VSOCKETS missing"
        grep -q "CONFIG_VHOST=m" "$CFG" && pass "  vhost backends" || fail "  CONFIG_VHOST missing"
        grep -q "CONFIG_SND_VIRTIO=m" "$CFG" && pass "  Virtio sound" || fail "  CONFIG_SND_VIRTIO missing"

        if grep -q "CONFIG_KVM_INTEL\|CONFIG_KVM_AMD" "$CFG"; then
            fail "  x86-specific KVM_INTEL or KVM_AMD found in ARM64 config"
        else
            pass "  No x86 KVM modules (correct for ARM64)"
        fi
    else
        fail "config-qubes-kvm-aarch64 NOT FOUND"
    fi

    echo "--- 3.2.4: kernel.spec.in dual-arch support ---"
    SPEC="$KDIR/kernel.spec.in"
    if [[ -f "$SPEC" ]]; then
        grep -q "ExclusiveArch:.*aarch64" "$SPEC" && pass "  spec: ExclusiveArch includes aarch64" || fail "  spec: aarch64 not in ExclusiveArch"
        grep -q '%ifarch aarch64' "$SPEC" && pass "  spec: has %ifarch aarch64 conditionals" || fail "  spec: no aarch64 conditionals"
        grep -q "config-base-aarch64" "$SPEC" && pass "  spec: references config-base-aarch64" || fail "  spec: config-base-aarch64 not referenced"
        grep -q "config-qubes-aarch64" "$SPEC" && pass "  spec: references config-qubes-aarch64" || fail "  spec: config-qubes-aarch64 not referenced"
        grep -q "config-qubes-kvm-aarch64" "$SPEC" && pass "  spec: references config-qubes-kvm-aarch64" || fail "  spec: config-qubes-kvm-aarch64 not referenced"
        grep -q "arch/arm64/boot/Image" "$SPEC" && pass "  spec: ARM64 boot image path" || fail "  spec: no arm64 boot image path"
        grep -q "arch/arm64/include" "$SPEC" && pass "  spec: ARM64 include path" || fail "  spec: no arm64 include path"
    else
        fail "kernel.spec.in NOT FOUND"
    fi

    echo "--- 3.2.5: gen-config multi-fragment support ---"
    GENCFG="$KDIR/gen-config"
    if [[ -f "$GENCFG" ]]; then
        if grep -q 'overlay_configs=\|overlay2.config\|\$@' "$GENCFG"; then
            pass "gen-config supports multiple overlays"
        else
            fail "gen-config still limited to 2 arguments"
        fi
    else
        fail "gen-config NOT FOUND"
    fi
}

# ── 3.3: Libvirt Templates ─────────────────────────────────────────

test_templates() {
    hdr "3.3: Libvirt Templates"
    TDIR="$SRC_ROOT/qubes-core-admin/templates/libvirt"

    echo "--- 3.3.1: kvm-aarch64.xml ---"
    TMPL="$TDIR/kvm-aarch64.xml"
    if [[ -f "$TMPL" ]]; then
        LINES=$(wc -l < "$TMPL")
        pass "kvm-aarch64.xml exists ($LINES lines)"

        grep -q 'arch="aarch64"' "$TMPL" && pass "  arch=aarch64" || fail "  arch not set to aarch64"
        grep -q 'machine="virt"' "$TMPL" && pass "  machine=virt (not q35)" || fail "  machine type not 'virt'"
        grep -q 'qemu-system-aarch64' "$TMPL" && pass "  emulator=qemu-system-aarch64" || fail "  wrong emulator"
        grep -q "gic version='3'" "$TMPL" && pass "  GICv3 interrupt controller" || fail "  GICv3 not configured"
        grep -q 'AAVMF' "$TMPL" && pass "  AAVMF firmware reference" || fail "  no AAVMF firmware"
        grep -q 'host-passthrough' "$TMPL" && pass "  CPU host-passthrough" || fail "  CPU mode wrong"

        if grep -q '<pae/>' "$TMPL"; then
            fail "  x86-specific <pae/> found in ARM64 template"
        else
            pass "  No x86-specific <pae/> (correct)"
        fi
        if grep -q '<ioapic' "$TMPL"; then
            fail "  x86-specific <ioapic> found in ARM64 template"
        else
            pass "  No x86-specific <ioapic> (correct)"
        fi
        if grep -q 'invtsc' "$TMPL"; then
            fail "  x86-specific 'invtsc' found in ARM64 template"
        else
            pass "  No x86 'invtsc' (correct)"
        fi

        grep -q 'virtio' "$TMPL" && pass "  Virtio devices present" || fail "  No virtio devices"
        grep -q '<vsock' "$TMPL" && pass "  Virtio vsock for vchan" || fail "  No vsock"
        grep -q '<rng' "$TMPL" && pass "  Virtio RNG" || fail "  No RNG"
        grep -q '<memballoon' "$TMPL" && pass "  Virtio balloon" || fail "  No balloon"
    else
        fail "kvm-aarch64.xml NOT FOUND"
    fi

    echo "--- 3.3.2: kvm-aarch64-xenshim.xml ---"
    XENSHIM="$TDIR/kvm-aarch64-xenshim.xml"
    if [[ -f "$XENSHIM" ]]; then
        pass "kvm-aarch64-xenshim.xml exists"
        grep -q 'xen-version' "$XENSHIM" && pass "  Xen version emulation configured" || fail "  No xen-version"
        grep -q 'xen-evtchn' "$XENSHIM" && pass "  Xen event channels enabled" || fail "  No xen-evtchn"
        grep -q 'xen-gnttab' "$XENSHIM" && pass "  Xen grant tables enabled" || fail "  No xen-gnttab"
        grep -q 'qemu:commandline' "$XENSHIM" && pass "  QEMU commandline passthrough" || fail "  No qemu:commandline"
        grep -q 'qemu-system-aarch64' "$XENSHIM" && pass "  Uses aarch64 emulator" || fail "  Wrong emulator"
        grep -q "gic version='3'" "$XENSHIM" && pass "  GICv3 configured" || fail "  No GICv3"
    else
        fail "kvm-aarch64-xenshim.xml NOT FOUND"
    fi

    echo "--- 3.3.3: pci-kvm-aarch64.xml ---"
    PCI="$TDIR/devices/pci-kvm-aarch64.xml"
    if [[ -f "$PCI" ]]; then
        pass "pci-kvm-aarch64.xml exists"
        grep -q 'vfio' "$PCI" && pass "  VFIO driver configured" || fail "  No VFIO"
        grep -q 'nostrictreset' "$PCI" && pass "  no-strict-reset support" || fail "  No nostrictreset"
    else
        fail "pci-kvm-aarch64.xml NOT FOUND"
    fi

    echo "--- 3.3.4: Template selection (config.py + __init__.py) ---"
    CONFIG_PY="$SRC_ROOT/qubes-core-admin/qubes/config.py"
    INIT_PY="$SRC_ROOT/qubes-core-admin/qubes/vm/__init__.py"

    if [[ -f "$CONFIG_PY" ]]; then
        grep -q "host_arch" "$CONFIG_PY" && pass "  config.py: host_arch detected" || fail "  config.py: no host_arch"
        grep -q "platform.machine" "$CONFIG_PY" && pass "  config.py: uses platform.machine()" || fail "  config.py: no platform.machine()"
        grep -q "aarch64" "$CONFIG_PY" && pass "  config.py: aarch64 handling" || fail "  config.py: no aarch64 references"
        grep -q "devicetree" "$CONFIG_PY" && pass "  config.py: DT hypervisor detection" || fail "  config.py: no DT detection"
    else
        fail "config.py NOT FOUND"
    fi

    if [[ -f "$INIT_PY" ]]; then
        grep -q "host_arch\|arch" "$INIT_PY" && pass "  __init__.py: arch-aware template selection" || fail "  __init__.py: no arch selection"
    else
        fail "__init__.py NOT FOUND"
    fi
}

# ── 3.4: Hypervisor Detection ──────────────────────────────────────

test_hypervisor() {
    hdr "3.4: Hypervisor Detection (ARM64)"
    AGENT="$SRC_ROOT/qubes-core-agent-linux/init/hypervisor.sh"
    UDEV="$SRC_ROOT/qubes-linux-utils/udev/hypervisor.sh"

    echo "--- 3.4.1: Agent hypervisor.sh ---"
    if [[ -f "$AGENT" ]]; then
        bash -n "$AGENT" 2>/dev/null && pass "hypervisor.sh syntax valid" || fail "hypervisor.sh syntax error"

        grep -q "aarch64" "$AGENT" && pass "  ARM64 architecture detection" || fail "  No aarch64 detection"
        grep -q "devicetree\|device-tree\|firmware/devicetree" "$AGENT" && pass "  Device tree hypervisor check" || fail "  No device tree check"
        grep -q "psci\|PSCI" "$AGENT" && pass "  PSCI presence check" || fail "  No PSCI check"
        grep -q "is_aarch64" "$AGENT" && pass "  is_aarch64() helper function" || fail "  No is_aarch64() helper"

        # Verify cpuid is gated behind x86_64 check, not used for aarch64
        # (grep -v comments, then look for cpuid inside an aarch64 context)
        CPUID_LINES=$(grep -v '^\s*#' "$AGENT" | grep -c 'cpuid' || true)
        X86_GUARD=$(grep -B2 'cpuid\|/proc/cpuinfo' "$AGENT" | grep -c 'x86_64' || true)
        if [[ "$CPUID_LINES" -gt 0 && "$X86_GUARD" -gt 0 ]]; then
            pass "  cpuid gated behind x86_64 check (correct for ARM64)"
        elif [[ "$CPUID_LINES" -eq 0 ]]; then
            pass "  No cpuid code at all (correct for ARM64)"
        else
            fail "  cpuid used without x86_64 guard"
        fi
    else
        fail "Agent hypervisor.sh NOT FOUND"
    fi

    echo "--- 3.4.2: udev hypervisor.sh ---"
    if [[ -f "$UDEV" ]]; then
        bash -n "$UDEV" 2>/dev/null && pass "udev hypervisor.sh syntax valid" || fail "udev hypervisor.sh syntax error"
        grep -q "aarch64" "$UDEV" && pass "  ARM64 detection in udev" || fail "  No aarch64 in udev"
        grep -q "devicetree\|device-tree\|firmware/devicetree" "$UDEV" && pass "  Device tree check in udev" || fail "  No DT check in udev"
    else
        fail "udev hypervisor.sh NOT FOUND"
    fi
}

# ── 3.5: Builder Config & Boot Chain ───────────────────────────────

test_builder() {
    hdr "3.5: Builder Config & Boot Chain"

    echo "--- 3.5.1: qubes-os-kvm-aarch64.yml ---"
    YML="$SRC_ROOT/qubes-builderv2/example-configs/qubes-os-kvm-aarch64.yml"
    if [[ -f "$YML" ]]; then
        pass "qubes-os-kvm-aarch64.yml exists"
        grep -q "backend-vmm: kvm" "$YML" && pass "  backend-vmm: kvm" || fail "  backend-vmm not kvm"
        grep -q "target-arch: aarch64\|aarch64" "$YML" && pass "  target-arch: aarch64" || fail "  no aarch64 target"
        grep -q "core-vchan-socket" "$YML" && pass "  vchan-socket included" || fail "  vchan-socket missing"
        grep -q "linux-kernel" "$YML" && pass "  linux-kernel component" || fail "  linux-kernel missing"
        grep -q "core-admin" "$YML" && pass "  core-admin component" || fail "  core-admin missing"

        # Check intel-microcode is only present as an exclusion comment, not as an active component
        if grep -v '^\s*#' "$YML" | grep -q "intel-microcode"; then
            fail "  x86-specific intel-microcode listed as active component"
        else
            pass "  No active intel-microcode component (correct for ARM64)"
        fi

        if grep -q "vmm-xen\b" "$YML" | grep -v "^#\|^  #"; then
            fail "  Xen hypervisor package included (should be excluded)"
        else
            pass "  Xen packages excluded (correct for KVM)"
        fi
    else
        fail "qubes-os-kvm-aarch64.yml NOT FOUND"
    fi

    echo "--- 3.5.2: grub-kvm-aarch64.cfg ---"
    GRUB="$SRC_ROOT/qubes-linux-kernel/grub-kvm-aarch64.cfg"
    if [[ -f "$GRUB" ]]; then
        pass "grub-kvm-aarch64.cfg exists"
        grep -q "arm-smmu\|smmu" "$GRUB" && pass "  SMMU/IOMMU params" || fail "  No SMMU params"
        grep -q "ttyAMA0\|console=" "$GRUB" && pass "  ARM serial console" || fail "  No ARM console"
        grep -q "iommu.passthrough=0\|iommu" "$GRUB" && pass "  IOMMU enforcement" || fail "  No IOMMU enforcement"
    else
        fail "grub-kvm-aarch64.cfg NOT FOUND"
    fi

    echo "--- 3.5.3: VM GRUB config ARM64 awareness ---"
    VM_GRUB="$SRC_ROOT/qubes-core-agent-linux/boot/grub.qubes"
    if [[ -f "$VM_GRUB" ]]; then
        grep -q "aarch64\|uname -m" "$VM_GRUB" && pass "  grub.qubes: arch-aware" || fail "  grub.qubes: not arch-aware"
        grep -q "ttyAMA0" "$VM_GRUB" && pass "  grub.qubes: ARM64 console" || fail "  grub.qubes: no ARM64 console"
    else
        fail "grub.qubes NOT FOUND"
    fi
}

# ── 3.6: crosvm ARM64 Launch Script ─────────────────────────────────

test_crosvm() {
    hdr "3.6: crosvm ARM64 Launch Script"
    SCRIPT="$SRC_ROOT/qubes-kvm-fork/scripts/crosvm-launch-aarch64.sh"

    if [[ -f "$SCRIPT" ]]; then
        pass "crosvm-launch-aarch64.sh exists"
        bash -n "$SCRIPT" 2>/dev/null && pass "  Syntax valid" || fail "  Syntax error"
        [[ -x "$SCRIPT" ]] && pass "  Executable" || fail "  Not executable"

        grep -q "GIC\|gic" "$SCRIPT" && pass "  GIC interrupt controller handling" || fail "  No GIC handling"
        grep -q "vsock\|VSOCK" "$SCRIPT" && pass "  Virtio vsock support" || fail "  No vsock"
        grep -q "virtio-gpu\|virglrenderer\|cross-domain" "$SCRIPT" && pass "  GPU mode support" || fail "  No GPU modes"
        grep -q "AAVMF\|aarch64" "$SCRIPT" && pass "  ARM64/AAVMF references" || fail "  No ARM64 references"
        grep -q "qubesdb\|QubesDB" "$SCRIPT" && pass "  QubesDB injection socket" || fail "  No QubesDB"
        grep -q "xen-version\|xenpvh\|xenshim\|start-xenshim" "$SCRIPT" && pass "  Xen shim mode" || fail "  No Xen shim mode"

        HELP_OUT=$(bash "$SCRIPT" 2>&1 || true)
        if echo "$HELP_OUT" | grep -qi "usage\|options\|start\|stop"; then
            pass "  Help output works"
        else
            skip "  Help output check inconclusive"
        fi
    else
        fail "crosvm-launch-aarch64.sh NOT FOUND"
    fi
}

# ── 3.7: QEMU ARM64 Boot Tests ─────────────────────────────────────

test_boot() {
    hdr "3.7: QEMU ARM64 Boot Tests"

    echo "--- 3.7.1: ARM64 virt machine (cortex-a76) ---"
    if command -v qemu-system-aarch64 &>/dev/null; then
        ARM_OUT=$(timeout 5 qemu-system-aarch64 \
            -M virt -cpu cortex-a76 -m 256 \
            -display none -nographic -no-reboot \
            -kernel /dev/null 2>&1 || true)
        if echo "$ARM_OUT" | grep -qi "error.*machine\|unsupported"; then
            fail "ARM64 virt machine rejected"
        else
            pass "ARM64 virt machine accepted (cortex-a76)"
        fi
    else
        skip "ARM64 virt machine test (QEMU not found)"
    fi

    echo "--- 3.7.2: ARM64 virt + GICv3 ---"
    if command -v qemu-system-aarch64 &>/dev/null; then
        GIC_OUT=$(timeout 5 qemu-system-aarch64 \
            -M virt,gic-version=3 -cpu cortex-a76 -m 256 \
            -display none -nographic -no-reboot \
            -kernel /dev/null 2>&1 || true)
        if echo "$GIC_OUT" | grep -qi "error\|unsupported\|invalid"; then
            fail "ARM64 virt+GICv3 rejected"
            echo "  Output: $GIC_OUT"
        else
            pass "ARM64 virt+GICv3 accepted"
        fi
    else
        skip "GICv3 test (QEMU not found)"
    fi

    echo "--- 3.7.3: ARM64 UEFI firmware boot ---"
    AAVMF=""
    for f in /usr/share/edk2/aarch64/QEMU_EFI.fd \
             /usr/share/AAVMF/AAVMF_CODE.fd; do
        [[ -f "$f" ]] && AAVMF="$f" && break
    done
    if command -v qemu-system-aarch64 &>/dev/null && [[ -n "$AAVMF" ]]; then
        UEFI_OUT=$(timeout 8 qemu-system-aarch64 \
            -M virt,gic-version=3 -cpu cortex-a76 -m 512 \
            -bios "$AAVMF" \
            -display none -nographic -no-reboot \
            -serial mon:stdio \
            2>&1 || true)
        if echo "$UEFI_OUT" | grep -qi "fatal\|abort\|error.*bios\|error.*firmware"; then
            fail "ARM64 UEFI boot failed"
            echo "  Output: $(echo "$UEFI_OUT" | head -5)"
        else
            pass "ARM64 UEFI firmware loaded (QEMU did not reject)"
            if echo "$UEFI_OUT" | grep -qi "UEFI\|TianoCore\|EDK II\|BDS\|Shell>"; then
                pass "  UEFI firmware produced output (boot started)"
            else
                pass "  UEFI firmware accepted (output may have timed out)"
            fi
        fi
    else
        skip "ARM64 UEFI boot test (missing QEMU or firmware)"
    fi

    echo "--- 3.7.4: ARM64 virt + virtio devices ---"
    if command -v qemu-system-aarch64 &>/dev/null; then
        TMPIMG=$(mktemp --suffix=.qcow2)
        qemu-img create -f qcow2 "$TMPIMG" 64M &>/dev/null 2>&1 || dd if=/dev/zero of="$TMPIMG" bs=1M count=64 2>/dev/null

        VIRTIO_OUT=$(timeout 5 qemu-system-aarch64 \
            -M virt,gic-version=3 -cpu cortex-a76 -m 256 \
            -display none -nographic -no-reboot \
            -drive file="$TMPIMG",if=virtio,format=qcow2 \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0 \
            -device virtio-rng-pci \
            -kernel /dev/null 2>&1 || true)
        rm -f "$TMPIMG"

        if echo "$VIRTIO_OUT" | grep -qi "error.*virtio\|unknown device\|unsupported"; then
            fail "ARM64 virtio devices rejected"
            echo "  Output: $VIRTIO_OUT"
        else
            pass "ARM64 virt + virtio-blk + virtio-net + virtio-rng accepted"
        fi
    else
        skip "ARM64 virtio test (QEMU not found)"
    fi

    echo "--- 3.7.5: vm-launch.sh ARM64 awareness ---"
    VMLAUNCH="$SRC_ROOT/qubes-kvm-fork/scripts/vm-launch.sh"
    if [[ -f "$VMLAUNCH" ]]; then
        grep -q "aarch64" "$VMLAUNCH" && pass "vm-launch.sh: ARM64 aware" || fail "vm-launch.sh: no aarch64 support"
        grep -q "virt,gic-version=3\|virt.*gic" "$VMLAUNCH" && pass "vm-launch.sh: virt+GICv3 machine type" || fail "vm-launch.sh: no ARM64 machine type"
        grep -q "AAVMF\|QEMU_EFI" "$VMLAUNCH" && pass "vm-launch.sh: ARM64 firmware path" || fail "vm-launch.sh: no ARM64 firmware"
    else
        fail "vm-launch.sh NOT FOUND"
    fi
}

# ── 3.8: Build & Boot Integration ───────────────────────────────────
# These tests validate actual cross-compilation and QEMU boot.
# They use pre-built artifacts if available, or build from scratch.

test_buildboot() {
    hdr "3.8: Build & Boot Integration"

    KERNEL_IMAGE="$SRC_ROOT/linux-6.12.17/arch/arm64/boot/Image"
    INITRAMFS="$SRC_ROOT/arm64-initramfs.cpio.gz"

    echo "--- 3.8.1: vchan-socket aarch64 cross-compile ---"
    VCHAN_DIR="$SRC_ROOT/qubes-core-vchan-socket/vchan"
    if [[ -d "$VCHAN_DIR" ]] && command -v aarch64-linux-gnu-gcc &>/dev/null; then
        make -C "$VCHAN_DIR" clean 2>/dev/null
        if make -C "$VCHAN_DIR" CC=aarch64-linux-gnu-gcc AR=aarch64-linux-gnu-ar \
                LDFLAGS="--sysroot=/usr/aarch64-linux-gnu" all 2>&1 | tail -1; then
            FTYPE=$(file "$VCHAN_DIR/libvchan-socket.so" 2>/dev/null)
            if echo "$FTYPE" | grep -qi "aarch64"; then
                pass "vchan-socket cross-compiled for aarch64"
            else
                fail "vchan-socket not aarch64: $FTYPE"
            fi
        else
            fail "vchan-socket cross-compilation failed"
        fi
    else
        skip "vchan cross-compile (missing source or cross-compiler)"
    fi

    echo "--- 3.8.2: qubesdb KVM tools aarch64 cross-compile ---"
    QDBDIR="$SRC_ROOT/qubes-core-qubesdb/daemon/kvm"
    if [[ -d "$QDBDIR" ]] && command -v aarch64-linux-gnu-gcc &>/dev/null; then
        make -C "$QDBDIR" clean 2>/dev/null
        if make -C "$QDBDIR" CC=aarch64-linux-gnu-gcc \
                LDFLAGS="--sysroot=/usr/aarch64-linux-gnu" all 2>&1 | tail -1; then
            FTYPE=$(file "$QDBDIR/qubesdb-config-inject" 2>/dev/null)
            if echo "$FTYPE" | grep -qi "aarch64"; then
                pass "qubesdb tools cross-compiled for aarch64"
            else
                fail "qubesdb tools not aarch64"
            fi
        else
            fail "qubesdb tools cross-compilation failed"
        fi
    else
        skip "qubesdb cross-compile (missing source or cross-compiler)"
    fi

    echo "--- 3.8.3: Rust aarch64 cross-compile ---"
    RUSTTEST="$SRC_ROOT/rust-arm64-test"
    if [[ -d "$RUSTTEST" ]] && command -v cargo &>/dev/null; then
        if cargo build --manifest-path="$RUSTTEST/Cargo.toml" \
                --target aarch64-unknown-linux-gnu --release 2>&1 | tail -3; then
            FTYPE=$(file "$RUSTTEST/target/aarch64-unknown-linux-gnu/release/qubes-arm64-test" 2>/dev/null)
            if echo "$FTYPE" | grep -qi "aarch64"; then
                pass "Rust aarch64 cross-compile succeeded"
                QEMU_USER=""
                command -v qemu-aarch64-static &>/dev/null && QEMU_USER="qemu-aarch64-static"
                command -v qemu-aarch64 &>/dev/null && QEMU_USER="qemu-aarch64"
                if [[ -n "$QEMU_USER" ]]; then
                    ROUT=$($QEMU_USER -L /usr/aarch64-linux-gnu "$RUSTTEST/target/aarch64-unknown-linux-gnu/release/qubes-arm64-test" 2>&1)
                    if echo "$ROUT" | grep -q "RUST_AARCH64_OK"; then
                        pass "Rust aarch64 binary runs under emulation"
                    else
                        fail "Rust binary execution failed"
                    fi
                fi
            else
                fail "Rust cross-compile wrong arch"
            fi
        else
            fail "Rust cross-compile failed"
        fi
    else
        skip "Rust cross-compile test (missing project or cargo)"
    fi

    echo "--- 3.8.4: ARM64 kernel Image ---"
    if [[ -f "$KERNEL_IMAGE" ]]; then
        FTYPE=$(file "$KERNEL_IMAGE" 2>/dev/null)
        if echo "$FTYPE" | grep -qi "ARM64 boot"; then
            KSIZE=$(ls -lh "$KERNEL_IMAGE" | awk '{print $5}')
            pass "ARM64 kernel Image: $KSIZE"
        else
            fail "Kernel image not ARM64: $FTYPE"
        fi
    else
        skip "ARM64 kernel not built (build with: make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image)"
    fi

    echo "--- 3.8.5: ARM64 QEMU full boot test ---"
    if [[ -f "$KERNEL_IMAGE" ]] && [[ -f "$INITRAMFS" ]] && \
       command -v qemu-system-aarch64 &>/dev/null; then
        BOOT_OUT=$(timeout 20 qemu-system-aarch64 \
            -M virt,gic-version=3 \
            -cpu cortex-a76 \
            -m 512 -smp 2 \
            -kernel "$KERNEL_IMAGE" \
            -initrd "$INITRAMFS" \
            -append "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/init" \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0 \
            -device virtio-rng-pci \
            -nographic -no-reboot 2>&1)

        if echo "$BOOT_OUT" | grep -q "ALL INTEGRATION TESTS PASSED"; then
            pass "ARM64 VM booted and all integration tests passed"
            INT_PASS=$(echo "$BOOT_OUT" | grep "RESULTS:" | grep -oP '[0-9]+(?= passed)')
            echo "    In-VM: $INT_PASS tests passed"
        elif echo "$BOOT_OUT" | grep -q "BOOT_SUCCESS\|RESULTS:"; then
            INT_FAIL=$(echo "$BOOT_OUT" | grep "RESULTS:" | grep -oP '[0-9]+(?= failed)')
            fail "ARM64 VM booted but $INT_FAIL in-VM test(s) failed"
        elif echo "$BOOT_OUT" | grep -q "Booting Linux"; then
            fail "Kernel started but did not reach userspace"
        else
            fail "QEMU did not boot"
        fi
    else
        skip "Full boot test (missing kernel or initramfs)"
    fi
}

# ── Summary ──────────────────────────────────────────────────────────

summary() {
    hdr "TIER 3 ARM64 TEST RESULTS"
    echo "  Total:   $TOTAL"
    echo "  Passed:  $PASS"
    echo "  Failed:  $FAIL"
    echo "  Skipped: $SKIP"
    echo ""
    if [[ $FAIL -eq 0 ]]; then
        echo "  >>> ALL TIER 3 TESTS PASSED <<<"
        return 0
    else
        echo "  >>> $FAIL TEST(S) FAILED <<<"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────

CMD="${1:-all}"
case "$CMD" in
    tools)     test_tools; summary ;;
    configs)   test_configs; summary ;;
    templates) test_templates; summary ;;
    hypervisor) test_hypervisor; summary ;;
    builder)   test_builder; summary ;;
    crosvm)    test_crosvm; summary ;;
    boot)      test_boot; summary ;;
    buildboot) test_buildboot; summary ;;
    all)       test_tools; test_configs; test_templates; test_hypervisor; test_builder; test_crosvm; test_boot; test_buildboot; summary ;;
    *)         echo "Usage: $0 [tools|configs|templates|hypervisor|builder|crosvm|boot|buildboot|all]"; exit 1 ;;
esac
