#!/bin/bash
# provision-kvm-dev.sh — Provision the kvm-dev qube after first boot
#
# Run this INSIDE the kvm-dev StandaloneVM after it boots.
# It installs KVM, QEMU, all dev tools, and verifies nested virt works.
#
# Copy this into the VM via:
#   qvm-copy-to-vm kvm-dev /path/to/qubes-kvm-fork/
# Or from visyble:
#   qvm-remote "qvm-run --pass-io kvm-dev 'cat > /tmp/provision.sh'" < scripts/provision-kvm-dev.sh
#   qvm-remote "qvm-run --pass-io kvm-dev 'bash /tmp/provision.sh'"
set -euo pipefail

log() { echo "[provision] $*"; }

log "=== Provisioning kvm-dev qube ==="
log "Hostname: $(hostname 2>/dev/null || echo unknown)"
log ""

# ── Step 1: Verify KVM ──────────────────────────────────────────
log "=== Step 1: Verify /dev/kvm ==="

if [[ -e /dev/kvm ]]; then
    log "  /dev/kvm: FOUND"
    log "  Nested HVM is working."
else
    log "  /dev/kvm: NOT FOUND"
    log ""
    log "  Trying to load kvm modules..."
    sudo modprobe kvm 2>/dev/null || true
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true

    if [[ -e /dev/kvm ]]; then
        log "  /dev/kvm: NOW AVAILABLE (after modprobe)"
    else
        log "  /dev/kvm: STILL NOT AVAILABLE"
        log ""
        log "  Troubleshooting:"
        log "  1. Did you reboot dom0 after adding 'hap=1 nestedhvm=1' to Xen config?"
        log "     Check from visyble: qvm-remote \"xl info | grep xen_commandline\""
        log "  2. Is the VM in HVM mode?"
        log "     Check from visyble: qvm-remote \"qvm-prefs kvm-dev virt_mode\""
        log "     Must be 'hvm', not 'pvh'."
        log "  3. Is the libvirt XML override in place?"
        log "     Check from visyble: qvm-remote \"cat /etc/qubes/templates/libvirt/xen/by-name/kvm-dev.xml\""
        log "  4. Does Xen report HVM capability?"
        log "     Check from visyble: qvm-remote \"xl info | grep virt_caps\""
        log "     Should contain 'hvm' and 'hap'."
        log "     NOTE: /proc/cpuinfo in dom0 may NOT show vmx on newer CPUs"
        log "     (Arrow Lake, etc.) because Xen consumes the flag."
        log "  5. Is the VM using its own kernel (not Qubes-provided)?"
        log "     Check from visyble: qvm-remote \"qvm-prefs kvm-dev kernel\""
        log "     Should be empty (VM-provided)."
        log ""
        log "  Loaded kvm modules:"
        lsmod | grep kvm 2>/dev/null || log "    (none)"
        log ""
        log "  Continuing without KVM (TCG software emulation mode)."
        log "  Fix the dom0 config and try again."
    fi
fi

# ── Step 2: Detect package manager ──────────────────────────────
if command -v dnf &>/dev/null; then
    PKG="dnf"
elif command -v pacman &>/dev/null; then
    PKG="pacman"
elif command -v apt-get &>/dev/null; then
    PKG="apt"
else
    log "ERROR: No supported package manager found"
    exit 1
fi
log "Package manager: $PKG"

# ── Step 3: Install everything ──────────────────────────────────
log ""
log "=== Step 3: Install dev environment ==="

case "$PKG" in
    dnf)
        # NOTE: xen-devel/xen-libs are NOT in standard Fedora repos.
        # They're only in Qubes repos. Skip them here; they're only
        # needed for building Xen-specific components (done in the
        # builder container which has Qubes repos configured).
        sudo dnf install -y \
            gcc gcc-c++ make cmake meson git git-lfs \
            python3-devel python3-pip python3-setuptools python3-pytest \
            python3-dbus python3-gobject python3-lxml python3-yaml \
            \
            qemu-kvm qemu-system-x86-core qemu-img \
            libvirt libvirt-devel virt-install \
            edk2-ovmf \
            \
            podman buildah \
            \
            libX11-devel libXext-devel gtk3-devel \
            openssl-devel systemd-devel \
            \
            ShellCheck openssh-server openssh-clients \
            wget curl jq rsync tmux \
            \
            rpm-build createrepo_c rpmlint \
            \
            cargo rust \
            \
            gcc-aarch64-linux-gnu \
            \
            grub2-efi-x64 grub2-tools shim-x64 kernel \
            || true

        sudo dnf install -y \
            qemu-system-aarch64-core qemu-user-static edk2-aarch64 \
            2>/dev/null || log "  INFO: Some ARM64 packages not available"
        ;;
    pacman)
        sudo pacman -Syu --needed --noconfirm \
            base-devel git cmake meson \
            python python-pip python-pytest python-dbus python-gobject \
            qemu-base qemu-system-x86 qemu-system-aarch64 qemu-img \
            libvirt virt-manager dnsmasq \
            podman buildah \
            edk2-ovmf \
            openssh wget curl jq rsync tmux \
            shellcheck rust \
            aarch64-linux-gnu-gcc
        ;;
    apt)
        sudo apt-get update
        sudo apt-get install -y \
            build-essential git cmake meson \
            python3-dev python3-pip python3-pytest python3-dbus \
            qemu-system-x86 qemu-system-arm qemu-utils qemu-user-static \
            libvirt-daemon-system virt-manager \
            podman buildah \
            ovmf \
            openssh-server wget curl jq rsync tmux \
            shellcheck cargo \
            gcc-aarch64-linux-gnu
        ;;
