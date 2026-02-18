#!/bin/bash
# build-all.sh — Build patched Qubes components for KVM backend
# Runs inside the builder container
set -euo pipefail

REPOS_DIR="/repos"
PATCHES_DIR="/patches"
OUTPUT_DIR="/output"
BACKEND_VMM="kvm"

export BACKEND_VMM

log() { echo "[build] $*"; }

# Phase 1: Apply patches to repos
apply_patches() {
    log "Applying patches..."
    for pdir in "$PATCHES_DIR"/*/; do
        [[ -d "$pdir" ]] || continue
        component=$(basename "$pdir")
        repo_dir="$REPOS_DIR/$component"

        if [[ ! -d "$repo_dir" ]]; then
            log "  SKIP $component (repo not cloned)"
            continue
        fi

        patch_count=$(find "$pdir" -name "*.patch" 2>/dev/null | wc -l)
        if [[ "$patch_count" -eq 0 ]]; then
            log "  SKIP $component (no patches)"
            continue
        fi

        log "  $component: applying $patch_count patches..."
        cd "$repo_dir"

        # Create a branch for our patches
        git checkout -B kvm-fork 2>/dev/null || true

        for patch in "$pdir"*.patch; do
            patch_name=$(basename "$patch")
            if git am --check "$patch" 2>/dev/null; then
                git am "$patch"
                log "    OK: $patch_name"
            else
                log "    SKIP: $patch_name (already applied or conflict)"
            fi
        done
    done
}

# Phase 2: Build vchan-socket (the KVM communication layer)
build_vchan_socket() {
    local repo="$REPOS_DIR/qubes-core-vchan-socket"
    if [[ ! -d "$repo" ]]; then
        log "SKIP vchan-socket (not cloned)"
        return
    fi
    log "Building vchan-socket..."
    cd "$repo"
    make clean 2>/dev/null || true
    make
    log "  vchan-socket: OK"
}

# Phase 3: Build qrexec (RPC framework)
build_qrexec() {
    local repo="$REPOS_DIR/qubes-core-qrexec"
    if [[ ! -d "$repo" ]]; then
        log "SKIP qrexec (not cloned)"
        return
    fi
    log "Building qrexec..."
    cd "$repo"
    if [[ -f Makefile ]]; then
        make BACKEND_VMM=kvm 2>&1 | tail -5 || log "  qrexec: build issues (expected at this stage)"
    fi
}

# Phase 4: Build core-admin (VM management daemon)
build_core_admin() {
    local repo="$REPOS_DIR/qubes-core-admin"
    if [[ ! -d "$repo" ]]; then
        log "SKIP core-admin (not cloned)"
        return
    fi
    log "Building core-admin..."
    cd "$repo"
    python3 setup.py build 2>&1 | tail -5 || log "  core-admin: build issues (expected at this stage)"
}

# Phase 5: Build summary
build_summary() {
    log ""
    log "=== Build Summary ==="
    log "BACKEND_VMM: $BACKEND_VMM"
    log "Output: $OUTPUT_DIR/"

    local built=0
    local failed=0
    for repo_dir in "$REPOS_DIR"/*/; do
        [[ -d "$repo_dir" ]] || continue
        component=$(basename "$repo_dir")
        if git -C "$repo_dir" log --oneline -1 2>/dev/null | grep -q "kvm-fork\|KVM" ; then
            log "  PATCHED: $component"
            ((built++))
        else
            log "  STOCK:   $component"
        fi
    done
    log ""
    log "Patched: $built  |  Stock: $(($(ls -d "$REPOS_DIR"/*/ 2>/dev/null | wc -l) - built))"
}

# Main
log "=== qubes-kvm-fork build ==="
log "Backend VMM: $BACKEND_VMM"
log ""

apply_patches
build_vchan_socket
build_qrexec
build_core_admin
build_summary
