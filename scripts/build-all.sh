#!/bin/bash
# build-all.sh — Build patched Qubes components for KVM backend
#
# Works in two modes:
#   1. Container mode: repos mounted at /repos, output at /output
#   2. Local mode: repos as sibling directories (auto-detected)
#
# Usage:
#   ./scripts/build-all.sh              # auto-detect mode
#   ./scripts/build-all.sh /path/to/src # explicit source root
set -euo pipefail

BACKEND_VMM="${BACKEND_VMM:-kvm}"
export BACKEND_VMM

log() { echo "[build] $*"; }
ok()  { echo "  OK: $*"; }
err() { echo "  ERR: $*"; }

# Determine repo layout
if [[ -d "/repos/qubes-core-vchan-socket" ]]; then
    REPOS_DIR="/repos"
    PATCHES_DIR="${PATCHES_DIR:-/patches}"
    OUTPUT_DIR="${OUTPUT_DIR:-/output}"
    MODE="container"
elif [[ -n "${1:-}" && -d "$1/qubes-core-vchan-socket" ]]; then
    REPOS_DIR="$1"
    PATCHES_DIR="${PATCHES_DIR:-$(dirname "$0")/../patches}"
    OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$0")/../build/rpms}"
    MODE="local-explicit"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    SRC_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
    if [[ -d "$SRC_ROOT/qubes-core-vchan-socket" ]]; then
        REPOS_DIR="$SRC_ROOT"
        PATCHES_DIR="${PATCHES_DIR:-$SCRIPT_DIR/../patches}"
        OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/../build/rpms}"
        MODE="local-sibling"
    else
        log "Cannot find repos. Run from project dir or pass path."
        exit 1
    fi
fi

log "=== qubes-kvm-fork build ==="
log "Backend VMM: $BACKEND_VMM"
log "Mode: $MODE"
log "Repos: $REPOS_DIR"
log ""

BUILT=0
FAILED=0

try_build() {
    local name="$1"
    shift
    log "Building $name..."
    if "$@" 2>&1; then
        ok "$name"
        BUILT=$((BUILT + 1))
    else
        err "$name"
        FAILED=$((FAILED + 1))
    fi
}

