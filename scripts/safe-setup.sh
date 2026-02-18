#!/bin/bash
# safe-setup.sh — Safe, incremental dev environment setup via qvm-remote
#
# Runs from the visyble AppVM. Executes each phase of the kvm-dev setup
# through qvm-remote with:
#   - Backups before every destructive change
#   - Read-only verification after every step
#   - Confirmation prompts before modifying dom0
#   - Dry-run mode to preview what would happen
#   - Rollback instructions at every checkpoint
#
# Usage:
#   bash scripts/safe-setup.sh              # Interactive, full run
#   bash scripts/safe-setup.sh --dry-run    # Preview only, no changes
#   bash scripts/safe-setup.sh phase1       # Run a single phase
#   bash scripts/safe-setup.sh phase2       # (phases: phase1..phase5)
#   bash scripts/safe-setup.sh status       # Read-only system check
set -euo pipefail

readonly PROGNAME="safe-setup"
readonly VM_NAME="kvm-dev"
readonly VM_LABEL="purple"
readonly VM_MEM="8192"
readonly VM_MAXMEM="16384"
readonly VM_VCPUS="6"
readonly VM_DISK="60G"
readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

# ── Helpers ────────────────────────────────────────────────────────

log()  { echo "[$PROGNAME] $*"; }
info() { echo "[$PROGNAME]   $*"; }
warn() { echo "[$PROGNAME] WARNING: $*"; }
err()  { echo "[$PROGNAME] ERROR: $*" >&2; }
sep()  { echo ""; echo "────────────────────────────────────────────────────"; }

confirm() {
    if $DRY_RUN; then
        log "[DRY-RUN] Would ask: $1"
        return 0
    fi
    echo ""
    read -r -p "[$PROGNAME] $1 [y/N] " answer
    case "$answer" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) log "Skipped."; return 1 ;;
    esac
}

dom0() {
    if $DRY_RUN; then
        log "[DRY-RUN] dom0> $*"
        return 0
    fi
    qvm-remote "$@"
}

dom0_read() {
    qvm-remote "$@"
}

check_qvm_remote() {
    if ! command -v qvm-remote &>/dev/null; then
        err "qvm-remote not found in PATH"
        exit 1
    fi
    if ! qvm-remote "echo dom0-ok" 2>/dev/null | grep -q "dom0-ok"; then
        err "qvm-remote cannot reach dom0"
        log "Verify the dom0 daemon is running and this VM is authorized."
        exit 1
    fi
    log "qvm-remote: connected to dom0"
}

# ── Phase 0: Read-Only Reconnaissance ─────────────────────────────

phase0_status() {
    sep
    log "=== Phase 0: System Status (read-only) ==="
    sep

    log "Xen hypervisor:"
    dom0_read "xl info 2>/dev/null | grep -E 'xen_version|nr_cpus|total_memory|free_memory|virt_caps|xen_commandline'"

    sep
    log "Running VMs:"
    dom0_read "qvm-ls --format simple --running 2>/dev/null"

    sep
    log "Available templates:"
    dom0_read "qvm-ls --format simple --class TemplateVM 2>/dev/null | head -15"

    sep
    log "Storage:"
    dom0_read "vgs --noheadings 2>/dev/null"

    sep
    log "kvm-dev qube:"
    if dom0_read "qvm-check $VM_NAME 2>/dev/null" | grep -q "exists"; then
        dom0_read "qvm-prefs $VM_NAME virt_mode 2>/dev/null; qvm-prefs $VM_NAME memory 2>/dev/null; qvm-prefs $VM_NAME kernel 2>/dev/null"
    else
        log "  Does not exist yet."
    fi

    sep
    log "Xen commandline (check for nestedhvm):"
    XEN_CMD=$(dom0_read "xl info 2>/dev/null | grep '^xen_commandline' | cut -d: -f2-" || echo "(could not read)")
    info "$XEN_CMD"
    if echo "$XEN_CMD" | grep -q "nestedhvm=1"; then
        info "nestedhvm=1: ACTIVE"
    else
        info "nestedhvm=1: NOT active (Phase 2 required)"
    fi

    sep
    log "GRUB_CMDLINE_XEN_DEFAULT:"
    dom0_read "grep GRUB_CMDLINE_XEN_DEFAULT /etc/default/grub 2>/dev/null" || info "(could not read)"

    sep
    log "Boot config files:"
    dom0_read "ls -la /etc/default/grub /boot/grub2/grub.cfg 2>/dev/null" || true
}

