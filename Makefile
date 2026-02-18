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

# Local repos: check sibling dirs first, fall back to build/repos (after clone)
SRC_ROOT      := $(realpath $(dir $(CURDIR)))
_sibling_or_clone = $(if $(wildcard $(SRC_ROOT)/$(1)),$(SRC_ROOT)/$(1),$(CURDIR)/$(REPOS_DIR)/$(1))
VCHAN_DIR     := $(call _sibling_or_clone,qubes-core-vchan-socket)
QUBESDB_DIR   := $(call _sibling_or_clone,qubes-core-qubesdb)
AGENT_DIR     := $(call _sibling_or_clone,qubes-core-agent-linux)
ADMIN_DIR     := $(call _sibling_or_clone,qubes-core-admin)
BUILDERV2_DIR := $(call _sibling_or_clone,qubes-builderv2)
BACKEND_VMM   := kvm

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

.PHONY: help info setup clone build build-vchan build-qubesdb-kvm build-container \
        test test-vchan test-shellcheck test-agent-syntax test-specs test-container test-vm \
        clean nuke rpm rpm-vchan builder-image \
        vm-create vm-install vm-start vm-ssh vm-stop \
        patch-status \
        qubes-setup qubes-deploy qubes-provision qubes-test qubes-xen-test \
        qubes-arm-test qubes-build qubes-sync qubes-status qubes-ssh \
        xen-bridge-list xen-bridge-define xen-bridge-start \
        probe probe-all probe-p0 probe-p1 probe-p2 probe-p3 probe-p4

# ── Help ──────────────────────────────────────────────────────────

help:
	@echo "$(PROJECT) v$(VERSION)  [accel=$(ACCEL), vmm=$(BACKEND_VMM)]"
	@echo ""
	@echo "Setup:"
	@echo "  make setup           Full first-time setup (image + clone + build)"
	@echo "  make builder-image   Build the container build environment"
	@echo "  make clone           Clone all upstream Qubes repos"
	@echo "  make info            Show detected system capabilities"
	@echo ""
	@echo "Development (local):"
	@echo "  make build           Build KVM components from local repos"
	@echo "  make test            Run all tests (vchan, shellcheck, specs)"
	@echo "  make rpm             Build an RPM from vchan-socket spec"
	@echo "  make patch-status    Show patch application status"
	@echo ""
	@echo "Development (container):"
	@echo "  make build-container Build all in builder container"
	@echo "  make test-container  Run tests in builder container"
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

# ── Build (local — uses sibling repos) ────────────────────────────

build: build-vchan build-qubesdb-kvm
	@echo ""
	@echo "=== Build complete (BACKEND_VMM=$(BACKEND_VMM)) ==="

