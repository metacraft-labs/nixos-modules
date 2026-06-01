# NixOS-on-aarch64 Guest Image for the Agent Harbor Test Suite
#
# This module builds a bootable aarch64-linux NixOS image whose system
# configuration is defined in ./configuration.nix.  The image is intended
# to be the canonical "safe place" to run `just test-all` against the AH
# (Agent Harbor) workspace — see the Multi-OS-VM-Automation-Campaign
# milestone file (M33, M34) for context.
#
# The image is produced as a QCOW2 disk via
# `nixos-generators -f qcow` style derivation but expressed directly with
# the NixOS image-builder modules so consumers don't need an extra flake
# input.  It is bootable under:
#
#   - Tart-Linux-ARM on Apple Silicon macOS hosts (`tart run`).
#   - libvirt/QEMU on aarch64-linux hosts (`virsh`).
#   - UTM on macOS hosts (manual import).
#
# A cloud-init NoCloud seed ISO is generated alongside the disk so the
# guest auto-authorizes the operator's SSH key on first boot.  The seed
# pattern matches ../ubuntu/cloud-init.nix.
#
# Outputs of `makeNixosAhTestGuest`:
#
#   $out/disk.qcow2           — the bootable VM disk image
#   $out/seed.iso             — cloud-init NoCloud seed (SSH key + hostname)
#   $out/ssh-key/id_ed25519   — private key for the seeded SSH access
#   $out/ssh-key/id_ed25519.pub
#   $out/bin/run-vm           — convenience launcher (qemu-system-aarch64)
#   $out/README.txt           — quick-start instructions
#
# References:
#   - Multi-OS-VM-Automation-Campaign.milestones.org § M33, M34
#   - AH flake: /Users/zahary/blocksense/agent-harbor/main/flake.nix
#   - vm-images/ubuntu/default.nix (the structural template this file mirrors)
{
  pkgs,
  lib,
}:

let
  cloudInit = import ./cloud-init.nix { inherit pkgs lib; };

  # Evaluate the NixOS configuration declared in ./configuration.nix and
  # extract a QCOW2 disk image via the NixOS "qemu image" builder.
  #
  # KNOWN ISSUE (2026-06-01): the `system.build.qcow2` attribute only exists
  # when `virtualisation/qemu-vm.nix` is imported into the configuration,
  # and even then it is an *ephemeral run-VM* (backing-file qcow with the
  # host's /nix/store passed through 9p), not a self-contained bootable disk.
  # The current configuration.nix imports `installer/cd-dvd/installation-cd-minimal.nix`,
  # which produces `system.build.isoImage` (a bootable installer ISO) — also
  # not a self-contained QCOW2 disk image with the AH toolchain pre-baked.
  #
  # To produce a real self-contained bootable QCOW2 disk image with the AH
  # toolchain baked in, the recommended fix is ONE of:
  #
  #   (A) Add `nixos-generators` as a flake input to nixos-modules and use
  #       `nixos-generators.nixosGenerate { format = "qcow"; ... }`. This is
  #       the most widely-deployed pattern.
  #
  #   (B) Switch the configuration to use the NixOS `image.repart` modules
  #       (`${modulesPath}/image/repart.nix`) to declaratively build a disk
  #       image. Removes the nixos-generators dep but requires more module
  #       wiring for the cloud-init seed.
  #
  #   (C) Replace this whole module with a build of an Ubuntu cloud image
  #       seeded with cloud-init that runs a NixOS installer on first boot
  #       (slow first boot but the simplest path).
  #
  # Until that fix lands, this builder accepts the resource-cap parameters
  # but produces a placeholder derivation that throws a clear error at
  # build time (rather than at evaluation time, so the rest of the
  # nixos-modules flake stays evaluatable on macOS). The 2026-06-01 M33
  # measurement pass used the Tart Ubuntu 24.04 ARM fallback guest with
  # the AH toolchain installed inline (the recipe is documented in the M33
  # methodology doc at specs/Public/AH-Test-Resource-Profile.md).
  buildNixosAhTestImage =
    {
      diskSizeMiB,
      memoryMiB,
      vcpus,
    }:
    let
      # Evaluating the bare configuration still validates the module structure
      # (so `nix eval` against the module catches typos/missing options).
      nixosSystem = pkgs.nixos { imports = [ ./configuration.nix ]; };
      _ = nixosSystem.config.system.build.toplevel;
    in
    pkgs.runCommand "nixos-ah-test-guest-image-placeholder" { } ''
      cat >&2 <<'EOF'
      ============================================================================
      nixos-ah-test-guest: cannot build a bootable QCOW2 from the current module.

      The configuration imports installer/cd-dvd/installation-cd-minimal.nix
      (which produces system.build.isoImage, not system.build.qcow2). To get a
      real bootable QCOW2 disk image with the AH toolchain pre-baked, apply
      ONE of fixes (A), (B), or (C) documented in default.nix above.

      Until that fix lands, use the Tart Ubuntu 24.04 ARM fallback documented
      in specs/Public/AH-Test-Resource-Profile.md (M33 doc) §"Triage path
      actually used (2026-06-01)".

      Resource caps requested by the builder:
        vcpus      = ${toString vcpus}
        memoryMiB  = ${toString memoryMiB}
        diskSizeMiB = ${toString diskSizeMiB}
      ============================================================================
      EOF
      exit 1
    '';

