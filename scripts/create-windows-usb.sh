#!/usr/bin/env bash
# create-windows-usb.sh — Create a bootable Windows CI runner USB drive
#
# Works on NixOS and macOS. Formats a USB drive, copies Windows ISO contents,
# Autounattend.xml, and CI runner bootstrap scripts.
#
# Usage:
#   ./create-windows-usb.sh <iso-path> <device> [scripts-dir]
#
# Arguments:
#   iso-path    — Path to the Windows 11/10 ISO file
#   device      — Target USB device (e.g., /dev/sdX on Linux, disk2 on macOS)
#   scripts-dir — Directory containing Autounattend.xml + bootstrap.ps1 etc.
#                 (defaults to the ci-runner directory next to this script's repo)
#
# The scripts-dir should contain at minimum:
#   - Autounattend.xml
#   - bootstrap.ps1
# And optionally:
#   - provision-github-runner.ps1
#   - configure-benchmark-isolation.ps1
#
# On macOS, install wimlib for large install.wim support: brew install wimlib

set -euo pipefail

usage() {
    echo "Usage: $0 <iso-path> <device> [scripts-dir]"
    echo ""
    echo "Arguments:"
    echo "  iso-path    — Path to Windows ISO file"
    echo "  device      — Target USB device (e.g., /dev/sdX or disk2)"
    echo "  scripts-dir — Directory with Autounattend.xml + scripts (optional)"
    exit 1
}