build-vchan:
	@echo "=== Building vchan-socket ==="
	$(MAKE) -C $(VCHAN_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(VCHAN_DIR) all

build-qubesdb-kvm:
	@echo "=== Building qubesdb KVM config tools ==="
	$(MAKE) -C $(QUBESDB_DIR)/daemon/kvm clean 2>/dev/null || true
	$(MAKE) -C $(QUBESDB_DIR)/daemon/kvm all

# ── Build (container) ─────────────────────────────────────────────

build-container:
	@mkdir -p $(RPMS_DIR)
	$(CONTAINER_ENG) run --rm --userns=keep-id \
		-v $(SRC_ROOT):/repos:Z \
		-v $(CURDIR)/$(PATCH_DIR):/patches:Z \
		-v $(CURDIR)/$(RPMS_DIR):/output:Z \
		-v $(CURDIR)/$(SCRIPT_DIR):/scripts:ro,Z \
		$(BUILD_IMAGE) \
		/scripts/build-all.sh
	@echo ""
	@echo "Build artifacts in $(RPMS_DIR)/"

# ── Tests ─────────────────────────────────────────────────────────

test: test-vchan test-shellcheck test-agent-syntax test-specs
	@echo ""
	@echo "=== All tests passed ==="

test-vchan:
	@echo "=== vchan-socket unit tests ==="
	rm -f /tmp/vchan.*.sock
	cd $(VCHAN_DIR) && python3 -m unittest tests.test_vchan tests.test_integration -v
	@echo ""

test-shellcheck:
	@echo "=== ShellCheck on KVM agent scripts ==="
	@PASS=0; FAIL=0; \
	for f in $(AGENT_DIR)/init/hypervisor.sh \
	         $(AGENT_DIR)/init/qubes-domain-id.sh \
	         $(AGENT_DIR)/network/qubesdb-hotplug-watcher.sh \
	         $(AGENT_DIR)/network/vif-route-qubes-kvm; do \
		if [ -f "$$f" ]; then \
			if shellcheck -S warning "$$f" 2>/dev/null; then \
				echo "  [PASS] $$(basename $$f)"; PASS=$$((PASS + 1)); \
			else \
				echo "  [FAIL] $$(basename $$f)"; FAIL=$$((FAIL + 1)); \
			fi; \
		fi; \
	done; \
	echo "  ShellCheck: $$PASS passed, $$FAIL failed"; \
	[ "$$FAIL" -eq 0 ]

test-agent-syntax:
	@echo "=== Agent script syntax check ==="
	@PASS=0; FAIL=0; \
	for f in $(AGENT_DIR)/init/hypervisor.sh \
	         $(AGENT_DIR)/init/qubes-domain-id.sh \
	         $(AGENT_DIR)/network/qubesdb-hotplug-watcher.sh \
	         $(AGENT_DIR)/network/vif-route-qubes-kvm \
	         $(AGENT_DIR)/vm-systemd/qubes-sysinit.sh \
	         $(AGENT_DIR)/vm-systemd/network-proxy-setup.sh; do \
		if [ -f "$$f" ]; then \
			if bash -n "$$f" 2>/dev/null; then \
				echo "  [PASS] $$(basename $$f)"; PASS=$$((PASS + 1)); \
			else \
				echo "  [FAIL] $$(basename $$f)"; FAIL=$$((FAIL + 1)); \
			fi; \
		fi; \
	done; \
	echo "  Syntax: $$PASS passed, $$FAIL failed"; \
	[ "$$FAIL" -eq 0 ]

test-specs:
	@echo "=== RPM spec macro validation ==="
	@echo "  Testing backend_vmm=kvm macro propagation..."
	@rpm --define 'backend_vmm kvm' --eval '%{?backend_vmm}' | grep -q kvm \
		&& echo "  [PASS] backend_vmm=kvm resolves correctly" \
		|| (echo "  [FAIL] backend_vmm macro broken" && exit 1)
	@echo "  Testing conditional spec syntax..."
	@for spec in $(VCHAN_DIR)/rpm_spec/libvchan-socket.spec.in \
	             $(AGENT_DIR)/rpm_spec/core-agent.spec.in; do \
		if [ -f "$$spec" ]; then \
			echo "  [PASS] $$(basename $$spec) exists"; \
		fi; \
	done

test-container:
	$(CONTAINER_ENG) run --rm --userns=keep-id \
		-v $(CURDIR):/workspace:Z \
		$(BUILD_IMAGE) \
		/workspace/$(TEST_DIR)/run-tests.sh

# ── RPM ───────────────────────────────────────────────────────────

VCHAN_VERSION := $(shell cat $(VCHAN_DIR)/version 2>/dev/null || echo 4.3.0)

rpm: rpm-vchan
	@echo "RPM artifacts in $(BUILD_DIR)/rpmbuild/RPMS/"

rpm-vchan: build-vchan
	@mkdir -p $(BUILD_DIR)/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
	@echo "=== Preparing vchan-socket tarball ==="
	@rm -rf /tmp/qubes-libvchan-socket-$(VCHAN_VERSION)
	@mkdir -p /tmp/qubes-libvchan-socket-$(VCHAN_VERSION)
	@cp -a $(VCHAN_DIR)/Makefile $(VCHAN_DIR)/vchan $(VCHAN_DIR)/vchan-simple \
		$(VCHAN_DIR)/version \
		/tmp/qubes-libvchan-socket-$(VCHAN_VERSION)/
	@tar czf $(BUILD_DIR)/rpmbuild/SOURCES/qubes-libvchan-socket-$(VCHAN_VERSION).tar.gz \
		-C /tmp qubes-libvchan-socket-$(VCHAN_VERSION)
	@rm -rf /tmp/qubes-libvchan-socket-$(VCHAN_VERSION)
	@echo "=== Processing spec template ==="
	@sed -e 's/@VERSION@/$(VCHAN_VERSION)/g' \
	     -e 's/@CHANGELOG@/* $(shell date "+%a %b %d %Y") Builder - $(VCHAN_VERSION)-1\n- KVM vchan-socket build/g' \
	     $(VCHAN_DIR)/rpm_spec/libvchan-socket.spec.in \
	     > $(BUILD_DIR)/rpmbuild/SPECS/libvchan-socket.spec
	@echo "=== Building RPM ==="
	rpmbuild -bb \
		--define "_topdir $(CURDIR)/$(BUILD_DIR)/rpmbuild" \
		--define "backend_vmm kvm" \
		$(BUILD_DIR)/rpmbuild/SPECS/libvchan-socket.spec

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

# ── Probe targets (run inside kvm-dev or any build host) ─────────
# These are fast, local, no-network validation probes.

probe: probe-all

probe-all:
	bash $(TEST_DIR)/granular-probes.sh all

probe-p0:
	bash $(TEST_DIR)/granular-probes.sh p0

probe-p1:
	bash $(TEST_DIR)/granular-probes.sh p1

probe-p2:
	bash $(TEST_DIR)/granular-probes.sh p2

probe-p3:
	bash $(TEST_DIR)/granular-probes.sh p3

probe-p4:
	bash $(TEST_DIR)/granular-probes.sh p4

qubes-sync:
	$(SCRIPT_DIR)/qubes-deploy.sh sync

qubes-status:
	$(SCRIPT_DIR)/qubes-deploy.sh status

qubes-ssh:
	$(SCRIPT_DIR)/qubes-deploy.sh ssh

# ── Xen-KVM Bridge (libvirt management of Xen-emulated VMs) ──────

xen-bridge-list:
	$(SCRIPT_DIR)/xen-kvm-bridge.sh list

xen-bridge-define:
	@test -n "$(VM_NAME)" || (echo "Usage: make xen-bridge-define VM_NAME=myvm DISK=/path/to/disk" && exit 1)
	@test -n "$(DISK)" || (echo "Usage: make xen-bridge-define VM_NAME=myvm DISK=/path/to/disk" && exit 1)
	$(SCRIPT_DIR)/xen-kvm-bridge.sh define $(VM_NAME) $(DISK) $(VM_MEM) $(VM_CPUS)

xen-bridge-start:
	@test -n "$(VM_NAME)" || (echo "Usage: make xen-bridge-start VM_NAME=myvm" && exit 1)
	$(SCRIPT_DIR)/xen-kvm-bridge.sh start $(VM_NAME)

# ── Cleanup ───────────────────────────────────────────────────────

clean:
	rm -rf $(BUILD_DIR)/rpms $(BUILD_DIR)/build-*

nuke:
	rm -rf $(BUILD_DIR) $(VM_DIR)/*.qcow2
	-$(CONTAINER_ENG) rmi $(BUILD_IMAGE) $(TEST_IMAGE) 2>/dev/null