esac

# ── Step 4: Enable services ─────────────────────────────────────
log ""
log "=== Step 4: Enable services ==="

sudo systemctl enable --now libvirtd 2>/dev/null || true
sudo systemctl enable --now sshd 2>/dev/null || true

# Add user to KVM and libvirt groups
sudo usermod -aG kvm,libvirt "$(whoami)" 2>/dev/null || true

# ── Step 5: Rust + ARM64 targets ────────────────────────────────
log ""
log "=== Step 5: Rust toolchain ==="

if command -v rustup &>/dev/null; then
    rustup target add aarch64-unknown-linux-gnu 2>/dev/null || true
    log "  Rust ARM64 target: installed"
elif command -v cargo &>/dev/null; then
    log "  Rust available via system package (no rustup)"
fi

# ── Step 6: SSH key for VM testing ──────────────────────────────
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "kvm-dev-qubes"
    log "  SSH key generated"
fi

# ── Step 7: Download test VM image ──────────────────────────────
log ""
log "=== Step 7: Test VM base image ==="

CLOUD_IMG="Fedora-Cloud-Base-42-1.1.x86_64.qcow2"
CLOUD_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/$CLOUD_IMG"

mkdir -p ~/vm-images
if [[ ! -f ~/vm-images/"$CLOUD_IMG" ]]; then
    log "  Downloading Fedora 42 cloud image..."
    wget -q --show-progress -O ~/vm-images/"$CLOUD_IMG" "$CLOUD_URL" || \
        log "  WARNING: Download failed. Get the image manually."
fi

if [[ -f ~/vm-images/"$CLOUD_IMG" ]] && [[ ! -f ~/vm-images/test-fedora.qcow2 ]]; then
    log "  Creating test snapshot..."
    # Use absolute path for backing file — relative paths break if CWD changes
    qemu-img create -f qcow2 \
        -b "$(realpath ~/vm-images/"$CLOUD_IMG")" -F qcow2 \
        ~/vm-images/test-fedora.qcow2 40G
fi

# ── Step 8: Final verification ──────────────────────────────────
log ""
log "=== Final Verification ==="

echo -n "  /dev/kvm:        "; [[ -e /dev/kvm ]] && echo "YES" || echo "NO"
echo -n "  QEMU:            "; qemu-system-x86_64 --version 2>/dev/null | head -1 || echo "NOT FOUND"
echo -n "  QEMU ARM64:      "; qemu-system-aarch64 --version 2>/dev/null | head -1 || echo "NOT FOUND"
echo -n "  Podman:          "; podman --version 2>/dev/null || echo "NOT FOUND"
echo -n "  libvirt:         "; virsh --version 2>/dev/null || echo "NOT FOUND"
echo -n "  Rust:            "; cargo --version 2>/dev/null || echo "NOT FOUND"
echo -n "  ARM64 GCC:       "; aarch64-linux-gnu-gcc --version 2>/dev/null | head -1 || echo "NOT FOUND"

# Quick KVM test — use timeout to prevent hangs
if [[ -e /dev/kvm ]]; then
    log ""
    log "  Running quick KVM test..."
    # -no-reboot + -kernel /dev/null makes QEMU start and immediately fail
    # to load the kernel, proving KVM acceleration was accepted.
    # Timeout prevents any hang scenario.
    if timeout 5 qemu-system-x86_64 \
        -accel kvm -cpu host -m 128 -display none \
        -no-reboot -serial none -monitor none \
        -kernel /dev/null 2>&1 | grep -qi "could not\|error\|kvm" ; then
        log "  KVM acceleration: WORKS (QEMU accepted -accel kvm)"
    else
        log "  KVM acceleration: likely works (check with: qemu-system-x86_64 -accel kvm -cpu host -m 128 -display none -no-reboot -kernel /dev/null)"
    fi
fi

log ""
log "==========================================="
log " kvm-dev qube provisioned!"
log "==========================================="
log ""
log " What you can do here:"
log "   Tier 1: make build && make test"
log "   Tier 2: bash configs/xen-on-kvm-test.sh vm-images/test-fedora.qcow2"
log "   Tier 2: bash configs/kvm-gpu-passthrough-test.sh (if PCI device passed)"
log "   Tier 3: bash configs/arm64-cross-test.sh compile-test"
log "   Tier 3: bash configs/arm64-cross-test.sh vm-boot vm-images/arm64.qcow2"
log ""
log " Get the project code:"
log "   cd ~ && git clone <your-repo-url> qubes-kvm-fork"
log "   # Or copy from visyble:"
log "   # (in visyble) qvm-copy-to-vm kvm-dev ~/fix/qubes-kvm-fork/"
