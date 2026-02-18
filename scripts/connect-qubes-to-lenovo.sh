#!/bin/bash
# connect-qubes-to-lenovo.sh — Set up SSH + port forwarding from Qubes to Lenovo
#
# Run this from the visyble AppVM in Qubes OS. It:
#   1. Configures ~/.ssh/config for the Lenovo host
#   2. Tests SSH connectivity
#   3. Forwards the agent API port (8420) to localhost
#   4. Sets up Cursor Remote-SSH workspace
#
# Usage:
#   bash scripts/connect-qubes-to-lenovo.sh setup LENOVO_IP
#   bash scripts/connect-qubes-to-lenovo.sh test
#   bash scripts/connect-qubes-to-lenovo.sh tunnel
#   bash scripts/connect-qubes-to-lenovo.sh deploy
#   bash scripts/connect-qubes-to-lenovo.sh status
set -euo pipefail

readonly PROGNAME="connect-lenovo"
readonly SSH_HOST="lenovo-kvm"
readonly AGENT_PORT=8420
readonly CONFIG_FILE="$HOME/.qubes-kvm-lenovo.conf"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly PROJECT_DIR

log()  { echo "[$PROGNAME] $*"; }
info() { echo "[$PROGNAME]   $*"; }
warn() { echo "[$PROGNAME] WARNING: $*"; }
err()  { echo "[$PROGNAME] ERROR: $*" >&2; }

# ── Setup ────────────────────────────────────────────────────────

cmd_setup() {
    local lenovo_ip="${1:?Usage: $0 setup LENOVO_IP [USER]}"
    local lenovo_user="${2:-user}"

    log "=== Setting up connection to Lenovo ==="
    info "IP: $lenovo_ip"
    info "User: $lenovo_user"

    echo "LENOVO_IP=$lenovo_ip" > "$CONFIG_FILE"
    echo "LENOVO_USER=$lenovo_user" >> "$CONFIG_FILE"

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    if [[ ! -f ~/.ssh/id_ed25519 ]]; then
        log "  Generating SSH key..."
        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "qubes-visyble-to-lenovo"
    fi

    local ssh_config="$HOME/.ssh/config"
    if grep -q "Host $SSH_HOST" "$ssh_config" 2>/dev/null; then
        log "  SSH config: $SSH_HOST already exists, updating..."
        local tmpf
        tmpf="$(mktemp)"
        awk -v host="$SSH_HOST" '
            /^Host / { if ($2 == host) skip=1; else skip=0 }
            !skip { print }
        ' "$ssh_config" > "$tmpf"
        mv "$tmpf" "$ssh_config"
    fi

    cat >> "$ssh_config" << EOF

Host $SSH_HOST
    HostName $lenovo_ip
    User $lenovo_user
    Port 22
    ForwardAgent yes
    ServerAliveInterval 30
    ServerAliveCountMax 5
    LocalForward $AGENT_PORT 127.0.0.1:$AGENT_PORT
    StrictHostKeyChecking accept-new
EOF

    chmod 600 "$ssh_config"
    log "  SSH config: written to $ssh_config"

    log ""
    log "  Now copy your SSH key to the Lenovo:"
    info "ssh-copy-id $SSH_HOST"
    log ""
    log "  Then test with:"
    info "bash scripts/connect-qubes-to-lenovo.sh test"
}

# ── Test connection ──────────────────────────────────────────────

