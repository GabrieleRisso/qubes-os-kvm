# KVM Architecture Pipeline Results — 2026-02-18

## Environment
- **Host:** Qubes OS 4.3 (dom0), Intel Core Ultra 9 275HX
- **Build VM:** kvm-dev (Fedora 42 HVM, /dev/kvm enabled)
- **QEMU:** 9.2.4 (Fedora 42)
- **GCC:** 15.2.1 (x86-64 native + aarch64 cross-compiler)
- **libvirt:** running in kvm-dev

---

## Pipeline Results (all PASS)

### 1. Code Deployment
| Component | Status |
|---|---|
| qubes-core-vchan-socket | DEPLOYED |
| qubes-core-qubesdb/daemon/kvm | DEPLOYED |
| qubes-core-admin (Python + templates) | DEPLOYED |
| qubes-kvm-fork/scripts | DEPLOYED |

### 2. Tier 1: vchan-socket Build + Test
| Test | Result |
|---|---|
| vchan C library compile (-Wall -Wextra -Werror) | PASS |
| vchan-simple compile | PASS |
| Unit tests (22 tests) | 21 pass, 1 skip |
| Full test suite (42 tests via build-all.sh) | 41 pass, 1 skip |

### 3. Tier 1: QubesDB KVM Build
| Test | Result |
|---|---|
| qubesdb-config-inject compile (-Wall -Werror) | PASS |
| qubesdb-config-read compile (-Wall -Werror) | PASS |
| Binary type | x86-64 ELF, dynamically linked |

### 4. Tier 2: Xen HVM Emulation on KVM
| Test | Result |
|---|---|
| QEMU accel: kvm,xen-version=0x40013,kernel-irqchip=split | PASS |
| SeaBIOS boots with Xen CPUID masking | PASS |
| xen-vapic CPU flag | PASS |
| libvirt domain define (xen-kvm-bridge.sh) | PASS |
| libvirt domain start | PASS |
| xen-kvm-bridge.sh verify | VERIFIED |

### 5. Tier 3: ARM64 Cross-Compilation
| Test | Result |
|---|---|
| aarch64-linux-gnu-gcc available | PASS (GCC 15.2.1) |
| ARM64 freestanding binary compile | PASS |
| QEMU user-mode execution (qemu-aarch64-static) | PASS (ARM64_OK) |

### 6. Full Build Pipeline (build-all.sh)
| Metric | Value |
|---|---|
| Components built | 4/4 |
| Components failed | 0 |
| Python module syntax | VALID |
| Total test count | 42 |
| Tests passed | 41 |
| Tests skipped | 1 |
| **RESULT** | **ALL BUILDS SUCCEEDED** |

---

## Bugs Fixed During Pipeline Testing

### Fix 1: QEMU 9.x xen-evtchn/xen-gnttab flags
- **Problem:** `xen-evtchn=on,xen-gnttab=on` not valid in QEMU 9.2.4
- **Root cause:** These properties were merged into `xen-version` in QEMU 9.x
- **Fix:** Removed from xen-kvm-bridge.sh, vm-launch.sh, crosvm-launch-aarch64.sh, kvm-xenshim.xml, kvm-aarch64-xenshim.xml

### Fix 2: virtio-pci.ioeventfd=off not valid for balloon
- **Problem:** `-global virtio-pci.ioeventfd=off` failed on virtio-balloon-pci
- **Root cause:** Property not applicable to all virtio-pci subtypes in QEMU 9.x
- **Fix:** Removed the -global flag from xen-kvm-bridge.sh and kvm-xenshim.xml

### Fix 3: invtsc CPU feature in nested VM
- **Problem:** `<feature name="invtsc" policy="require"/>` fails in nested KVM
- **Root cause:** Host (Xen dom0) doesn't expose invariant TSC to HVM guests
- **Fix:** Removed invtsc requirement from xen-kvm-bridge.sh CPU section

### Fix 4: virsh undefine needs --nvram
- **Problem:** `virsh undefine` fails for domains with OVMF NVRAM
- **Fix:** Added `--nvram` fallback to undefine command in xen-kvm-bridge.sh

---

## Architecture Verification Summary

```
Qubes OS (dom0/Xen)
  └── kvm-dev (HVM with /dev/kvm)
       ├── vchan-socket library  ......... BUILT + TESTED
       ├── qubesdb-kvm tools  ............ BUILT
       ├── QEMU Xen HVM emulation  ...... VERIFIED (SeaBIOS boots)
       ├── libvirt Xen-on-KVM domain  ... DEFINE + START + VERIFY
       ├── ARM64 cross-compile  ......... WORKS
       ├── ARM64 QEMU user-mode  ........ WORKS
       └── build-all.sh pipeline  ....... 4/4 PASS, 0 FAIL
```

**Status: Architecture pipeline is operational end-to-end.**
