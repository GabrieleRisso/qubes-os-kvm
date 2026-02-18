#!/bin/bash
# setup-qubes-vm.sh — First-time setup on the Qubes OS AppVM
# Run this inside your dev VM (visyble)
#
# This machine is for: building, unit tests, light QEMU smoke tests (TCG)
# Heavy testing (Xen-on-KVM, nested VMs) happens on the Lenovo laptop.
set -euo pipefail

log() { echo "[setup-qubes] $*"; }

log "=== Qubes AppVM Dev Setup ==="
log "VM: $(hostname 2>/dev/null || echo unknown)"
log "OS: $(head -1 /etc/os-release 2>/dev/null || echo unknown)"
log ""

# Detect package manager
if command -v pacman &>/dev/null; then
    PKG="pacman"
elif command -v dnf &>/dev/null; then
    PKG="dnf"
else
    log "ERROR: unsupported package manager"
    exit 1
fi

# Install dependencies
log "Installing build dependencies..."
case "$PKG" in
    pacman)
        sudo pacman -Sy --needed --noconfirm \
            base-devel git git-lfs \
            python python-pip python-setuptools python-pytest \
            qemu-base qemu-system-x86 qemu-img \
            podman buildah skopeo \
            openssh wget curl jq \
            shellcheck \
            aarch64-linux-gnu-gcc  # ARM64 cross-compiler
        ;;
    dnf)
        sudo dnf install -y \
            gcc gcc-c++ make git \
            python3-devel python3-pip python3-pytest \
            qemu-system-x86-core qemu-img \
            podman buildah \
            openssh-clients wget curl jq \
            ShellCheck
        ;;
esac

# Podman setup for rootless containers
log "Configuring podman..."
if ! grep -q "$(whoami)" /etc/subuid 2>/dev/null; then
    log "  Setting up rootless podman..."
    sudo sh -c "echo '$(whoami):100000:65536' >> /etc/subuid"
    sudo sh -c "echo '$(whoami):100000:65536' >> /etc/subgid"
fi

# Create working directories
log "Creating project structure..."
cd "$(dirname "$0")/.."
mkdir -p build/{repos,rpms} vm-images patches test

# SSH key for VM testing
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    log "Generating SSH key for VM access..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "qubes-kvm-fork-dev"
fi

# Git config for patch management
log "Configuring git for patch workflow..."
git config --global diff.algorithm histogram 2>/dev/null || true
git config --global rerere.enabled true 2>/dev/null || true

log ""
log "=== Setup Complete ==="
log ""
log "This machine (Qubes AppVM) supports:"
log "  [x] Building Qubes components in containers"
log "  [x] Unit tests and linting"
log "  [x] QEMU smoke tests (TCG mode — slow but functional)"
log "  [ ] Xen-on-KVM testing (needs /dev/kvm — use Lenovo)"
log "  [ ] GPU passthrough (needs real hardware — use Lenovo)"
log "  [ ] Nested virtualization (needs KVM host — use Lenovo)"
log ""
log "Next steps:"
log "  make setup        # Build container + clone repos"
log "  make build        # Build all components"
log "  make test         # Run tests"
