#!/usr/bin/env bash
# Probe a Windows VM over SSH and verify it reports a Windows OS version.
#
# Environment variables:
#   SSH_PORT           SSH port (required).
#   USERNAME           SSH username (required).
#   PASSWORD           SSH password (required).
#   BOOT_TIMEOUT       Maximum seconds to wait for SSH (default: 300).
#   SSH_RETRIES        Number of connection attempts (default: 50).
#   SSH_RETRY_DELAY    Seconds between attempts (default: 6).
#   HOST               Host to connect to (default: 127.0.0.1).
set -euo pipefail

: "${SSH_PORT:?SSH_PORT is required}"
: "${USERNAME:?USERNAME is required}"
: "${PASSWORD:?PASSWORD is required}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
SSH_RETRIES="${SSH_RETRIES:-50}"
SSH_RETRY_DELAY="${SSH_RETRY_DELAY:-6}"
HOST="${HOST:-127.0.0.1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "============================================"
log_info "Windows VM Health Check"
log_info "============================================"
log_info "SSH Port: $SSH_PORT"
log_info "Username: $USERNAME"
log_info "Timeout: $BOOT_TIMEOUT seconds"
log_info "============================================"

ssh_ready=false
start_time=$(date +%s)

for i in $(seq 1 "$SSH_RETRIES"); do
  elapsed=$(( $(date +%s) - start_time ))

  if [ "$elapsed" -ge "$BOOT_TIMEOUT" ]; then
    log_error "Boot timeout exceeded (${BOOT_TIMEOUT} seconds)"
    exit 1
  fi

  log_info "SSH probe attempt $i/$SSH_RETRIES (elapsed: ${elapsed}s)..."

  if ssh-keyscan -p "$SSH_PORT" "$HOST" 2>/dev/null | grep -q "ssh-"; then
    log_info "SSH is listening, attempting connection..."
    if sshpass -p "$PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -p "$SSH_PORT" \
      "${USERNAME}@${HOST}" \
      "echo 'SSH connection successful'" 2>/dev/null; then
      ssh_ready=true
      break
    fi
  fi

  sleep "$SSH_RETRY_DELAY"
done

if [ "$ssh_ready" != "true" ]; then
  log_error "Failed to establish SSH connection within timeout"
  exit 1
fi

log_info "============================================"
log_info "SSH connection established!"
log_info "============================================"
log_info "Running health check: Windows version query"

sysinfo_output=$(sshpass -p "$PASSWORD" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" \
  "${USERNAME}@${HOST}" \
  'powershell -Command "[System.Environment]::OSVersion.VersionString"' 2>/dev/null)

if [ -z "$sysinfo_output" ]; then
  log_error "Health check command returned empty output"
  exit 1
fi

log_info "Windows version information:"
echo "$sysinfo_output"

if echo "$sysinfo_output" | grep -qi "Windows"; then
  log_info "Health check passed: Windows is responding correctly"
else
  log_error "Health check failed: unexpected output"
  exit 1
fi

log_info "============================================"
log_info "HEALTH CHECK PASSED"
log_info "============================================"
