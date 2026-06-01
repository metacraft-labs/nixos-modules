# M34 AH-test-guest image builder — Path C (Ubuntu cloud image + Nix-on-first-boot).
#
# This module produces a bootable VM disk + cloud-init seed for the Agent Harbor
# test suite (`just test-all`) on aarch64-linux. M34's original plan (Path A:
# pure NixOS aarch64 QCOW2 evaluated on the host) is blocked on macOS workstations
# without a Linux/aarch64 remote builder, so M34 ships **Path C**:
#
#   - Base: Ubuntu 24.04 LTS aarch64 cloud image (operator-provided URL or
#     pre-fetched derivation).
#   - First boot: cloud-init installs Nix multi-user + the AH build toolchain
#     (rustup, nim, just, pixi, mutagen, system libs) via `apt-get` and the
#     upstream installers documented in
#     `specs/Public/AH-Test-Resource-Profile.md`'s "Triage path actually used".
#   - The recipe matches the one validated by hand on 2026-06-01 (see M33 doc).
#
# Trade-off vs Path A (pure NixOS): we lose declarative pinning of toolchain
# versions and trust apt/rustup defaults at first-boot. We gain: builds on a
# macOS workstation without a Linux/aarch64 remote builder; ~30 min wall-clock
# vs hours for a full NixOS aarch64 closure pull; consistency with the
# bring-up recipe already documented in the M33 measurement pass.
#
# Operators who want the pure-NixOS path (Path A) should set up
# nix-darwin's linux-builder (`nix.linux-builder.enable = true`) on macOS or
# build on a Linux/aarch64 host, then use the historical configuration.nix in
# this directory as the system-config seed. See README.md §"Path A escape hatch".
#
# Outputs:
#   $out/disk.qcow2           — Ubuntu cloud image with extra storage allocated
#   $out/seed.iso             — cloud-init NoCloud seed (SSH key + first-boot
#                               Nix install + AH toolchain install)
#   $out/ssh-key/id_ed25519   — private key for SSH access
#   $out/ssh-key/id_ed25519.pub
#   $out/bin/run-vm           — qemu-system-aarch64 launcher
#   $out/README.txt           — quick-start
{
  pkgs,
  lib,
}:

