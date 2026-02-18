#!/bin/bash
# setup-lenovo.sh — First-time setup on the Lenovo T15 Gen 2/3
#
# Target: EndeavourOS (Arch-based) with KVM enabled
# Run this ON the Lenovo laptop (bare metal) as your regular user.
#
# This machine handles:
#   - Full KVM-accelerated VM testing (Xen-on-KVM, GPU passthrough)
#   - Container builds (podman)
#   - ARM64 cross-compilation + emulation
#   - Remote development via SSH (Cursor Remote-SSH from Qubes)
#   - Open crawl agent for remote task execution
#
# Usage:
#   bash setup-lenovo.sh           # Full setup
#   bash setup-lenovo.sh --agent   # Agent service only (after initial setup)
#   bash setup-lenovo.sh --ssh     # SSH setup only
#   bash setup-lenovo.sh --check   # Verify everything is working
set -euo pipefail

readonly PROGNAME="setup-lenovo"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_DIR
readonly AGENT_DIR="${PROJECT_DIR}/lenovo-agent"

log()  { echo "[$PROGNAME] $*"; }
info() { echo "[$PROGNAME]   $*"; }
warn() { echo "[$PROGNAME] WARNING: $*"; }
err()  { echo "[$PROGNAME] ERROR: $*" >&2; }

# ── Step 1: Verify hardware ─────────────────────────────────────

check_hardware() {
    log "=== Step 1: Hardware Check ==="

    if [[ ! -e /dev/kvm ]]; then
        warn "/dev/kvm not found!"
        info "Check BIOS: Enable Intel VT-x / AMD-V"
        info "Check BIOS: Enable VT-d / AMD IOMMU"
        info "Then: sudo modprobe kvm_intel (or kvm_amd)"
        info "Continuing without KVM..."
    else
        log "  /dev/kvm: present"
    fi

    local cpu_vendor="unknown"
    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        cpu_vendor="intel"
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        cpu_vendor="amd"
    fi
    log "  CPU: $cpu_vendor ($(nproc) cores)"
    log "  RAM: $(awk '/MemTotal/{printf "%.0f GB", $2/1024/1024}' /proc/meminfo)"
    log "  Kernel: $(uname -r)"

    if [[ -f /etc/endeavouros-release ]]; then
        log "  Distro: EndeavourOS $(cat /etc/endeavouros-release 2>/dev/null || echo '')"
    elif [[ -f /etc/arch-release ]]; then
        log "  Distro: Arch Linux"
    else
        warn "Not Arch-based — package commands may need adjustment"
    fi
}

# ── Step 2: Install packages ────────────────────────────────────

install_packages() {
    log "=== Step 2: Install Packages ==="

    log "Updating system..."
    sudo pacman -Syu --noconfirm

    log "Installing build + virtualization packages..."
    sudo pacman -S --needed --noconfirm \
        base-devel git cmake meson ninja \
        python python-pip python-virtualenv python-pytest python-setuptools \
        qemu-base qemu-system-x86 qemu-system-aarch64 qemu-img \
        libvirt virt-manager dnsmasq iptables-nft nftables \
        podman buildah skopeo \
        edk2-ovmf swtpm \
        openssh wget curl jq rsync tmux htop \
        shellcheck \
        rust \
        rpm-tools \
        pciutils usbutils lshw

    log "Installing ARM64 cross-compilation tools..."
    sudo pacman -S --needed --noconfirm \
        aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
        2>/dev/null || warn "ARM64 cross-compiler not available — install from AUR if needed"

    log "Installing Python AI/ML dependencies..."
    pip install --user --break-system-packages \
        fastapi uvicorn httpx websockets \
        crawl4ai aiohttp beautifulsoup4 \
        pydantic rich \
        2>/dev/null || warn "Some Python packages failed — will retry in venv"
}

# ── Step 3: Enable KVM + libvirt ─────────────────────────────────

enable_kvm() {
    log "=== Step 3: Enable KVM + Libvirt ==="

    sudo systemctl enable --now libvirtd 2>/dev/null || true
    sudo usermod -aG kvm,libvirt "$(whoami)" 2>/dev/null || true

    if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
        local nested_file="/sys/module/kvm_intel/parameters/nested"
        if [[ -f "$nested_file" ]]; then
            local current
            current="$(cat "$nested_file")"
            if [[ "$current" != "Y" && "$current" != "1" ]]; then
                sudo modprobe -r kvm_intel 2>/dev/null || true
                sudo modprobe kvm_intel nested=1
                echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
                log "  Intel nested virtualization: ENABLED"
            else
                log "  Intel nested virtualization: already enabled"
            fi
        fi
    elif grep -q "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then
        local nested_file="/sys/module/kvm_amd/parameters/nested"
        if [[ -f "$nested_file" ]]; then
            local current
            current="$(cat "$nested_file")"
            if [[ "$current" != "1" ]]; then
                sudo modprobe -r kvm_amd 2>/dev/null || true
                sudo modprobe kvm_amd nested=1
                echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm-nested.conf
                log "  AMD nested virtualization: ENABLED"
            else
                log "  AMD nested virtualization: already enabled"
            fi
        fi
    fi
}

