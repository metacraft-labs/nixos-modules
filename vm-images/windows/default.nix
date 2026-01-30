# Windows VM Builder for Automated Testing
#
# Copyright 2026 Schelling Point Labs Inc
# SPDX-License-Identifier: AGPL-3.0-only
#
# This module provides Nix functions to build Windows VM images for multi-OS testing.
# It generates customized autounattend.xml files for unattended Windows installation
# with VirtIO drivers, SSH, and RDP enabled.
#
# Key features:
# - Generates autounattend.xml with configurable username, password, computer name
# - Injects VirtIO driver paths for QEMU/KVM compatibility
# - Enables SSH (OpenSSH) and RDP for remote access
# - Bypasses Windows 11 TPM/SecureBoot requirements for VM installation
# - Creates UEFI/GPT partition layout
#
# Dependencies (must be passed as parameters):
#   - virtio-win-drivers: VirtIO drivers ISO (from iso-fetchers.fetchVirtIODrivers)
#     Location in this repo: ../lib/iso-fetchers.nix
#   - yaml-automation-runner: Optional, for post-install automation
#     Location in this repo: ../../packages/vm-automation
#
# Usage:
#   let
#     windowsBuilders = import ./vm-images/windows { inherit pkgs lib; };
#   in
#   windowsBuilders.generateAutounattendXml {
#     username = "admin";
#     password = "admin";
#     computerName = "WIN11-AGENT";
#     timezone = "UTC";
#   }
#
# References:
# - Microsoft Answer File Reference: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
# - Fedora VirtIO Drivers: https://fedorapeople.org/groups/virt/virtio-win/
# - Windows Setup Automation: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup
{
  pkgs,
  lib,
  # Optional: VirtIO drivers ISO for default fallback
  virtio-win-drivers ? null,
  # Optional: YAML automation runner for post-install setup
  yaml-automation-runner ? null,
}:

let
  # Path to the autounattend.xml template in this directory
  autounattendTemplate = ./autounattend.xml;

  # Path to the VirtIO driver check script
  virtioDriverCheckScript = ./virtio-driver-check.ps1;

  # Default VirtIO driver path when the ISO is mounted as a secondary drive
  # In QEMU, we typically mount the VirtIO ISO as a second CD-ROM drive,
  # which Windows sees as E: (D: is usually the Windows installation media)
  defaultVirtioDriverPath = "E:\\";

  # Windows timezone mapping
  # Maps common timezone identifiers to Windows timezone names
  # Reference: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/default-time-zones
  timezoneMapping = {
    "UTC" = "UTC";
    "America/New_York" = "Eastern Standard Time";
    "America/Chicago" = "Central Standard Time";
    "America/Denver" = "Mountain Standard Time";
    "America/Los_Angeles" = "Pacific Standard Time";
    "America/Phoenix" = "US Mountain Standard Time";
    "America/Anchorage" = "Alaskan Standard Time";
    "Pacific/Honolulu" = "Hawaiian Standard Time";
    "Europe/London" = "GMT Standard Time";
    "Europe/Paris" = "Romance Standard Time";
    "Europe/Berlin" = "W. Europe Standard Time";
    "Europe/Moscow" = "Russian Standard Time";
    "Asia/Tokyo" = "Tokyo Standard Time";
    "Asia/Shanghai" = "China Standard Time";
    "Asia/Singapore" = "Singapore Standard Time";
    "Asia/Kolkata" = "India Standard Time";
    "Australia/Sydney" = "AUS Eastern Standard Time";
    "Australia/Perth" = "W. Australia Standard Time";
  };

  # Convert a timezone identifier to Windows timezone name
  # Falls back to the input if not found in mapping (assumes it's already a Windows name)
  toWindowsTimezone = tz: if builtins.hasAttr tz timezoneMapping then timezoneMapping.${tz} else tz;

