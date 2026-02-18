# Qubes KVM Fork — Build Status (2026-02-18)

## Build Pipeline: ALL GREEN

### Compilation
| Component | Status | Output |
|-----------|--------|--------|
| vchan-socket (libvchan-socket.so) | PASS | 0 warnings, 0 errors |
| vchan-simple (libvchan-socket-simple.so) | PASS | 0 warnings, 0 errors |
| qubesdb-config-inject | PASS | 0 warnings, 0 errors |
| qubesdb-config-read | PASS | 0 warnings, 0 errors |

### RPM Packages (5 total)
| Package | Arch | Size | Status |
|---------|------|------|--------|
| qubes-libvchan-socket-4.1.0 | x86_64 | 20K | BUILT |
| qubes-libvchan-socket-devel-4.1.0 | x86_64 | 9.1K | BUILT |
| qubes-qubesdb-kvm-dom0-4.3.0 | x86_64 | 11K | BUILT |
| qubes-qubesdb-kvm-vm-4.3.0 | x86_64 | 11K | BUILT |
| qubes-core-agent-kvm-4.3.0 | noarch | 19K | BUILT |

### Tests (54 total)
| Suite | Passed | Failed | Skipped |
|-------|--------|--------|---------|
| vchan-socket unit tests | 22 | 0 | 0 |
| vchan integration tests | 19 | 0 | 1 |
| ShellCheck lint | 4 | 0 | 0 |
| Bash syntax checks | 6 | 0 | 0 |
| RPM spec validation | 2 | 0 | 0 |
| **Total** | **53** | **0** | **1** |

---

## Fixes Applied in This Session

### 1. Removed `invtsc` CPU feature requirement
- **Files**: `setup-qubes-nested.sh`, `safe-setup.sh`
- **Why**: `invtsc` (invariant TSC) fails in nested KVM because the outer Xen hypervisor doesn't expose it. Removed from the libvirt XML override template.

### 2. Added `qubesdb-hotplug-watcher.sh` to agent RPM
- **Files**: `Makefile`, `qubes-agent-kvm.spec`
- **Why**: Tests and build scripts expected this file to be packaged, but it was missing from both the tarball assembly and the spec `%files` list. Also added its systemd service (`qubes-kvm-hotplug-watcher.service`).

### 3. Fixed `%{_unitdir}` macro resolution in RPM specs
- **Files**: `qubesdb-kvm.spec`, `qubes-agent-kvm.spec`
- **Why**: The `%{_unitdir}` macro wasn't expanding because `systemd-rpm-macros` wasn't loaded. Added `BuildRequires: systemd-rpm-macros` and a `%global` fallback to `/usr/lib/systemd/system`.

### 4. Fixed `make clean` to remove `rpmbuild/`
- **File**: `Makefile`
- **Why**: `clean` target only removed `rpms/` and `build-*`, leaving stale RPM artifacts in `rpmbuild/`.

### 5. Fixed changelog day-of-week in spec files
- **Files**: `qubesdb-kvm.spec`, `qubes-agent-kvm.spec`
- **Why**: Feb 18 2026 is a Wednesday, not Tuesday. Bogus dates cause rpmbuild warnings.

### 6. Added GPU/PCI passthrough support for AI inference VMs
- **File**: `xen-kvm-bridge.sh`
- **New commands**:
  - `gpu-define VM_NAME DISK PCI_ADDR[,PCI_ADDR2] [MEM] [VCPUS]` — defines a Xen-on-KVM domain with VFIO GPU passthrough
  - `gpu-list` — lists PCI devices suitable for passthrough
- **Features**:
  - Parses both `DDDD:BB:SS.F` and `BB:SS.F` PCI address formats
  - Generates `<hostdev>` with VFIO driver and correct BDF addresses
  - Warns if device is not bound to `vfio-pci`
  - Supports multiple comma-separated PCI devices
  - KVM hidden state for NVIDIA compatibility
  - ioapic driver=kvm for interrupt delivery

### 7. Added Makefile targets for GPU passthrough
- **File**: `Makefile`
- **New targets**:
  - `make gpu-list` — show available GPUs
  - `make gpu-define VM_NAME=ai DISK=... PCI=01:00.0` — define GPU VM

### 8. Added Phase 6 to safe-setup.sh (GPU/AI Inference)
- **File**: `safe-setup.sh`
- **New phase**: `phase6/gpu/ai` — installs AI inference dependencies (PyTorch, transformers, llama-cpp-python), creates AI VM disk, verifies GPU tools
- Help text updated with phase6 documentation

---

## Architecture Component Status

| Component | Location | Status |
|-----------|----------|--------|
| vchan-socket IPC | `qubes-core-vchan-socket/` | Complete, tested, RPM built |
| QubesDB KVM inject/read | `qubes-core-qubesdb/daemon/kvm/` | Complete, tested, RPM built |
| Hypervisor detection | `qubes-core-agent-linux/init/hypervisor.sh` | Complete, tested |
| Domain ID resolution | `qubes-core-agent-linux/init/qubes-domain-id.sh` | Complete, tested |
| KVM network routing | `qubes-core-agent-linux/network/vif-route-qubes-kvm` | Complete, tested |
| vhost-user bridge | `qubes-core-agent-linux/network/qubes-vhost-bridge.py` | Complete, tested |
| Hotplug watcher | `qubes-core-agent-linux/network/qubesdb-hotplug-watcher.sh` | Complete, packaged |
| Xen-on-KVM bridge | `qubes-kvm-fork/scripts/xen-kvm-bridge.sh` | Complete + GPU passthrough |
| GPU passthrough | `xen-kvm-bridge.sh gpu-define/gpu-list` | NEW — ready for testing |
| Libvirt KVM templates | `qubes-core-admin/templates/libvirt/kvm*.xml` | Complete (x86, ARM, PCI) |
| ARM64 crosvm launch | `qubes-kvm-fork/scripts/crosvm-launch-aarch64.sh` | Complete |
| Safe setup (6 phases) | `qubes-kvm-fork/scripts/safe-setup.sh` | Complete + Phase 6 |
| Build pipeline | `Makefile`, `build-all.sh`, `Containerfile.builder` | Complete, all targets pass |

## Next Steps for Live Testing

1. **On Qubes (nested)**: `bash scripts/safe-setup.sh phase6` to install AI tools inside `kvm-dev`
2. **On Lenovo (bare metal)**: Bind GPU to vfio-pci, then `make gpu-define VM_NAME=ai-inference DISK=... PCI=01:00.0`
3. **AI inference test**: Boot GPU VM, install model, run inference benchmark
4. **Full integration**: Deploy RPMs into a Xen-on-KVM guest, verify QubesDB + vchan + network + firewall chain
