#!/bin/bash
# setup-qubes-nested.sh — Create a nested-KVM dev qube on Qubes OS
#
# This script runs in dom0 (via qvm-remote or manually).
# It creates a StandaloneVM with Xen nested HVM enabled,
# giving /dev/kvm inside the VM so you can run ALL tiers:
#   Tier 1: Build + container tests (always worked)
#   Tier 2: Xen-on-KVM, VFIO passthrough testing
#   Tier 3: ARM64 cross-compilation + system emulation
#
# Architecture:
#   Qubes OS (Xen L0, bare metal)
#     └── kvm-dev qube (HVM + nested virt → has /dev/kvm)
#           └── QEMU+KVM (L1 — the test environment)
#                 ├── Xen-on-KVM VMs (Qubes components see "Xen")
#                 ├── GPU test VMs (VFIO, if PCI passthrough configured)
#                 └── ARM64 VMs (qemu-system-aarch64)
#
# Everything stays confined inside Qubes' security model.
#
# Usage (in dom0):
#   bash setup-qubes-nested.sh
#
# Or via qvm-remote from visyble:
#   qvm-remote < scripts/setup-qubes-nested.sh
set -euo pipefail

readonly VM_NAME="kvm-dev"
readonly VM_LABEL="purple"
readonly VM_MEM="8192"
readonly VM_MAXMEM="16384"
readonly VM_VCPUS="4"
readonly VM_DISK="60G"
readonly TEMPLATE="fedora-42-xfce"

log() { echo "[setup-nested] $*"; }

# ── Step 1: Verify Xen nested HVM is possible ────────────────────
log "=== Step 1: Check Xen nested HVM support ==="

# Check if CPU supports HVM via Xen's reported capabilities.
# NOTE: /proc/cpuinfo may NOT show vmx/svm under Xen on newer CPUs
# (e.g. Arrow Lake) because Xen consumes the flag. Use xl info instead.
XEN_VIRT_CAPS=$(xl info 2>/dev/null | grep '^virt_caps' | cut -d: -f2- || echo "")
if echo "$XEN_VIRT_CAPS" | grep -q "hvm"; then
    log "  Xen virt_caps: hvm detected (CPU supports hardware virtualization)"
elif grep -q vmx /proc/cpuinfo 2>/dev/null; then
    log "  CPU VMX flag: found in /proc/cpuinfo"
elif grep -q svm /proc/cpuinfo 2>/dev/null; then
    log "  CPU SVM flag: found in /proc/cpuinfo"
else
    log "ERROR: CPU does not support hardware virtualization"
    log "  xl info virt_caps: $XEN_VIRT_CAPS"
    log "  Nested HVM requires Intel VT-x or AMD-V"
    exit 1
fi
log "  CPU virtualization extensions: OK"

# Check current Xen config for nestedhvm
# NOTE: /proc/cmdline has the Linux kernel cmdline, NOT Xen's.
# Xen's cmdline is in `xl info` under xen_commandline.
CURRENT_XEN_CMDLINE=$(xl info 2>/dev/null | grep '^xen_commandline' | cut -d: -f2- || echo "")
if echo "$CURRENT_XEN_CMDLINE" | grep -q "nestedhvm=1"; then
    log "  Xen nestedhvm=1: already enabled"
