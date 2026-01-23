# Linux VM Builder for Multi-OS Testing
#
# This module provides the `makeLinuxVM` function which creates bootable QEMU VMs
# from Ubuntu cloud images. It handles:
# - Cloud-init configuration injection via ISO seed
# - Disk image resizing and overlay creation
# - QEMU launch script generation with proper networking
# - SSH port forwarding for host access
#
# The resulting VMs are suitable for automated testing and can be started/stopped
# programmatically via the generated run script.
#
# References:
# - QEMU documentation: https://www.qemu.org/docs/master/system/qemu-manpage.html
# - Ubuntu Cloud Images: https://cloud-images.ubuntu.com/
# - Cloud-init NoCloud: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
# - VirtIO devices: https://wiki.qemu.org/Features/VirtIO

{ pkgs, lib }:

let
  cloudInit = import ./cloud-init.nix { inherit pkgs lib; };
in
{
  # Create a bootable Linux VM from a cloud image.
  #
  # This function takes a cloud image (QCOW2 format) and produces a derivation
  # containing:
  # - A resized/overlayed disk image
  # - A cloud-init seed ISO for first-boot configuration
  # - A run script that launches QEMU with appropriate settings
  #
  # Parameters:
  #   name: Name for the VM derivation
  #   cloudImage: Path to the base cloud image (QCOW2 format)
  #   hostname: Hostname to configure via cloud-init
  #   username: Username for the primary user account
  #   sshPort: Host port for SSH forwarding (VM uses port 22)
  #   memory: Amount of RAM in MB (default: 2048)
  #   cpus: Number of CPU cores (default: 2)
  #   diskSize: Virtual disk size (default: "20G")
  #   installNix: Install Nix package manager via cloud-init (default: false)
  #   ahFollowerdPath: Optional path to ah-followerd binary to deploy (default: null)
  #
  # Returns: A derivation with:
  #   - $out/disk.qcow2: The VM disk image
  #   - $out/seed.iso: Cloud-init configuration ISO
  #   - $out/ssh-key/: Directory containing SSH keys
  #   - $out/bin/run-vm: Script to start the VM
  #
  # Example usage:
  #   makeLinuxVM {
  #     name = "ubuntu-2404-vm";
  #     cloudImage = ubuntu-cloud-image-2404;
  #     hostname = "ubuntu-follower";
  #     username = "agent";
  #     sshPort = 2224;
  #     installNix = true;
  #     ahFollowerdPath = "${ah-followerd}/bin/ah-followerd";
  #   }
  makeLinuxVM =
    {
      name,
      cloudImage,
      hostname,
      username,
      sshPort,
      memory ? 2048,
      cpus ? 2,
      diskSize ? "20G",
      installNix ? false,
      ahFollowerdPath ? null,
    }:
    let
      # Generate SSH key pair for VM access
      sshKey = cloudInit.generateTestSSHKey { name = "${name}-key"; };

      # Generate cloud-init configuration with the SSH public key
      # Pass ahFollowerdPath to deploy the binary if provided
      cloudInitConfig = cloudInit.makeCloudInitConfig {
        inherit
          hostname
          username
          installNix
          ahFollowerdPath
          ;
        sshPublicKey = sshKey.publicKey;
        sshPort = 22; # VM internal port (always 22, we forward to sshPort)
      };

      # Create the cloud-init seed ISO using cloud-localds
      # This ISO is attached as a CD-ROM to provide configuration data
      # Reference: https://manpages.ubuntu.com/manpages/focal/man1/cloud-localds.1.html
      seedISO =
        pkgs.runCommand "${name}-seed.iso"
          {
            nativeBuildInputs = [ pkgs.cloud-utils ];
          }
          ''
            # cloud-localds creates an ISO9660 filesystem with cloud-init data
            # The NoCloud datasource in cloud-init will automatically detect this
            cloud-localds $out ${cloudInitConfig}/user-data ${cloudInitConfig}/meta-data
          '';

      # Build the VM disk image
      # We create a QCOW2 overlay on top of the base image to avoid modifying it
      # This also allows multiple VMs to share the same base image
      vmDisk =
        pkgs.runCommand "${name}-disk.qcow2"
          {
            nativeBuildInputs = [ pkgs.qemu_kvm ];
          }
          ''
            # Create a QCOW2 overlay image that uses the cloud image as backing
            # The overlay will store all changes, keeping the base image pristine
            # Format: qcow2 (QEMU Copy-On-Write version 2)
            # Backing file: the original cloud image
            # Size: increased from base image size to provide more space
            qemu-img create -f qcow2 -F qcow2 -b ${cloudImage} $out ${diskSize}
          '';

      # Generate the VM run script
      # This script launches QEMU with appropriate parameters for:
      # - KVM acceleration (if available)
      # - User-mode networking with SSH port forwarding
      # - VirtIO devices for better performance
      # - Cloud-init seed ISO attached as CD-ROM
      runScript = pkgs.writeShellScript "run-vm" ''
        set -euo pipefail

        # Determine the directory where this script is located
        SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
        VM_DIR="$(dirname "$SCRIPT_DIR")"

        # VM resource paths
        # The disk image in Nix store is read-only, so we use QEMU's snapshot mode
        # This creates an ephemeral overlay in /tmp that is discarded on shutdown
        DISK="$VM_DIR/disk.qcow2"
        SEED_ISO="$VM_DIR/seed.iso"

        # Allow overriding the SSH forward port at runtime.
        # This is useful for running multiple VMs in parallel without port collisions.
        SSH_PORT="''${AH_VM_SSH_PORT:-${toString sshPort}}"
        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
          echo "Invalid SSH port: $SSH_PORT" >&2
          exit 1
        fi

        # Check if KVM acceleration is available
        # KVM provides near-native performance but requires /dev/kvm
        if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
          ACCEL="-enable-kvm -cpu host"
          echo "KVM acceleration enabled"
        else
          ACCEL="-cpu qemu64"
          echo "KVM not available, using software emulation (slower)"
        fi

        # QEMU system emulator path
        # We use qemu-system-x86_64 for x86-64 architecture VMs
        QEMU="${pkgs.qemu_kvm}/bin/qemu-system-x86_64"

        # Check if running in daemonize mode
        # When daemonizing, we can't use -nographic or -serial mon:stdio
        DAEMONIZE=false
        for arg in "$@"; do
          if [[ "$arg" == "-daemonize" ]]; then
            DAEMONIZE=true
            break
          fi
        done

        if [ "$DAEMONIZE" = false ]; then
          echo "Starting ${name}..."
          echo "  Hostname: ${hostname}"
          echo "  SSH: localhost:$SSH_PORT (VM port 22)"
          echo "  Memory: ${toString memory} MB"
          echo "  CPUs: ${toString cpus}"
          echo ""
          echo "To connect: ssh -p $SSH_PORT -i $VM_DIR/ssh-key/id_ed25519 ${username}@localhost"
          echo ""
        fi

        # Build the QEMU command line
        # When running in daemon mode, we use -display none instead of -nographic
        # We use -snapshot to create an ephemeral overlay, since the Nix store is read-only
        # Reference: https://www.qemu.org/docs/master/system/invocation.html
        if [ "$DAEMONIZE" = true ]; then
          # Daemon mode: no console, no serial output
          exec "$QEMU" \
            -M pc \
            $ACCEL \
            -m ${toString memory} \
            -smp ${toString cpus} \
            -display none \
            -snapshot \
            -drive file="$DISK",if=virtio,format=qcow2,cache=writeback \
            -drive file="$SEED_ISO",if=virtio,format=raw,media=cdrom,readonly=on \
            -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
            -device virtio-net-pci,netdev=net0 \
            "$@"
        else
          # Interactive mode: serial console via stdio
          exec "$QEMU" \
            -M pc \
            $ACCEL \
            -m ${toString memory} \
            -smp ${toString cpus} \
            -nographic \
            -serial mon:stdio \
            -snapshot \
            -drive file="$DISK",if=virtio,format=qcow2,cache=writeback \
            -drive file="$SEED_ISO",if=virtio,format=raw,media=cdrom,readonly=on \
            -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
            -device virtio-net-pci,netdev=net0 \
            "$@"
        fi
      '';

    in
    pkgs.runCommand name
      (
        {
          # Include necessary build tools
          nativeBuildInputs = [ pkgs.qemu_kvm ];

          # Metadata for the VM package
          meta = {
            description = "${name} - Linux VM for multi-OS testing";
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
          };
        }
        // (
          # If ahFollowerdPath is provided, add it as a build input
          # This ensures Nix tracks the dependency and rebuilds the VM when the binary changes
          if ahFollowerdPath != null then { inherit ahFollowerdPath; } else { }
        )
      )
      ''
        mkdir -p $out/bin
        mkdir -p $out/ssh-key

        # Copy the VM disk image
        cp ${vmDisk} $out/disk.qcow2
        chmod 644 $out/disk.qcow2

        # Copy the cloud-init seed ISO
        cp ${seedISO} $out/seed.iso
        chmod 644 $out/seed.iso

        # Copy SSH keys for easy access
        cp ${sshKey.privateKey} $out/ssh-key/id_ed25519
        cp ${sshKey.keyPath}/id_ed25519.pub $out/ssh-key/id_ed25519.pub
        chmod 600 $out/ssh-key/id_ed25519
        chmod 644 $out/ssh-key/id_ed25519.pub

        # Install the run script
        cp ${runScript} $out/bin/run-vm
        chmod +x $out/bin/run-vm

        # Create a convenience README
        cat > $out/README.txt <<'EOF'
        ${name} - Ubuntu VM for Multi-OS Testing
        =========================================

        This package contains a pre-configured Ubuntu VM with cloud-init setup.${lib.optionalString installNix "\nNix package manager is pre-installed via cloud-init."}${
          lib.optionalString (
            ahFollowerdPath != null
          ) "\nah-followerd binary is deployed to /usr/local/bin/ah-followerd."
        }

        Quick Start:
        -----------
        ./bin/run-vm                    # Start VM in foreground
        ./bin/run-vm -daemonize &       # Start VM in background

        SSH Access:
        ----------
        ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost${
          lib.optionalString (ahFollowerdPath != null)
            "\n\nVerify ah-followerd:\n  ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost '/usr/local/bin/ah-followerd --version'"
        }

        Files:
        -----
        disk.qcow2    - VM disk image (QCOW2 format, ${diskSize})
        seed.iso      - Cloud-init configuration ISO
        ssh-key/      - SSH keys for VM access
        bin/run-vm    - QEMU launch script

        Configuration:
        -------------
        Hostname: ${hostname}
        Username: ${username}
        SSH Port: ${toString sshPort} (host) -> 22 (VM)
        Memory: ${toString memory} MB
        CPUs: ${toString cpus}${lib.optionalString installNix "\nNix: Installed (multi-user daemon)"}${
          lib.optionalString (
            ahFollowerdPath != null
          ) "\nah-followerd: Deployed to /usr/local/bin/ah-followerd"
        }

        Note: First boot may take ${
          if installNix then
            "60-90 seconds for cloud-init + Nix installation"
          else
            "30-60 seconds for cloud-init"
        } to complete.
        EOF
      '';
}
