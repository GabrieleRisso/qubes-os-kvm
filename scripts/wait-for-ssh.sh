#!/bin/bash
# wait-for-ssh.sh — Wait for SSH to become available on a host:port
set -euo pipefail

HOST="${1:?Usage: wait-for-ssh.sh HOST PORT TIMEOUT_SECONDS}"
PORT="${2:-22}"
TIMEOUT="${3:-120}"

echo "Waiting for SSH on ${HOST}:${PORT} (timeout: ${TIMEOUT}s)..."
start=$(date +%s)

while true; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= TIMEOUT )); then
        echo "TIMEOUT: SSH not available after ${TIMEOUT}s"
        exit 1
    fi

    if ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
           -p "$PORT" "user@${HOST}" true 2>/dev/null; then
        echo "SSH ready after ${elapsed}s"
        exit 0
    fi

    sleep 2
done