in
rec {
  # Generate a customized autounattend.xml file for Windows unattended installation
  #
  # This function takes configuration parameters and generates an autounattend.xml
  # file that can be placed on a floppy image or secondary ISO for Windows Setup
  # to automatically discover and use.
  #
  # Parameters:
  #   username: Local administrator account username (default: "admin")
  #   password: Local administrator account password (default: "admin")
  #   computerName: Windows computer name (default: "WIN-AGENT")
  #              Must be 15 characters or less, alphanumeric and hyphens only
  #   timezone: Timezone setting (default: "UTC")
  #             Accepts IANA timezone IDs or Windows timezone names
  #   virtioDriverPath: Path to VirtIO drivers (default: "E:\\")
  #                     This is where the VirtIO ISO is mounted during installation
  #   locale: Locale/language setting (default: "en-US")
  #
  # Returns: A derivation containing the customized autounattend.xml file
  #
  # Example:
  #   generateAutounattendXml {
  #     username = "testuser";
  #     password = "testpass123";
  #     computerName = "WIN11-TEST";
  #     timezone = "America/Los_Angeles";
  #   }
  generateAutounattendXml =
    {
      username ? "admin",
      password ? "admin",
      computerName ? "WIN-AGENT",
      timezone ? "UTC",
      virtioDriverPath ? defaultVirtioDriverPath,
      locale ? "en-US",
    }:
    let
      # Validate computer name (Windows restrictions)
      # - Max 15 characters
      # - Only alphanumeric and hyphens
      # - Cannot start or end with hyphen
      validatedComputerName =
        let
          len = builtins.stringLength computerName;
        in
        if len > 15 then
          throw "Computer name '${computerName}' exceeds 15 character Windows limit"
        else if len == 0 then
          throw "Computer name cannot be empty"
        else
          computerName;

      # Convert timezone to Windows format
      windowsTimezone = toWindowsTimezone timezone;

      # Ensure virtioDriverPath ends with backslash for path concatenation
      normalizedVirtioPath =
        if lib.hasSuffix "\\" virtioDriverPath then virtioDriverPath else "${virtioDriverPath}\\";

    in
    pkgs.runCommand "autounattend.xml"
      {
        inherit
          username
          password
          windowsTimezone
          normalizedVirtioPath
          validatedComputerName
          ;
        template = autounattendTemplate;
      }
      ''
        # Copy the template and perform substitutions
        # Using sed for simple placeholder replacement
        # The placeholders use @ delimiters to avoid conflicts with XML content

        # Read template and perform substitutions
        ${pkgs.gnused}/bin/sed \
          -e "s|@USERNAME@|$username|g" \
          -e "s|@PASSWORD@|$password|g" \
          -e "s|@COMPUTER_NAME@|$validatedComputerName|g" \
          -e "s|@TIMEZONE@|$windowsTimezone|g" \
          -e "s|@VIRTIO_DRIVER_PATH@|$normalizedVirtioPath|g" \
          "$template" > "$out"

        # Validate the XML structure (basic check)
        if ! ${pkgs.libxml2}/bin/xmllint --noout "$out" 2>/dev/null; then
          echo "Warning: Generated autounattend.xml may have XML syntax issues"
          echo "This might be due to special characters in the configuration values"
        fi

        echo "Generated autounattend.xml with:"
        echo "  Username: $username"
        echo "  Computer Name: $validatedComputerName"
        echo "  Timezone: $windowsTimezone"
        echo "  VirtIO Driver Path: $normalizedVirtioPath"
      '';

  # Create a floppy disk image containing the autounattend.xml
  #
  # Windows Setup automatically searches for autounattend.xml on removable drives.
  # A floppy disk image is the traditional method for providing answer files to VMs.
  #
  # Parameters:
  #   autounattendXml: Derivation containing the autounattend.xml file
  #                    (output of generateAutounattendXml)
  #   additionalFiles: Optional list of additional files to include
  #                    Format: [ { name = "filename"; source = /path/to/file; } ]
  #
  # Returns: A derivation containing the floppy disk image (autounattend.vfd)
  #
  # Example:
  #   makeAutounattendFloppy {
  #     autounattendXml = generateAutounattendXml { username = "admin"; };
  #   }
  makeAutounattendFloppy =
    {
      autounattendXml,
      additionalFiles ? [ ],
    }:
    pkgs.runCommand "autounattend-floppy.vfd"
      {
        nativeBuildInputs = [
          pkgs.dosfstools
          pkgs.mtools
        ];
        inherit autounattendXml;
      }
      ''
        # Create a 1.44 MB floppy disk image (standard size)
        # 1.44 MB = 1474560 bytes = 2880 sectors of 512 bytes
        dd if=/dev/zero of=$out bs=512 count=2880

        # Create FAT12 filesystem (standard for floppy)
        # -n sets the volume label
        ${pkgs.dosfstools}/bin/mkfs.vfat -n "AUTOUNATTEND" $out

        # Copy autounattend.xml to the floppy image root
        # The file MUST be named Autounattend.xml (case-insensitive on Windows)
        ${pkgs.mtools}/bin/mcopy -i $out ${autounattendXml} ::Autounattend.xml

        # Copy any additional files
        ${lib.concatMapStringsSep "\n" (file: ''
          ${pkgs.mtools}/bin/mcopy -i $out ${file.source} ::${file.name}
        '') additionalFiles}

        echo "Created floppy image with Autounattend.xml"
        ${pkgs.mtools}/bin/mdir -i $out ::
      '';

  # Create an ISO image containing the autounattend.xml
  #
  # An ISO image can be mounted as a secondary CD-ROM drive in QEMU.
  # This is an alternative to the floppy method, especially useful when
  # the floppy controller is not available or additional files are needed.
  #
  # Parameters:
  #   autounattendXml: Derivation containing the autounattend.xml file
  #   additionalFiles: Optional list of additional files to include
  #   volumeLabel: ISO volume label (default: "AUTOUNATTEND")
  #
  # Returns: A derivation containing the ISO image (autounattend.iso)
  #
  # Example:
  #   makeAutounattendIso {
  #     autounattendXml = generateAutounattendXml { username = "admin"; };
  #     additionalFiles = [
  #       { name = "setup.ps1"; source = ./scripts/setup.ps1; }
  #     ];
  #   }
  makeAutounattendIso =
    {
      autounattendXml,
      additionalFiles ? [ ],
      volumeLabel ? "AUTOUNATTEND",
    }:
    pkgs.runCommand "autounattend.iso"
      {
        nativeBuildInputs = [ pkgs.xorriso ];
        inherit autounattendXml volumeLabel;
      }
      ''
        # Create a temporary directory for ISO contents
        mkdir -p iso_contents

        # Copy autounattend.xml to the root
        cp ${autounattendXml} iso_contents/Autounattend.xml

        # Copy any additional files
        ${lib.concatMapStringsSep "\n" (file: ''
          cp ${file.source} iso_contents/${file.name}
        '') additionalFiles}

        # Create the ISO image
        # -J: Joliet extension (for Windows compatibility)
        # -r: Rock Ridge extension (for Unix compatibility)
        # -V: Volume label
        xorriso -as mkisofs \
          -J -r \
          -V "$volumeLabel" \
          -o $out \
          iso_contents/

        echo "Created ISO image with Autounattend.xml"
        ls -la iso_contents/
      '';

  # Build a complete Windows VM installation package
  #
  # This function creates a package containing everything needed to boot
  # and install Windows in a QEMU VM with VirtIO drivers:
  # - Autounattend.xml (either floppy or ISO)
  # - VirtIO drivers ISO (if provided)
  # - QEMU run script
  #
  # Parameters:
  #   name: Name for the package
  #   windowsIsoPath: Path to the Windows installation ISO (user-provided)
  #   username, password, computerName, timezone: Passed to generateAutounattendXml
  #   memoryMB: RAM allocation (default: 4096)
  #   cpuCores: Number of CPU cores (default: 2)
  #   diskSizeGB: Target disk size in GB (default: 64)
  #   sshPort: SSH port forwarding (default: 2223)
  #   rdpPort: RDP port forwarding (default: 3389)
  #   useIso: Use ISO instead of floppy for autounattend (default: false)
  #
  # Returns: A derivation containing the Windows VM installation package
  #
  # Note: This function creates a run script but does NOT perform the actual
  # installation (which requires user interaction or the YAML automation engine).
  #
  # Example:
  #   makeWindowsVMPackage {
  #     name = "windows11-agent-vm";
  #     windowsIsoPath = "/path/to/Win11_English_x64.iso";
  #     username = "admin";
  #     password = "admin";
  #     computerName = "WIN11-AGENT";
  #   }
  makeWindowsVMPackage =
    {
      name,
      windowsIsoPath,
      username ? "admin",
      password ? "admin",
      computerName ? "WIN-AGENT",
      timezone ? "UTC",
      memoryMB ? 4096,
      cpuCores ? 2,
      diskSizeGB ? 64,
      sshPort ? 2223,
      rdpPort ? 3389,
      vncDisplay ? 2,
      useIso ? false,
    }:
    let
      # Generate the autounattend.xml
      autounattendXml = generateAutounattendXml {
        inherit
          username
          password
          computerName
          timezone
          ;
      };

      # Create the autounattend media (floppy or ISO)
      autounattendMedia =
        if useIso then
          makeAutounattendIso { inherit autounattendXml; }
        else
          makeAutounattendFloppy { inherit autounattendXml; };

      # VNC port calculation
      vncPort = 5900 + vncDisplay;

      # QEMU run script for Windows installation
      runScript = pkgs.writeShellScriptBin "run-windows-install" ''
        #!/usr/bin/env bash
        set -e

        # Configuration
        WINDOWS_ISO="''${WINDOWS_ISO:-${windowsIsoPath}}"
        VIRTIO_ISO="''${VIRTIO_ISO:-}"
        DISK_IMAGE="''${DISK_IMAGE:-./windows.qcow2}"

        # Check for Windows ISO
        if [ ! -f "$WINDOWS_ISO" ]; then
          echo "Error: Windows ISO not found: $WINDOWS_ISO"
          echo "Please set WINDOWS_ISO environment variable to the path of your Windows ISO"
          echo ""
          echo "You can obtain a Windows ISO from:"
          echo "  - https://www.microsoft.com/software-download/windows11"
          echo "  - https://www.microsoft.com/software-download/windows10ISO"
          exit 1
        fi

        # Check for VirtIO drivers ISO
        if [ -z "$VIRTIO_ISO" ]; then
          # Try to find it in common locations
          if [ -f "${if virtio-win-drivers != null then virtio-win-drivers else "/nonexistent"}" ]; then
            VIRTIO_ISO="${virtio-win-drivers}"
          else
            echo "Warning: VirtIO drivers ISO not found"
            echo "Windows may not be able to see the VirtIO disk during installation"
            echo ""
            echo "Set VIRTIO_ISO environment variable to the path of virtio-win.iso"
            echo "You can build it with: nix build .#virtio-win-drivers"
            echo ""
            read -p "Continue without VirtIO drivers? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
              exit 1
            fi
          fi
        fi

        # Create disk image if it doesn't exist
        if [ ! -f "$DISK_IMAGE" ]; then
          echo "Creating ${toString diskSizeGB}GB QCOW2 disk image..."
          ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 "$DISK_IMAGE" ${toString diskSizeGB}G
        fi

        # Check for KVM support
        if [ ! -r /dev/kvm ]; then
          echo "Warning: KVM not available. Installation will be VERY slow."
          echo "Please ensure:"
          echo "  1. KVM kernel module is loaded (modprobe kvm_intel or kvm_amd)"
          echo "  2. You have permission to access /dev/kvm"
          KVM_FLAG=""
        else
          KVM_FLAG="-enable-kvm"
        fi

        # Build QEMU command
        QEMU_ARGS=(
          $KVM_FLAG
          -m ${toString memoryMB}
          -cpu host
          -smp ${toString cpuCores}
          -machine q35,accel=kvm

          # UEFI firmware (OVMF)
          -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
          -drive if=pflash,format=raw,file=./OVMF_VARS.fd

          # VirtIO disk for Windows installation
          -drive file="$DISK_IMAGE",if=virtio,format=qcow2,cache=writeback

          # Windows installation ISO (as first CD-ROM)
          -drive file="$WINDOWS_ISO",media=cdrom,index=0

          # VirtIO drivers ISO (as second CD-ROM, drive E:)
          ''${VIRTIO_ISO:+-drive file="$VIRTIO_ISO",media=cdrom,index=1}

          # Autounattend media
          ${
            if useIso then
              "-drive file=${autounattendMedia},media=cdrom,index=2"
            else
              "-drive file=${autounattendMedia},if=floppy,format=raw"
          }

          # VirtIO network
          -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22,hostfwd=tcp:127.0.0.1:${toString rdpPort}-:3389
          -device virtio-net-pci,netdev=net0

          # Display and input
          -device virtio-vga
          -device usb-ehci
          -device usb-kbd
          -device usb-tablet

          # VNC for remote viewing
          -vnc 0.0.0.0:${toString vncDisplay}

          # QEMU monitor socket for automation
          -monitor unix:qemu-monitor-socket,server,nowait

          # Boot from CD-ROM first (for installation)
          -boot order=d,menu=on

          # Additional arguments from command line
          "$@"
        )

        # Copy OVMF_VARS for this VM instance (must be writable)
        if [ ! -f ./OVMF_VARS.fd ]; then
          cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd ./OVMF_VARS.fd
          chmod +w ./OVMF_VARS.fd
        fi

        echo "============================================"
        echo "Starting Windows VM Installation"
        echo "============================================"
        echo "Windows ISO: $WINDOWS_ISO"
        echo "VirtIO ISO: ''${VIRTIO_ISO:-Not provided}"
        echo "Disk Image: $DISK_IMAGE"
        echo ""
        echo "Network:"
        echo "  SSH: localhost:${toString sshPort}"
        echo "  RDP: localhost:${toString rdpPort}"
        echo "  VNC: localhost:${toString vncPort}"
        echo ""
        echo "Credentials (after installation):"
        echo "  Username: ${username}"
        echo "  Password: ${password}"
        echo "============================================"

        exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${QEMU_ARGS[@]}"
      '';

      # Run script for booting an already-installed Windows VM
      runInstalledScript = pkgs.writeShellScriptBin "run-windows-vm" ''
        #!/usr/bin/env bash
        set -e

        DISK_IMAGE="''${DISK_IMAGE:-./windows.qcow2}"

        if [ ! -f "$DISK_IMAGE" ]; then
          echo "Error: Disk image not found: $DISK_IMAGE"
          echo "Run the installation first, or set DISK_IMAGE to the correct path."
          exit 1
        fi

        # Copy OVMF_VARS if not present
        if [ ! -f ./OVMF_VARS.fd ]; then
          cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd ./OVMF_VARS.fd
          chmod +w ./OVMF_VARS.fd
        fi

        # Check for KVM support
        if [ ! -r /dev/kvm ]; then
          echo "Warning: KVM not available. VM will run slowly."
          KVM_FLAG=""
        else
          KVM_FLAG="-enable-kvm"
        fi

        QEMU_ARGS=(
          $KVM_FLAG
          -m ${toString memoryMB}
          -cpu host
          -smp ${toString cpuCores}
          -machine q35,accel=kvm

          -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
          -drive if=pflash,format=raw,file=./OVMF_VARS.fd

          -drive file="$DISK_IMAGE",if=virtio,format=qcow2,cache=writeback

          -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22,hostfwd=tcp:127.0.0.1:${toString rdpPort}-:3389
          -device virtio-net-pci,netdev=net0

          -device virtio-vga
          -device usb-ehci
          -device usb-kbd
          -device usb-tablet

          -vnc 0.0.0.0:${toString vncDisplay}
          -monitor unix:qemu-monitor-socket,server,nowait

          "$@"
        )

        echo "Starting Windows VM..."
        echo "  SSH: localhost:${toString sshPort}"
        echo "  RDP: localhost:${toString rdpPort}"
        echo "  VNC: localhost:${toString vncPort}"
        echo "  Username: ${username}"

        exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${QEMU_ARGS[@]}"
      '';

    in
    pkgs.symlinkJoin {
      inherit name;
      paths = [
        runScript
        runInstalledScript
      ];
      passthru = {
        inherit
          autounattendXml
          autounattendMedia
          runScript
          runInstalledScript
          sshPort
          rdpPort
          vncPort
          username
          password
          computerName
          ;
      };

      meta = {
        description = "Windows VM installation package for ${computerName}";
        homepage = "https://github.com/blocksense/agent-harbor";
        platforms = [ "x86_64-linux" ];
      };
    };

  # Create a run script for Windows VM health check
  #
  # This function creates a test script that verifies a Windows VM can boot
  # and respond to SSH health checks. It's used to verify that the unattended
  # installation completed successfully.
  #
  # Parameters:
  #   sshPort: SSH port (default: 2223)
  #   username: SSH username (default: "admin")
  #   password: SSH password (default: "admin")
  #   bootTimeoutSeconds: Maximum time to wait for SSH (default: 300)
  #   sshRetries: Number of SSH connection retries (default: 50)
  #   sshRetryDelay: Seconds between SSH retries (default: 6)
  #
  # Returns: A derivation containing the health check script
  makeWindowsHealthCheck =
    {
      sshPort ? 2223,
      username ? "admin",
      password ? "admin",
      bootTimeoutSeconds ? 300,
      sshRetries ? 50,
      sshRetryDelay ? 6,
    }:
    pkgs.writeShellScriptBin "check-windows-vm-health" ''
      #!/usr/bin/env bash
      set -e

      SSH_PORT="''${SSH_PORT:-${toString sshPort}}"
      USERNAME="''${USERNAME:-${username}}"
      PASSWORD="''${PASSWORD:-${password}}"
      BOOT_TIMEOUT="${toString bootTimeoutSeconds}"
      SSH_RETRIES="${toString sshRetries}"
      SSH_RETRY_DELAY="${toString sshRetryDelay}"

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      NC='\033[0m'

      log_info() { echo -e "''${GREEN}[INFO]''${NC} $1"; }
      log_warn() { echo -e "''${YELLOW}[WARN]''${NC} $1"; }
      log_error() { echo -e "''${RED}[ERROR]''${NC} $1"; }

      log_info "============================================"
      log_info "Windows VM Health Check"
      log_info "============================================"
      log_info "SSH Port: $SSH_PORT"
      log_info "Username: $USERNAME"
      log_info "Timeout: $BOOT_TIMEOUT seconds"
      log_info "============================================"

      SSH_READY=false
      START_TIME=$(date +%s)

      for i in $(seq 1 "$SSH_RETRIES"); do
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - START_TIME))

        if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
          log_error "Boot timeout exceeded ($BOOT_TIMEOUT seconds)"
          exit 1
        fi

        log_info "SSH probe attempt $i/$SSH_RETRIES (elapsed: ''${ELAPSED}s)..."

        # Try ssh-keyscan to check if SSH is listening
        if ${pkgs.openssh}/bin/ssh-keyscan -p "$SSH_PORT" 127.0.0.1 2>/dev/null | grep -q "ssh-"; then
          log_info "SSH is listening, attempting connection..."

          # Try actual SSH connection
          if ${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            -p "$SSH_PORT" \
            "$USERNAME@127.0.0.1" \
            "echo 'SSH connection successful'" 2>/dev/null; then
            SSH_READY=true
            break
          fi
        fi

        sleep "$SSH_RETRY_DELAY"
      done

      if [ "$SSH_READY" != "true" ]; then
        log_error "Failed to establish SSH connection within timeout"
        exit 1
      fi

      log_info "============================================"
      log_info "SSH connection established!"
      log_info "============================================"

      # Run health check command (get Windows version)
      log_info "Running health check: systeminfo"

      SYSINFO_OUTPUT=$(${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$SSH_PORT" \
        "$USERNAME@127.0.0.1" \
        'powershell -Command "[System.Environment]::OSVersion.VersionString"' 2>/dev/null)

      if [ -z "$SYSINFO_OUTPUT" ]; then
        log_error "Health check command returned empty output"
        exit 1
      fi

      log_info "Windows version information:"
      echo "$SYSINFO_OUTPUT"

      if echo "$SYSINFO_OUTPUT" | grep -qi "Windows"; then
        log_info "Health check passed: Windows is responding correctly"
      else
        log_error "Health check failed: unexpected output"
        exit 1
      fi

      log_info "============================================"
      log_info "HEALTH CHECK PASSED"
      log_info "============================================"
    '';

  # Build a Windows VM image with automated unattended installation
  #
  # This function creates a Windows VM by running the unattended installation
  # inside QEMU. Unlike macOS, Windows uses autounattend.xml for full automation,
  # so no YAML automation is typically needed during installation.
  #
  # Parameters:
  #   name: Name for the resulting VM package
  #   windowsIso: Path to the Windows installation ISO (user-provided)
  #   virtioDriversIso: Path to VirtIO drivers ISO (from iso-fetchers.fetchVirtIODrivers)
  #   automationConfig: Optional path to YAML automation config for post-install setup
  #   diskSizeGB: Target disk size in GB (default: 64)
  #   memoryMB: RAM allocation in MB (default: 4096)
  #   cpuCores: Number of CPU cores (default: 2)
  #   sshPort: SSH port forwarding (default: 2223)
  #   rdpPort: RDP port forwarding (default: 3389)
  #   vncDisplay: VNC display number (default: 2, meaning port 5902)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #   computerName: Windows computer name (default: "WIN-AGENT")
  #   timezone: Timezone setting (default: "UTC")
  #   installTimeoutSeconds: Maximum time to wait for installation (default: 3600 = 1 hour)
  #   enableTpm: Enable TPM 2.0 emulation via swtpm (default: false)
  #              Recommended for Windows 11 but not required with registry bypass
  #   allowImpure: Enable impure derivation mode (default: false)
  #
  # Returns: A derivation containing the Windows QCOW2 image and run script
  #
  # Example usage:
  #   makeWindowsVM {
  #     name = "windows11-agent-vm";
  #     windowsIso = /path/to/Win11_English_x64.iso;
  #     virtioDriversIso = virtio-win-drivers;
  #     username = "admin";
  #     password = "admin";
  #     computerName = "WIN11-AGENT";
  #   }
  #
  # Note: This function creates an impure derivation since Windows installation
  # requires KVM hardware virtualization and network access for some components.
  makeWindowsVM =
    {
      name,
      windowsIso,
      virtioDriversIso,
      automationConfig ? null,
      diskSizeGB ? 64,
      memoryMB ? 4096,
      cpuCores ? 2,
      sshPort ? 2223,
      rdpPort ? 3389,
      vncDisplay ? 2,
      username ? "admin",
      password ? "admin",
      computerName ? "WIN-AGENT",
      timezone ? "UTC",
      installTimeoutSeconds ? 3600,
      enableTpm ? false,
      allowImpure ? false,
    }:
    let
      # Minimum disk size check (40 GB recommended for Windows)
      diskSize =
        if diskSizeGB < 40 then
          throw "diskSizeGB ${toString diskSizeGB} too small for Windows (minimum 40GB recommended)"
        else
          diskSizeGB;

      # VNC port is 5900 + display number
      vncPort = 5900 + vncDisplay;

      # Generate the autounattend.xml
      autounattendXml = generateAutounattendXml {
        inherit
          username
          password
          computerName
          timezone
          ;
        # VirtIO drivers are mounted as second CD-ROM (drive E:)
        virtioDriverPath = "E:\\";
      };

      # Create the autounattend floppy image
      # Floppy is the standard/reliable method for Windows unattended installation
      autounattendFloppy = makeAutounattendFloppy { inherit autounattendXml; };

      # QEMU arguments for Windows installation
      # This configuration:
      # - Uses UEFI boot via OVMF
      # - Provides VirtIO disk (requires viostor driver from VirtIO ISO)
      # - Provides VirtIO network (requires netkvm driver from VirtIO ISO)
      # - Mounts Windows ISO as first CD-ROM (D:)
      # - Mounts VirtIO drivers ISO as second CD-ROM (E:)
      # - Mounts autounattend.xml on floppy (A:)
      # - Enables VNC for monitoring installation progress
      # - Forwards SSH and RDP ports for post-install access
      qemuArgsInstall = ''
        args=(
          -enable-kvm
          -m ${toString memoryMB}
          -cpu host
          -smp ${toString cpuCores}
          -machine q35,accel=kvm

          # UEFI firmware (OVMF)
          # OVMF_CODE.fd is read-only firmware, OVMF_VARS.fd stores NVRAM variables
          -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
          -drive if=pflash,format=raw,file="$WORK_DIR/OVMF_VARS.fd"

          # VirtIO disk for Windows installation
          # Windows will see this after viostor driver is loaded
          -drive file="$WORK_DIR/windows.qcow2",if=virtio,format=qcow2,cache=writeback

          # Windows installation ISO (first CD-ROM, typically D:)
          -drive file="${windowsIso}",media=cdrom,index=0,readonly=on

          # VirtIO drivers ISO (second CD-ROM, typically E:)
          # Contains drivers: viostor, netkvm, vioserial, balloon, qxldod
          -drive file="${virtioDriversIso}",media=cdrom,index=1,readonly=on

          # Autounattend floppy (A:)
          # Windows Setup automatically searches for Autounattend.xml on floppy
          -drive file="${autounattendFloppy}",if=floppy,format=raw,readonly=on

          # VirtIO network with port forwarding
          # SSH (22) and RDP (3389) are forwarded to host ports
          -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22,hostfwd=tcp:127.0.0.1:${toString rdpPort}-:3389
          -device virtio-net-pci,netdev=net0

          # Display: VirtIO VGA for best performance
          -device virtio-vga

          # USB for keyboard and mouse input
          -device usb-ehci
          -device usb-kbd
          -device usb-tablet

          # VNC for remote viewing (useful for debugging installation)
          -vnc 0.0.0.0:${toString vncDisplay}

          # QEMU monitor socket for automation/control
          -monitor unix:"$WORK_DIR/qemu-monitor-socket",server,nowait

          # Boot from CD-ROM first (Windows installation media)
          -boot order=d,menu=on

          # Disable snapshot mode - we want persistent changes
          -no-reboot
        )
      '';

      # QEMU arguments for running installed Windows (post-installation)
      qemuArgsRun = ''
        args=(
          -enable-kvm
          -m ${toString memoryMB}
          -cpu host
          -smp ${toString cpuCores}
          -machine q35,accel=kvm

          -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
          -drive if=pflash,format=raw,file="$WORK_DIR/OVMF_VARS.fd"

          -drive file="$WORK_DIR/windows.qcow2",if=virtio,format=qcow2,cache=writeback

          -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22,hostfwd=tcp:127.0.0.1:${toString rdpPort}-:3389
          -device virtio-net-pci,netdev=net0

          -device virtio-vga
          -device usb-ehci
          -device usb-kbd
          -device usb-tablet

          -vnc 0.0.0.0:${toString vncDisplay}
          -monitor unix:"$WORK_DIR/qemu-monitor-socket",server,nowait
        )
      '';

      # Wait for SSH to become available (indicates Windows has booted)
      waitForSshScript = pkgs.writeShellScript "wait-for-ssh" ''
        SSH_PORT="${toString sshPort}"
        USERNAME="${username}"
        PASSWORD="${password}"
        TIMEOUT="${toString installTimeoutSeconds}"

        echo "Waiting for SSH to become available (timeout: $TIMEOUT seconds)..."
        START_TIME=$(date +%s)

        while true; do
          CURRENT_TIME=$(date +%s)
          ELAPSED=$((CURRENT_TIME - START_TIME))

          if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
            echo "ERROR: Timeout waiting for SSH after $TIMEOUT seconds"
            return 1
          fi

          # Try ssh-keyscan to check if SSH is listening
          if ${pkgs.openssh}/bin/ssh-keyscan -p "$SSH_PORT" 127.0.0.1 2>/dev/null | grep -q "ssh-"; then
            echo "SSH is listening, attempting connection..."

            # Try actual SSH connection
            if ${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 \
              -p "$SSH_PORT" \
              "$USERNAME@127.0.0.1" \
              "echo 'SSH connection successful'" 2>/dev/null; then
              echo "SSH connection established!"
              return 0
            fi
          fi

          echo "SSH not ready yet (elapsed: ''${ELAPSED}s)..."
          sleep 10
        done
      '';

      # Graceful shutdown via SSH
      shutdownScript = pkgs.writeShellScript "shutdown-windows" ''
        SSH_PORT="${toString sshPort}"
        USERNAME="${username}"
        PASSWORD="${password}"

        echo "Initiating graceful shutdown via SSH..."

        # Send shutdown command via SSH
        ${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -p "$SSH_PORT" \
          "$USERNAME@127.0.0.1" \
          "shutdown /s /t 5 /f" 2>/dev/null || true

        echo "Shutdown command sent, waiting for VM to terminate..."
        sleep 30
      '';

      # Main build script that orchestrates the Windows installation
      buildScript = pkgs.writeShellScript "build-windows-vm" ''
        set -ex

        WORK_DIR="$(pwd)"
        export WORK_DIR

        echo "============================================"
        echo "Windows VM Build - ${name}"
        echo "============================================"
        echo "Windows ISO: ${windowsIso}"
        echo "VirtIO ISO: ${virtioDriversIso}"
        echo "Disk Size: ${toString diskSize}GB"
        echo "Memory: ${toString memoryMB}MB"
        echo "CPU Cores: ${toString cpuCores}"
        echo "VNC Port: ${toString vncPort}"
        echo "SSH Port: ${toString sshPort}"
        echo "RDP Port: ${toString rdpPort}"
        echo "Username: ${username}"
        echo "Computer Name: ${computerName}"
        echo "============================================"

        # Verify Windows ISO exists
        if [ ! -f "${windowsIso}" ]; then
          echo "ERROR: Windows ISO not found: ${windowsIso}"
          exit 1
        fi

        # Verify VirtIO drivers ISO exists
        if [ ! -f "${virtioDriversIso}" ]; then
          echo "ERROR: VirtIO drivers ISO not found: ${virtioDriversIso}"
          exit 1
        fi

        # Create QCOW2 disk image for Windows
        echo "Creating ${toString diskSize}GB QCOW2 disk image..."
        ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 "$WORK_DIR/windows.qcow2" ${toString diskSize}G

        # Copy OVMF_VARS for this VM instance (must be writable for NVRAM)
        cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd "$WORK_DIR/OVMF_VARS.fd"
        chmod +w "$WORK_DIR/OVMF_VARS.fd"

        echo "============================================"
        echo "Stage 1: Windows Unattended Installation"
        echo "VNC available at: localhost:${toString vncPort}"
        echo "============================================"
        echo ""
        echo "The installation will proceed automatically via autounattend.xml."
        echo "You can monitor progress via VNC if needed."
        echo ""

        # Start QEMU for Windows installation
        ${qemuArgsInstall}
        ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}" &
        QEMU_PID=$!

        # Wait for QEMU to start
        sleep 10

        # Wait for SSH to become available (indicates installation is complete)
        echo "Waiting for Windows installation to complete..."
        echo "This typically takes 15-30 minutes depending on hardware."
        echo ""

        if ${waitForSshScript}; then
          echo "============================================"
          echo "Windows installation completed successfully!"
          echo "============================================"

          ${
            if automationConfig != null && yaml-automation-runner != null then
              ''
                echo "Running post-installation YAML automation..."
                ${yaml-automation-runner}/bin/yaml-automation-runner \
                  --config ${automationConfig} \
                  --vnc localhost:${toString vncPort} \
                  --debug \
                  || echo "Automation completed or encountered issues."
              ''
            else if automationConfig != null then
              ''
                echo "Warning: automationConfig provided but yaml-automation-runner not available."
                echo "Skipping post-installation automation."
              ''
            else
              ''
                echo "No post-installation automation configured."
              ''
          }

          # Graceful shutdown
          ${shutdownScript}

          # Wait for QEMU to exit
          echo "Waiting for VM to shut down..."
          wait $QEMU_PID || true

        else
          echo "ERROR: Windows installation did not complete within timeout."
          echo "Check VNC at localhost:${toString vncPort} for status."

          # Kill QEMU on failure
          kill $QEMU_PID 2>/dev/null || true
          wait $QEMU_PID || true

          exit 1
        fi

        echo "============================================"
        echo "Windows VM build complete!"
        echo "Output: $WORK_DIR/windows.qcow2"
        echo "============================================"
      '';

      # Create the run script for the resulting VM
      runScript = pkgs.writeShellScriptBin "run-vm" ''
        #!/usr/bin/env bash
        set -e

        SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
        VM_DIR="''${SCRIPT_DIR}/.."

        # Check for KVM support
        if [ ! -r /dev/kvm ]; then
          echo "Error: KVM not available. Please ensure:"
          echo "  1. KVM kernel module is loaded (modprobe kvm_intel or kvm_amd)"
          echo "  2. You have permission to access /dev/kvm"
          exit 1
        fi

        # Verify disk image exists
        if [ ! -f "$VM_DIR/windows.qcow2" ]; then
          echo "Error: Disk image not found: $VM_DIR/windows.qcow2"
          exit 1
        fi

        # Copy OVMF_VARS if not already present (for writable NVRAM)
        if [ ! -f "$VM_DIR/OVMF_VARS.fd" ]; then
          cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd "$VM_DIR/OVMF_VARS.fd"
          chmod +w "$VM_DIR/OVMF_VARS.fd"
        fi

        WORK_DIR="$VM_DIR"
        export WORK_DIR

        ${qemuArgsRun}

        echo "Starting Windows VM..."
        echo "SSH: ssh -p ${toString sshPort} ${username}@localhost"
        echo "RDP: localhost:${toString rdpPort}"
        echo "VNC: localhost:${toString vncPort}"
        echo "Username: ${username}"
        echo ""

        exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}" "$@"
      '';

      impureAttrs = lib.optionalAttrs allowImpure {
        # Mark as impure for manual verification runs (requires impure-derivations feature).
        # Keep this gated so default flake evaluation stays pure for nix develop/flake check.
        __impure = true;
      };

    in
    pkgs.runCommand name
      (
        {
          nativeBuildInputs = [
            pkgs.qemu_kvm
            pkgs.openssh
            pkgs.sshpass
          ];

          passthru = {
            inherit
              runScript
              autounattendXml
              autounattendFloppy
              sshPort
              rdpPort
              vncPort
              username
              password
              computerName
              virtioDriverCheckScript
              ;
          };
        }
        // impureAttrs
      )
      ''
        # Create output directory structure
        mkdir -p $out/bin

        # Run the build
        ${buildScript}

        # Copy results to output
        cp windows.qcow2 $out/
        cp OVMF_VARS.fd $out/
        cp ${runScript}/bin/run-vm $out/bin/
      '';

  # Create a run script for a Windows VM directory (output of makeWindowsVM)
  #
  # This function creates a run script that operates on a VM directory structure
  # containing windows.qcow2 and OVMF_VARS.fd.
  # The VM directory must be provided at runtime via environment variable or argument.
  #
  # Parameters:
  #   sshPort: SSH port forwarding (default: 2223)
  #   rdpPort: RDP port forwarding (default: 3389)
  #   memoryMB: RAM allocation in MB (default: 4096)
  #   cpuCores: Number of CPU cores (default: 2)
  #   vncDisplay: VNC display number (default: 2, meaning port 5902)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #
  # Example usage:
  #   VM_DIR=/path/to/windows-vm ./result/bin/run-windows-vm
  #   or
  #   ./result/bin/run-windows-vm /path/to/windows-vm
  #
  makeWindowsRunScript =
    {
      sshPort ? 2223,
      rdpPort ? 3389,
      memoryMB ? 4096,
      cpuCores ? 2,
      vncDisplay ? 2,
      username ? "admin",
      password ? "admin",
    }:
    let
      vncPort = 5900 + vncDisplay;
    in
    pkgs.writeShellScriptBin "run-windows-vm" ''
      #!/usr/bin/env bash
      set -e

      # VM directory can be provided as argument or environment variable
      VM_DIR="''${1:-''${VM_DIR:-}}"

      if [ -z "$VM_DIR" ]; then
        echo "Error: VM directory not specified"
        echo "Usage: $0 <vm-directory>"
        echo "   or: VM_DIR=<vm-directory> $0"
        exit 1
      fi

      # Verify required files exist
      if [ ! -f "$VM_DIR/windows.qcow2" ]; then
        echo "Error: Disk image not found: $VM_DIR/windows.qcow2"
        exit 1
      fi

      # Copy OVMF_VARS if not present (must be writable)
      if [ ! -f "$VM_DIR/OVMF_VARS.fd" ]; then
        cp ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd "$VM_DIR/OVMF_VARS.fd"
        chmod +w "$VM_DIR/OVMF_VARS.fd"
      fi

      # Check for KVM support
      if [ ! -r /dev/kvm ]; then
        echo "Error: KVM not available. Please ensure:"
        echo "  1. KVM kernel module is loaded (modprobe kvm_intel or kvm_amd)"
        echo "  2. You have permission to access /dev/kvm"
        exit 1
      fi

      args=(
        -enable-kvm
        -m ${toString memoryMB}
        -cpu host
        -smp ${toString cpuCores}
        -machine q35,accel=kvm

        -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd
        -drive if=pflash,format=raw,file="$VM_DIR/OVMF_VARS.fd"

        -drive file="$VM_DIR/windows.qcow2",if=virtio,format=qcow2,cache=writeback

        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22,hostfwd=tcp:127.0.0.1:${toString rdpPort}-:3389
        -device virtio-net-pci,netdev=net0

        -device virtio-vga
        -device usb-ehci
        -device usb-kbd
        -device usb-tablet

        -vnc 0.0.0.0:${toString vncDisplay}
        -monitor unix:qemu-monitor-socket,server,nowait

        "''${@:2}"
      )

      echo "Starting Windows VM from: $VM_DIR"
      echo "SSH will be available at: localhost:${toString sshPort}"
      echo "RDP will be available at: localhost:${toString rdpPort}"
      echo "VNC will be available at: localhost:${toString vncPort}"
      echo "Username: ${username}"
      echo ""

      exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}"
    '';

  # Create a cached boot test script for a pre-built Windows VM
  #
  # This function creates a test script that verifies a pre-built Windows VM
  # can boot from its cached QCOW2 image and respond to SSH health checks.
  #
  # The test:
  # 1. Starts the VM in the background
  # 2. Waits for SSH to become available (with timeout and retries)
  # 3. Runs systeminfo via SSH to verify Windows is responding
  # 4. Gracefully shuts down the VM via SSH
  # 5. Reports success/failure with exit code
  #
  # Parameters:
  #   vmDir: Path to the VM directory (output of makeWindowsVM)
  #   sshPort: SSH port forwarding (default: 2223)
  #   rdpPort: RDP port forwarding (default: 3389)
  #   memoryMB: RAM allocation in MB (default: 4096)
  #   cpuCores: Number of CPU cores (default: 2)
  #   vncDisplay: VNC display number (default: 2, meaning port 5902)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #   bootTimeoutSeconds: Maximum time to wait for SSH (default: 300)
  #   sshRetries: Number of SSH connection retries (default: 50)
  #   sshRetryDelay: Seconds between SSH retries (default: 6)
  #
  # Example usage:
  #   nix build .#windows-vm-test
  #   ./result/bin/test-windows-vm-boot
  #
  makeWindowsCachedBootTest =
    {
      vmDir,
      sshPort ? 2223,
      rdpPort ? 3389,
      memoryMB ? 4096,
      cpuCores ? 2,
      vncDisplay ? 2,
      username ? "admin",
      password ? "admin",
      bootTimeoutSeconds ? 300,
      sshRetries ? 50,
      sshRetryDelay ? 6,
    }:
    let
      vncPort = 5900 + vncDisplay;

      # Create the run script for this specific VM
      runScript = makeWindowsRunScript {
        inherit
          sshPort
          rdpPort
          memoryMB
          cpuCores
          vncDisplay
          username
          password
          ;
      };

      # Test script that orchestrates boot, health check, and shutdown
      testScript = pkgs.writeShellScriptBin "test-windows-vm-boot" ''
        #!/usr/bin/env bash
        set -e

        # Configuration
        VM_DIR="${vmDir}"
        SSH_PORT="${toString sshPort}"
        USERNAME="${username}"
        PASSWORD="${password}"
        BOOT_TIMEOUT="${toString bootTimeoutSeconds}"
        SSH_RETRIES="${toString sshRetries}"
        SSH_RETRY_DELAY="${toString sshRetryDelay}"

        # Colors for output
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        NC='\033[0m' # No Color

        log_info() {
          echo -e "''${GREEN}[INFO]''${NC} $1"
        }

        log_warn() {
          echo -e "''${YELLOW}[WARN]''${NC} $1"
        }

        log_error() {
          echo -e "''${RED}[ERROR]''${NC} $1"
        }

        cleanup() {
          log_info "Cleaning up..."
          if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
            log_info "Sending SIGTERM to QEMU (PID: $QEMU_PID)"
            kill "$QEMU_PID" 2>/dev/null || true
            # Wait briefly for graceful shutdown
            sleep 5
            # Force kill if still running
            if kill -0 "$QEMU_PID" 2>/dev/null; then
              log_warn "QEMU still running, sending SIGKILL"
              kill -9 "$QEMU_PID" 2>/dev/null || true
            fi
          fi
          # Clean up monitor socket
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

        # Verify VM directory exists
        if [ ! -d "$VM_DIR" ]; then
          log_error "VM directory not found: $VM_DIR"
          exit 1
        fi

        # Verify required files
        if [ ! -f "$VM_DIR/windows.qcow2" ]; then
          log_error "Disk image not found: $VM_DIR/windows.qcow2"
          exit 1
        fi

        log_info "Starting Windows VM..."

        # Start QEMU in the background with nographic mode for testing
        ${runScript}/bin/run-windows-vm "$VM_DIR" -nographic -serial none &
        QEMU_PID=$!

        log_info "QEMU started with PID: $QEMU_PID"
        log_info "VNC available at: localhost:${toString vncPort}"

        # Wait for SSH to become available
        log_info "Waiting for SSH to become available (up to $BOOT_TIMEOUT seconds)..."

        SSH_READY=false
        START_TIME=$(date +%s)

        for i in $(seq 1 "$SSH_RETRIES"); do
          CURRENT_TIME=$(date +%s)
          ELAPSED=$((CURRENT_TIME - START_TIME))

          if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
            log_error "Boot timeout exceeded ($BOOT_TIMEOUT seconds)"
            break
          fi

          log_info "SSH probe attempt $i/$SSH_RETRIES (elapsed: ''${ELAPSED}s)..."

          # Try ssh-keyscan first to check if SSH is listening
          if ${pkgs.openssh}/bin/ssh-keyscan -p "$SSH_PORT" 127.0.0.1 2>/dev/null | grep -q "ssh-"; then
            log_info "SSH is listening, attempting connection..."

            # Try actual SSH connection
            if ${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 \
              -p "$SSH_PORT" \
              "$USERNAME@127.0.0.1" \
              "echo 'SSH connection successful'" 2>/dev/null; then
              SSH_READY=true
              break
            fi
          fi

          # Check if QEMU is still running
          if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log_error "QEMU process died unexpectedly"
            exit 1
          fi

          sleep "$SSH_RETRY_DELAY"
        done

        if [ "$SSH_READY" != "true" ]; then
          log_error "Failed to establish SSH connection within timeout"
          exit 1
        fi

        log_info "============================================"
        log_info "SSH connection established!"
        log_info "============================================"

        # Run health check command (get Windows version info via PowerShell)
        log_info "Running health check: Windows version query"

        SYSINFO_OUTPUT=$(${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -p "$SSH_PORT" \
          "$USERNAME@127.0.0.1" \
          'powershell -Command "[System.Environment]::OSVersion.VersionString"' 2>/dev/null)

        if [ -z "$SYSINFO_OUTPUT" ]; then
          log_error "Health check command returned empty output"
          exit 1
        fi

        log_info "Windows version information:"
        echo "$SYSINFO_OUTPUT"

        # Verify we got valid Windows version info
        if echo "$SYSINFO_OUTPUT" | grep -qi "Windows"; then
          log_info "Health check passed: Windows is responding correctly"
        else
          log_error "Health check failed: unexpected output"
          exit 1
        fi

        # Graceful shutdown via SSH
        log_info "============================================"
        log_info "Initiating graceful shutdown..."
        log_info "============================================"

        ${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -p "$SSH_PORT" \
          "$USERNAME@127.0.0.1" \
          "shutdown /s /t 5 /f" 2>/dev/null || true

        log_info "Shutdown command sent, waiting for VM to terminate..."

        # Wait for QEMU to exit gracefully (up to 60 seconds for Windows shutdown)
        for i in $(seq 1 60); do
          if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            log_info "VM shut down gracefully"
            break
          fi
          sleep 1
        done

        # If still running, the cleanup trap will handle it
        if kill -0 "$QEMU_PID" 2>/dev/null; then
          log_warn "VM did not shut down gracefully, will be killed by cleanup"
        fi

        log_info "============================================"
        log_info "TEST PASSED: Windows VM cached boot test successful!"
        log_info "============================================"

        exit 0
      '';
    in
    pkgs.symlinkJoin {
      name = "windows-cached-boot-test";
      paths = [
        testScript
        runScript
      ];
      passthru = {
        inherit
          testScript
          runScript
          vmDir
          sshPort
          rdpPort
          username
          password
          ;
      };
    };
}
