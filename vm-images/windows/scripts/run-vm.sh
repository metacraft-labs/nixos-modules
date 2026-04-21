#!/usr/bin/env bash
# Boot an installed Windows VM with QEMU.
#
# Environment variables:
#   VM_DIR           Directory containing windows.qcow2 and OVMF_VARS.fd.
#                    If unset, falls back to DISK_IMAGE and ./OVMF_VARS.fd.
#   DISK_IMAGE       Path to QCOW2 disk (default: "$VM_DIR/windows.qcow2"
#                    or ./windows.qcow2 when VM_DIR is unset).
#   OVMF_CODE        Path to read-only OVMF_CODE.fd (required).
#   OVMF_VARS_SRC    Path to template OVMF_VARS.fd (required; used to seed a
#                    writable copy when one does not yet exist).
#   OVMF_VARS        Writable OVMF_VARS.fd (default: "$VM_DIR/OVMF_VARS.fd"
#                    or ./OVMF_VARS.fd).
#   MEMORY_MB        RAM in MB (default: 4096).
#   CPU_CORES        vCPU count (default: 2).
#   SSH_PORT         Host SSH forward port (default: 2223).
#   RDP_PORT         Host RDP forward port (default: 3389).
#   VNC_DISPLAY      VNC display number (default: 2).
#   USERNAME         For display only (default: admin).
#
# Additional arguments are forwarded to qemu-system-x86_64.
set -euo pipefail

MEMORY_MB="${MEMORY_MB:-4096}"
CPU_CORES="${CPU_CORES:-2}"
SSH_PORT="${SSH_PORT:-2223}"
RDP_PORT="${RDP_PORT:-3389}"
VNC_DISPLAY="${VNC_DISPLAY:-2}"
USERNAME="${USERNAME:-admin}"
: "${OVMF_CODE:?OVMF_CODE is required}"
: "${OVMF_VARS_SRC:?OVMF_VARS_SRC is required}"

# Allow the first positional argument to override VM_DIR when it is a
# directory. This lets callers invoke `run-vm <vm-dir>` without env vars.
if [ $# -gt 0 ] && [ -d "$1" ]; then
  VM_DIR="$1"
  shift
fi

if [ -n "${VM_DIR:-}" ]; then
  DISK_IMAGE="${DISK_IMAGE:-$VM_DIR/windows.qcow2}"
  OVMF_VARS="${OVMF_VARS:-$VM_DIR/OVMF_VARS.fd}"
else
  DISK_IMAGE="${DISK_IMAGE:-./windows.qcow2}"
  OVMF_VARS="${OVMF_VARS:-./OVMF_VARS.fd}"
fi

if [ ! -f "$DISK_IMAGE" ]; then
  echo "Error: disk image not found: $DISK_IMAGE" >&2
  exit 1
fi

if [ ! -f "$OVMF_VARS" ]; then
  cp "$OVMF_VARS_SRC" "$OVMF_VARS"
  chmod +w "$OVMF_VARS"
fi

if [ ! -r /dev/kvm ]; then
  echo "Error: KVM not available. Ensure the kvm kernel module is loaded" >&2
  echo "and that /dev/kvm is accessible." >&2
  exit 1
fi

vnc_port=$(( 5900 + VNC_DISPLAY ))

qemu_args=(
  -enable-kvm
  -m "$MEMORY_MB"
  -cpu host
  -smp "$CPU_CORES"
  -machine q35,accel=kvm

  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -drive "if=pflash,format=raw,file=${OVMF_VARS}"

  -drive "file=${DISK_IMAGE},if=virtio,format=qcow2,cache=writeback"

  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${RDP_PORT}-:3389"
  -device virtio-net-pci,netdev=net0

  -device virtio-vga
  -device usb-ehci
  -device usb-kbd
  -device usb-tablet

  -vnc "0.0.0.0:${VNC_DISPLAY}"
  -monitor unix:qemu-monitor-socket,server,nowait
)

qemu_args+=("$@")

echo "Starting Windows VM..."
[ -n "${VM_DIR:-}" ] && echo "  VM directory: $VM_DIR"
echo "  Disk image: $DISK_IMAGE"
echo "  SSH: localhost:${SSH_PORT}"
echo "  RDP: localhost:${RDP_PORT}"
echo "  VNC: localhost:${vnc_port}"
echo "  Username: ${USERNAME}"
echo ""

exec qemu-system-x86_64 "${qemu_args[@]}"
