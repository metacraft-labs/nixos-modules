# macOS VM Builder for Automated Testing
#
# This module provides functions to build macOS VM images for multi-OS testing.
# It uses OpenCore bootloader, QEMU/KVM, and our YAML automation engine to create
# pre-configured macOS VMs with SSH enabled.
#
# The build process follows the NixThePlanet two-stage approach:
# 1. Stage 1: Boot from BaseSystem + InstallAssistant, run OOBE automation
# 2. Stage 2: Continue installation without installer media, finish setup
#
# Dependencies (must be passed as parameters):
#   - osx-kvm: External flake input providing OpenCore bootloader and OVMF firmware
#     Source: https://github.com/kholia/OSX-KVM (or a fork with Nix packaging)
#   - yaml-automation-runner: The YAML-based automation engine package
#     Location in this repo: ../../packages/vm-automation
#
# References:
# - NixThePlanet: https://github.com/MatthewCroughan/NixThePlanet
# - OSX-KVM: https://github.com/kholia/OSX-KVM
# - OpenCore: https://github.com/acidanthera/OpenCorePkg
{
  pkgs,
  lib,
  # External dependency: osx-kvm flake providing OpenCore bootloader and OVMF firmware
  # Must be provided by the caller (typically from flake inputs)
  osx-kvm,
  # The yaml-automation-runner package for VNC-based GUI automation
  # Can be built from ../../packages/vm-automation
  yaml-automation-runner,
}:

let
  # Apple SMC key - required for macOS to boot in QEMU
  # This is a well-known string used by all macOS virtualization projects
  appleSMCKey = "ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc";

  # CPU options for macOS compatibility
  # Penryn is a safe baseline that works across macOS versions
  cpuOptions = "+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check";