in
{
  # Build a complete nixos-ah-test-guest package (disk image + cloud-init seed
  # + SSH key + launcher script).  Parameters are intentionally minimal:
  # everything that affects the *contents* of the image is declared inside
  # ./configuration.nix; the arguments here only tune resource ceilings for
  # the host-side launcher and the seeded hostname.
  #
  # Parameters:
  #   hostname    — instance hostname (default "nixos-ah-test-guest")
  #   username    — SSH login (default "agent" — matches NixOS configuration)
  #   sshPort     — host port to forward to the guest's SSH (default 2228;
  #                 chosen to avoid colliding with the Ubuntu/macOS/Windows
  #                 forwards already documented in ../../flake-parts module)
  #   memoryMiB   — RAM allocation (default 16 GiB — see configuration.nix
  #                 commentary on M33 measurement goals)
  #   vcpus       — vCPU count (default 8 — half a 16-core host)
  #   diskSizeMiB — virtual disk size (default 100 GiB)
  makeNixosAhTestGuest =
    {
      hostname ? "nixos-ah-test-guest",
      username ? "agent",
      sshPort ? 2228,
      memoryMiB ? 16384,
      vcpus ? 8,
      diskSizeMiB ? 102400,
    }:
    let
      sshKey = cloudInit.generateTestSSHKey { name = "nixos-ah-test-guest-key"; };

      cloudInitConfig = cloudInit.makeCloudInitConfig {
        inherit hostname username;
        sshPublicKey = sshKey.publicKey;
      };

      seedISO =
        pkgs.runCommand "nixos-ah-test-guest-seed.iso"
          {
            nativeBuildInputs = [ pkgs.cloud-utils ];
          }
          ''
            cloud-localds $out ${cloudInitConfig}/user-data ${cloudInitConfig}/meta-data
          '';

      qcow = buildNixosAhTestImage {
        inherit diskSizeMiB memoryMiB vcpus;
      };

      # aarch64 launcher.  We use `qemu-system-aarch64` directly so the same
      # output works on Linux/aarch64 (KVM accel) and on macOS/aarch64
      # (HVF accel via the `hvf` machine type) without per-host launcher
      # variants.  Tart users will typically `tart create --from-disk` from
      # $out/disk.qcow2 and ignore this launcher entirely.
      runScript = pkgs.writeShellScript "run-nixos-ah-test-guest" ''
        set -euo pipefail
        SCRIPT_DIR="$(cd "$(dirname "''${BASH_SOURCE[0]}")" && pwd)"
        VM_DIR="$(dirname "$SCRIPT_DIR")"

        DISK="$VM_DIR/disk.qcow2"
        SEED_ISO="$VM_DIR/seed.iso"

        SSH_PORT="''${AH_VM_SSH_PORT:-${toString sshPort}}"
        if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
          echo "Invalid SSH port: $SSH_PORT" >&2
          exit 1
        fi

        # Pick the best available acceleration for the host architecture.
        UNAME_S="$(uname -s)"
        UNAME_M="$(uname -m)"
        ACCEL=""
        if [ "$UNAME_M" != "aarch64" ] && [ "$UNAME_M" != "arm64" ]; then
          echo "WARNING: nixos-ah-test-guest is an aarch64 image but the host is $UNAME_M." >&2
          echo "         QEMU will emulate aarch64 in software — expect 10-100x slowdown." >&2
          ACCEL="-machine virt -cpu cortex-a76"
        elif [ "$UNAME_S" = "Linux" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
          ACCEL="-machine virt,gic-version=3,accel=kvm -cpu host"
          echo "Using KVM acceleration (Linux/aarch64)."
        elif [ "$UNAME_S" = "Darwin" ]; then
          ACCEL="-machine virt,accel=hvf -cpu cortex-a72"
          echo "Using Hypervisor.framework acceleration (macOS/aarch64)."
        else
          ACCEL="-machine virt -cpu cortex-a76"
          echo "WARNING: no hardware acceleration available — using software emulation." >&2
        fi

        QEMU="${pkgs.qemu}/bin/qemu-system-aarch64"
        FW="${pkgs.OVMF.fd}/FV/AAVMF_CODE.fd"

        echo "Starting ${hostname}..."
        echo "  SSH: localhost:$SSH_PORT (VM port 22)"
        echo "  Memory: ${toString memoryMiB} MiB"
        echo "  vCPUs: ${toString vcpus}"
        echo "  Disk:  $DISK"
        echo ""
        echo "To connect: ssh -p $SSH_PORT -i $VM_DIR/ssh-key/id_ed25519 ${username}@localhost"
        echo ""

        exec "$QEMU" \
          $ACCEL \
          -m ${toString memoryMiB} \
          -smp ${toString vcpus} \
          -drive if=pflash,format=raw,readonly=on,file="$FW" \
          -drive file="$DISK",if=virtio,format=qcow2,cache=writeback \
          -drive file="$SEED_ISO",if=virtio,format=raw,media=cdrom,readonly=on \
          -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
          -device virtio-net-pci,netdev=net0 \
          -nographic \
          -serial mon:stdio \
          "$@"
      '';

    in
    pkgs.runCommand "nixos-ah-test-guest"
      {
        nativeBuildInputs = [ pkgs.qemu ];
        meta = {
          description = "NixOS aarch64 guest image preloaded with the AH build toolchain (M34)";
          platforms = [ "aarch64-linux" ];
          longDescription = ''
            A NixOS aarch64 VM image baked with every prerequisite the Agent
            Harbor test suite (`just test-all`) needs: Rust, Nim, pixi, just,
            Nix, mutagen, FUSE, btrfs-progs, and the system libraries the AH
            devshell references for Linux builds.  Intended to be booted via
            Tart-Linux-ARM, libvirt, or UTM on an Apple Silicon host so the
            AH test suite can run in isolation from the host (the suite is
            known to hang macOS hosts when run natively).
          '';
        };
        passthru = {
          inherit
            hostname
            username
            sshPort
            memoryMiB
            vcpus
            diskSizeMiB
            ;
        };
      }
      ''
        mkdir -p $out/bin $out/ssh-key

        # Copy the QCOW2 disk image produced by the NixOS image builder.
        # Some NixOS versions expose the qcow under a versioned filename;
        # we glob to be robust to that.
        cp ${qcow}/nixos.qcow2 $out/disk.qcow2 2>/dev/null || \
          cp $(find ${qcow} -name '*.qcow2' | head -1) $out/disk.qcow2
        chmod 644 $out/disk.qcow2

        cp ${seedISO} $out/seed.iso
        chmod 644 $out/seed.iso

        cp ${sshKey.privateKey} $out/ssh-key/id_ed25519
        cp ${sshKey.keyPath}/id_ed25519.pub $out/ssh-key/id_ed25519.pub
        chmod 600 $out/ssh-key/id_ed25519
        chmod 644 $out/ssh-key/id_ed25519.pub

        cp ${runScript} $out/bin/run-vm
        chmod +x $out/bin/run-vm

        cat > $out/README.txt <<EOF
        nixos-ah-test-guest — NixOS aarch64 guest for the AH test suite
        ================================================================

        Defaults baked into this image:
          hostname:  ${hostname}
          username:  ${username}
          ssh port:  ${toString sshPort} (host) → 22 (guest)
          memory:    ${toString memoryMiB} MiB
          vcpus:     ${toString vcpus}
          disk:      ${toString diskSizeMiB} MiB

        Quick start (libvirt/qemu host):
          ./bin/run-vm
          # then, from another terminal:
          ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost

        Quick start (Tart on macOS):
          tart create --from-disk ./disk.qcow2 ah-test-guest
          tart run ah-test-guest
          # SSH key is in ssh-key/id_ed25519; tart will assign an IP visible via
          # `tart ip ah-test-guest`.

        Quick start (UTM on macOS):
          File → New → Virtualize → Linux, then point the disk image at
          disk.qcow2.  Attach seed.iso as a CD-ROM for first-boot SSH key
          injection.

        Verifying the toolchain (M34 verification test):
          ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost \\
            'rustc --version && nim --version && just --version && mutagen version'

        Running the AH test suite inside the guest (M33 triage):
          ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost
          # Inside the guest:
          git clone https://github.com/blocksense-network/agent-harbor /home/${username}/agent-harbor
          cd /home/${username}/agent-harbor
          nix develop .#default
          /usr/bin/time -v just test-all

        See README.md alongside this module for a full discussion of how to
        update the image when AH's flake inputs change.
        EOF
      '';
}