# ── Step 4: IOMMU for GPU passthrough ───────────────────────────

setup_iommu() {
    log "=== Step 4: IOMMU / GPU Passthrough Setup ==="

    local iommu_active=false
    if dmesg 2>/dev/null | grep -qi "IOMMU enabled\|DMAR.*IOMMU\|AMD-Vi"; then
        iommu_active=true
        log "  IOMMU: ACTIVE"
    fi

    if ! $iommu_active; then
        warn "IOMMU not detected in dmesg"
        info "To enable GPU passthrough, add to kernel cmdline:"
        info ""

        if [[ -f /etc/kernel/cmdline ]]; then
            : # systemd-boot unified kernel
        fi

        if grep -q "GenuineIntel" /proc/cpuinfo 2>/dev/null; then
            info "  intel_iommu=on iommu=pt"
        else
            info "  amd_iommu=on iommu=pt"
        fi
        info ""
        info "For systemd-boot (EndeavourOS default):"
        info "  Edit /etc/kernel/cmdline and add the flags"
        info "  Then: sudo reinstall-kernels"
        info ""
        info "For GRUB:"
        info "  Edit /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT"
        info "  Then: sudo grub-mkconfig -o /boot/grub/grub.cfg"
        return
    fi

    log "  IOMMU groups with GPU/accelerator devices:"
    local found=0
    for iommu_dir in /sys/kernel/iommu_groups/*/devices/*; do
        [[ -e "$iommu_dir" ]] || continue
        local bdf="${iommu_dir##*/}"
        local desc
        desc="$(lspci -nns "$bdf" 2>/dev/null | head -1 || true)"
        if echo "$desc" | grep -qiE "VGA|3D|Display|Accelerator"; then
            local group_num
            group_num="$(echo "$iommu_dir" | grep -oP 'iommu_groups/\K\d+')"
            info "  Group $group_num: $desc"
            found=$((found + 1))
        fi
    done
    if [[ $found -eq 0 ]]; then
        info "  No GPU devices found in IOMMU groups"
    fi

    log "  Loading VFIO modules..."
    sudo modprobe vfio-pci 2>/dev/null || true
    if ! grep -q "vfio-pci" /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf >/dev/null
        log "  vfio-pci: added to auto-load"
    fi
}

# ── Step 5: SSH server for remote development ───────────────────

setup_ssh() {
    log "=== Step 5: SSH Server for Cursor Remote-SSH ==="

    sudo systemctl enable --now sshd

    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        log "  Generating SSH key..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "lenovo-qubes-kvm-dev"
    fi

    if [[ ! -f ~/.ssh/authorized_keys ]]; then
        touch ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
    fi

    local local_ip
    local_ip="$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1 || echo 'unknown')"

    log "  SSH server: running"
    log "  Local IP: $local_ip"
    log "  Port: 22"
    log ""
    log "  To connect from Qubes (visyble VM):"
    info "  1. Copy your Qubes SSH public key to this machine:"
    info "     ssh-copy-id user@$local_ip"
    info "  2. In Cursor, add to SSH config (~/.ssh/config):"
    info "     Host lenovo-kvm"
    info "       HostName $local_ip"
    info "       User $(whoami)"
    info "       Port 22"
    info "       ForwardAgent yes"
    info "  3. In Cursor: Ctrl+Shift+P → Remote-SSH: Connect to Host → lenovo-kvm"
}

# ── Step 6: Podman rootless ──────────────────────────────────────

setup_podman() {
    log "=== Step 6: Podman Rootless ==="

    local user
    user="$(whoami)"
    if ! grep -q "^${user}:" /etc/subuid 2>/dev/null; then
        sudo sh -c "echo '${user}:100000:65536' >> /etc/subuid"
        sudo sh -c "echo '${user}:100000:65536' >> /etc/subgid"
        log "  subuid/subgid: configured"
    else
        log "  subuid/subgid: already configured"
    fi
}

# ── Step 7: Agent service ────────────────────────────────────────

setup_agent() {
    log "=== Step 7: Open Crawl Agent Service ==="

    if [[ ! -d "$AGENT_DIR" ]]; then
        err "Agent directory not found: $AGENT_DIR"
        info "Deploy the qubes-kvm-fork repo to this machine first."
        return 1
    fi

    log "  Creating Python virtual environment..."
    if [[ ! -d "$AGENT_DIR/.venv" ]]; then
        python -m venv "$AGENT_DIR/.venv"
    fi

    log "  Installing agent dependencies..."
    "$AGENT_DIR/.venv/bin/pip" install -q \
        -r "$AGENT_DIR/requirements.txt" 2>&1 | tail -3

    log "  Installing systemd service..."
    local service_src="$AGENT_DIR/qubes-kvm-agent.service"
    if [[ -f "$service_src" ]]; then
        sudo cp "$service_src" /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable qubes-kvm-agent
        sudo systemctl restart qubes-kvm-agent
        log "  Agent service: STARTED"
        log "  Status: sudo systemctl status qubes-kvm-agent"
        log "  Logs: journalctl -u qubes-kvm-agent -f"
    else
        warn "Service file not found: $service_src"
    fi

    local local_ip
    local_ip="$(ip -4 addr show scope global | grep -oP 'inet \K[\d.]+' | head -1 || echo 'localhost')"
    log ""
    log "  Agent API: http://$local_ip:8420"
    log "  Health:    http://$local_ip:8420/health"
    log "  Docs:      http://$local_ip:8420/docs"
}