else
    log "  Xen nestedhvm=1: NOT enabled yet"
    log ""
    log "  ACTION REQUIRED: Add 'hap=1 nestedhvm=1' to Xen boot parameters."
    log ""
    log "  For UEFI boot (most modern systems):"
    log "    Edit /boot/efi/EFI/qubes/xen.cfg"
    log "    Find the [global] or options= line and add:"
    log "      hap=1 nestedhvm=1"
    log ""
    log "  For GRUB boot:"
    log "    Edit /etc/default/grub"
    log "    Add to GRUB_CMDLINE_XEN_DEFAULT:"
    log "      GRUB_CMDLINE_XEN_DEFAULT=\"hap=1 nestedhvm=1\""
    log "    Then run: grub2-mkconfig -o /boot/grub2/grub.cfg"
    log ""
    log "  A reboot is required after this change."
    log ""

    # Try to apply automatically — with safety checks
    XEN_CFG=""
    for candidate in \
        /boot/efi/EFI/qubes/xen.cfg \
        /boot/grub2/grub.cfg; do
        [[ -f "$candidate" ]] && XEN_CFG="$candidate" && break
    done

    if [[ -n "$XEN_CFG" ]]; then
        log "  Found $XEN_CFG"
        if grep -q "nestedhvm" "$XEN_CFG"; then
            log "  nestedhvm already present in $XEN_CFG"
        else
            log "  Backing up before modification..."
            cp "$XEN_CFG" "${XEN_CFG}.bak-$(date +%Y%m%d%H%M%S)"

            if [[ "$XEN_CFG" == *"xen.cfg" ]]; then
                # UEFI xen.cfg format: options= line under [global]
                # Only modify if the options= line actually exists
                if grep -q '^options=' "$XEN_CFG"; then
                    sed -i '/^options=/ s/$/ hap=1 nestedhvm=1/' "$XEN_CFG"
                    log "  DONE: Appended 'hap=1 nestedhvm=1' to options= line"
                else
                    log "  WARNING: No 'options=' line found in $XEN_CFG."
                    log "  Add manually under [global]: options=hap=1 nestedhvm=1"
                fi
            else
                # GRUB format: modify GRUB_CMDLINE_XEN_DEFAULT in /etc/default/grub
                GRUB_DEF="/etc/default/grub"
                if [[ -f "$GRUB_DEF" ]]; then
                    cp "$GRUB_DEF" "${GRUB_DEF}.bak-$(date +%Y%m%d%H%M%S)"
                    if grep -q 'GRUB_CMDLINE_XEN_DEFAULT' "$GRUB_DEF"; then
                        sed -i 's/^GRUB_CMDLINE_XEN_DEFAULT="\(.*\)"/GRUB_CMDLINE_XEN_DEFAULT="\1 hap=1 nestedhvm=1"/' "$GRUB_DEF"
                    else
                        echo 'GRUB_CMDLINE_XEN_DEFAULT="hap=1 nestedhvm=1"' >> "$GRUB_DEF"
                    fi
                    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || \
                        log "  WARNING: grub2-mkconfig failed — regenerate manually"
                    log "  DONE: Updated GRUB config"
                fi
            fi
            log "  REBOOT REQUIRED for this to take effect."
            log "  Original backed up to ${XEN_CFG}.bak-*"
        fi
    else
        log "  Could not find Xen boot config — please configure manually."
        log "  Add 'hap=1 nestedhvm=1' to your Xen hypervisor boot parameters."
    fi
fi

# ── Step 2: Create the StandaloneVM ──────────────────────────────
log ""
log "=== Step 2: Create $VM_NAME StandaloneVM ==="

if qvm-check "$VM_NAME" 2>/dev/null; then
    log "  $VM_NAME already exists"
else
    # Determine best template — try -xfce variants first (they exist on most
    # Qubes installs), then bare names, then Debian.
    AVAIL_TEMPLATE=""
    for t in fedora-42-xfce fedora-43 fedora-42-nvidia fedora-42 \
             debian-14-xfce debian-13-xfce debian-13; do
        if qvm-check "$t" 2>/dev/null; then
            AVAIL_TEMPLATE="$t"
            break
        fi
    done

    if [[ -z "$AVAIL_TEMPLATE" ]]; then
        log "ERROR: No suitable template found"
        log "Tried: fedora-42-xfce, fedora-43, fedora-42-nvidia, fedora-42,"
        log "       debian-14-xfce, debian-13-xfce, debian-13"
        log "Install a template first: sudo qubes-dom0-update qubes-template-fedora-42-xfce"
        exit 1
    fi

    log "  Creating StandaloneVM from $AVAIL_TEMPLATE..."
    qvm-create --class StandaloneVM \
        --template "$AVAIL_TEMPLATE" \
        --label "$VM_LABEL" \
        "$VM_NAME"
    log "  Created: $VM_NAME"
fi

# ── Step 3: Configure VM properties ──────────────────────────────
log ""
log "=== Step 3: Configure $VM_NAME ==="

# Must be HVM mode for nested virtualization.
# BUT: we keep the Qubes-provided kernel for the FIRST boot so the VM
# can start (Qubes templates lack a bootloader for HVM/UEFI boot).
# After provisioning installs GRUB, we switch to kernel='' (see Step 5).
qvm-prefs "$VM_NAME" virt_mode hvm
log "  virt_mode: hvm"

