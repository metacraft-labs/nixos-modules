#!/usr/bin/env bash
# Poll SSH on a host until it becomes reachable with the given credentials.
#
# Environment variables:
#   SSH_PORT   Port to probe (required).
#   USERNAME   SSH username (required).
#   PASSWORD   SSH password (required).
#   TIMEOUT    Max seconds to wait (default: 300).
#   HOST       Host to probe (default: 127.0.0.1).
#   RETRY_DELAY Seconds between probe attempts (default: 10).
set -euo pipefail

: "${SSH_PORT:?SSH_PORT is required}"
: "${USERNAME:?USERNAME is required}"
: "${PASSWORD:?PASSWORD is required}"
TIMEOUT="${TIMEOUT:-300}"
HOST="${HOST:-127.0.0.1}"
RETRY_DELAY="${RETRY_DELAY:-10}"

echo "Waiting for SSH on ${HOST}:${SSH_PORT} (timeout: ${TIMEOUT}s)..."
start_time=$(date +%s)

while true; do
  elapsed=$(( $(date +%s) - start_time ))
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "ERROR: timeout waiting for SSH after ${TIMEOUT}s" >&2
    exit 1
  fi

  if ssh-keyscan -p "$SSH_PORT" "$HOST" 2>/dev/null | grep -q "ssh-"; then
    echo "SSH is listening, attempting connection..."
    if sshpass -p "$PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -p "$SSH_PORT" \
      "${USERNAME}@${HOST}" \
      "echo 'SSH connection successful'" 2>/dev/null; then
      echo "SSH connection established."
      exit 0
    fi
  fi

  echo "SSH not ready yet (elapsed: ${elapsed}s)..."
  sleep "$RETRY_DELAY"
done