# ── Phase 1: Backup ───────────────────────────────────────────────

phase1_backup() {
    sep
    log "=== Phase 1: Backup Critical dom0 Files ==="
    sep

    local DATESTAMP
    DATESTAMP=$(date +%Y%m%d-%H%M%S)

    log "Will back up:"
    info "/etc/default/grub          -> /etc/default/grub.bak-$DATESTAMP"
    info "/boot/grub2/grub.cfg       -> /boot/grub2/grub.cfg.bak-$DATESTAMP"

    if ! confirm "Create backups in dom0?"; then
        return 0
    fi

    dom0 "cp /etc/default/grub /etc/default/grub.bak-$DATESTAMP"
    dom0 "cp /boot/grub2/grub.cfg /boot/grub2/grub.cfg.bak-$DATESTAMP"

    if ! $DRY_RUN; then
        log "Verifying backups..."
        dom0_read "ls -la /etc/default/grub.bak-$DATESTAMP /boot/grub2/grub.cfg.bak-$DATESTAMP"
        log "Backups created successfully."
    fi

    sep
    log "ROLLBACK INSTRUCTIONS (save this):"
    info "If anything goes wrong after Phase 2 reboot:"
    info "  1. At GRUB menu, select a recovery/older kernel entry"
    info "  2. In dom0 terminal:"
    info "     cp /etc/default/grub.bak-$DATESTAMP /etc/default/grub"
    info "     grub2-mkconfig -o /boot/grub2/grub.cfg"
    info "     reboot"
}

# ── Phase 2: Enable Nested HVM ───────────────────────────────────

phase2_nestedhvm() {
    sep
    log "=== Phase 2: Enable Xen Nested HVM ==="
    sep

    log "Checking current Xen commandline..."
    local XEN_CMD
    XEN_CMD=$(dom0_read "xl info 2>/dev/null | grep '^xen_commandline' | cut -d: -f2-" || echo "")

    if echo "$XEN_CMD" | grep -q "nestedhvm=1"; then
        log "nestedhvm=1 is ALREADY active. Nothing to do."
        return 0
    fi

    log "Current GRUB_CMDLINE_XEN_DEFAULT:"
    dom0_read "grep '^GRUB_CMDLINE_XEN_DEFAULT' /etc/default/grub 2>/dev/null"

    sep
    log "Will append 'hap=1 nestedhvm=1' to GRUB_CMDLINE_XEN_DEFAULT."
    log "This is the ONLY change to dom0 config. It is reversible."
    log ""
    log "What this does:"
    info "hap=1        — Ensures Hardware Assisted Paging for nested guests"
    info "nestedhvm=1  — Allows HVM guests to expose VT-x to their guests"

    if ! confirm "Modify /etc/default/grub in dom0?"; then
        return 0
    fi

    log "Checking that nestedhvm is not already in the GRUB default..."
    local ALREADY
    ALREADY=$(dom0_read "grep 'nestedhvm' /etc/default/grub 2>/dev/null" || echo "")
    if [[ -n "$ALREADY" ]]; then
        log "nestedhvm already present in /etc/default/grub:"
        info "$ALREADY"
        log "Skipping modification."
    else
        dom0 "sed -i 's/^GRUB_CMDLINE_XEN_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_XEN_DEFAULT=\"\1 hap=1 nestedhvm=1\"/' /etc/default/grub"
    fi

    if ! $DRY_RUN; then
        log "Verifying change..."
        dom0_read "grep '^GRUB_CMDLINE_XEN_DEFAULT' /etc/default/grub"
    fi

    sep
    log "Regenerating GRUB config..."
    if confirm "Run grub2-mkconfig in dom0?"; then
        dom0 "grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tail -5"

        if ! $DRY_RUN; then
            log "Verifying nestedhvm in generated grub.cfg..."
            local COUNT
            COUNT=$(dom0_read "grep -c 'nestedhvm' /boot/grub2/grub.cfg 2>/dev/null" || echo "0")
            info "Found nestedhvm in $COUNT GRUB entries."
        fi
    fi

    sep
    log "REBOOT REQUIRED"
    log ""
    log "The change takes effect after dom0 reboots."
    log "Steps:"
    info "1. Save all work in all VMs"
    info "2. Shut down unnecessary VMs"
    info "3. Reboot dom0 (from dom0 terminal: sudo reboot)"
    info "4. After reboot, from visyble run:"
    info "   bash scripts/safe-setup.sh phase3"
    log ""
    log "To verify after reboot:"
    info "qvm-remote \"xl info | grep xen_commandline\""
    info "Should contain: nestedhvm=1"
}

