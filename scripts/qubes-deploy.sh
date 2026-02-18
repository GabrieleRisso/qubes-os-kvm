#!/bin/bash
# qubes-deploy.sh — Deploy and manage the kvm-dev qube from visyble
#
# Run this from your current AppVM (visyble) to set up and manage
# the kvm-dev qube via qvm-remote and qvm-copy-to-vm.
#
# Usage:
#   bash scripts/qubes-deploy.sh setup      # One-time: create kvm-dev qube
#   bash scripts/qubes-deploy.sh deploy      # Copy project into kvm-dev
#   bash scripts/qubes-deploy.sh provision   # Install dev tools inside kvm-dev
#   bash scripts/qubes-deploy.sh test        # Run tests inside kvm-dev
#   bash scripts/qubes-deploy.sh ssh         # Open shell in kvm-dev
#   bash scripts/qubes-deploy.sh status      # Check kvm-dev state
set -euo pipefail

readonly VM_NAME="kvm-dev"
readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROGNAME="qubes-deploy"

log() { echo "[$PROGNAME] $*"; }

check_remote() {
    if ! command -v qvm-remote &>/dev/null; then
        log "ERROR: qvm-remote not in PATH"
        log "Install it first, or run dom0 commands manually."
        exit 1
    fi
    # Quick connectivity check — run a trivial command in dom0.
    # NOTE: 'qvm-remote ping' / '--ping' may not work on all versions;
    # a simple echo is the most reliable way to verify the link.
    if ! qvm-remote "echo dom0-ok" 2>/dev/null | grep -q "dom0-ok"; then
        log "ERROR: qvm-remote cannot reach dom0"
        log "Verify the dom0 daemon is running and this VM is authorized."
        log "  In dom0: systemctl status qvm-remote-dom0"
        exit 1
    fi
}

# Ensure kvm-dev is running; start it if not.
ensure_vm_running() {
    local state
    state=$(qvm-remote "qvm-check --running $VM_NAME 2>/dev/null && echo RUNNING || echo STOPPED")
    if [[ "$state" == *"STOPPED"* ]]; then
        log "Starting $VM_NAME..."
        qvm-remote "qvm-start $VM_NAME"
        log "Waiting for VM to boot..."
        sleep 10
    fi
}