let
  cloudInit = import ./cloud-init.nix { inherit pkgs lib; };

  # First-boot script that installs the AH build toolchain on Ubuntu.
  # Mirrors the recipe captured in specs/Public/AH-Test-Resource-Profile.md
  # §"Triage path actually used (2026-06-01)" — what the operator ran by
  # hand against the Tart Ubuntu fallback guest. Captured here so cloud-init
  # runs it automatically on first boot of every clone.
  ahToolchainInstallScript = pkgs.writeText "install-ah-toolchain.sh" ''
    #!/usr/bin/env bash
    set -euo pipefail

    LOG=/var/log/ah-toolchain-install.log
    exec > >(tee -a "$LOG") 2>&1
    echo "=== AH toolchain install start: $(date -Iseconds) ==="

    # cloud-init runcmd executes us as root with an empty environment. The
    # official Nix installer (step 2) and several rustup/pixi sub-installers
    # abort with "$HOME is not set" under `set -u`. Seed HOME for the root
    # phases; the per-user phase below runs under `sudo -u agent bash -lc`
    # which establishes its own HOME from /etc/passwd.
    export HOME=/root

    # 1. System libraries from the AH nix/devshell.nix Linux branch + the M33
    #    instrumentation toolchain.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      build-essential pkg-config libssl-dev libseccomp-dev libcap-dev \
      fuse3 libfuse3-dev libuv1-dev btrfs-progs cmake ninja-build \
      clang lld libclang-dev git curl wget jq time sysstat lsof htop strace \
      python3 python3-pip nodejs npm libdbus-1-dev protobuf-compiler \
      libprotobuf-dev libx11-dev libxkbcommon-dev libxcb1-dev libwayland-dev \
      mold rsync libasound2-dev libudev-dev xz-utils ca-certificates

    # 2. Nix multi-user (the official installer; same as Ubuntu cloud-init's
    #    installNix path, but invoked here so we can sequence it relative to
    #    the toolchain installers below).
    if [ ! -d /nix/store ]; then
      echo "Installing Nix multi-user..."
      curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    fi

    # Trust the AH cachix substituters so the first `nix develop` against the
    # AH source tree pulls from cache rather than rebuilding from source.
    mkdir -p /etc/nix
    cat > /etc/nix/nix.conf <<EOF
    experimental-features = nix-command flakes
    trusted-users = root agent
    substituters = https://cache.nixos.org https://agent-harbor.cachix.org https://mcl-public-cache.cachix.org https://nix-community.cachix.org
    trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= agent-harbor.cachix.org-1:OkD+ev9p7Lt5iEgN+1OUjFwm9TmTrEKDoYqcUe11/y0= mcl-public-cache.cachix.org-1:F1S4tQGZ6jiyxA9OOL/2J64KO0pcKzv+jHcKv+IO4iE= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
    EOF
    systemctl restart nix-daemon 2>/dev/null || true

    # 3. Per-user AH toolchain (Rust + Nim + just + pixi + mutagen). Installed
    #    as the `agent` user so the binaries land in /home/agent/.cargo + /opt
    #    and the agent's interactive shell picks them up via /etc/profile.d.
    AGENT_HOME=/home/agent
    sudo -u agent bash -lc '
      set -euo pipefail
      cd "$HOME"

      # Rust via rustup (stable channel). The fenix-pinned toolchain comes in
      # via `nix develop` once the operator clones AH; this is the bootstrap
      # so `cargo` is on PATH before the devshell exists.
      if ! command -v rustup >/dev/null 2>&1; then
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default
      fi
      source "$HOME/.cargo/env"
      cargo install --locked cargo-nextest || true

      # Nim 2.x via Nix (choosenim has no linux_arm64 build — "platform is
      # not supported" — so we delegate to the multi-user Nix installed in
      # step 2 instead. Single-user profile so the agent's interactive shell
      # picks it up via ~/.nix-profile/bin, which /etc/profile.d/nix.sh adds
      # to PATH.).
      if ! command -v nim >/dev/null 2>&1; then
        # /etc/profile.d/nix.sh is sourced by `bash -lc`, so `nix-env` is on
        # PATH here. Guard with an explicit source for robustness if the
        # profile snippet isn't installed yet.
        if [ -f /etc/profile.d/nix.sh ]; then . /etc/profile.d/nix.sh; fi
        nix-env -iA nixpkgs.nim2
      fi

      # just (cargo install)
      command -v just >/dev/null 2>&1 || cargo install just --locked

      # pixi (upstream installer; binary release).
      command -v pixi >/dev/null 2>&1 || curl -fsSL https://pixi.sh/install.sh | bash

      # mutagen (linux_arm64 release tarball).
      if ! command -v mutagen >/dev/null 2>&1; then
        MUT_VER=0.18.1
        TMP=$(mktemp -d)
        curl -fsSL "https://github.com/mutagen-io/mutagen/releases/download/v${"$"}{MUT_VER}/mutagen_linux_arm64_v${"$"}{MUT_VER}.tar.gz" -o "$TMP/mutagen.tgz"
        tar -xzf "$TMP/mutagen.tgz" -C "$TMP"
        sudo install -m 0755 "$TMP/mutagen" /usr/local/bin/mutagen
        rm -rf "$TMP"
      fi
    '

    # 4. Resource-cap env vars (consumed by the M36 just test-in-vm wrapper +
    #    M37 host-starvation guard). Match the defaults documented in
    #    nixos-ah-test-guest/configuration.nix.
    cat > /etc/profile.d/ah-test-guest.sh <<'EOF'
    export AH_TEST_GUEST_VCPUS=8
    export AH_TEST_GUEST_MEMORY_MIB=16384
    export AH_TEST_GUEST_DISK_MIB=102400
    export AH_TEST_RECOMMENDED_TEST_THREADS=4
    EOF
    chmod 0644 /etc/profile.d/ah-test-guest.sh

    # 5. Mark the install as complete so subsequent boots no-op.
    touch /etc/ah-toolchain-installed

    echo "=== AH toolchain install complete: $(date -Iseconds) ==="
  '';

  # Cloud-init user-data for Path C — combines the Ubuntu makeLinuxVM
  # installNix path with the bespoke AH-toolchain install script above.
  makeAhPathCSeed =
    {
      hostname,
      username,
      sshPublicKey,
    }:
    let
      installScriptB64 = pkgs.runCommand "ah-toolchain-install-b64" { } ''
        base64 -w 0 ${ahToolchainInstallScript} > $out
      '';

      userData = pkgs.writeText "user-data" ''
        #cloud-config

        hostname: ${hostname}
        preserve_hostname: false

        users:
          - name: ${username}
            sudo: ALL=(ALL) NOPASSWD:ALL
            groups: [sudo, users]
            lock_passwd: true
            ssh_authorized_keys:
              - ${sshPublicKey}
            shell: /bin/bash

        ssh_pwauth: false
        disable_root: true

        package_update: true
        package_upgrade: false

        write_files:
          - path: /usr/local/sbin/install-ah-toolchain.sh
            permissions: '0755'
            owner: root:root
            encoding: b64
            content: ${builtins.readFile installScriptB64}

        runcmd:
          - [ /usr/local/sbin/install-ah-toolchain.sh ]

        final_message: "M34 Path C cloud-init complete: AH toolchain installed. SSH as ${username}@<host>."
      '';

      metaData = pkgs.writeText "meta-data" ''
        instance-id: ${hostname}
        local-hostname: ${hostname}
      '';
    in
    pkgs.runCommand "nixos-ah-test-guest-seed" { } ''
      mkdir -p $out
      cp ${userData} $out/user-data
      cp ${metaData} $out/meta-data
    '';