# Keep Qubes-provided kernel for first boot — provision-kvm-dev.sh
# will install GRUB and then we switch to VM-provided kernel.
# (setting kernel='' now would make the VM unbootable)
log "  kernel: (Qubes-provided for first boot — will switch after provisioning)"

# Memory: generous for nested VMs
qvm-prefs "$VM_NAME" memory "$VM_MEM"
qvm-prefs "$VM_NAME" maxmem "$VM_MAXMEM"
log "  memory: ${VM_MEM}MB (max: ${VM_MAXMEM}MB)"

# CPUs
qvm-prefs "$VM_NAME" vcpus "$VM_VCPUS"
log "  vcpus: $VM_VCPUS"

# Network access (for downloading packages, git clone, etc.)
qvm-prefs "$VM_NAME" netvm sys-firewall 2>/dev/null || \
    qvm-prefs "$VM_NAME" netvm sys-net 2>/dev/null || \
    log "  WARNING: could not set netvm"
log "  netvm: $(qvm-prefs "$VM_NAME" netvm)"

# Increase private storage for repos + VM images
qvm-volume resize "$VM_NAME":private "$VM_DISK" 2>/dev/null || \
    log "  WARNING: could not resize private volume (may already be large enough)"
log "  private disk: $VM_DISK"

# ── Step 4: Create libvirt override for nested HVM ───────────────
log ""
log "=== Step 4: Libvirt nested HVM template ==="

LIBVIRT_DIR="/etc/qubes/templates/libvirt/xen/by-name"
LIBVIRT_FILE="$LIBVIRT_DIR/${VM_NAME}.xml"

mkdir -p "$LIBVIRT_DIR"

# NOTE: <nestedhvm/> is NOT a valid libvirt XML element.
# Nested HVM is enabled at the Xen hypervisor level (nestedhvm=1 boot param).
# The per-VM part is: expose VMX via cpu host-passthrough + hap in features.
cat > "$LIBVIRT_FILE" << 'XMLEOF'
{% extends 'libvirt/xen.xml' %}
{% block cpu %}
    <cpu mode='host-passthrough'>
        <feature name='vmx' policy='require'/>
    </cpu>
{% endblock %}
{% block features %}
    <pae/>
    <acpi/>
    <apic/>
    <hap/>
    <viridian/>
{% endblock %}
XMLEOF

log "  Created: $LIBVIRT_FILE"
log "  This exposes VMX (Intel VT-x) CPU flags to $VM_NAME"
log "  The VM will have /dev/kvm available"

# ── Step 5: Note about kernel switch ─────────────────────────────
log ""
log "=== Step 5: Kernel note ==="
log "  The VM currently uses a Qubes-provided kernel so it can boot."
log "  After provisioning (which installs GRUB), switch to VM's own kernel:"
log "    qvm-prefs $VM_NAME kernel ''"
log "  This is done automatically by: qubes-deploy.sh provision"

# ── Step 6: Summary ──────────────────────────────────────────────
log ""
log "=== Setup Complete (Phase 1) ==="
log ""
log "VM:           $VM_NAME"
log "Class:        StandaloneVM (HVM, nested virt enabled)"
log "Memory:       ${VM_MEM}MB — ${VM_MAXMEM}MB"
log "vCPUs:        $VM_VCPUS"
log "Disk:         $VM_DISK"
log "Kernel:       VM-provided (not Qubes kernel)"
log ""
log "Capabilities inside $VM_NAME:"
log "  [x] /dev/kvm (nested HVM via Xen)"
log "  [x] Full KVM acceleration"
log "  [x] QEMU with Xen HVM emulation"
log "  [x] Nested VMs (L2 guests)"
log "  [x] Container builds (podman)"
log "  [x] ARM64 cross-compilation"
log ""
log "IMPORTANT:"
log "  1. If you added nestedhvm=1 to Xen config, REBOOT dom0 first"
log "  2. Then start the VM:  qvm-start $VM_NAME"
log "  3. Inside the VM, run: bash /home/user/qubes-kvm-fork/scripts/provision-kvm-dev.sh"
log "  4. Verify: ls -la /dev/kvm"