if [ $# -lt 2 ]; then
    usage
fi

ISO_PATH="$1"
DEVICE="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${3:-${SCRIPT_DIR}/../vm-images/windows/ci-runner}"

# Resolve the scripts dir to an absolute path
SCRIPTS_DIR="$(cd "$SCRIPTS_DIR" && pwd)"

if [ ! -f "$ISO_PATH" ]; then
    echo "Error: ISO file not found: $ISO_PATH"
    exit 1
fi

# Detect OS
OS="$(uname -s)"

echo "=========================================="
echo "Windows CI Runner USB Creator"
echo "=========================================="
echo "ISO:        $ISO_PATH"
echo "Device:     $DEVICE"
echo "Scripts:    $SCRIPTS_DIR"
echo "OS:         $OS"
echo "=========================================="
echo ""
echo "WARNING: This will ERASE ALL DATA on $DEVICE."
read -p "Continue? (yes/no) " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# ── macOS path ──────────────────────────────────────────────────────────────

if [ "$OS" = "Darwin" ]; then
    # Normalize device path
    if [[ "$DEVICE" != /dev/* ]]; then
        DEVICE="/dev/$DEVICE"
    fi

    if ! diskutil info "$DEVICE" >/dev/null 2>&1; then
        echo "Error: $DEVICE does not exist."
        exit 1
    fi

    MNT_ISO=$(mktemp -d)

    cleanup() {
        echo "Cleaning up..."
        hdiutil detach "$MNT_ISO" 2>/dev/null || true
        diskutil unmountDisk "$DEVICE" 2>/dev/null || true
    }
    trap cleanup EXIT

    # macOS can't natively write NTFS, so we use ExFAT
    echo "Erasing $DEVICE as ExFAT (GPT)..."
    diskutil eraseDisk ExFAT WININSTALL GPT "$DEVICE"

    echo "Mounting ISO..."
    hdiutil attach "$ISO_PATH" -mountpoint "$MNT_ISO" -nobrowse -readonly

    USB_MOUNT="/Volumes/WININSTALL"

    # Check for wimlib for WIM splitting
    if command -v wimlib-imagex >/dev/null 2>&1; then
        echo "Copying all files except install.wim..."
        rsync -ah --info=progress2 --exclude='sources/install.wim' "$MNT_ISO/" "$USB_MOUNT/"

        WIM="$MNT_ISO/sources/install.wim"
        if [ -f "$WIM" ]; then
            WIM_SIZE=$(stat -f%z "$WIM")
            WIM_SIZE_MB=$((WIM_SIZE / 1048576))
            if [ "$WIM_SIZE_MB" -gt 4000 ]; then
                echo "Splitting install.wim ($WIM_SIZE_MB MB) into SWM files (max 3800 MB)..."
                wimlib-imagex split "$WIM" "$USB_MOUNT/sources/install.swm" 3800
            else
                echo "Copying install.wim ($WIM_SIZE_MB MB, no split needed)..."
                cp "$WIM" "$USB_MOUNT/sources/install.wim"
            fi
        fi
    else
        echo "wimlib not found; copying files directly."
        echo "  Install wimlib for large image support: brew install wimlib"
        rsync -ah --info=progress2 "$MNT_ISO/" "$USB_MOUNT/"
    fi

    echo "Copying CI runner files..."
    if [ -f "$SCRIPTS_DIR/../Autounattend.xml" ] 2>/dev/null; then
        cp "$SCRIPTS_DIR/../Autounattend.xml" "$USB_MOUNT/Autounattend.xml"
    elif [ -f "$SCRIPTS_DIR/Autounattend.xml" ]; then
        cp "$SCRIPTS_DIR/Autounattend.xml" "$USB_MOUNT/Autounattend.xml"
    fi

    for script in bootstrap.ps1 provision-github-runner.ps1 configure-benchmark-isolation.ps1; do
        if [ -f "$SCRIPTS_DIR/$script" ]; then
            cp "$SCRIPTS_DIR/$script" "$USB_MOUNT/$script"
        fi
    done

    echo ""
    echo "Bootable Windows USB created on $DEVICE."
    exit 0
fi

# ── Linux path ──────────────────────────────────────────────────────────────

if [ "$OS" = "Linux" ]; then
    if [ ! -b "$DEVICE" ]; then
        echo "Error: $DEVICE is not a block device."
        exit 1
    fi

    MNT_ISO=$(mktemp -d)
    MNT_USB=$(mktemp -d)

    cleanup() {
        echo "Cleaning up..."
        umount "$MNT_ISO" 2>/dev/null || true
        umount "$MNT_USB" 2>/dev/null || true
        rmdir "$MNT_ISO" "$MNT_USB" 2>/dev/null || true
    }
    trap cleanup EXIT

    echo "Partitioning $DEVICE (GPT)..."
    sudo sgdisk --zap-all "$DEVICE"
    sudo sgdisk --new=1:0:0 --typecode=1:0700 "$DEVICE"
    sudo partprobe "$DEVICE"
    sleep 2

    # Determine partition name
    PART="${DEVICE}1"
    if [ ! -b "$PART" ]; then
        PART="${DEVICE}p1"
    fi

    echo "Formatting ${PART} as NTFS..."
    sudo mkfs.ntfs --fast -L WININSTALL "$PART"

    echo "Mounting ISO..."
    sudo mount -o loop,ro "$ISO_PATH" "$MNT_ISO"

    echo "Mounting USB partition..."
    sudo mount "$PART" "$MNT_USB"

    echo "Copying Windows installation files..."
    sudo rsync -ah --info=progress2 "$MNT_ISO/" "$MNT_USB/"

    echo "Copying CI runner files..."
    if [ -f "$SCRIPTS_DIR/../Autounattend.xml" ] 2>/dev/null; then
        sudo cp "$SCRIPTS_DIR/../Autounattend.xml" "$MNT_USB/Autounattend.xml"
    elif [ -f "$SCRIPTS_DIR/Autounattend.xml" ]; then
        sudo cp "$SCRIPTS_DIR/Autounattend.xml" "$MNT_USB/Autounattend.xml"
    fi

    for script in bootstrap.ps1 provision-github-runner.ps1 configure-benchmark-isolation.ps1; do
        if [ -f "$SCRIPTS_DIR/$script" ]; then
            sudo cp "$SCRIPTS_DIR/$script" "$MNT_USB/$script"
        fi
    done

    sudo sync

    echo ""
    echo "Bootable Windows USB created on $DEVICE."
    exit 0
fi

echo "Error: Unsupported OS: $OS"
echo "This script supports Linux and macOS."
exit 1
