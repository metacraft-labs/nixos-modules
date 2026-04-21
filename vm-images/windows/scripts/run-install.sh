#!/usr/bin/env bash
# Launch QEMU to perform an unattended Windows installation.
#
# Environment variables (required unless marked optional):
#   WINDOWS_ISO              Path to Windows installation ISO.
#   VIRTIO_ISO               Path to VirtIO drivers ISO (optional; may be empty).
#   DISK_IMAGE               Path to QCOW2 disk image (default: ./windows.qcow2).
#   DISK_SIZE_GB             Disk size in GB to create if missing (default: 64).
#   MEMORY_MB                RAM in MB (default: 4096).
#   CPU_CORES                vCPU count (default: 2).
#   SSH_PORT                 Host SSH forward port (default: 2223).
#   RDP_PORT                 Host RDP forward port (default: 3389).
#   VNC_DISPLAY              VNC display number (default: 2).
#   OVMF_CODE                Path to read-only OVMF_CODE.fd (required).
#   OVMF_VARS_SRC            Path to template OVMF_VARS.fd (required).
#   AUTOUNATTEND_MEDIA       Path to floppy/ISO containing Autounattend.xml (optional).
#   AUTOUNATTEND_MEDIA_TYPE  "floppy" or "iso" (default: floppy).
#   USERNAME / PASSWORD      For display only (defaults: admin/admin).
set -euo pipefail

DISK_IMAGE="${DISK_IMAGE:-./windows.qcow2}"
DISK_SIZE_GB="${DISK_SIZE_GB:-64}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPU_CORES="${CPU_CORES:-2}"
SSH_PORT="${SSH_PORT:-2223}"
RDP_PORT="${RDP_PORT:-3389}"
VNC_DISPLAY="${VNC_DISPLAY:-2}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-admin}"
AUTOUNATTEND_MEDIA_TYPE="${AUTOUNATTEND_MEDIA_TYPE:-floppy}"
: "${OVMF_CODE:?OVMF_CODE is required}"
: "${OVMF_VARS_SRC:?OVMF_VARS_SRC is required}"

vnc_port=$(( 5900 + VNC_DISPLAY ))

if [ -z "${WINDOWS_ISO:-}" ] || [ ! -f "$WINDOWS_ISO" ]; then
  echo "Error: Windows ISO not found: ${WINDOWS_ISO:-<unset>}" >&2
  echo "Set WINDOWS_ISO to the path of your Windows installation ISO." >&2
  echo "" >&2
  echo "You can obtain a Windows ISO from:" >&2
  echo "  - https://www.microsoft.com/software-download/windows11" >&2
  echo "  - https://www.microsoft.com/software-download/windows10ISO" >&2
  exit 1
fi

if [ -z "${VIRTIO_ISO:-}" ] || [ ! -f "$VIRTIO_ISO" ]; then
  echo "Warning: VirtIO drivers ISO not found" >&2
  echo "Windows may not be able to see the VirtIO disk during installation." >&2
  echo "Set VIRTIO_ISO to the path of virtio-win.iso." >&2
  read -r -p "Continue without VirtIO drivers? [y/N] " -n 1 reply
  echo
  if [[ ! $reply =~ ^[Yy]$ ]]; then
    exit 1
  fi
  VIRTIO_ISO=""
fi

if [ ! -f "$DISK_IMAGE" ]; then
  echo "Creating ${DISK_SIZE_GB}GB QCOW2 disk image at $DISK_IMAGE..."
  qemu-img create -f qcow2 "$DISK_IMAGE" "${DISK_SIZE_GB}G"
fi

if [ ! -f ./OVMF_VARS.fd ]; then
  cp "$OVMF_VARS_SRC" ./OVMF_VARS.fd
  chmod +w ./OVMF_VARS.fd
fi

if [ ! -r /dev/kvm ]; then
  echo "Warning: KVM not available. Installation will be VERY slow." >&2
  echo "Ensure the kvm kernel module is loaded and /dev/kvm is accessible." >&2
  kvm_flag=()
else
  kvm_flag=(-enable-kvm)
fi

qemu_args=(
  "${kvm_flag[@]}"
  -m "$MEMORY_MB"
  -cpu host
  -smp "$CPU_CORES"
  -machine q35,accel=kvm

  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -drive "if=pflash,format=raw,file=./OVMF_VARS.fd"

  -drive "file=${DISK_IMAGE},if=virtio,format=qcow2,cache=writeback"

  -drive "file=${WINDOWS_ISO},media=cdrom,index=0"
)

if [ -n "$VIRTIO_ISO" ]; then
  qemu_args+=(-drive "file=${VIRTIO_ISO},media=cdrom,index=1")
fi

if [ -n "${AUTOUNATTEND_MEDIA:-}" ]; then
  case "$AUTOUNATTEND_MEDIA_TYPE" in
    iso)
      qemu_args+=(-drive "file=${AUTOUNATTEND_MEDIA},media=cdrom,index=2")
      ;;
    floppy|*)
      qemu_args+=(-drive "file=${AUTOUNATTEND_MEDIA},if=floppy,format=raw")
      ;;
  esac
fi

qemu_args+=(
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${RDP_PORT}-:3389"
  -device virtio-net-pci,netdev=net0

  -device virtio-vga
  -device usb-ehci
  -device usb-kbd
  -device usb-tablet

  -vnc "0.0.0.0:${VNC_DISPLAY}"
  -monitor unix:qemu-monitor-socket,server,nowait

  -boot order=d,menu=on
)

qemu_args+=("$@")

echo "============================================"
echo "Starting Windows VM Installation"
echo "============================================"
echo "Windows ISO: $WINDOWS_ISO"
echo "VirtIO ISO: ${VIRTIO_ISO:-Not provided}"
echo "Disk Image: $DISK_IMAGE"
echo ""
echo "Network:"
echo "  SSH: localhost:${SSH_PORT}"
echo "  RDP: localhost:${RDP_PORT}"
echo "  VNC: localhost:${vnc_port}"
echo ""
echo "Credentials (after installation):"
echo "  Username: ${USERNAME}"
echo "  Password: ${PASSWORD}"
echo "============================================"

exec qemu-system-x86_64 "${qemu_args[@]}"