# ── Phase 3: Create kvm-dev StandaloneVM ──────────────────────────

phase3_create_vm() {
    sep
    log "=== Phase 3: Create kvm-dev StandaloneVM ==="
    sep

    log "Verifying nested HVM is active..."
    local XEN_CMD
    XEN_CMD=$(dom0_read "xl info 2>/dev/null | grep '^xen_commandline' | cut -d: -f2-" || echo "")
    if ! echo "$XEN_CMD" | grep -q "nestedhvm=1"; then
        warn "nestedhvm=1 NOT detected in Xen commandline."
        warn "Did you reboot dom0 after Phase 2?"
        info "Current: $XEN_CMD"
        if ! confirm "Continue anyway (kvm-dev will lack /dev/kvm)?"; then
            return 1
        fi
    else
        log "nestedhvm=1: ACTIVE"
    fi

    sep
    log "Checking if $VM_NAME already exists..."
    local EXISTS
    EXISTS=$(dom0_read "qvm-check $VM_NAME 2>/dev/null && echo YES || echo NO")
    if [[ "$EXISTS" == *"YES"* ]]; then
        log "$VM_NAME already exists. Skipping creation."
        log "Current config:"
        dom0_read "echo \"virt_mode: \$(qvm-prefs $VM_NAME virt_mode 2>/dev/null)\"; echo \"memory: \$(qvm-prefs $VM_NAME memory 2>/dev/null)\"; echo \"vcpus: \$(qvm-prefs $VM_NAME vcpus 2>/dev/null)\"; echo \"kernel: \$(qvm-prefs $VM_NAME kernel 2>/dev/null)\""
        return 0
    fi

    log "Will create:"
    info "Name:      $VM_NAME"
    info "Class:     StandaloneVM"
    info "Template:  fedora-42-xfce (or best available)"
    info "Label:     $VM_LABEL"
    info "virt_mode: hvm (required for nested virtualization)"
    info "Memory:    ${VM_MEM}MB initial, ${VM_MAXMEM}MB max"
    info "vCPUs:     $VM_VCPUS"
    info "Private:   $VM_DISK"
    info "Kernel:    Qubes-provided (temporary, until GRUB installed)"
    info "NetVM:     sys-firewall"

    if ! confirm "Create $VM_NAME in dom0?"; then
        return 0
    fi

    log "Step 3a: Creating StandaloneVM..."
    dom0 "qvm-create --class StandaloneVM --template fedora-42-xfce --label $VM_LABEL $VM_NAME"

    log "Step 3b: Setting virt_mode=hvm..."
    dom0 "qvm-prefs $VM_NAME virt_mode hvm"

    log "Step 3c: Allocating resources..."
    dom0 "qvm-prefs $VM_NAME memory $VM_MEM"
    dom0 "qvm-prefs $VM_NAME maxmem $VM_MAXMEM"
    dom0 "qvm-prefs $VM_NAME vcpus $VM_VCPUS"

    log "Step 3d: Setting network..."
    dom0 "qvm-prefs $VM_NAME netvm sys-firewall"

    log "Step 3e: Resizing private volume to $VM_DISK..."
    dom0 "qvm-volume resize ${VM_NAME}:private $VM_DISK"

    log "Step 3f: Creating libvirt XML override for CPU passthrough..."
    dom0 "mkdir -p /etc/qubes/templates/libvirt/xen/by-name"
    dom0 "cat > /etc/qubes/templates/libvirt/xen/by-name/${VM_NAME}.xml << 'XMLEOF'
{% extends 'libvirt/xen.xml' %}
{% block cpu %}
    <cpu mode='host-passthrough'>
        <feature name='vmx' policy='require'/>
        <feature name='invtsc' policy='require'/>
    </cpu>
{% endblock %}
{% block features %}
    <pae/>
    <acpi/>
    <apic/>
    <hap/>
    <viridian/>
{% endblock %}
XMLEOF"

    if ! $DRY_RUN; then
        sep
        log "Verifying creation..."
        dom0_read "echo \"virt_mode: \$(qvm-prefs $VM_NAME virt_mode)\"; echo \"memory: \$(qvm-prefs $VM_NAME memory)MB\"; echo \"maxmem: \$(qvm-prefs $VM_NAME maxmem)MB\"; echo \"vcpus: \$(qvm-prefs $VM_NAME vcpus)\"; echo \"netvm: \$(qvm-prefs $VM_NAME netvm)\"; echo \"kernel: \$(qvm-prefs $VM_NAME kernel)\""
        log ""
        log "Libvirt XML override:"
        dom0_read "cat /etc/qubes/templates/libvirt/xen/by-name/${VM_NAME}.xml"
    fi

    sep
    log "$VM_NAME created successfully."
    log ""
    log "ROLLBACK: To remove this VM:"
    info "qvm-remote \"qvm-remove -f $VM_NAME\""
    info "qvm-remote \"rm /etc/qubes/templates/libvirt/xen/by-name/${VM_NAME}.xml\""
    log ""
    log "Next: bash scripts/safe-setup.sh phase4"
}