case "${1:-help}" in

    setup)
        log "=== Setting up kvm-dev qube via dom0 ==="
        check_remote

        log "Step 1: Running dom0 setup script..."
        qvm-remote < "$PROJECT_DIR/scripts/setup-qubes-nested.sh"

        log ""
        log "Step 2: Check if nestedhvm is active in Xen..."
        # xl info xen_commandline shows the Xen boot parameters
        XEN_LINE=$(qvm-remote "xl info 2>/dev/null | grep '^xen_commandline' || echo ''")
        if echo "$XEN_LINE" | grep -q "nestedhvm=1"; then
            log "  Nested HVM: ACTIVE"
            log ""
            log "Next steps:"
            log "  bash scripts/qubes-deploy.sh deploy"
            log "  bash scripts/qubes-deploy.sh provision"
        else
            log "  Nested HVM: NOT YET ACTIVE"
            log ""
            log "ACTION REQUIRED: Reboot dom0 for nestedhvm=1 to take effect."
            log ""
            log "After reboot, run:"
            log "  bash scripts/qubes-deploy.sh deploy"
            log "  bash scripts/qubes-deploy.sh provision"
        fi
        ;;

    deploy)
        log "=== Deploying project to $VM_NAME ==="
        check_remote
        ensure_vm_running

        # Transfer via dom0 relay: visyble -> dom0 /tmp -> kvm-dev
        # qvm-copy-to-vm opens a GUI dialog and hangs in non-interactive use.
        # Instead we use dom0 as an intermediary: pull from this VM, push to target.
        log "Creating project archive..."
        TMPTAR="/tmp/qubes-kvm-fork-deploy.tar.gz"
        tar czf "$TMPTAR" \
            -C "$(dirname "$PROJECT_DIR")" \
            --exclude='build/repos' \
            --exclude='build/rpms' \
            --exclude='vm-images/*.qcow2' \
            --exclude='.git' \
            "$(basename "$PROJECT_DIR")"

        LOCAL_VM=$(hostname 2>/dev/null || echo "visyble")
        log "Pulling archive to dom0 (relay)..."
        qvm-remote "qvm-run --pass-io --no-gui $LOCAL_VM -- cat $TMPTAR > /tmp/deploy-relay.tar.gz"

        log "Pushing to $VM_NAME and extracting..."
        qvm-remote "cat /tmp/deploy-relay.tar.gz | qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cat > /tmp/deploy.tar.gz && cd /home/user && tar xzf /tmp/deploy.tar.gz && rm /tmp/deploy.tar.gz'"

        log "Cleaning up relay..."
        qvm-remote "rm -f /tmp/deploy-relay.tar.gz"
        rm -f "$TMPTAR"

        log "Project deployed to $VM_NAME:/home/user/qubes-kvm-fork/"
        log ""
        log "Next: bash scripts/qubes-deploy.sh provision"
        ;;

    provision)
        log "=== Provisioning $VM_NAME ==="
        check_remote
        ensure_vm_running

        log "Running provision script inside $VM_NAME (this takes 5-10 minutes)..."
        qvm-remote -t 900 "qvm-run --pass-io --no-gui $VM_NAME -- bash /home/user/qubes-kvm-fork/scripts/provision-kvm-dev.sh"

        log ""
        log "Installing GRUB so we can switch to VM-provided kernel..."
        qvm-remote "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'sudo dnf install -y grub2-efi-x64 grub2-tools shim-x64 kernel 2>/dev/null || sudo pacman -S --needed --noconfirm grub efibootmgr linux 2>/dev/null || sudo apt-get install -y grub-efi-amd64 linux-image-amd64 2>/dev/null; echo GRUB_INSTALL_DONE'"

        log "Switching $VM_NAME to VM-provided kernel (enables /dev/kvm)..."
        qvm-remote "qvm-prefs $VM_NAME kernel ''"
        log "  kernel: (VM-provided)"

        log ""
        log "Restarting $VM_NAME with new kernel..."
        qvm-remote "qvm-shutdown --wait --timeout 30 $VM_NAME" || true
        sleep 2
        qvm-remote "qvm-start $VM_NAME"
        sleep 10

        log "Verifying /dev/kvm..."
        KVM_CHECK=$(qvm-remote "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'test -e /dev/kvm && echo KVM_OK || echo KVM_MISSING'" 2>/dev/null || echo "VM_ERROR")
        if [[ "$KVM_CHECK" == *"KVM_OK"* ]]; then
            log "  /dev/kvm: YES — nested HVM is working"
        elif [[ "$KVM_CHECK" == *"KVM_MISSING"* ]]; then
            log "  /dev/kvm: NO"
            log "  Troubleshooting:"
            log "    1. Did dom0 reboot after adding nestedhvm=1?"
            log "    2. Check: qvm-remote \"xl info | grep xen_commandline\""
            log "    3. Check: qvm-remote \"cat /etc/qubes/templates/libvirt/xen/by-name/kvm-dev.xml\""
            log "  The VM will still work in TCG (software) mode for now."
        else
            log "  Could not check (VM may still be booting). Try:"
            log "    bash scripts/qubes-deploy.sh status"
        fi

        log ""
        log "Provisioning complete."
        log "Next: bash scripts/qubes-deploy.sh test"
        ;;

    test)
        log "=== Running tests in $VM_NAME ==="
        check_remote
        ensure_vm_running

        log "Running granular probe suite..."
        qvm-remote -t 60 "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cd /home/user/qubes-kvm-fork && bash test/granular-probes.sh all'"
        ;;

    xen-test)
        log "=== Running Xen-on-KVM test in $VM_NAME ==="
        check_remote
        ensure_vm_running

        log "This boots a VM inside kvm-dev where the guest sees Xen 4.19."
        log "It's the core proof-of-concept for the entire architecture."
        qvm-remote -t 120 "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cd /home/user/qubes-kvm-fork && bash test/granular-probes.sh p2'"
        ;;

    arm-test)
        log "=== Running ARM64 tests in $VM_NAME ==="
        check_remote
        ensure_vm_running

        qvm-remote -t 60 "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cd /home/user/qubes-kvm-fork && bash test/granular-probes.sh p1 && bash test/granular-probes.sh p3'"
        ;;

    build)
        log "=== Building in $VM_NAME ==="
        check_remote
        ensure_vm_running

        qvm-remote -t 900 "qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cd /home/user/qubes-kvm-fork && make setup && make build'"
        ;;

    ssh|shell)
        log "NOTE: Interactive shells don't work through qvm-remote."
        log ""
        log "Use one of these instead:"
        log ""
        log "  1. Run a single command:"
        log "     qvm-remote \"qvm-run --pass-io --no-gui $VM_NAME -- <command>\""
        log ""
        log "  2. Open a GUI terminal in $VM_NAME (from dom0):"
        log "     qvm-remote \"qvm-run $VM_NAME 'xterm'\""
        log ""
        log "  3. Run a script:"
        log "     qvm-remote \"qvm-run --pass-io --no-gui $VM_NAME -- bash -c '<commands>'\""
        ;;

    status)
        log "=== $VM_NAME status ==="
        check_remote

        # Single dom0 command to gather all info — efficient, one round-trip
        qvm-remote "
            echo \"STATE: \$(qvm-check --running $VM_NAME 2>/dev/null && echo running || echo stopped)\"
            echo \"virt_mode: \$(qvm-prefs $VM_NAME virt_mode 2>/dev/null)\"
            echo \"memory: \$(qvm-prefs $VM_NAME memory 2>/dev/null)MB\"
            echo \"maxmem: \$(qvm-prefs $VM_NAME maxmem 2>/dev/null)MB\"
            echo \"vcpus: \$(qvm-prefs $VM_NAME vcpus 2>/dev/null)\"
            echo \"kernel: \$(qvm-prefs $VM_NAME kernel 2>/dev/null || echo 'VM-provided')\"
            echo \"netvm: \$(qvm-prefs $VM_NAME netvm 2>/dev/null)\"
            if qvm-check --running $VM_NAME 2>/dev/null; then
                KVM=\$(qvm-run --pass-io --no-gui $VM_NAME -- test -e /dev/kvm 2>/dev/null && echo YES || echo NO)
                echo \"kvm_inside: \$KVM\"
                QEMU=\$(qvm-run --pass-io --no-gui $VM_NAME -- qemu-system-x86_64 --version 2>/dev/null | head -1 || echo 'not installed')
                echo \"qemu: \$QEMU\"
            else
                echo \"(VM not running — start with: bash scripts/qubes-deploy.sh start)\"
            fi
        "
        ;;

    sync)
        log "=== Syncing changes to $VM_NAME ==="
        check_remote
        ensure_vm_running

        TMPTAR="/tmp/qubes-kvm-fork-sync.tar.gz"
        tar czf "$TMPTAR" \
            -C "$(dirname "$PROJECT_DIR")" \
            --exclude='build' \
            --exclude='vm-images' \
            --exclude='.git' \
            "$(basename "$PROJECT_DIR")"

        LOCAL_VM=$(hostname 2>/dev/null || echo "visyble")
        qvm-remote "qvm-run --pass-io --no-gui $LOCAL_VM -- cat $TMPTAR > /tmp/sync-relay.tar.gz"
        qvm-remote "cat /tmp/sync-relay.tar.gz | qvm-run --pass-io --no-gui $VM_NAME -- bash -c 'cat > /tmp/sync.tar.gz && cd /home/user && tar xzf /tmp/sync.tar.gz && rm /tmp/sync.tar.gz'"
        qvm-remote "rm -f /tmp/sync-relay.tar.gz"
        rm -f "$TMPTAR"

        log "Synced."
        ;;

    stop)
        log "Shutting down $VM_NAME..."
        check_remote
        qvm-remote "qvm-shutdown --wait --timeout 60 $VM_NAME"
        log "$VM_NAME stopped."
        ;;

    start)
        log "Starting $VM_NAME..."
        check_remote
        qvm-remote "qvm-start $VM_NAME"
        sleep 5
        log "$VM_NAME started."
        ;;

    help|*)
        echo "Usage: $PROGNAME <command>"
        echo ""
        echo "First-time setup:"
        echo "  setup       Create kvm-dev qube with nested HVM in dom0"
        echo "  deploy      Copy project files into kvm-dev"
        echo "  provision   Install all dev tools inside kvm-dev"
        echo ""
        echo "Development:"
        echo "  sync        Quick-sync source changes to kvm-dev"
        echo "  build       Build all components inside kvm-dev"
        echo "  test        Run test suite inside kvm-dev"
        echo "  xen-test    Run Xen-on-KVM proof of concept"
        echo "  arm-test    Run ARM64 cross-compilation test"
        echo ""
        echo "VM management:"
        echo "  start       Start kvm-dev qube"
        echo "  stop        Shutdown kvm-dev qube"
        echo "  status      Show kvm-dev state and capabilities"
        echo "  ssh         Instructions for shell access"
        ;;
esac
