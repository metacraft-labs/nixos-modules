#!/usr/bin/env bash
# Orchestrate an unattended Windows installation inside QEMU, then shut the VM
# down gracefully once SSH becomes reachable.
#
# Required environment variables:
#   NAME                    Human-readable build label (used in log output).
#   WINDOWS_ISO             Path to Windows installation ISO.
#   VIRTIO_ISO              Path to VirtIO drivers ISO.
#   AUTOUNATTEND_MEDIA      Path to floppy/ISO with Autounattend.xml.
#   AUTOUNATTEND_MEDIA_TYPE "floppy" (default) or "iso".
#   OVMF_CODE               Path to read-only OVMF_CODE.fd.
#   OVMF_VARS_SRC           Path to template OVMF_VARS.fd.
#   WAIT_FOR_SSH            Path to wait-for-ssh executable.
#   SHUTDOWN_WINDOWS        Path to shutdown-windows executable.
#   SSH_PORT, RDP_PORT, VNC_DISPLAY
#   MEMORY_MB, CPU_CORES, DISK_SIZE_GB
#   USERNAME, PASSWORD, COMPUTER_NAME
#   INSTALL_TIMEOUT_SECS    Maximum seconds to wait for installation.
#
# Optional:
#   AUTOMATION_CMD    If non-empty, a shell command line that runs after SSH is
#                     ready (typically invokes yaml-automation-runner).
set -eux

: "${NAME:?NAME is required}"
: "${WINDOWS_ISO:?WINDOWS_ISO is required}"
: "${VIRTIO_ISO:?VIRTIO_ISO is required}"
: "${AUTOUNATTEND_MEDIA:?AUTOUNATTEND_MEDIA is required}"
: "${OVMF_CODE:?OVMF_CODE is required}"
: "${OVMF_VARS_SRC:?OVMF_VARS_SRC is required}"
: "${WAIT_FOR_SSH:?WAIT_FOR_SSH is required}"
: "${SHUTDOWN_WINDOWS:?SHUTDOWN_WINDOWS is required}"
SSH_PORT="${SSH_PORT:-2223}"
RDP_PORT="${RDP_PORT:-3389}"
VNC_DISPLAY="${VNC_DISPLAY:-2}"
MEMORY_MB="${MEMORY_MB:-4096}"
CPU_CORES="${CPU_CORES:-2}"
DISK_SIZE_GB="${DISK_SIZE_GB:-64}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-admin}"
COMPUTER_NAME="${COMPUTER_NAME:-WIN-AGENT}"
INSTALL_TIMEOUT_SECS="${INSTALL_TIMEOUT_SECS:-3600}"
AUTOUNATTEND_MEDIA_TYPE="${AUTOUNATTEND_MEDIA_TYPE:-floppy}"
AUTOMATION_CMD="${AUTOMATION_CMD:-}"

work_dir="$(pwd)"
vnc_port=$(( 5900 + VNC_DISPLAY ))

echo "============================================"
echo "Windows VM Build - ${NAME}"
echo "============================================"
echo "Windows ISO: ${WINDOWS_ISO}"
echo "VirtIO ISO: ${VIRTIO_ISO}"
echo "Disk Size: ${DISK_SIZE_GB}GB"
echo "Memory: ${MEMORY_MB}MB"
echo "CPU Cores: ${CPU_CORES}"
echo "VNC Port: ${vnc_port}"
echo "SSH Port: ${SSH_PORT}"
echo "RDP Port: ${RDP_PORT}"
echo "Username: ${USERNAME}"
echo "Computer Name: ${COMPUTER_NAME}"
echo "============================================"

if [ ! -f "$WINDOWS_ISO" ]; then
  echo "ERROR: Windows ISO not found: $WINDOWS_ISO" >&2
  exit 1
fi

if [ ! -f "$VIRTIO_ISO" ]; then
  echo "ERROR: VirtIO drivers ISO not found: $VIRTIO_ISO" >&2
  exit 1
fi

echo "Creating ${DISK_SIZE_GB}GB QCOW2 disk image..."
qemu-img create -f qcow2 "$work_dir/windows.qcow2" "${DISK_SIZE_GB}G"

cp "$OVMF_VARS_SRC" "$work_dir/OVMF_VARS.fd"
chmod +w "$work_dir/OVMF_VARS.fd"

echo "============================================"
echo "Stage 1: Windows Unattended Installation"
echo "VNC available at: localhost:${vnc_port}"
echo "============================================"
echo
echo "The installation will proceed automatically via autounattend.xml."
echo "You can monitor progress via VNC if needed."
echo

qemu_args=(
  -enable-kvm
  -m "$MEMORY_MB"
  -cpu host
  -smp "$CPU_CORES"
  -machine q35,accel=kvm

  -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
  -drive "if=pflash,format=raw,file=${work_dir}/OVMF_VARS.fd"

  -drive "file=${work_dir}/windows.qcow2,if=virtio,format=qcow2,cache=writeback"

  -drive "file=${WINDOWS_ISO},media=cdrom,index=0,readonly=on"
  -drive "file=${VIRTIO_ISO},media=cdrom,index=1,readonly=on"
)

case "$AUTOUNATTEND_MEDIA_TYPE" in
  iso)
    qemu_args+=(-drive "file=${AUTOUNATTEND_MEDIA},media=cdrom,index=2,readonly=on")
    ;;
  floppy|*)
    qemu_args+=(-drive "file=${AUTOUNATTEND_MEDIA},if=floppy,format=raw,readonly=on")
    ;;
esac

qemu_args+=(
  -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${RDP_PORT}-:3389"
  -device virtio-net-pci,netdev=net0

  -device virtio-vga
  -device usb-ehci
  -device usb-kbd
  -device usb-tablet

  -vnc "0.0.0.0:${VNC_DISPLAY}"
  -monitor "unix:${work_dir}/qemu-monitor-socket,server,nowait"

  -boot order=d,menu=on
  -no-reboot
)

qemu-system-x86_64 "${qemu_args[@]}" &
qemu_pid=$!

sleep 10

echo "Waiting for Windows installation to complete..."
echo "This typically takes 15-30 minutes depending on hardware."
echo

if SSH_PORT="$SSH_PORT" USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
  TIMEOUT="$INSTALL_TIMEOUT_SECS" "$WAIT_FOR_SSH"; then
  echo "============================================"
  echo "Windows installation completed successfully!"
  echo "============================================"

  if [ -n "$AUTOMATION_CMD" ]; then
    echo "Running post-installation automation..."
    bash -c "$AUTOMATION_CMD" || echo "Automation completed or encountered issues."
  else
    echo "No post-installation automation configured."
  fi

  SSH_PORT="$SSH_PORT" USERNAME="$USERNAME" PASSWORD="$PASSWORD" \
    "$SHUTDOWN_WINDOWS"

  echo "Waiting for VM to shut down..."
  wait "$qemu_pid" || true
else
  echo "ERROR: Windows installation did not complete within timeout." >&2
  echo "Check VNC at localhost:${vnc_port} for status." >&2

  kill "$qemu_pid" 2>/dev/null || true
  wait "$qemu_pid" || true
  exit 1
fi

echo "============================================"
echo "Windows VM build complete!"
echo "Output: ${work_dir}/windows.qcow2"
echo "============================================"