# ── Step 8: Download test VM images ──────────────────────────────

setup_vm_images() {
    log "=== Step 8: Test VM Images ==="

    mkdir -p "$PROJECT_DIR/vm-images"
    cd "$PROJECT_DIR"

    local cloud_img="Fedora-Cloud-Base-42-1.1.x86_64.qcow2"
    local cloud_url="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/$cloud_img"

    if [[ ! -f "vm-images/$cloud_img" ]]; then
        log "  Downloading Fedora 42 cloud image..."
        wget -q --show-progress -O "vm-images/$cloud_img" "$cloud_url" || \
            warn "Download failed — download manually to vm-images/"
    else
        log "  Fedora cloud image: already present"
    fi

    if [[ -f "vm-images/$cloud_img" ]] && [[ ! -f "vm-images/test-fedora.qcow2" ]]; then
        log "  Creating test VM snapshot..."
        qemu-img create -f qcow2 -b "$cloud_img" -F qcow2 \
            "vm-images/test-fedora.qcow2" 40G
    fi

    if [[ ! -f "vm-images/ai-inference.qcow2" ]]; then
        log "  Creating AI inference VM disk (40G)..."
        qemu-img create -f qcow2 "vm-images/ai-inference.qcow2" 40G
    fi
}

# ── Check mode ───────────────────────────────────────────────────

run_check() {
    log "=== System Readiness Check ==="
    echo ""

    local pass=0 fail=0

    check_item() {
        if eval "$2" 2>/dev/null; then
            printf "  [PASS] %s\n" "$1"
            pass=$((pass + 1))
        else
            printf "  [FAIL] %s\n" "$1"
            fail=$((fail + 1))
        fi
    }

    check_item "/dev/kvm present" "test -e /dev/kvm"
    check_item "QEMU x86 installed" "command -v qemu-system-x86_64"
    check_item "QEMU ARM64 installed" "command -v qemu-system-aarch64"
    check_item "libvirtd running" "systemctl is-active libvirtd"
    check_item "sshd running" "systemctl is-active sshd"
    check_item "podman available" "command -v podman"
    check_item "gcc available" "command -v gcc"
    check_item "rust available" "command -v cargo"
    check_item "Python 3 available" "command -v python3 || command -v python"
    check_item "ShellCheck available" "command -v shellcheck"
    check_item "Nested virt enabled" "cat /sys/module/kvm_intel/parameters/nested 2>/dev/null | grep -q Y || cat /sys/module/kvm_amd/parameters/nested 2>/dev/null | grep -q 1"
    check_item "VFIO module loaded" "lsmod | grep -q vfio"
    check_item "Agent service running" "systemctl is-active qubes-kvm-agent 2>/dev/null"
    check_item "Agent API responding" "curl -sf http://localhost:8420/health"

    echo ""
    log "Results: $pass passed, $fail failed"
    [[ $fail -eq 0 ]] && log "System is fully ready." || warn "Some checks failed — see above."
}

# ── Main ─────────────────────────────────────────────────────────

main() {
    log "============================================"
    log " Lenovo T15 KVM Dev Setup (EndeavourOS)"
    log "============================================"
    log ""

    case "${1:-full}" in
        --check|check)
            run_check
            ;;
        --ssh|ssh)
            setup_ssh
            ;;
        --agent|agent)
            setup_agent
            ;;
        --iommu|iommu)
            setup_iommu
            ;;
        full|--full|"")
            check_hardware
            install_packages
            enable_kvm
            setup_iommu
            setup_ssh
            setup_podman
            setup_agent
            setup_vm_images
            log ""
            log "=== Setup Complete ==="
            log ""
            log "IMPORTANT: Log out and back in for group changes (kvm, libvirt)"
            log ""
            log "Next steps:"
            info "make setup        # Build container + clone repos"
            info "make info         # Verify capabilities"
            info "make build        # Build all components"
            info "make test         # Run all tests"
            info "make gpu-list     # Check GPU passthrough readiness"
            log ""
            log "Remote development:"
            info "From Qubes: bash scripts/connect-qubes-to-lenovo.sh"
            info "In Cursor:  Remote-SSH → lenovo-kvm"
            ;;
        *)
            echo "Usage: $PROGNAME [--full|--check|--ssh|--agent|--iommu]"
            ;;
    esac
}

main "$@"