in
{
  # M34 builder — Path C (Ubuntu cloud image + Nix-on-first-boot AH toolchain).
  #
  # Parameters:
  #   cloudImage  — path to an Ubuntu 24.04 aarch64 cloud QCOW2. Operator
  #                 supplies this; we don't bundle iso-fetchers' aarch64
  #                 variant yet. Suggested download:
  #                   https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img
  #                 Pin the sha256 in the consumer flake via vmImages.fetchUbuntuCloudImage
  #                 once iso-fetchers grows an arm64 variant; until then,
  #                 use a flake input with pkgs.fetchurl directly.
  #   hostname    — default "nixos-ah-test-guest"
  #   username    — default "agent"
  #   sshPort     — host port forwarded to guest:22 (default 2228)
  #   memoryMiB   — RAM (default 16 GiB)
  #   vcpus       — vCPUs (default 8)
  #   diskSizeMiB — virtual disk (default 100 GiB)
  makeNixosAhTestGuest =
    {
      cloudImage ? null,
      hostname ? "nixos-ah-test-guest",
      username ? "agent",
      sshPort ? 2228,
      memoryMiB ? 16384,
      vcpus ? 8,
      diskSizeMiB ? 102400,
    }:
    let
      sshKey = cloudInit.generateTestSSHKey { name = "nixos-ah-test-guest-key"; };

      seed = makeAhPathCSeed {
        inherit hostname username;
        sshPublicKey = sshKey.publicKey;
      };

      seedISO =
        pkgs.runCommand "nixos-ah-test-guest-seed.iso"
          {
            nativeBuildInputs = [ pkgs.cloud-utils ];
          }
          ''
            cloud-localds $out ${seed}/user-data ${seed}/meta-data
          '';

      # If the operator didn't supply a cloud image, fail loudly at build
      # time (rather than at evaluation) with a clear pointer to the URL.
      cloudImageResolved =
        if cloudImage != null then
          cloudImage
        else
          pkgs.runCommand "nixos-ah-test-guest-cloud-image-required" { } ''
            cat >&2 <<'EOF'
            ============================================================================
            nixos-ah-test-guest (M34, Path C) requires a cloud-image input.

            Pass `cloudImage = <path>` when calling makeNixosAhTestGuest. The
            expected file is an Ubuntu 24.04 aarch64 server cloud QCOW2:

              https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img

            Fetch via pkgs.fetchurl in the consumer flake:

              pkgs.fetchurl {
                url = "https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-arm64.img";
                sha256 = "<run nix-prefetch-url to fill in>";
              }
            ============================================================================
            EOF
            exit 1
          '';

      diskGiB = (diskSizeMiB + 1023) / 1024;

      vmDisk =
        pkgs.runCommand "nixos-ah-test-guest-disk.qcow2"
          {
            nativeBuildInputs = [ pkgs.qemu ];
          }
          ''
            # Create a QCOW2 overlay on top of the cloud image. Operators who
            # need a self-contained disk (no backing reference) should rebase
            # with `qemu-img convert -O qcow2 disk.qcow2 standalone.qcow2`.
            qemu-img create -f qcow2 -F qcow2 -b ${cloudImageResolved} $out ${toString diskGiB}G
          '';

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

        # UEFI firmware: prefer host-installed AAVMF (Homebrew QEMU on macOS,
        # /usr/share/AAVMF on Linux distros) over a Nix-built one because the
        # ARM EDK2 build is brittle on aarch64-darwin (CLANGPDB toolchain
        # gap). Operators who want a Nix-pinned firmware should rebuild this
        # module under Linux/aarch64 where pkgs.OVMF.fd is well-supported.
        if [ -n "''${AH_VM_FIRMWARE:-}" ]; then
          FW="$AH_VM_FIRMWARE"
        elif [ -r /opt/homebrew/share/qemu/edk2-aarch64-code.fd ]; then
          FW=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
        elif [ -r /usr/share/AAVMF/AAVMF_CODE.fd ]; then
          FW=/usr/share/AAVMF/AAVMF_CODE.fd
        elif [ -r /usr/share/qemu/edk2-aarch64-code.fd ]; then
          FW=/usr/share/qemu/edk2-aarch64-code.fd
        else
          echo "ERROR: no AAVMF UEFI firmware found. Set AH_VM_FIRMWARE=<path>." >&2
          exit 1
        fi

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
          description = "Ubuntu 24.04 aarch64 guest with AH build toolchain installed on first boot (M34 Path C)";
          platforms = [
            "aarch64-linux"
            "aarch64-darwin"
          ];
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
          path = "C";
          ahToolchainInstallScript = ahToolchainInstallScript;
        };
      }
      ''
        mkdir -p $out/bin $out/ssh-key

        cp ${vmDisk} $out/disk.qcow2
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
        nixos-ah-test-guest (M34, Path C: Ubuntu + first-boot AH toolchain)
        ====================================================================

        Defaults:
          hostname:  ${hostname}
          username:  ${username}
          ssh port:  ${toString sshPort} (host) -> 22 (guest)
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
          # cloud-init takes ~5-10 min on first boot (apt + rustup + nim + pixi)

        First-boot timeline (cloud-init runcmd → install-ah-toolchain.sh):
          ~30s   apt-get update + system packages
          ~60s   Nix multi-user installer
          ~3min  rustup + cargo-install (cargo-nextest, just)
          ~2min  choosenim (Nim 2.x)
          ~10s   pixi installer
          ~5s    mutagen tarball
          ===================================================
          ~6min  total wall-clock on Apple Silicon under hvf

        Verifying the toolchain (M34 verification test):
          ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost '
            test -f /etc/ah-toolchain-installed &&
            rustc --version && nim --version &&
            just --version && mutagen version && pixi --version'

        Running the AH test suite inside the guest (M36 just test-in-vm):
          ssh -p ${toString sshPort} -i ssh-key/id_ed25519 ${username}@localhost
          # Inside the guest:
          git clone https://github.com/blocksense-network/agent-harbor /home/${username}/agent-harbor
          cd /home/${username}/agent-harbor
          source ~/.cargo/env
          just test-in-vm
        EOF
      '';

  # Re-export the cloud-init helpers so consumers can build custom seeds
  # without re-importing the cloud-init module.
  inherit (cloudInit) makeCloudInitConfig generateTestSSHKey;
}
