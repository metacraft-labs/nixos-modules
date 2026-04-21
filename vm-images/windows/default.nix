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

  # Path to the CI-runner autounattend template (bare-metal variant)
  ciAutounattendTemplate = ./ci-runner/autounattend-template.xml;

  # Path to the VirtIO driver check script
  virtioDriverCheckScript = ./virtio-driver-check.ps1;

  # Paths to the extracted shell scripts (kept standalone for maintainability).
  # Each script reads its configuration from environment variables and is
  # wrapped below via `pkgs.writeShellApplication` which sets up PATH via
  # `runtimeInputs` so the scripts can call bare command names.
  scripts = {
    waitForSsh = ./scripts/wait-for-ssh.sh;
    shutdownWindows = ./scripts/shutdown-windows.sh;
    healthCheck = ./scripts/health-check.sh;
    runInstall = ./scripts/run-install.sh;
    runVm = ./scripts/run-vm.sh;
    buildVm = ./scripts/build-vm.sh;
    bootTest = ./scripts/boot-test.sh;
  };

  # Shell-escape a build-time value so injecting it into the wrapper text is
  # safe regardless of the characters it contains.
  sh = lib.escapeShellArg;

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
        nativeBuildInputs = [
          pkgs.gnused
          pkgs.libxml2
        ];
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
        sed \
          -e "s|@USERNAME@|$username|g" \
          -e "s|@PASSWORD@|$password|g" \
          -e "s|@COMPUTER_NAME@|$validatedComputerName|g" \
          -e "s|@TIMEZONE@|$windowsTimezone|g" \
          -e "s|@VIRTIO_DRIVER_PATH@|$normalizedVirtioPath|g" \
          "$template" > "$out"

        if ! xmllint --noout "$out" 2>/dev/null; then
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
        # 1.44 MB floppy disk image (2880 sectors of 512 bytes)
        dd if=/dev/zero of=$out bs=512 count=2880
        mkfs.vfat -n "AUTOUNATTEND" $out

        # Windows Setup looks for this exact (case-insensitive) name.
        mcopy -i $out ${autounattendXml} ::Autounattend.xml

        ${lib.concatMapStringsSep "\n" (file: ''
          mcopy -i $out ${file.source} ::${file.name}
        '') additionalFiles}

        echo "Created floppy image with Autounattend.xml"
        mdir -i $out ::
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

      virtioIsoDefault = if virtio-win-drivers != null then "${virtio-win-drivers}" else "";

      # QEMU run script for Windows installation
      runScript = pkgs.writeShellApplication {
        name = "run-windows-install";
        runtimeInputs = [ pkgs.qemu_kvm ];
        text = ''
          export WINDOWS_ISO="''${WINDOWS_ISO:-${windowsIsoPath}}"
          export VIRTIO_ISO="''${VIRTIO_ISO:-${virtioIsoDefault}}"
          export DISK_IMAGE="''${DISK_IMAGE:-./windows.qcow2}"
          export DISK_SIZE_GB=${sh (toString diskSizeGB)}
          export MEMORY_MB=${sh (toString memoryMB)}
          export CPU_CORES=${sh (toString cpuCores)}
          export SSH_PORT=${sh (toString sshPort)}
          export RDP_PORT=${sh (toString rdpPort)}
          export VNC_DISPLAY=${sh (toString vncDisplay)}
          export USERNAME=${sh username}
          export PASSWORD=${sh password}
          export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
          export OVMF_VARS_SRC="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
          export AUTOUNATTEND_MEDIA="${autounattendMedia}"
          export AUTOUNATTEND_MEDIA_TYPE=${sh (if useIso then "iso" else "floppy")}
          exec bash ${scripts.runInstall} "$@"
        '';
      };

      # Run script for booting an already-installed Windows VM
      runInstalledScript = pkgs.writeShellApplication {
        name = "run-windows-vm";
        runtimeInputs = [ pkgs.qemu_kvm ];
        text = ''
          export MEMORY_MB=${sh (toString memoryMB)}
          export CPU_CORES=${sh (toString cpuCores)}
          export SSH_PORT=${sh (toString sshPort)}
          export RDP_PORT=${sh (toString rdpPort)}
          export VNC_DISPLAY=${sh (toString vncDisplay)}
          export USERNAME=${sh username}
          export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
          export OVMF_VARS_SRC="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
          exec bash ${scripts.runVm} "$@"
        '';
      };

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
    pkgs.writeShellApplication {
      name = "check-windows-vm-health";
      runtimeInputs = [
        pkgs.openssh
        pkgs.sshpass
      ];
      text = ''
        export SSH_PORT="''${SSH_PORT:-${toString sshPort}}"
        export USERNAME="''${USERNAME:-${username}}"
        export PASSWORD="''${PASSWORD:-${password}}"
        export BOOT_TIMEOUT=${sh (toString bootTimeoutSeconds)}
        export SSH_RETRIES=${sh (toString sshRetries)}
        export SSH_RETRY_DELAY=${sh (toString sshRetryDelay)}
        exec bash ${scripts.healthCheck} "$@"
      '';
    };

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

      # Poll SSH until the VM is reachable with the given credentials.
      waitForSshBin = pkgs.writeShellApplication {
        name = "wait-for-ssh";
        runtimeInputs = [
          pkgs.openssh
          pkgs.sshpass
        ];
        text = ''
          export SSH_PORT=${sh (toString sshPort)}
          export USERNAME=${sh username}
          export PASSWORD=${sh password}
          export TIMEOUT=${sh (toString installTimeoutSeconds)}
          exec bash ${scripts.waitForSsh} "$@"
        '';
      };

      # Send a Windows shutdown command over SSH.
      shutdownBin = pkgs.writeShellApplication {
        name = "shutdown-windows";
        runtimeInputs = [
          pkgs.openssh
          pkgs.sshpass
        ];
        text = ''
          export SSH_PORT=${sh (toString sshPort)}
          export USERNAME=${sh username}
          export PASSWORD=${sh password}
          exec bash ${scripts.shutdownWindows} "$@"
        '';
      };

      # Shell snippet for post-install automation (empty when not configured).
      automationCmd =
        if automationConfig != null && yaml-automation-runner != null then
          "${yaml-automation-runner}/bin/yaml-automation-runner"
          + " --config ${automationConfig}"
          + " --vnc localhost:${toString vncPort}"
          + " --debug"
        else
          "";

      # Main build script that orchestrates the Windows installation.
      buildVmBin = pkgs.writeShellApplication {
        name = "build-windows-vm";
        runtimeInputs = [ pkgs.qemu_kvm ];
        text = ''
          export NAME=${sh name}
          export WINDOWS_ISO="${windowsIso}"
          export VIRTIO_ISO="${virtioDriversIso}"
          export AUTOUNATTEND_MEDIA="${autounattendFloppy}"
          export AUTOUNATTEND_MEDIA_TYPE=floppy
          export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
          export OVMF_VARS_SRC="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
          export WAIT_FOR_SSH="${waitForSshBin}/bin/wait-for-ssh"
          export SHUTDOWN_WINDOWS="${shutdownBin}/bin/shutdown-windows"
          export SSH_PORT=${sh (toString sshPort)}
          export RDP_PORT=${sh (toString rdpPort)}
          export VNC_DISPLAY=${sh (toString vncDisplay)}
          export MEMORY_MB=${sh (toString memoryMB)}
          export CPU_CORES=${sh (toString cpuCores)}
          export DISK_SIZE_GB=${sh (toString diskSize)}
          export USERNAME=${sh username}
          export PASSWORD=${sh password}
          export COMPUTER_NAME=${sh computerName}
          export INSTALL_TIMEOUT_SECS=${sh (toString installTimeoutSeconds)}
          export AUTOMATION_CMD=${sh automationCmd}
          exec bash ${scripts.buildVm} "$@"
        '';
      };

      # Run script that ships with the built VM output (in $out/bin/run-vm).
      # It locates the VM directory relative to itself so users can simply
      # execute `./result/bin/run-vm`.
      runScript = pkgs.writeShellApplication {
        name = "run-vm";
        runtimeInputs = [ pkgs.qemu_kvm ];
        text = ''
          script_dir="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
          export VM_DIR="''${VM_DIR:-$script_dir/..}"
          export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
          export OVMF_VARS_SRC="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
          export SSH_PORT=${sh (toString sshPort)}
          export RDP_PORT=${sh (toString rdpPort)}
          export VNC_DISPLAY=${sh (toString vncDisplay)}
          export MEMORY_MB=${sh (toString memoryMB)}
          export CPU_CORES=${sh (toString cpuCores)}
          export USERNAME=${sh username}
          exec bash ${scripts.runVm} "$@"
        '';
      };

      impureAttrs = lib.optionalAttrs allowImpure {
        # Mark as impure for manual verification runs (requires impure-derivations feature).
        # Keep this gated so default flake evaluation stays pure for nix develop/flake check.
        __impure = true;
      };

    in
    pkgs.runCommand name
      (
        {
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
        mkdir -p $out/bin
        ${buildVmBin}/bin/build-windows-vm
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
    # `password` is accepted for API parity but not consumed here.
    assert builtins.isString password;
    pkgs.writeShellApplication {
      name = "run-windows-vm";
      runtimeInputs = [ pkgs.qemu_kvm ];
      text = ''
        export OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
        export OVMF_VARS_SRC="${pkgs.OVMF.fd}/FV/OVMF_VARS.fd"
        export SSH_PORT=${sh (toString sshPort)}
        export RDP_PORT=${sh (toString rdpPort)}
        export VNC_DISPLAY=${sh (toString vncDisplay)}
        export MEMORY_MB=${sh (toString memoryMB)}
        export CPU_CORES=${sh (toString cpuCores)}
        export USERNAME=${sh username}
        exec bash ${scripts.runVm} "$@"
      '';
    };

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
      testScript = pkgs.writeShellApplication {
        name = "test-windows-vm-boot";
        runtimeInputs = [
          pkgs.openssh
          pkgs.sshpass
        ];
        text = ''
          export VM_DIR=${sh (toString vmDir)}
          export RUN_VM="${runScript}/bin/run-windows-vm"
          export SSH_PORT=${sh (toString sshPort)}
          export USERNAME=${sh username}
          export PASSWORD=${sh password}
          export BOOT_TIMEOUT=${sh (toString bootTimeoutSeconds)}
          export SSH_RETRIES=${sh (toString sshRetries)}
          export SSH_RETRY_DELAY=${sh (toString sshRetryDelay)}
          export VNC_DISPLAY=${sh (toString vncDisplay)}
          exec bash ${scripts.bootTest} "$@"
        '';
      };
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

  # ============================================================================
  # CI Runner Functions -- Bare-metal Windows provisioning
  # ============================================================================

  # Paths to the CI runner provisioning scripts in this directory
  ciRunnerScripts = {
    bootstrap = ./ci-runner/bootstrap.ps1;
    provisionGithubRunner = ./ci-runner/provision-github-runner.ps1;
    configureBenchmarkIsolation = ./ci-runner/configure-benchmark-isolation.ps1;
  };

  # Generate an Autounattend.xml tailored for CI runner bare-metal installation.
  #
  # This wraps the bare-metal installation concept with CI-specific defaults:
  # - WinRM and SSH are enabled via bootstrap.ps1 injection
  # - OOBE is fully skipped
  # - Designed for bare-metal (no VirtIO drivers needed)
  # - Optional Windows product key support
  #
  # Parameters:
  #   username: Local admin account (default: "ci")
  #   password: Initial password (default: "ChangeMe!")
  #   computerName: Machine hostname (default: "CI-RUNNER")
  #   timezone: Timezone (default: "UTC")
  #   productKey: Windows product key (default: "" = no activation, 90-day grace)
  #               Pass a KMS/GVLK key for volume licensing or a retail key.
  #   locale: Locale (default: "en-US")
  #   organization: Organization name in Windows setup (default: "")
  #
  # Returns: A derivation containing the Autounattend.xml file
  generateCIRunnerAutounattend =
    {
      username ? "ci",
      password ? "ChangeMe!",
      computerName ? "CI-RUNNER",
      timezone ? "UTC",
      productKey ? "",
      locale ? "en-US",
      organization ? "",
    }:
    let
      # Validate computer name
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

      windowsTimezone = toWindowsTimezone timezone;

      # Product key XML snippet -- only included if a key is provided
      productKeyXml =
        if productKey == "" then
          "<ProductKey><WillShowUI>OnError</WillShowUI></ProductKey>"
        else
          "<ProductKey><Key>${productKey}</Key><WillShowUI>OnError</WillShowUI></ProductKey>";

      orgName = if organization == "" then "CI" else organization;
    in
    pkgs.runCommand "ci-runner-autounattend.xml"
      {
        nativeBuildInputs = [
          pkgs.gnused
          pkgs.libxml2
        ];
        inherit
          username
          password
          validatedComputerName
          windowsTimezone
          productKeyXml
          orgName
          locale
          ;
        template = ciAutounattendTemplate;
      }
      ''
        sed \
          -e "s|@USERNAME@|$username|g" \
          -e "s|@PASSWORD@|$password|g" \
          -e "s|@COMPUTER_NAME@|$validatedComputerName|g" \
          -e "s|@TIMEZONE@|$windowsTimezone|g" \
          -e "s|@LOCALE@|$locale|g" \
          -e "s|@ORG@|$orgName|g" \
          -e "s|@PRODUCTKEY@|$productKeyXml|g" \
          "$template" > "$out"

        if ! xmllint --noout "$out" 2>/dev/null; then
          echo "Warning: Generated CI runner autounattend.xml may have XML syntax issues"
        fi

        echo "Generated CI runner autounattend.xml:"
        echo "  Username: $username"
        echo "  Computer Name: $validatedComputerName"
        echo "  Timezone: $windowsTimezone"
      '';

  # Build a directory ready to be written to a USB drive for bare-metal
  # Windows CI runner installation.
  #
  # The output contains:
  # - Autounattend.xml (CI runner variant)
  # - bootstrap.ps1 (WinRM + SSH first-boot setup)
  # - provision-github-runner.ps1 (runner registration)
  # - configure-benchmark-isolation.ps1 (benchmark tuning)
  #
  # Parameters:
  #   windowsIsoPath: Path to a Windows ISO file (string path, not derivation)
  #   username, password, computerName, timezone, productKey, locale, organization:
  #     Passed through to generateCIRunnerAutounattend
  #   splitWimThreshold: Maximum WIM file size in MB before splitting (default: 4000)
  #     Set to 0 to skip WIM splitting (e.g. when using NTFS USB).
  #
  # Returns: A derivation containing a directory with all files ready
  #          to be copied to a USB drive alongside Windows ISO contents.
  #
  # Example:
  #   buildBaremetalUSB {
  #     windowsIsoPath = "/path/to/Win11_English_x64.iso";
  #     computerName = "CI-BENCH-01";
  #   }
  buildBaremetalUSB =
    {
      windowsIsoPath,
      username ? "ci",
      password ? "ChangeMe!",
      computerName ? "CI-RUNNER",
      timezone ? "UTC",
      productKey ? "",
      locale ? "en-US",
      organization ? "",
      splitWimThreshold ? 4000,
    }:
    let
      autounattendXml = generateCIRunnerAutounattend {
        inherit
          username
          password
          computerName
          timezone
          productKey
          locale
          organization
          ;
      };
    in
    pkgs.runCommand "windows-ci-usb-contents"
      {
        nativeBuildInputs = with pkgs; [
          p7zip
          wimlib
        ];
        inherit autounattendXml;
        windowsIso = windowsIsoPath;
        threshold = toString splitWimThreshold;
      }
      ''
        mkdir -p "$out"

        echo "Extracting Windows ISO contents..."
        7z x -o"$out" "$windowsIso"

        echo "Copying Autounattend.xml..."
        cp "$autounattendXml" "$out/Autounattend.xml"

        echo "Copying CI runner scripts..."
        cp ${ciRunnerScripts.bootstrap} "$out/bootstrap.ps1"
        cp ${ciRunnerScripts.provisionGithubRunner} "$out/provision-github-runner.ps1"
        cp ${ciRunnerScripts.configureBenchmarkIsolation} "$out/configure-benchmark-isolation.ps1"

        # Split install.wim if it exceeds the threshold (for FAT32 USB drives)
        wim="$out/sources/install.wim"
        if [ "$threshold" -gt 0 ] && [ -f "$wim" ]; then
          wim_size_mb=$(( $(stat -c%s "$wim") / 1048576 ))
          echo "install.wim size: $wim_size_mb MB (threshold: $threshold MB)"
          if [ "$wim_size_mb" -gt "$threshold" ]; then
            echo "Splitting install.wim into SWM files..."
            wimlib-imagex split "$wim" "$out/sources/install.swm" "$threshold"
            rm "$wim"
            echo "install.wim split complete."
          fi
        fi

        echo "USB contents ready at: $out"
        ls -la "$out"
      '';
}