# ── Phase 4: Provision and Deploy ─────────────────────────────────

phase4_provision() {
    sep
    log "=== Phase 4: Provision and Deploy ==="
    sep

    log "Checking $VM_NAME exists..."
    local EXISTS
    EXISTS=$(dom0_read "qvm-check $VM_NAME 2>/dev/null && echo YES || echo NO")
    if [[ "$EXISTS" == *"NO"* ]]; then
        err "$VM_NAME does not exist. Run Phase 3 first."
        return 1
    fi

    log "Starting $VM_NAME..."
    local STATE
    STATE=$(dom0_read "qvm-check --running $VM_NAME 2>/dev/null && echo RUNNING || echo STOPPED")
    if [[ "$STATE" == *"STOPPED"* ]]; then
        dom0 "qvm-start $VM_NAME"
        if ! $DRY_RUN; then
            log "Waiting 15s for boot..."
            sleep 15
        fi
    else
        log "$VM_NAME is already running."
    fi

    sep
    log "Step 4a: Installing packages inside $VM_NAME..."
    log "This installs build tools, QEMU, KVM, podman, ARM64 toolchain, and GRUB."
    log "It will take 5-10 minutes depending on network speed."

    if ! confirm "Install packages inside $VM_NAME?"; then
        return 0
    fi

    dom0 "qvm-run --pass-io --no-gui $VM_NAME -- sudo dnf install -y \
gcc gcc-c++ make cmake meson git git-lfs \
python3-devel python3-pip python3-setuptools python3-pytest \
python3-dbus python3-gobject python3-lxml python3-yaml \
qemu-kvm qemu-system-x86-core qemu-img \
libvirt libvirt-devel virt-install edk2-ovmf \
podman buildah \
libX11-devel libXext-devel gtk3-devel openssl-devel systemd-devel \
ShellCheck openssh-server openssh-clients wget curl jq rsync tmux \
rpm-build createrepo_c rpmlint cargo rust \
grub2-efi-x64 grub2-tools shim-x64 kernel \
2>&1 | tail -10"

    log "Installing ARM64 packages..."
    dom0 "qvm-run --pass-io --no-gui $VM_NAME -- sudo dnf install -y \
qemu-system-aarch64-core qemu-user-static edk2-aarch64 \
2>&1 | tail -5" || warn "Some ARM64 packages may not be available"

    log "Enabling services..."
    dom0 "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'sudo systemctl enable --now libvirtd 2>/dev/null; sudo systemctl enable --now sshd 2>/dev/null; sudo usermod -aG kvm,libvirt user 2>/dev/null; echo SERVICES_DONE'"

    sep
    log "Step 4b: Switch to VM-provided kernel..."
    log "This shuts down $VM_NAME, sets kernel='', and restarts."
    log "The VM-provided kernel allows /dev/kvm to appear."

    if ! confirm "Switch $VM_NAME to VM-provided kernel (requires restart)?"; then
        return 0
    fi

    log "Shutting down $VM_NAME..."
    dom0 "qvm-shutdown --wait --timeout 30 $VM_NAME" || true
    if ! $DRY_RUN; then
        sleep 3
    fi

    log "Setting kernel='' (VM-provided)..."
    dom0 "qvm-prefs $VM_NAME kernel ''"

    log "Restarting $VM_NAME..."
    dom0 "qvm-start $VM_NAME"
    if ! $DRY_RUN; then
        log "Waiting 20s for boot with new kernel..."
        sleep 20
    fi

    sep
    log "Step 4c: Verifying /dev/kvm..."
    if ! $DRY_RUN; then
        local KVM_CHECK
        KVM_CHECK=$(dom0_read "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'test -e /dev/kvm && echo KVM_OK || echo KVM_MISSING'" 2>/dev/null || echo "VM_ERROR")
        if [[ "$KVM_CHECK" == *"KVM_OK"* ]]; then
            log "/dev/kvm: YES -- nested HVM is working!"
        elif [[ "$KVM_CHECK" == *"KVM_MISSING"* ]]; then
            warn "/dev/kvm: NOT FOUND"
            info "The VM will still work in TCG (software emulation) mode."
            info "Check: qvm-remote \"xl info | grep xen_commandline\""
        else
            warn "Could not verify (VM may still be booting). Check manually:"
            info "qvm-remote \"qvm-run --pass-io --no-gui $VM_NAME -- ls -la /dev/kvm\""
        fi
    fi

    sep
    log "Step 4d: Deploying project into $VM_NAME..."

    if ! confirm "Copy qubes-kvm-fork project into $VM_NAME?"; then
        return 0
    fi

    if ! $DRY_RUN; then
        local TMPTAR="/tmp/qubes-kvm-fork-deploy.tar.gz"
        log "Creating archive..."
        tar czf "$TMPTAR" \
            -C "$(dirname "$PROJECT_DIR")" \
            --exclude='build/repos' \
            --exclude='build/rpms' \
            --exclude='vm-images/*.qcow2' \
            --exclude='.git' \
            "$(basename "$PROJECT_DIR")"

        local LOCAL_VM
        LOCAL_VM=$(hostname 2>/dev/null || echo "visyble")

        log "Transferring via dom0 relay..."
        dom0 "qvm-run --pass-io --no-gui $LOCAL_VM -- cat $TMPTAR > /tmp/deploy-relay.tar.gz"
        dom0 "cat /tmp/deploy-relay.tar.gz | qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cat > /tmp/deploy.tar.gz && cd /home/user && tar xzf /tmp/deploy.tar.gz && rm /tmp/deploy.tar.gz && echo DEPLOY_OK'"
        dom0 "rm -f /tmp/deploy-relay.tar.gz"
        rm -f "$TMPTAR"
    fi

    sep
    log "Phase 4 complete."
    log ""
    log "ROLLBACK: To undo provisioning:"
    info "qvm-remote \"qvm-shutdown --wait $VM_NAME\""
    info "qvm-remote \"qvm-remove -f $VM_NAME\"  (destroys everything)"
    info "Or to just revert the kernel change:"
    info "qvm-remote \"qvm-shutdown --wait $VM_NAME\""
    info "qvm-remote \"qvm-prefs $VM_NAME kernel 6.17.9-1.fc41\"  (restore Qubes kernel)"
    log ""
    log "Next: bash scripts/safe-setup.sh phase5"
}