cmd_test() {
    log "=== Testing Lenovo Connection ==="

    log "  SSH connectivity..."
    if ssh -o ConnectTimeout=5 "$SSH_HOST" "echo SSH_OK" 2>/dev/null | grep -q "SSH_OK"; then
        log "  SSH: CONNECTED"
    else
        err "SSH connection failed."
        info "Run: bash scripts/connect-qubes-to-lenovo.sh setup LENOVO_IP"
        info "Then: ssh-copy-id $SSH_HOST"
        return 1
    fi

    log "  Remote system info..."
    ssh "$SSH_HOST" "uname -a; echo '---'; cat /etc/os-release 2>/dev/null | head -3; echo '---'; test -e /dev/kvm && echo 'KVM: YES' || echo 'KVM: NO'" 2>/dev/null

    log ""
    log "  Checking agent API..."
    if ssh "$SSH_HOST" "curl -sf http://localhost:$AGENT_PORT/health" 2>/dev/null | grep -q "ok"; then
        log "  Agent API: RUNNING"
    else
        warn "Agent API not responding on port $AGENT_PORT"
        info "On the Lenovo, run: bash scripts/setup-lenovo.sh --agent"
    fi

    log ""
    log "  Checking project deployment..."
    if ssh "$SSH_HOST" "test -d ~/qubes-kvm-fork && echo FOUND" 2>/dev/null | grep -q "FOUND"; then
        log "  Project: DEPLOYED"
    else
        warn "Project not found on Lenovo"
        info "Run: bash scripts/connect-qubes-to-lenovo.sh deploy"
    fi

    log ""
    log "Connection test complete."
    info "Cursor Remote-SSH: use host '$SSH_HOST'"
    info "Agent API: http://localhost:$AGENT_PORT/docs (via SSH tunnel)"
}

# ── Start tunnel ─────────────────────────────────────────────────

cmd_tunnel() {
    log "=== Starting SSH Tunnel to Lenovo ==="
    log "  Port forwarding: localhost:$AGENT_PORT → Lenovo:$AGENT_PORT"
    log "  Press Ctrl+C to stop"
    log ""
    log "  Agent API will be at: http://localhost:$AGENT_PORT/docs"
    log "  Agent health check:   http://localhost:$AGENT_PORT/health"
    log ""

    ssh -N -L "$AGENT_PORT:127.0.0.1:$AGENT_PORT" "$SSH_HOST"
}

# ── Deploy project ───────────────────────────────────────────────

cmd_deploy() {
    log "=== Deploying qubes-kvm-fork to Lenovo ==="

    log "  Creating archive..."
    local tmptar="/tmp/qubes-kvm-fork-deploy.tar.gz"
    tar czf "$tmptar" \
        -C "$(dirname "$PROJECT_DIR")" \
        --exclude='build/repos' \
        --exclude='build/rpms' \
        --exclude='build/rpmbuild' \
        --exclude='vm-images/*.qcow2' \
        --exclude='lenovo-agent/.venv' \
        --exclude='.git' \
        "$(basename "$PROJECT_DIR")"

    local size
    size="$(du -h "$tmptar" | cut -f1)"
    log "  Archive: $size"

    log "  Uploading to Lenovo..."
    scp "$tmptar" "$SSH_HOST:/tmp/qubes-kvm-fork-deploy.tar.gz"

    log "  Extracting on Lenovo..."
    ssh "$SSH_HOST" "cd /home/user && tar xzf /tmp/qubes-kvm-fork-deploy.tar.gz && rm /tmp/qubes-kvm-fork-deploy.tar.gz && echo DEPLOY_OK"

    rm -f "$tmptar"

    log ""
    log "  Also deploying sibling repos..."
    for repo in qubes-core-vchan-socket qubes-core-qubesdb qubes-core-agent-linux qubes-core-admin; do
        local repo_dir
        repo_dir="$(realpath "$PROJECT_DIR/../$repo" 2>/dev/null || true)"
        if [[ -d "$repo_dir" ]]; then
            log "  Syncing $repo..."
            rsync -az --delete \
                --exclude='.git' \
                --exclude='*.o' \
                --exclude='*.so' \
                "$repo_dir/" "$SSH_HOST:/home/user/$repo/"
        fi
    done

    log ""
    log "Deployment complete."
    info "On Lenovo, run: cd ~/qubes-kvm-fork && make build && make test"
}

# ── Quick sync ───────────────────────────────────────────────────

