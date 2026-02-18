#!/bin/bash
# setup-lenovo.sh — First-time setup on the Lenovo KVM laptop
# Run this on the Lenovo laptop (bare metal Linux with KVM)
#
# This machine is for: EVERYTHING — build, unit tests, AND full VM testing
# It has /dev/kvm so it can run Xen-on-KVM, nested VMs, GPU passthrough.
set -euo pipefail

log() { echo "[setup-lenovo] $*"; }

log "=== Lenovo KVM Laptop Dev Setup ==="
log ""

# Verify KVM is available
if [[ ! -e /dev/kvm ]]; then
    log "WARNING: /dev/kvm not found!"
    log "Check:"
    log "  1. BIOS: Enable Intel VT-x / AMD-V"
    log "  2. BIOS: Enable VT-d / AMD IOMMU"
    log "  3. Kernel: modprobe kvm_intel (or kvm_amd)"
    log ""
    log "Continuing without KVM (will use TCG)..."
fi

# Detect distro
if [[ -f /etc/fedora-release ]]; then
    DISTRO="fedora"
elif [[ -f /etc/arch-release ]]; then
    DISTRO="arch"
elif [[ -f /etc/debian_version ]]; then
    DISTRO="debian"
else
    DISTRO="unknown"
fi

log "Detected distro: $DISTRO"

# Install dependencies
log "Installing build + virtualization dependencies..."
case "$DISTRO" in
    fedora)
        sudo dnf install -y \
            gcc gcc-c++ make cmake meson git \
            python3-devel python3-pip python3-pytest \
            qemu-kvm qemu-img libvirt virt-manager \
            podman buildah \
            edk2-ovmf swtpm \
            openssh-server wget curl jq \
            ShellCheck \
            # IOMMU tools for GPU passthrough testing
            pciutils iommu-tools \
            # ARM64 cross-compilation
            qemu-user-static qemu-system-aarch64 \
            # Rust (for crosvm)
            cargo rust
        ;;
    arch)
        sudo pacman -Sy --needed --noconfirm \
            base-devel git cmake meson \
            python python-pip python-pytest \
            qemu-base qemu-system-x86 qemu-system-aarch64 qemu-img \
            libvirt virt-manager dnsmasq \
            podman buildah \
            edk2-ovmf swtpm \
            openssh wget curl jq \
            shellcheck \
            aarch64-linux-gnu-gcc \
            rust
        ;;
    debian)
        sudo apt-get update
        sudo apt-get install -y \
            build-essential git cmake meson \
            python3-dev python3-pip python3-pytest \
            qemu-system-x86 qemu-utils libvirt-daemon-system \
            podman buildah \
            ovmf swtpm \
            openssh-server wget curl jq \
            shellcheck \
            gcc-aarch64-linux-gnu qemu-system-arm \
            cargo
        ;;
    *)
        log "Unknown distro. Install manually:"
        log "  qemu-kvm, libvirt, podman, python3, gcc, git, rust"
        ;;
esac

# Enable KVM + libvirt
log "Enabling KVM and libvirt..."
sudo systemctl enable --now libvirtd 2>/dev/null || true
sudo usermod -aG kvm,libvirt "$(whoami)" 2>/dev/null || true

# Enable nested virtualization (CRITICAL for Xen-in-KVM testing)
log "Enabling nested virtualization..."
if grep -q "Intel" /proc/cpuinfo 2>/dev/null; then
    NESTED_FILE="/sys/module/kvm_intel/parameters/nested"
    MODULE="kvm_intel"
    if [[ -f "$NESTED_FILE" ]] && [[ "$(cat "$NESTED_FILE")" != "Y" ]]; then
        sudo modprobe -r kvm_intel 2>/dev/null || true
        sudo modprobe kvm_intel nested=1
        echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
        log "  Intel nested virtualization: ENABLED"
    else
        log "  Intel nested virtualization: already enabled"
    fi
elif grep -q "AMD" /proc/cpuinfo 2>/dev/null; then
    NESTED_FILE="/sys/module/kvm_amd/parameters/nested"
    MODULE="kvm_amd"
    if [[ -f "$NESTED_FILE" ]] && [[ "$(cat "$NESTED_FILE")" != "1" ]]; then
        sudo modprobe -r kvm_amd 2>/dev/null || true
        sudo modprobe kvm_amd nested=1
        echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
        log "  AMD nested virtualization: ENABLED"
    else
        log "  AMD nested virtualization: already enabled"
    fi
fi

# IOMMU setup for GPU passthrough testing
log "Checking IOMMU status..."
if dmesg 2>/dev/null | grep -qi "IOMMU enabled\|DMAR.*IOMMU"; then
    log "  IOMMU: ENABLED"
    # Show IOMMU groups (useful for GPU passthrough)
    log "  IOMMU groups:"
    for g in /sys/kernel/iommu_groups/*/devices/*; do
        [[ -e "$g" ]] || continue
        local group
        group=$(echo "$g" | grep -oP 'iommu_groups/\K\d+')
        local device
        device=$(lspci -nns "${g##*/}" 2>/dev/null | head -1)
        echo "    Group $group: $device"
    done 2>/dev/null | head -20
else
    log "  IOMMU: NOT DETECTED"
    log "  Enable in BIOS: Intel VT-d or AMD IOMMU"
    log "  Add to kernel cmdline: intel_iommu=on iommu=pt"
fi

# Podman rootless
log "Configuring podman..."
if ! grep -q "$(whoami)" /etc/subuid 2>/dev/null; then
    sudo sh -c "echo '$(whoami):100000:65536' >> /etc/subuid"
    sudo sh -c "echo '$(whoami):100000:65536' >> /etc/subgid"
fi

# SSH key
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    log "Generating SSH key..."
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "qubes-kvm-fork-dev"
fi

# Download test VM base image (Fedora cloud, small)
log "Downloading Fedora 42 cloud image for VM testing..."
CLOUD_IMG="Fedora-Cloud-Base-42-1.1.x86_64.qcow2"
CLOUD_URL="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/$CLOUD_IMG"
cd "$(dirname "$0")/.."
mkdir -p vm-images
if [[ ! -f "vm-images/$CLOUD_IMG" ]]; then
    wget -O "vm-images/$CLOUD_IMG" "$CLOUD_URL" || \
        log "  Download failed — download manually to vm-images/"
fi

# Create a test snapshot from cloud image
if [[ -f "vm-images/$CLOUD_IMG" ]] && [[ ! -f "vm-images/test-fedora.qcow2" ]]; then
    log "Creating test VM snapshot from cloud image..."
    qemu-img create -f qcow2 -b "$CLOUD_IMG" -F qcow2 \
        "vm-images/test-fedora.qcow2" 40G
fi

log ""
log "=== Setup Complete ==="
log ""
log "This machine (Lenovo + KVM) supports:"
log "  [x] Building Qubes components in containers"
log "  [x] Unit tests and linting"
log "  [x] QEMU test VMs (KVM-accelerated — full speed)"
log "  [x] Xen-on-KVM testing (QEMU --accel kvm,xen-version=...)"
log "  [x] Nested virtualization (Xen inside KVM)"
log "  [x] GPU passthrough testing (VFIO, if IOMMU enabled)"
log "  [x] ARM64 cross-compilation and emulation (qemu-user-static)"
log ""
log "IMPORTANT: Log out and back in for group changes (kvm, libvirt)"
log ""
log "Next steps:"
log "  make setup        # Build container + clone repos"
log "  make info         # Verify capabilities"
log "  make build        # Build all components"
log "  make vm-start     # Boot test VM"
log "  make vm-ssh       # SSH in"
