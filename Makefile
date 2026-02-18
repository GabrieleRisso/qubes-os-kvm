# qubes-kvm-fork — Development environment
# Works on: Qubes AppVM (TCG), Lenovo KVM laptop (KVM-accelerated)

SHELL         := /bin/bash
PROJECT       := qubes-kvm-fork
VERSION       := 0.1.0

# Auto-detect acceleration: KVM if /dev/kvm exists, else TCG (software)
ACCEL         := $(shell test -e /dev/kvm && echo kvm || echo tcg)
QEMU          := qemu-system-x86_64
CONTAINER_ENG := $(shell command -v podman 2>/dev/null || echo docker)
BUILD_IMAGE   := $(PROJECT)-builder
TEST_IMAGE    := $(PROJECT)-testvm

# VM defaults
VM_MEM        ?= 4096
VM_CPUS       ?= 2
VM_DISK_SIZE  ?= 20G

# Paths
BUILD_DIR     := build
PATCH_DIR     := patches
SCRIPT_DIR    := scripts
TEST_DIR      := test
VM_DIR        := vm-images
REPOS_DIR     := $(BUILD_DIR)/repos
RPMS_DIR      := $(BUILD_DIR)/rpms

# Upstream Qubes repos to fork/patch
QUBES_REPOS := \
	qubes-core-admin \
	qubes-core-agent-linux \
	qubes-core-qrexec \
	qubes-core-qubesdb \
	qubes-core-vchan-xen \
	qubes-core-vchan-socket \
	qubes-core-libvirt \
	qubes-gui-daemon \
	qubes-gui-agent-linux \
	qubes-linux-kernel \
	qubes-linux-utils \
	qubes-vmm-xen

.PHONY: help info setup clone build test test-vm clean nuke \
        builder-image test-image vm-create vm-start vm-ssh vm-stop \
        patch-status \
        qubes-setup qubes-deploy qubes-provision qubes-test qubes-xen-test \
        qubes-arm-test qubes-build qubes-sync qubes-status qubes-ssh

# ── Help ──────────────────────────────────────────────────────────

help:
	@echo "$(PROJECT) v$(VERSION)  [accel=$(ACCEL)]"
	@echo ""
	@echo "Setup:"
	@echo "  make setup           Full first-time setup (image + clone + build)"
	@echo "  make builder-image   Build the container build environment"
	@echo "  make clone           Clone all upstream Qubes repos"
	@echo "  make info            Show detected system capabilities"
	@echo ""
	@echo "Development:"
	@echo "  make build           Build all patched Qubes components"
	@echo "  make patch-status    Show patch application status"
	@echo "  make test            Run unit/integration tests in container"
	@echo ""
	@echo "VM Testing (ACCEL=$(ACCEL)):"
	@echo "  make vm-create       Create test VM disk image"
	@echo "  make vm-start        Boot test VM (Fedora with Qubes agents)"
	@echo "  make vm-ssh          SSH into running test VM"
	@echo "  make vm-stop         Shutdown test VM"
	@echo "  make test-vm         Full VM integration test cycle"
	@echo ""
	@echo "  VM_MEM=$(VM_MEM) VM_CPUS=$(VM_CPUS) VM_DISK_SIZE=$(VM_DISK_SIZE)"
	@echo ""
	@echo "Qubes-Native (from visyble, via qvm-remote):"
	@echo "  make qubes-setup     Create kvm-dev qube with nested KVM"
	@echo "  make qubes-deploy    Copy project into kvm-dev qube"
	@echo "  make qubes-provision Install dev tools inside kvm-dev"
	@echo "  make qubes-build     Build components inside kvm-dev"
	@echo "  make qubes-test      Run tests inside kvm-dev (has /dev/kvm)"
	@echo "  make qubes-xen-test  Run Xen-on-KVM PoC inside kvm-dev"
	@echo "  make qubes-arm-test  Run ARM64 tests inside kvm-dev"
	@echo "  make qubes-sync      Quick-sync source changes"
	@echo "  make qubes-status    Show kvm-dev state"
	@echo "  make qubes-ssh       Shell into kvm-dev"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean           Remove build artifacts"
	@echo "  make nuke            Remove everything including repos and images"

# ── Info ──────────────────────────────────────────────────────────

info:
	@echo "=== System Capabilities ==="
	@echo "KVM:        $(shell test -e /dev/kvm && echo 'YES (/dev/kvm present)' || echo 'NO (TCG software emulation)')"
	@echo "QEMU:       $(shell $(QEMU) --version 2>/dev/null | head -1 || echo 'NOT INSTALLED')"
	@echo "Container:  $(CONTAINER_ENG) $(shell $(CONTAINER_ENG) --version 2>/dev/null | grep -oP '[\d.]+')"
	@echo "Accel:      $(ACCEL)"
	@echo "Nested VMX: $(shell cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo 'N/A')"
	@echo "Arch:       $(shell uname -m)"
	@echo "Kernel:     $(shell uname -r)"
	@echo ""
	@echo "=== Estimated Test VM Performance ==="
	@if [ "$(ACCEL)" = "kvm" ]; then \
		echo "Mode:  KVM hardware-accelerated — FULL SPEED"; \
		echo "       Nested Xen + Qubes VMs will work"; \
		echo "       GPU passthrough testing possible"; \
	else \
		echo "Mode:  TCG software emulation — SLOW (~10-50x)"; \
		echo "       Good for: build verification, boot testing"; \
		echo "       Bad for:  nested VMs, performance testing"; \
		echo "       Tip: Use Lenovo laptop for Tier 2/3 testing"; \
	fi

# ── Container Build Environment ──────────────────────────────────

