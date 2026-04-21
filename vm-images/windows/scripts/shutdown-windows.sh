#!/usr/bin/env bash
# Send a graceful Windows shutdown over SSH.
#
# Environment variables:
#   SSH_PORT   SSH port (required).
#   USERNAME   SSH username (required).
#   PASSWORD   SSH password (required).
#   HOST       Host to connect to (default: 127.0.0.1).
#   WAIT_SECS  Seconds to wait for the VM to terminate (default: 30).
set -euo pipefail

: "${SSH_PORT:?SSH_PORT is required}"
: "${USERNAME:?USERNAME is required}"
: "${PASSWORD:?PASSWORD is required}"
HOST="${HOST:-127.0.0.1}"
WAIT_SECS="${WAIT_SECS:-30}"

echo "Initiating graceful shutdown via SSH..."
sshpass -p "$PASSWORD" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 \
  -p "$SSH_PORT" \
  "${USERNAME}@${HOST}" \
  "shutdown /s /t 5 /f" 2>/dev/null || true

echo "Shutdown command sent; waiting for VM to terminate..."
sleep "$WAIT_SECS"