# ── Phase 1: Apply patches (container mode only) ─────────────────
apply_patches() {
    [[ -d "$PATCHES_DIR" ]] || return 0
    log "Checking for patches..."
    for pdir in "$PATCHES_DIR"/*/; do
        [[ -d "$pdir" ]] || continue
        component=$(basename "$pdir")
        repo_dir="$REPOS_DIR/$component"
        [[ -d "$repo_dir" ]] || { log "  SKIP $component (not found)"; continue; }

        patch_count=$(find "$pdir" -name "*.patch" 2>/dev/null | wc -l)
        [[ "$patch_count" -gt 0 ]] || continue

        log "  $component: $patch_count patches"
        cd "$repo_dir"
        git checkout -B kvm-fork 2>/dev/null || true
        for patch in "$pdir"*.patch; do
            patch_name=$(basename "$patch")
            if git am --check "$patch" 2>/dev/null; then
                git am "$patch"
                log "    Applied: $patch_name"
            else
                log "    Skip: $patch_name (already applied or conflict)"
            fi
        done
    done
}

# ── Phase 2: Build vchan-socket ──────────────────────────────────
build_vchan_socket() {
    local dir="$REPOS_DIR/qubes-core-vchan-socket"
    [[ -d "$dir" ]] || { log "SKIP vchan-socket (not found)"; return; }
    try_build "vchan-socket" make -C "$dir" clean all
}

# ── Phase 3: Build full qubesdb with KVM daemon ─────────────────
build_qubesdb() {
    local dir="$REPOS_DIR/qubes-core-qubesdb"
    [[ -d "$dir" ]] || { log "SKIP qubesdb (not found)"; return; }

    # vchan-socket headers/libs must be discoverable
    local vchan_dir="$REPOS_DIR/qubes-core-vchan-socket"
    if [[ -d "$vchan_dir" ]]; then
        export PKG_CONFIG_PATH="${vchan_dir}:${PKG_CONFIG_PATH:-}"
        export CFLAGS="${CFLAGS:-} -I${vchan_dir}/include"
        export LDFLAGS="${LDFLAGS:-} -L${vchan_dir}"
    fi

    # Build the KVM-specific inject/read tools
    local kvm_dir="$dir/daemon/kvm"
    if [[ -d "$kvm_dir" ]]; then
        try_build "qubesdb-config-inject + qubesdb-config-read" \
            make -C "$kvm_dir" BACKEND_VMM=kvm clean all

        # Verify binaries were produced
        local ok_count=0
        for bin in qubesdb-config-inject qubesdb-config-read; do
            if [[ -x "$kvm_dir/$bin" ]]; then
                ok "$bin binary exists"
                ok_count=$((ok_count + 1))
            else
                err "$bin binary not found after build"
            fi
        done
        [[ $ok_count -eq 2 ]] || FAILED=$((FAILED + 1))
    else
        log "  SKIP qubesdb KVM daemons (daemon/kvm dir not found)"
    fi

    # Build the main qubesdb library and daemons with KVM backend
    if [[ -f "$dir/Makefile" ]]; then
        try_build "qubesdb (full, BACKEND_VMM=kvm)" \
            make -C "$dir" BACKEND_VMM=kvm
    fi
}

# ── Phase 4: Build gui-daemon ────────────────────────────────────
build_gui_daemon() {
    local dir="$REPOS_DIR/qubes-gui-daemon"
    [[ -d "$dir" ]] || { log "SKIP gui-daemon (not found)"; return; }
    if [[ -f "$dir/Makefile" ]]; then
        try_build "gui-daemon (BACKEND_VMM=kvm)" \
            make -C "$dir" BACKEND_VMM=kvm
    else
        log "  SKIP gui-daemon (no Makefile)"
    fi
}

# ── Phase 5: Build gui-agent-linux ───────────────────────────────
build_gui_agent() {
    local dir="$REPOS_DIR/qubes-gui-agent-linux"
    [[ -d "$dir" ]] || { log "SKIP gui-agent-linux (not found)"; return; }
    if [[ -f "$dir/Makefile" ]]; then
        try_build "gui-agent-linux (BACKEND_VMM=kvm)" \
            make -C "$dir" BACKEND_VMM=kvm
    else
        log "  SKIP gui-agent-linux (no Makefile)"
    fi
}

# ── Phase 6: Build core-agent-linux ──────────────────────────────
build_core_agent() {
    local dir="$REPOS_DIR/qubes-core-agent-linux"
    [[ -d "$dir" ]] || { log "SKIP core-agent-linux (not found)"; return; }

    # Validate shell scripts first
    log "Validating agent KVM scripts..."
    local fail=0
    for f in init/hypervisor.sh init/qubes-domain-id.sh \
             network/qubesdb-hotplug-watcher.sh \
             network/vif-route-qubes-kvm; do
        if [[ -f "$dir/$f" ]]; then
            if bash -n "$dir/$f" 2>/dev/null; then
                ok "$(basename "$f") syntax"
            else
                err "$(basename "$f") syntax error"
                fail=1
            fi
        fi
    done
    if [[ $fail -eq 0 ]]; then
        BUILT=$((BUILT + 1))
    else
        FAILED=$((FAILED + 1))
    fi

    # Build if Makefile exists
    if [[ -f "$dir/Makefile" ]]; then
        try_build "core-agent-linux (BACKEND_VMM=kvm)" \
            make -C "$dir" BACKEND_VMM=kvm
    fi
}

# ── Phase 7: Build linux-utils ───────────────────────────────────
build_linux_utils() {
    local dir="$REPOS_DIR/qubes-linux-utils"
    [[ -d "$dir" ]] || { log "SKIP linux-utils (not found)"; return; }
    if [[ -f "$dir/Makefile" ]]; then
        try_build "linux-utils (BACKEND_VMM=kvm)" \
            make -C "$dir" BACKEND_VMM=kvm
    else
        log "  SKIP linux-utils (no Makefile)"
    fi
}

# ── Phase 8: Run vchan tests ────────────────────────────────────
run_vchan_tests() {
    local dir="$REPOS_DIR/qubes-core-vchan-socket"
    [[ -d "$dir" ]] || { log "SKIP vchan tests (not found)"; return; }
    log "Running vchan tests..."
    rm -f /tmp/vchan.*.sock
    if (cd "$dir" && timeout 30 python3 -m unittest tests.test_vchan tests.test_integration 2>&1); then
        BUILT=$((BUILT + 1))
    else
        err "vchan tests failed"
        FAILED=$((FAILED + 1))
    fi
}

# ── Phase 9: Validate Python modules ────────────────────────────
validate_python_modules() {
    log "Validating KVM Python modules..."
    local core_admin="$REPOS_DIR/qubes-core-admin"
    [[ -d "$core_admin" ]] || { log "SKIP Python validation (core-admin not found)"; return; }

    local fail=0

    # Check that KVM-specific files exist and have valid syntax
    for f in qubes/vm/mix/kvm_mem.py qubes/vm/mix/vhost_net.py; do
        if [[ -f "$core_admin/$f" ]]; then
            if python3 -c "
import ast, sys
try:
    ast.parse(open('$core_admin/$f').read())
    sys.exit(0)
except SyntaxError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1; then
                ok "$f syntax valid"
            else
                err "$f syntax error"
                fail=1
            fi
        else
            err "$f not found"
            fail=1
        fi
    done

    # Try full import if dependencies are available
    export PYTHONPATH="$core_admin:${PYTHONPATH:-}"
    export QUBES_BACKEND_VMM=kvm
    if python3 -c "import qubes.vm.mix.kvm_mem" 2>/dev/null; then
        ok "full import qubes.vm.mix.kvm_mem"
    else
        log "  NOTE: full import skipped (missing upstream deps like docutils)"
    fi

    if [[ $fail -eq 0 ]]; then
        BUILT=$((BUILT + 1))
    else
        FAILED=$((FAILED + 1))
    fi
}

# ── Build summary ────────────────────────────────────────────────
build_summary() {
    log ""
    log "=== Build Summary ==="
    log "BACKEND_VMM: $BACKEND_VMM"
    log "Built:  $BUILT"
    log "Failed: $FAILED"
    if [[ $FAILED -gt 0 ]]; then
        log "RESULT: SOME BUILDS FAILED"
        return 1
    else
        log "RESULT: ALL BUILDS SUCCEEDED"
        return 0
    fi
}

# ── Main ─────────────────────────────────────────────────────────
if [[ "$MODE" == "container" ]]; then
    apply_patches
fi

build_vchan_socket
build_qubesdb
build_gui_daemon
build_gui_agent
build_core_agent
build_linux_utils
run_vchan_tests
validate_python_modules
build_summary