builder-image:
	$(CONTAINER_ENG) build -f Containerfile.builder -t $(BUILD_IMAGE) .
	@echo ""
	@echo "Builder image ready: $(BUILD_IMAGE)"

# ── Clone Upstream Repos ──────────────────────────────────────────

clone:
	@mkdir -p $(REPOS_DIR)
	@for repo in $(QUBES_REPOS); do \
		if [ -d "$(REPOS_DIR)/$$repo" ]; then \
			echo "$$repo: already cloned, pulling..."; \
			cd "$(REPOS_DIR)/$$repo" && git pull --ff-only 2>/dev/null || true; \
		else \
			echo "$$repo: cloning..."; \
			git clone --depth=1 "https://github.com/QubesOS/$$repo.git" \
				"$(REPOS_DIR)/$$repo"; \
		fi; \
	done
	@echo ""
	@echo "All repos cloned to $(REPOS_DIR)/"

# ── Build ─────────────────────────────────────────────────────────

build:
	@mkdir -p $(RPMS_DIR)
	$(CONTAINER_ENG) run --rm \
		-v $(CURDIR)/$(REPOS_DIR):/repos:Z \
		-v $(CURDIR)/$(PATCH_DIR):/patches:Z \
		-v $(CURDIR)/$(RPMS_DIR):/output:Z \
		-v $(CURDIR)/$(SCRIPT_DIR):/scripts:ro,Z \
		$(BUILD_IMAGE) \
		/scripts/build-all.sh
	@echo ""
	@echo "Build artifacts in $(RPMS_DIR)/"

# ── Tests ─────────────────────────────────────────────────────────

test:
	$(CONTAINER_ENG) run --rm \
		-v $(CURDIR):/workspace:Z \
		$(BUILD_IMAGE) \
		/workspace/$(TEST_DIR)/run-tests.sh

# ── VM Image Management ──────────────────────────────────────────

vm-create: $(VM_DIR)/test-fedora.qcow2

$(VM_DIR)/test-fedora.qcow2:
	@echo "Creating test VM disk ($(VM_DISK_SIZE))..."
	qemu-img create -f qcow2 $(VM_DIR)/test-fedora.qcow2 $(VM_DISK_SIZE)
	@echo ""
	@echo "Disk created. To install Fedora, run:"
	@echo "  make vm-install ISO=/path/to/Fedora-Server-42.iso"

vm-install:
	@test -n "$(ISO)" || (echo "Usage: make vm-install ISO=/path/to/fedora.iso" && exit 1)
	$(SCRIPT_DIR)/vm-launch.sh install \
		--accel $(ACCEL) \
		--mem $(VM_MEM) \
		--cpus $(VM_CPUS) \
		--disk $(VM_DIR)/test-fedora.qcow2 \
		--iso $(ISO)

vm-start:
	$(SCRIPT_DIR)/vm-launch.sh start \
		--accel $(ACCEL) \
		--mem $(VM_MEM) \
		--cpus $(VM_CPUS) \
		--disk $(VM_DIR)/test-fedora.qcow2

vm-ssh:
	ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-p 2222 user@localhost

vm-stop:
	@echo "Sending ACPI shutdown..."
	@pkill -f "qemu-system.*test-fedora" || echo "VM not running"

test-vm: vm-start
	@echo "Waiting for VM boot..."
	@$(SCRIPT_DIR)/wait-for-ssh.sh localhost 2222 120
	@echo "Running in-VM tests..."
	ssh -p 2222 -o StrictHostKeyChecking=no user@localhost \
		'bash -s' < $(TEST_DIR)/in-vm-tests.sh
	@echo "Tests complete. Shutting down..."
	$(MAKE) vm-stop

# ── Patch Management ─────────────────────────────────────────────

patch-status:
	@echo "=== Patch Status ==="
	@for pdir in $(PATCH_DIR)/*/; do \
		component=$$(basename "$$pdir"); \
		count=$$(ls "$$pdir"*.patch 2>/dev/null | wc -l); \
		echo "  $$component: $$count patches"; \
	done

# ── Full Setup ────────────────────────────────────────────────────

setup: builder-image clone
	@echo ""
	@echo "========================================="
	@echo " Setup complete!"
	@echo " Next: make build"
	@echo "========================================="

# ── Qubes-native nested workflow (run from visyble AppVM) ────────
# These targets manage the kvm-dev qube via qvm-remote.
# Everything runs INSIDE Qubes OS — no Lenovo needed.

qubes-setup:
	$(SCRIPT_DIR)/qubes-deploy.sh setup

qubes-deploy:
	$(SCRIPT_DIR)/qubes-deploy.sh deploy

qubes-provision:
	$(SCRIPT_DIR)/qubes-deploy.sh provision

qubes-build:
	$(SCRIPT_DIR)/qubes-deploy.sh build

qubes-test:
	$(SCRIPT_DIR)/qubes-deploy.sh test

qubes-xen-test:
	$(SCRIPT_DIR)/qubes-deploy.sh xen-test

qubes-arm-test:
	$(SCRIPT_DIR)/qubes-deploy.sh arm-test

qubes-sync:
	$(SCRIPT_DIR)/qubes-deploy.sh sync

qubes-status:
	$(SCRIPT_DIR)/qubes-deploy.sh status

qubes-ssh:
	$(SCRIPT_DIR)/qubes-deploy.sh ssh

# ── Cleanup ───────────────────────────────────────────────────────

clean:
	rm -rf $(BUILD_DIR)/rpms $(BUILD_DIR)/build-*

nuke:
	rm -rf $(BUILD_DIR) $(VM_DIR)/*.qcow2
	-$(CONTAINER_ENG) rmi $(BUILD_IMAGE) $(TEST_IMAGE) 2>/dev/null