cmd_sync() {
    log "=== Quick-syncing source to Lenovo ==="

    rsync -az --delete \
        --exclude='build/' \
        --exclude='vm-images/' \
        --exclude='.git' \
        --exclude='lenovo-agent/.venv' \
        "$PROJECT_DIR/" "$SSH_HOST:/home/user/qubes-kvm-fork/"

    for repo in qubes-core-vchan-socket qubes-core-qubesdb qubes-core-agent-linux qubes-core-admin; do
        local repo_dir
        repo_dir="$(realpath "$PROJECT_DIR/../$repo" 2>/dev/null || true)"
        if [[ -d "$repo_dir" ]]; then
            rsync -az --delete \
                --exclude='.git' --exclude='*.o' --exclude='*.so' \
                "$repo_dir/" "$SSH_HOST:/home/user/$repo/"
        fi
    done

    log "Sync complete."
}

# ── Remote status ────────────────────────────────────────────────

cmd_status() {
    log "=== Lenovo Remote Status ==="
    ssh "$SSH_HOST" "bash -c '
echo \"Hostname: \$(hostname)\"
echo \"Kernel:   \$(uname -r)\"
echo \"KVM:      \$(test -e /dev/kvm && echo YES || echo NO)\"
echo \"libvirt:  \$(systemctl is-active libvirtd 2>/dev/null || echo inactive)\"
echo \"Agent:    \$(systemctl is-active qubes-kvm-agent 2>/dev/null || echo inactive)\"
echo \"CPU:      \$(nproc) cores\"
echo \"RAM:      \$(awk \"/MemTotal/{printf \\\"%.1f GB\\\", \\\$2/1024/1024}\" /proc/meminfo)\"
echo \"Disk:     \$(df -h / | awk \"NR==2{print \\\$4}\" ) free\"
echo \"\"
echo \"VMs:\"
virsh -c qemu:///system list --all 2>/dev/null || echo \"  (libvirt not available)\"
'" 2>/dev/null || err "Cannot connect to Lenovo"
}

# ── Remote shell ─────────────────────────────────────────────────

cmd_ssh() {
    ssh -t "$SSH_HOST" "cd ~/qubes-kvm-fork && exec bash"
}

# ── Remote build + test ──────────────────────────────────────────

cmd_build() {
    log "=== Building on Lenovo ==="
    ssh "$SSH_HOST" "cd ~/qubes-kvm-fork && make build 2>&1"
}

cmd_test_remote() {
    log "=== Testing on Lenovo ==="
    ssh "$SSH_HOST" "cd ~/qubes-kvm-fork && make test 2>&1"
}

cmd_rpm_remote() {
    log "=== Building RPMs on Lenovo ==="
    ssh "$SSH_HOST" "cd ~/qubes-kvm-fork && make rpm 2>&1"
}

# ── Main ─────────────────────────────────────────────────────────

case "${1:-help}" in
    setup)    shift; cmd_setup "$@" ;;
    test)     cmd_test ;;
    tunnel)   cmd_tunnel ;;
    deploy)   cmd_deploy ;;
    sync)     cmd_sync ;;
    status)   cmd_status ;;
    ssh)      cmd_ssh ;;
    build)    cmd_build ;;
    rtest)    cmd_test_remote ;;
    rpm)      cmd_rpm_remote ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Connection:"
        echo "  setup LENOVO_IP [USER]  Configure SSH + tunnel"
        echo "  test                    Test connectivity"
        echo "  tunnel                  Start SSH port-forward tunnel"
        echo "  ssh                     Interactive shell on Lenovo"
        echo ""
        echo "Deployment:"
        echo "  deploy                  Full project upload to Lenovo"
        echo "  sync                    Quick rsync of source changes"
        echo ""
        echo "Remote operations:"
        echo "  status                  Show Lenovo system status"
        echo "  build                   Run make build on Lenovo"
        echo "  rtest                   Run make test on Lenovo"
        echo "  rpm                     Build RPMs on Lenovo"
        ;;
esac