# ── Phase 5: Verify All Three Tiers ──────────────────────────────

phase5_test() {
    sep
    log "=== Phase 5: Verify All Three Tiers ==="
    sep

    log "Checking $VM_NAME is running..."
    local STATE
    STATE=$(dom0_read "qvm-check --running $VM_NAME 2>/dev/null && echo RUNNING || echo STOPPED")
    if [[ "$STATE" == *"STOPPED"* ]]; then
        log "Starting $VM_NAME..."
        dom0 "qvm-start $VM_NAME"
        if ! $DRY_RUN; then
            sleep 15
        fi
    fi

    sep
    log "--- Tier 1: Build Environment ---"
    if ! $DRY_RUN; then
        dom0_read "qvm-run --pass-io --no-gui $VM_NAME -- bash -c '
            echo \"GCC: \$(gcc --version 2>/dev/null | head -1 || echo NOT_FOUND)\"
            echo \"Make: \$(make --version 2>/dev/null | head -1 || echo NOT_FOUND)\"
            echo \"Podman: \$(podman --version 2>/dev/null || echo NOT_FOUND)\"
            echo \"Cargo: \$(cargo --version 2>/dev/null || echo NOT_FOUND)\"
            if command -v gcc &>/dev/null && command -v podman &>/dev/null; then
                echo \"TIER1_OK\"
            else
                echo \"TIER1_INCOMPLETE\"
            fi
        '"
    else
        log "[DRY-RUN] Would test: gcc, make, podman, cargo"
    fi

    sep
    log "--- Tier 2: KVM + Xen Emulation ---"
    if ! $DRY_RUN; then
        dom0_read "qvm-run --pass-io --no-gui $VM_NAME -- bash -c '
            echo \"/dev/kvm: \$(test -e /dev/kvm && echo YES || echo NO)\"
            echo \"KVM modules: \$(lsmod 2>/dev/null | grep kvm | tr \"\\n\" \", \" || echo none)\"
            echo \"QEMU x86: \$(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo NOT_FOUND)\"
            if test -e /dev/kvm; then
                ACCEL=\$(qemu-system-x86_64 -accel help 2>&1 || true)
                echo \"QEMU KVM accel: \$(echo \"\$ACCEL\" | grep -c kvm) matches\"
                echo \"TIER2_OK\"
            else
                echo \"TIER2_NO_KVM (TCG mode available)\"
            fi
        '"
    else
        log "[DRY-RUN] Would test: /dev/kvm, qemu-system-x86_64, KVM acceleration"
    fi

    sep
    log "--- Tier 3: ARM64 Cross-Compilation + Emulation ---"
    if ! $DRY_RUN; then
        dom0_read "qvm-run --pass-io --no-gui $VM_NAME -- bash -c '
            echo \"QEMU ARM64: \$(qemu-system-aarch64 --version 2>/dev/null | head -1 || echo NOT_FOUND)\"
            echo \"ARM64 GCC: \$(aarch64-linux-gnu-gcc --version 2>/dev/null | head -1 || echo NOT_FOUND)\"
            if command -v qemu-system-aarch64 &>/dev/null; then
                echo \"TIER3_OK\"
            else
                echo \"TIER3_INCOMPLETE\"
            fi
        '"
    else
        log "[DRY-RUN] Would test: qemu-system-aarch64, aarch64-linux-gnu-gcc"
    fi

    sep
    log "=== Verification Complete ==="
    log ""
    log "Development environment is ready."
    log ""
    log "Quick commands:"
    info "Status:     bash scripts/safe-setup.sh status"
    info "Sync code:  bash scripts/qubes-deploy.sh sync"
    info "Run tests:  bash scripts/qubes-deploy.sh test"
    info "Xen test:   bash scripts/qubes-deploy.sh xen-test"
    info "ARM test:   bash scripts/qubes-deploy.sh arm-test"
    info "Shell cmd:  qvm-remote \"qvm-run --pass-io --no-gui $VM_NAME -- <command>\""
}

