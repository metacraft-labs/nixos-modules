#!/usr/bin/env bash
# Boot a pre-built Windows VM, verify it responds to SSH, and shut it down.
#
# Required environment variables:
#   VM_DIR                Directory holding windows.qcow2.
#   RUN_VM                Path to the run-vm executable (wraps qemu-system-x86_64).
#   SSH_PORT, USERNAME, PASSWORD
#
# Optional:
#   BOOT_TIMEOUT          Max seconds to wait for SSH (default: 300).
#   SSH_RETRIES           Max connection attempts (default: 50).
#   SSH_RETRY_DELAY       Seconds between attempts (default: 6).
#   VNC_DISPLAY           VNC display used by the run script (display only).
set -euo pipefail

: "${VM_DIR:?VM_DIR is required}"
: "${RUN_VM:?RUN_VM is required}"
: "${SSH_PORT:?SSH_PORT is required}"
: "${USERNAME:?USERNAME is required}"
: "${PASSWORD:?PASSWORD is required}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
SSH_RETRIES="${SSH_RETRIES:-50}"
SSH_RETRY_DELAY="${SSH_RETRY_DELAY:-6}"
VNC_DISPLAY="${VNC_DISPLAY:-2}"

vnc_port=$(( 5900 + VNC_DISPLAY ))

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
  log_info "Cleaning up..."
  if [ -n "${QEMU_PID:-}" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
    log_info "Sending SIGTERM to QEMU (PID: $QEMU_PID)"
    kill "$QEMU_PID" 2>/dev/null || true
    sleep 5
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      log_warn "QEMU still running, sending SIGKILL"
      kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
  fi
  rm -f qemu-monitor-socket
}

trap cleanup EXIT

log_info "============================================"
log_info "Windows VM Cached Boot Test"
log_info "============================================"
log_info "VM Directory: $VM_DIR"
log_info "SSH Port: $SSH_PORT"
log_info "Boot Timeout: $BOOT_TIMEOUT seconds"
log_info "============================================"

if [ ! -d "$VM_DIR" ]; then
  log_error "VM directory not found: $VM_DIR"
  exit 1
fi

if [ ! -f "$VM_DIR/windows.qcow2" ]; then
  log_error "Disk image not found: $VM_DIR/windows.qcow2"
  exit 1
fi

log_info "Starting Windows VM..."

"$RUN_VM" "$VM_DIR" -nographic -serial none &
QEMU_PID=$!

log_info "QEMU started with PID: $QEMU_PID"
log_info "VNC available at: localhost:${vnc_port}"

log_info "Waiting for SSH to become available (up to $BOOT_TIMEOUT seconds)..."

ssh_ready=false
start_time=$(date +%s)

for i in $(seq 1 "$SSH_RETRIES"); do
  elapsed=$(( $(date +%s) - start_time ))

  if [ "$elapsed" -ge "$BOOT_TIMEOUT" ]; then
    log_error "Boot timeout exceeded (${BOOT_TIMEOUT} seconds)"
    break
  fi

  log_info "SSH probe attempt $i/$SSH_RETRIES (elapsed: ${elapsed}s)..."

  if ssh-keyscan -p "$SSH_PORT" 127.0.0.1 2>/dev/null | grep -q "ssh-"; then
    log_info "SSH is listening, attempting connection..."
    if sshpass -p "$PASSWORD" ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -p "$SSH_PORT" \
      "${USERNAME}@127.0.0.1" \
      "echo 'SSH connection successful'" 2>/dev/null; then
      ssh_ready=true
      break
    fi
  fi

  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log_error "QEMU process died unexpectedly"
    exit 1
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
  "${USERNAME}@127.0.0.1" \
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
log_info "Initiating graceful shutdown..."
log_info "============================================"

sshpass -p "$PASSWORD" ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -p "$SSH_PORT" \
  "${USERNAME}@127.0.0.1" \
  "shutdown /s /t 5 /f" 2>/dev/null || true

log_info "Shutdown command sent, waiting for VM to terminate..."

for _ in $(seq 1 60); do
  if ! kill -0 "$QEMU_PID" 2>/dev/null; then
    log_info "VM shut down gracefully"
    break
  fi
  sleep 1
done

if kill -0 "$QEMU_PID" 2>/dev/null; then
  log_warn "VM did not shut down gracefully, will be killed by cleanup"
fi

log_info "============================================"
log_info "TEST PASSED: Windows VM cached boot test successful!"
log_info "============================================"