in
rec {
  # Build a macOS VM image with automated OOBE setup
  #
  # Parameters:
  #   name: Name for the resulting VM package
  #   baseSystemImg: Path to BaseSystem.img (from fetchMacOSBaseSystem)
  #   installAssistantIso: Path to InstallAssistant.iso (from fetchMacOSInstallAssistant)
  #   automationConfig: Path to YAML automation config file
  #   diskSizeBytes: Target disk size in bytes (default: 50GB)
  #   memoryMB: RAM allocation in MB (default: 4096)
  #   cpuCores: Number of CPU cores (default: 1 for deterministic installation)
  #   sshPort: SSH port forwarding (default: 2222)
  #   vncDisplay: VNC display number (default: 1, meaning port 5901)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #   allowImpure: Enable impure derivation mode (default: false)
  #
  # Returns: A derivation containing the macOS QCOW2 image and run script
  #
  # Example usage:
  #   makeDarwinVM {
  #     name = "macos-sonoma-vm";
  #     baseSystemImg = macos-sonoma-basesystem;
  #     installAssistantIso = macos-sonoma-installassistant;
  #     automationConfig = ./configs/macos/unattended-sonoma.yml;
  #   }
  makeDarwinVM =
    {
      name,
      baseSystemImg,
      installAssistantIso,
      automationConfig,
      diskSizeBytes ? 50000000000, # 50 GB
      memoryMB ? 4096,
      cpuCores ? 1, # Single core for deterministic installation
      sshPort ? 2222,
      vncDisplay ? 1,
      username ? "admin",
      password ? "admin",
      allowImpure ? false,
    }:
    let
      # Minimum disk size check (40 GB required for macOS)
      diskSize =
        if diskSizeBytes < 40000000000 then
          throw "diskSizeBytes ${toString diskSizeBytes} too small for macOS (minimum 40GB)"
        else
          diskSizeBytes;

      # VNC port is 5900 + display number
      vncPort = 5900 + vncDisplay;

      # Create the run_offline.sh script for disk partitioning
      # This script runs inside the macOS Recovery environment to:
      # 1. Find and erase the target disk
      # 2. Format it as APFS
      # 3. Copy the installer and start the installation
      runOfflineScript = pkgs.writeText "run_offline.sh" ''
        #!/usr/bin/env bash
        set -e

        # Multi-layered disk detection for reliability across macOS versions
        # Uses diskutil info for stable output format instead of fragile JSON grep
        TARGET_SIZE=${toString diskSize}  # 50000000000
        MIN_SIZE=$((TARGET_SIZE - 1073741824))  # -1GB tolerance
        MAX_SIZE=$((TARGET_SIZE + 1073741824))  # +1GB tolerance

        echo "Looking for disk with size ~$TARGET_SIZE bytes..."

        # Find all physical disks
        DISKS=$(diskutil list | grep '^/dev/disk[0-9]' | sed 's|/dev/||' | awk '{print $1}')

        found_disk=""

        for disk in $DISKS; do
            echo "Checking $disk..."

            # Extract size from "Total Size: ... (NNNNNN Bytes)" format
            # This format is stable across macOS versions
            disk_size=$(diskutil info "$disk" | grep "Total Size:" | grep -oE '\([0-9]+ Bytes\)' | grep -oE '[0-9]+')

            if [ -z "$disk_size" ]; then
                echo "  Skipping $disk: could not determine size"
                continue
            fi

            echo "  $disk size: $disk_size bytes"

            # Check size within tolerance
            if [ "$disk_size" -lt "$MIN_SIZE" ] || [ "$disk_size" -gt "$MAX_SIZE" ]; then
                echo "  Skipping $disk: size out of range"
                continue
            fi

            # Validate: not virtual, not read-only, not removable
            disk_info=$(diskutil info "$disk")

            if echo "$disk_info" | grep -q "Virtual:.*Yes"; then
                echo "  Skipping $disk: virtual disk"
                continue
            fi

            if echo "$disk_info" | grep -q "Read-Only Media:.*Yes"; then
                echo "  Skipping $disk: read-only"
                continue
            fi

            if echo "$disk_info" | grep -q "Removable Media:.*Yes"; then
                echo "  Skipping $disk: removable"
                continue
            fi

            echo "  Found candidate: $disk"
            found_disk="$disk"
            break
        done

        if [ -z "$found_disk" ]; then
            echo "ERROR: Could not find suitable disk to erase"
            echo "Expected size: $TARGET_SIZE bytes (±1GB)"
            echo "Available disks:"
            diskutil list
            exit 1
        fi

        diskToErase="$found_disk"
        echo "Selected disk: $diskToErase"

        # Erase and format as APFS
        diskutil eraseDisk APFS "macOS" "/dev/$diskToErase"

        # Set up the installer
        cd /Volumes/macOS
        mkdir -p private/tmp

        # Find the macOS installer app (version-agnostic)
        # Search up to depth 2 to find apps in mounted ISO subdirectories
        INSTALLER_APP=$(find /Volumes -maxdepth 2 -name "Install macOS *.app" | head -1)
        if [ -z "$INSTALLER_APP" ]; then
          echo "Error: Could not find macOS installer app"
          exit 1
        fi

        echo "Found installer: $INSTALLER_APP"
        cp -R "$INSTALLER_APP" private/tmp

        # Get the installer app name without path
        INSTALLER_NAME=$(basename "$INSTALLER_APP")
        cd "private/tmp/$INSTALLER_NAME"

        mkdir -p Contents/SharedSupport
        cp -R /Volumes/InstallAssistant/InstallAssistant.pkg Contents/SharedSupport/SharedSupport.dmg

        # Start the installation
        ./Contents/Resources/startosinstall --agreetolicense --nointeraction --volume /Volumes/macOS
      '';

      # Create ISO containing the run_offline script
      runOfflineIso = pkgs.runCommand "run_offline.iso" { nativeBuildInputs = [ pkgs.xorriso ]; } ''
        mkdir -p iso_contents
        cp ${runOfflineScript} iso_contents/run_offline.sh
        chmod +x iso_contents/run_offline.sh
        xorriso -volid run_offline -as mkisofs -o $out iso_contents/
      '';

      # QEMU arguments for Stage 1 (with installation media)
      qemuArgsStage1 = ''
        args=(
          -enable-kvm
          -m ${toString memoryMB}
          -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,${cpuOptions}
          -machine q35
          -smp 1,cores=${toString cpuCores},sockets=1
          -usb -device usb-kbd -device usb-tablet
          -device usb-ehci,id=ehci
          -device nec-usb-xhci,id=xhci
          -global nec-usb-xhci.msi=off
          -device isa-applesmc,osk="${appleSMCKey}"
          -drive if=pflash,format=raw,readonly=on,file="$REPO_PATH/OVMF_CODE.fd"
          -drive if=pflash,format=raw,file="$REPO_PATH/OVMF_VARS-1920x1080.fd"
          -smbios type=2
          -device ich9-intel-hda -device hda-duplex
          -drive id=run_offline,snapshot=on,file="$REPO_PATH/run_offline.iso",format=raw
          -drive id=InstallMedia,snapshot=on,file="$REPO_PATH/BaseSystem.qcow2",format=qcow2
          -drive id=OpenCoreBoot,if=virtio,snapshot=on,format=qcow2,file="$REPO_PATH/OpenCore/OpenCore.qcow2"
          -drive id=MacHDD,if=virtio,file="$REPO_PATH/mac_hdd_ng.qcow2",format=qcow2
          -drive id=MacDVD,if=virtio,snapshot=on,file="$REPO_PATH/InstallAssistant.qcow2",format=qcow2
          -netdev user,id=net0,hostfwd=tcp::${toString sshPort}-:22,restrict=yes
          -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
          -nic none
          -device virtio-vga
          -monitor unix:qemu-monitor-socket,server,nowait
          -vnc 0.0.0.0:${toString vncDisplay}
          -rtc base=2023-10-10T12:12:12
          -no-reboot
        )
      '';

      # QEMU arguments for Stage 2 (without installation media)
      qemuArgsStage2 = ''
        args=(
          -enable-kvm
          -m ${toString memoryMB}
          -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,${cpuOptions}
          -machine q35
          -smp 1,cores=${toString cpuCores},sockets=1
          -usb -device usb-kbd -device usb-tablet
          -device usb-ehci,id=ehci
          -device nec-usb-xhci,id=xhci
          -global nec-usb-xhci.msi=off
          -device isa-applesmc,osk="${appleSMCKey}"
          -drive if=pflash,format=raw,readonly=on,file="$REPO_PATH/OVMF_CODE.fd"
          -drive if=pflash,format=raw,file="$REPO_PATH/OVMF_VARS-1920x1080.fd"
          -smbios type=2
          -device ich9-intel-hda -device hda-duplex
          -drive id=OpenCoreBoot,if=virtio,snapshot=on,format=qcow2,file="$REPO_PATH/OpenCore/OpenCore.qcow2"
          -drive id=MacHDD,if=virtio,file="$REPO_PATH/mac_hdd_ng.qcow2",format=qcow2
          -netdev user,id=net0,hostfwd=tcp::${toString sshPort}-:22,restrict=yes
          -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
          -nic none
          -device virtio-vga
          -monitor unix:qemu-monitor-socket,server,nowait
          -vnc 0.0.0.0:${toString vncDisplay}
          -rtc base=2023-10-10T12:12:12
        )
      '';

      # Mouse jiggler script to prevent screensaver during automation
      mouseJigglerScript = pkgs.writeShellScript "mouse-jiggler" ''
        while true; do
          sleep $((RANDOM % (240 - 120 + 1) + 120))
          randomX=$((RANDOM % (1920 - 1910 + 1) + 1910))
          randomY=$((RANDOM % (1080 - 1070 + 1) + 1070))
          echo "mouse_move $randomX $randomY" | ${pkgs.socat}/bin/socat - unix-connect:qemu-monitor-socket
        done
      '';

      # SSH power-off script for graceful shutdown
      powerOffScript = pkgs.writeShellScript "poweroff-macos" ''
        # Wait for SSH to become available
        while ! ${pkgs.openssh}/bin/ssh-keyscan -p ${toString sshPort} 127.0.0.1 2>/dev/null; do
          sleep 3
          echo "SSH Not Ready"
        done

        # Graceful shutdown via SSH
        ${pkgs.sshpass}/bin/sshpass -p '${password}' ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -p ${toString sshPort} \
          ${username}@127.0.0.1 \
          'set -e; killall -9 Terminal KeyboardSetupAssistant 2>/dev/null || true; sleep 5; echo "${password}" | sudo -S shutdown -h now' || true

        # macOS terminates SSH uncleanly during shutdown (exit 255 is expected)
        echo "Waiting for VM to shut down..."
        sleep 10
      '';

      # Build script that orchestrates the entire VM creation
      buildScript = pkgs.writeShellScript "build-macos-vm" ''
        set -ex

        REPO_PATH="$(pwd)"
        export REPO_PATH

        # Copy osx-kvm files (OpenCore, OVMF firmware)
        cp -r --no-preserve=mode ${osx-kvm}/* .

        # Copy our custom scripts
        cp ${runOfflineIso} run_offline.iso

        # Create QCOW2 overlays (base images remain read-only)
        ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 -b ${baseSystemImg} -F raw ./BaseSystem.qcow2
        ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 -b ${installAssistantIso} -F raw ./InstallAssistant.qcow2

        # Create target disk
        ${pkgs.qemu_kvm}/bin/qemu-img create -f qcow2 ./mac_hdd_ng.qcow2 ${toString diskSize}

        # Copy writable OVMF_VARS
        cp --no-preserve=mode OVMF_VARS-1920x1080.fd OVMF_VARS-1920x1080.fd.tmp
        mv OVMF_VARS-1920x1080.fd.tmp OVMF_VARS-1920x1080.fd

        echo "============================================"
        echo "Stage 1: Installing macOS from BaseSystem"
        echo "VNC available at: localhost:${toString vncPort}"
        echo "============================================"

        # Stage 1: Boot with installation media
        ${qemuArgsStage1}
        ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}" &
        QEMU_PID=$!

        # Start mouse jiggler to prevent screensaver
        ${mouseJigglerScript} &
        JIGGLER_PID=$!

        # Wait a bit for QEMU to start
        sleep 10

        # Run YAML automation for OOBE
        echo "Running YAML automation..."
        ${yaml-automation-runner}/bin/yaml-automation-runner \
          --config ${automationConfig} \
          --vnc localhost:${toString vncPort} \
          --debug \
          || echo "Automation completed or VM rebooted"

        # Wait for Stage 1 QEMU to exit (after first reboot)
        wait $QEMU_PID || true
        kill $JIGGLER_PID 2>/dev/null || true

        echo "============================================"
        echo "Stage 2: Continuing installation"
        echo "============================================"

        # Stage 2: Boot without installation media
        ${qemuArgsStage2}
        ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}" &
        QEMU_PID=$!

        # Start mouse jiggler again
        ${mouseJigglerScript} &
        JIGGLER_PID=$!

        # Wait for installation to complete and perform graceful shutdown
        sleep 60  # Give macOS time to boot
        ${powerOffScript}

        # Wait for QEMU to exit
        wait $QEMU_PID || true
        kill $JIGGLER_PID 2>/dev/null || true

        echo "============================================"
        echo "macOS VM build complete!"
        echo "============================================"
      '';

      # Create the run script for the resulting VM
      runScript = pkgs.writeShellScriptBin "run-vm" ''
        #!/usr/bin/env bash
        set -e

        MY_OPTIONS="${cpuOptions}"
        SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
        VM_DIR="''${SCRIPT_DIR}/.."

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
          -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$MY_OPTIONS"
          -machine q35
          -smp 4,cores=2,sockets=1
          -usb -device usb-kbd -device usb-tablet
          -device usb-ehci,id=ehci
          -device nec-usb-xhci,id=xhci
          -global nec-usb-xhci.msi=off
          -device isa-applesmc,osk="${appleSMCKey}"
          -drive if=pflash,format=raw,readonly=on,file="$VM_DIR/OVMF_CODE.fd"
          -drive if=pflash,format=raw,readonly=on,file="$VM_DIR/OVMF_VARS-1920x1080.fd"
          -smbios type=2
          -device ich9-intel-hda -device hda-duplex
          -drive id=OpenCoreBoot,if=virtio,snapshot=on,format=qcow2,file="$VM_DIR/OpenCore/OpenCore.qcow2"
          -drive id=MacHDD,if=virtio,file="$VM_DIR/mac_hdd_ng.qcow2",format=qcow2
          -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22
          -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
          -device virtio-vga
          "$@"
        )

        echo "Starting macOS VM..."
        echo "SSH will be available at: localhost:${toString sshPort}"
        echo "Username: ${username}"
        echo ""

        exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}"
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
            pkgs.xorriso
            pkgs.socat
            pkgs.openssh
            pkgs.sshpass
          ];
          passthru = {
            inherit
              runScript
              sshPort
              username
              password
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
        cp mac_hdd_ng.qcow2 $out/
        cp -r ${osx-kvm}/OpenCore $out/
        cp ${osx-kvm}/OVMF_CODE.fd $out/
        cp ${osx-kvm}/OVMF_VARS-1920x1080.fd $out/
        cp ${runScript}/bin/run-vm $out/bin/
      '';

  # Create a run script for an existing macOS VM image
  # This is useful for running VMs that were built elsewhere
  makeRunScript =
    {
      diskImage,
      sshPort ? 2222,
      memoryMB ? 6144,
      cpuCores ? 2,
      username ? "admin",
      password ? "admin",
    }:
    pkgs.writeShellScriptBin "run-macos-vm" ''
      #!/usr/bin/env bash
      set -e

      MY_OPTIONS="${cpuOptions}"

      if [ ! -f "${diskImage}" ]; then
        echo "Error: Disk image not found: ${diskImage}"
        exit 1
      fi

      # Check for KVM support
      if [ ! -r /dev/kvm ]; then
        echo "Error: KVM not available."
        exit 1
      fi

      args=(
        -enable-kvm
        -m ${toString memoryMB}
        -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$MY_OPTIONS"
        -machine q35
        -smp ${toString (cpuCores * 2)},cores=${toString cpuCores},sockets=1
        -usb -device usb-kbd -device usb-tablet
        -device usb-ehci,id=ehci
        -device nec-usb-xhci,id=xhci
        -global nec-usb-xhci.msi=off
        -device isa-applesmc,osk="${appleSMCKey}"
        -drive if=pflash,format=raw,readonly=on,file="${osx-kvm}/OVMF_CODE.fd"
        -drive if=pflash,format=raw,readonly=on,file="${osx-kvm}/OVMF_VARS-1920x1080.fd"
        -smbios type=2
        -device ich9-intel-hda -device hda-duplex
        -drive id=OpenCoreBoot,if=virtio,snapshot=on,format=qcow2,file="${osx-kvm}/OpenCore/OpenCore.qcow2"
        -drive id=MacHDD,if=virtio,file="${diskImage}",format=qcow2
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22
        -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
        -device virtio-vga
        "$@"
      )

      echo "Starting macOS VM..."
      echo "SSH: ssh -p ${toString sshPort} ${username}@localhost"
      echo ""

      exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}"
    '';

  # Create a run script for a macOS VM directory (output of makeDarwinVM)
  #
  # This function creates a run script that operates on a VM directory structure
  # containing mac_hdd_ng.qcow2, OpenCore/, OVMF_CODE.fd, and OVMF_VARS-1920x1080.fd.
  # The VM directory must be provided at runtime via environment variable or argument.
  #
  # Parameters:
  #   sshPort: SSH port forwarding (default: 2225)
  #   memoryMB: RAM allocation in MB (default: 6144)
  #   cpuCores: Number of CPU cores (default: 2)
  #   vncDisplay: VNC display number (default: 1, meaning port 5901)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #
  # Example usage:
  #   VM_DIR=/path/to/macos-vm ./result/bin/run-darwin-vm
  #   or
  #   ./result/bin/run-darwin-vm /path/to/macos-vm
  #
  makeDarwinRunScript =
    {
      sshPort ? 2225,
      memoryMB ? 6144,
      cpuCores ? 2,
      vncDisplay ? 1,
      username ? "admin",
      password ? "admin",
    }:
    let
      vncPort = 5900 + vncDisplay;
    in
    pkgs.writeShellScriptBin "run-darwin-vm" ''
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
      if [ ! -f "$VM_DIR/mac_hdd_ng.qcow2" ]; then
        echo "Error: Disk image not found: $VM_DIR/mac_hdd_ng.qcow2"
        exit 1
      fi

      if [ ! -d "$VM_DIR/OpenCore" ]; then
        echo "Error: OpenCore directory not found: $VM_DIR/OpenCore"
        exit 1
      fi

      if [ ! -f "$VM_DIR/OVMF_CODE.fd" ]; then
        echo "Error: OVMF_CODE.fd not found: $VM_DIR/OVMF_CODE.fd"
        exit 1
      fi

      if [ ! -f "$VM_DIR/OVMF_VARS-1920x1080.fd" ]; then
        echo "Error: OVMF_VARS not found: $VM_DIR/OVMF_VARS-1920x1080.fd"
        exit 1
      fi

      # Check for KVM support
      if [ ! -r /dev/kvm ]; then
        echo "Error: KVM not available. Please ensure:"
        echo "  1. KVM kernel module is loaded (modprobe kvm_intel or kvm_amd)"
        echo "  2. You have permission to access /dev/kvm"
        exit 1
      fi

      MY_OPTIONS="${cpuOptions}"

      args=(
        -enable-kvm
        -m ${toString memoryMB}
        -cpu Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,"$MY_OPTIONS"
        -machine q35
        -smp ${toString (cpuCores * 2)},cores=${toString cpuCores},sockets=1
        -usb -device usb-kbd -device usb-tablet
        -device usb-ehci,id=ehci
        -device nec-usb-xhci,id=xhci
        -global nec-usb-xhci.msi=off
        -device isa-applesmc,osk="${appleSMCKey}"
        -drive if=pflash,format=raw,readonly=on,file="$VM_DIR/OVMF_CODE.fd"
        -drive if=pflash,format=raw,readonly=on,file="$VM_DIR/OVMF_VARS-1920x1080.fd"
        -smbios type=2
        -device ich9-intel-hda -device hda-duplex
        -drive id=OpenCoreBoot,if=virtio,snapshot=on,format=qcow2,file="$VM_DIR/OpenCore/OpenCore.qcow2"
        -drive id=MacHDD,if=virtio,file="$VM_DIR/mac_hdd_ng.qcow2",format=qcow2
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:${toString sshPort}-:22
        -device virtio-net-pci,netdev=net0,id=net0,mac=52:54:00:c9:18:27
        -device virtio-vga
        -monitor unix:qemu-monitor-socket,server,nowait
        -vnc 0.0.0.0:${toString vncDisplay}
        "''${@:2}"
      )

      echo "Starting macOS VM from: $VM_DIR"
      echo "SSH will be available at: localhost:${toString sshPort}"
      echo "VNC will be available at: localhost:${toString vncPort}"
      echo "Username: ${username}"
      echo ""

      exec ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 "''${args[@]}"
    '';

  # Create a cached boot test script for a pre-built macOS VM
  #
  # This function creates a test script that verifies a pre-built macOS VM can boot
  # from its cached QCOW2 image and respond to SSH health checks.
  #
  # The test:
  # 1. Starts the VM in the background
  # 2. Waits for SSH to become available (with timeout and retries)
  # 3. Runs sw_vers via SSH to verify macOS is responding
  # 4. Gracefully shuts down the VM via SSH
  # 5. Reports success/failure with exit code
  #
  # Parameters:
  #   vmDir: Path to the VM directory (output of makeDarwinVM)
  #   sshPort: SSH port forwarding (default: 2225)
  #   memoryMB: RAM allocation in MB (default: 6144)
  #   cpuCores: Number of CPU cores (default: 2)
  #   username: Account username (default: "admin")
  #   password: Account password (default: "admin")
  #   bootTimeoutSeconds: Maximum time to wait for SSH (default: 180)
  #   sshRetries: Number of SSH connection retries (default: 30)
  #   sshRetryDelay: Seconds between SSH retries (default: 6)
  #
  # Example usage:
  #   nix build .#macos-sonoma-vm-test
  #   ./result/bin/test-darwin-vm-boot
  #
  makeDarwinCachedBootTest =
    {
      vmDir,
      sshPort ? 2225,
      memoryMB ? 6144,
      cpuCores ? 2,
      vncDisplay ? 1,
      username ? "admin",
      password ? "admin",
      bootTimeoutSeconds ? 180,
      sshRetries ? 30,
      sshRetryDelay ? 6,
    }:
    let
      vncPort = 5900 + vncDisplay;

      # Create the run script for this specific VM
      runScript = makeDarwinRunScript {
        inherit
          sshPort
          memoryMB
          cpuCores
          vncDisplay
          username
          password
          ;
      };

      # Test script that orchestrates boot, health check, and shutdown
      testScript = pkgs.writeShellScriptBin "test-darwin-vm-boot" ''
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
        log_info "macOS VM Cached Boot Test"
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
        if [ ! -f "$VM_DIR/mac_hdd_ng.qcow2" ]; then
          log_error "Disk image not found: $VM_DIR/mac_hdd_ng.qcow2"
          exit 1
        fi

        log_info "Starting macOS VM..."

        # Start QEMU in the background with nographic mode for testing
        # We use -nographic -serial none to suppress output
        ${runScript}/bin/run-darwin-vm "$VM_DIR" -nographic -serial none &
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

        # Run health check command (sw_vers to get macOS version info)
        log_info "Running health check: sw_vers"

        SW_VERS_OUTPUT=$(${pkgs.sshpass}/bin/sshpass -p "$PASSWORD" ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -p "$SSH_PORT" \
          "$USERNAME@127.0.0.1" \
          "sw_vers" 2>/dev/null)

        if [ -z "$SW_VERS_OUTPUT" ]; then
          log_error "sw_vers command returned empty output"
          exit 1
        fi

        log_info "macOS version information:"
        echo "$SW_VERS_OUTPUT"

        # Verify we got valid macOS version info
        if echo "$SW_VERS_OUTPUT" | grep -q "ProductName"; then
          log_info "Health check passed: macOS is responding correctly"
        else
          log_error "Health check failed: unexpected sw_vers output"
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
          "echo '$PASSWORD' | sudo -S shutdown -h now" 2>/dev/null || true

        # macOS terminates SSH uncleanly during shutdown, so we expect this to fail
        log_info "Shutdown command sent, waiting for VM to terminate..."

        # Wait for QEMU to exit gracefully (up to 30 seconds)
        for i in $(seq 1 30); do
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
        log_info "TEST PASSED: macOS VM cached boot test successful!"
        log_info "============================================"

        exit 0
      '';
    in
    pkgs.symlinkJoin {
      name = "darwin-cached-boot-test";
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
          username
          password
          ;
      };
    };
}