# ── Main ──────────────────────────────────────────────────────────

main() {
    local cmd="${1:-all}"

    log "=========================================="
    log " Safe Development Environment Setup"
    log "=========================================="
    if $DRY_RUN; then
        log " MODE: DRY-RUN (no changes will be made)"
    fi
    log ""

    check_qvm_remote

    case "$cmd" in
        status|phase0)
            phase0_status
            ;;
        phase1|backup)
            phase1_backup
            ;;
        phase2|nestedhvm)
            phase2_nestedhvm
            ;;
        phase3|create-vm)
            phase3_create_vm
            ;;
        phase4|provision)
            phase4_provision
            ;;
        phase5|test|verify)
            phase5_test
            ;;
        all)
            phase0_status
            echo ""
            if confirm "Proceed to Phase 1 (Backup)?"; then
                phase1_backup
            fi
            echo ""
            if confirm "Proceed to Phase 2 (Enable Nested HVM)?"; then
                phase2_nestedhvm
                if ! $DRY_RUN; then
                    log ""
                    log "STOP HERE: Reboot dom0, then resume with:"
                    info "bash scripts/safe-setup.sh phase3"
                    exit 0
                fi
            fi
            echo ""
            if confirm "Proceed to Phase 3 (Create kvm-dev VM)?"; then
                phase3_create_vm
            fi
            echo ""
            if confirm "Proceed to Phase 4 (Provision and Deploy)?"; then
                phase4_provision
            fi
            echo ""
            if confirm "Proceed to Phase 5 (Verify Tiers)?"; then
                phase5_test
            fi
            ;;
        *)
            echo "Usage: $PROGNAME [--dry-run] [phase0|phase1|phase2|phase3|phase4|phase5|status|all]"
            echo ""
            echo "Phases:"
            echo "  status/phase0  Read-only system check"
            echo "  phase1/backup  Backup dom0 configs"
            echo "  phase2         Enable Xen nested HVM (requires reboot)"
            echo "  phase3         Create kvm-dev StandaloneVM"
            echo "  phase4         Provision and deploy project"
            echo "  phase5/test    Verify all three tiers"
            echo "  all            Run all phases interactively"
            echo ""
            echo "Options:"
            echo "  --dry-run      Preview what would happen (no changes)"
            ;;
    esac
}

main "$@"
