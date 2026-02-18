# qubes-kvm-fork

A fork of Qubes OS 4.3 that runs on KVM instead of bare-metal Xen,
using QEMU's Xen HVM emulation layer to maintain full compatibility
with existing Qubes components.

## Architecture

```
Hardware (Intel/AMD x86_64, ARM64 Snapdragon)
  └─ KVM (Linux kernel — full hardware support)
       ├─ Security VMs: QEMU + Xen shim (qubes agents think they're on Xen)
       │    ├─ dom0 (management, killswitch)
       │    ├─ sys-net (VFIO WiFi passthrough)
       │    ├─ sys-firewall
       │    └─ AppVMs (personal, work, etc.)
       └─ Hardware VMs: plain KVM (VFIO GPU passthrough, USB, etc.)
```

**Key insight:** QEMU already emulates Xen hypercalls, event channels, and
PV devices (`--accel kvm,xen-version=0x40013,kernel-irqchip=split`).
Qubes components see Xen; the host runs KVM.

## Development Environment: All-on-Qubes

The primary workflow runs **entirely on the Qubes OS laptop** using
Xen nested HVM. The Lenovo is only needed at the end for bare-metal
KVM live USB testing.

### Architecture

```
Qubes OS laptop (Xen, bare metal)
├── visyble (AppVM) ─── you code here, run make commands
│     └── qvm-remote ─── controls dom0 and kvm-dev
├── kvm-dev (StandaloneVM, HVM + nested virt)
│     ├── /dev/kvm ─── FULL KVM acceleration
│     ├── QEMU + Xen shim ─── Tier 2 testing
│     ├── Podman ─── Tier 1 container builds
│     └── ARM64 tools ─── Tier 3 cross-compilation
└── dom0 ─── manages everything via Xen
```

### Three qubes, three roles

| Qube | Role | Has KVM? |
|------|------|:--------:|
| **visyble** (AppVM) | Edit code, manage builds via `make qubes-*` | No |
| **kvm-dev** (StandaloneVM) | Full test environment, runs nested VMs | **Yes** |
| **dom0** | Manages qubes, Xen config | N/A |

### What runs where

| Task                           | visyble | kvm-dev | Lenovo |
|--------------------------------|:-------:|:-------:|:------:|
| Edit source code               |    x    |         |        |
| Container builds (podman)      |    x    |    x    |        |
| Unit tests / linting           |    x    |    x    |        |
| Xen-on-KVM PoC                 |         |    x    |        |
| Nested VM testing              |         |    x    |        |
| ARM64 cross-compile            |    x    |    x    |        |
| ARM64 system VM                |         |    x    |        |
| GPU passthrough (VFIO)         |         |  maybe  |   x    |
| Final live USB product test    |         |         |   x    |

## Quick Start (All-on-Qubes)

### One-time setup (from visyble)

```bash
cd ~/fix/qubes-kvm-fork/

# Step 1: Create kvm-dev qube with nested HVM
make qubes-setup
# → If it says "REBOOT REQUIRED", reboot dom0, then continue

# Step 2: Copy project into kvm-dev
make qubes-deploy

# Step 3: Install all dev tools inside kvm-dev
make qubes-provision

# Step 4: Verify everything works
make qubes-status
make qubes-test
```

### Daily development workflow

```bash
# Edit code in visyble (your normal editor/IDE)
vim patches/qubes-core-admin/01-kvm-backend.patch

# Sync changes to kvm-dev
make qubes-sync

# Build inside kvm-dev (has KVM, full toolchain)
make qubes-build

# Run tests (including KVM-accelerated VM tests)
make qubes-test

# Run the Xen-on-KVM proof of concept
make qubes-xen-test

# Run ARM64 cross-compilation tests
make qubes-arm-test

# Open a shell inside kvm-dev for debugging
make qubes-ssh
```

### Lenovo (final product only)

```bash
# Only at the end: test the live USB on bare metal KVM
bash scripts/setup-lenovo.sh
# Install the final product and validate on real hardware
```

## Project Structure

```
qubes-kvm-fork/
├── Makefile                     # All build/test/VM commands
├── Containerfile.builder        # Fedora 41 build environment
├── README.md
│
├── build/
│   ├── repos/                   # Cloned upstream Qubes repos
│   └── rpms/                    # Built RPM packages
│
├── patches/                     # Our patches, per component
│   ├── qubes-core-admin/        #   VM lifecycle → libvirt+KVM
│   ├── qubes-core-qrexec/       #   RPC → vchan-socket
│   ├── qubes-core-qubesdb/      #   Config store → socket-based
│   ├── qubes-gui-daemon/        #   GUI → virtio-gpu
│   └── ...
│
├── configs/
│   ├── xen-on-kvm-test.sh       # CORE: Xen emulation on KVM
│   ├── kvm-gpu-passthrough-test.sh  # NVIDIA GPU via VFIO
│   └── arm64-cross-test.sh      # ARM64 toolchain tests
│
├── scripts/
│   ├── setup-qubes-vm.sh        # First-time setup (Qubes laptop)
│   ├── setup-lenovo.sh          # First-time setup (Lenovo laptop)
│   ├── vm-launch.sh             # QEMU VM launcher (TCG/KVM auto)
│   ├── build-all.sh             # Container build script
│   └── wait-for-ssh.sh          # SSH wait helper
│
├── test/
│   ├── run-tests.sh             # Host-side test suite
│   └── in-vm-tests.sh           # Guest-side integration tests
│
└── vm-images/                   # QEMU disk images (gitignored)
```

## Tier Roadmap

### Tier 1: KVM Xen Shim (Months 1-4)
- vchan-socket as default IPC
- QEMU Xen HVM emulation for guest compatibility
- libvirt KVM backend for VM lifecycle
- qubesdb over sockets (replace xenstore)

### Tier 2: Hardware VMs (Months 2-5)
- NVIDIA GPU passthrough via VFIO
- USB passthrough for sys-usb
- WiFi via VFIO to sys-net
- Killswitch daemon in dom0

### Tier 3: ARM64/Snapdragon (Months 4-10)
- Cross-compilation toolchain
- ARM64 Qubes templates
- KVM on Snapdragon X2 Elite
- crosvm as VMM for ARM

## Key Technologies

- **QEMU Xen HVM emulation** — `qemu.org/docs/master/system/i386/xen.html`
- **qubes-core-vchan-socket** — `github.com/QubesOS/qubes-core-vchan-socket`
- **fepitre's KVM PRs** — `github.com/QubesOS/qubes-issues/issues/7051`
- **Spectrum OS (crosvm)** — `spectrum-os.org`
- **VFIO GPU passthrough** — `kernel.org/doc/Documentation/virt/kvm/`

## License

GPLv2+ (following Qubes OS licensing)
