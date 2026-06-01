# NixOS Guest Configuration for the Agent Harbor Test Suite
#
# This module defines the NixOS system configuration for the `nixos-ah-test-guest`
# VM image. The image is built for `aarch64-linux` (Apple Silicon hosts) and is
# intended to be booted from one of three backends:
#
#   1. Tart-Linux-ARM on macOS hosts.
#   2. libvirt/QEMU on Linux/aarch64 hosts.
#   3. UTM on macOS hosts (for manual interactive debugging).
#
# The configuration bakes in every build prerequisite needed to compile and
# exercise the Agent Harbor (AH) test suite from `just test-all`:
#
#   - Rust toolchain (rustc/cargo/clippy/rustfmt + nextest).
#   - Nim 2.x for the agentfs Nim FFI bindings + vm-harness library.
#   - pixi for the AH/Windows-style toolchain pin manifest.
#   - just for the AH Justfile.
#   - Nix (multi-user) for the AH devshell.
#   - mutagen for `ah-mutagen-sync` source-tree synchronisation from the host.
#   - System dependencies referenced by the AH `nix/devshell.nix` Linux branch
#     that are required even before `nix develop .#default` enters the AH shell
#     (so the guest is useful for a quick smoke test without a multi-gigabyte
#     devshell pull).
#
# The image is intentionally *generous* on resources — the M33 triage measures
# peak demand, so the defaults need to be large enough to *observe* host
# starvation, not constrain it.  M37 will introduce tight per-backend caps
# downstream once the M33 measurements land.
#
# References:
#   - AH flake: /Users/zahary/blocksense/agent-harbor/main/flake.nix
#   - AH devshell: /Users/zahary/blocksense/agent-harbor/main/nix/devshell.nix
#   - Multi-OS-VM-Automation-Campaign milestone file (M33, M34).
#   - VM-Harness-Design.md §5 (aarch64-linux guest).
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  # Username for the `agent` account inside the guest.  Matches the convention
  # established by the Ubuntu cloud-image VMs in this repo (see
  # ../ubuntu/cloud-init.nix) so existing host-side tooling that connects with
  # the `agent` login keeps working unchanged.
  username = "agent";

  # Resource caps baked into the VM image metadata.  M33 measurements will
  # refine these; the defaults here come from the prompt's "Initial sane
  # defaults" guidance:
  #
  #   - 8 vCPU: half a 16-core M-series host, prevents fan-runaway during cargo
  #     parallel compilation while still giving nextest enough cores to make
  #     progress.
  #   - 16 GB RAM: AH workspace cargo build (workspace ≈ 150 crates) peaks
  #     around 12 GB during link-time codegen with nextest's default
  #     concurrency.  16 GB leaves a 4 GB headroom for the OS + FUSE caches +
  #     the synced source tree.
  #   - 100 GB disk: cargo target/ for the full AH workspace lands around
  #     40 GB; Nix /nix/store with the AH devshell closures adds another 20 GB;
  #     leave 40 GB free for test artefacts, mutagen state, agentfs scratch.
  defaultVcpus = 8;
  defaultMemoryMiB = 16384;
  defaultDiskSizeMiB = 102400;

in
{
  imports = [
    # NixOS QEMU disk-image builder.  This produces a QCOW2 image that boots
    # under both Tart-Linux-ARM (which expects EFI + virtio) and libvirt.
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  # ---------------------------------------------------------------------------
  # Boot configuration
  # ---------------------------------------------------------------------------
  #
  # We target aarch64-linux exclusively.  EFI is required for Tart-Linux-ARM
  # and for modern libvirt QEMU guests on aarch64; legacy BIOS boot does not
  # apply on this architecture.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;

  # Enable the kernel modules QEMU/Tart need for virtio devices.
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_net"
    "virtio_scsi"
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "sd_mod"
    "ahci"
  ];

  # FUSE is mandatory for the AgentFS test crates that mount via libfuse3.
  boot.kernelModules = [
    "fuse"
    "kvm"
  ];

  # ---------------------------------------------------------------------------
  # Filesystems
  # ---------------------------------------------------------------------------
  #
  # The disk image is a single ext4 root.  No swap by default — M33 wants to
  # observe true RAM peaks, not have them masked by swap.  Operators who want
  # to relax that constraint can enable a swapfile post-boot.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  # ---------------------------------------------------------------------------
  # Networking
  # ---------------------------------------------------------------------------
  networking.hostName = "nixos-ah-test-guest";
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.allowedTCPPorts = [
    22 # SSH
  ];

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------
  #
  # The `agent` account is the standard non-root login for AH operations.
  # Password is locked (SSH key auth only); the public key is injected by the
  # cloud-init NoCloud seed at first boot.  See ./cloud-init.nix for the seed.
  users.mutableUsers = false;
  users.users.${username} = {
    isNormalUser = true;
    description = "Agent Harbor test runner";
    extraGroups = [
      "wheel" # passwordless sudo
      "kvm"
      "video"
      "audio"
      "input"
    ];
    shell = pkgs.bash;
    # SSH authorized keys are seeded via cloud-init at first boot.
  };
  security.sudo.wheelNeedsPassword = false;

  # ---------------------------------------------------------------------------
  # SSH
  # ---------------------------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      KbdInteractiveAuthentication = false;
    };
  };

  # ---------------------------------------------------------------------------
  # Cloud-init for first-boot SSH seed
  # ---------------------------------------------------------------------------
  #
  # cloud-init reads the NoCloud seed ISO attached by the host VM launcher
  # (see ./cloud-init.nix and the host-side run script for the seed shape) and
  # writes the SSH authorized_keys for the `agent` user.  This is the same
  # pattern used by ../ubuntu/cloud-init.nix.
  services.cloud-init = {
    enable = true;
    network.enable = true;
  };

  # ---------------------------------------------------------------------------
  # Nix
  # ---------------------------------------------------------------------------
  #
  # The AH devshell relies on flakes + nix-command experimental features.
  # We also enable the AH cachix substituters so a `nix develop` against the
  # synced AH source tree pulls from the cache instead of building from
  # source — without this, the first `just test-rust` inside the guest spends
  # an hour building rustc/playwright/etc.
  nix = {
    package = pkgs.nixVersions.stable;
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [
        "root"
        username
      ];
      substituters = [
        "https://cache.nixos.org"
        "https://agent-harbor.cachix.org"
        "https://mcl-public-cache.cachix.org"
        "https://nix-community.cachix.org"
      ];
      trusted-public-keys = [
        "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        "agent-harbor.cachix.org-1:2x123W9OUoHUzXoSvPv2CRXPo7rjLKAOd6/MkaHFNRA="
        "mcl-public-cache.cachix.org-1:OcUzMeoSAwNEd3YCaEbNjLV5/Gd+U5VFxdN2WGHfpCI="
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      # Tune for "give me throughput" rather than "be polite to the host" —
      # the guest is dedicated to the test suite.
      max-jobs = "auto";
      cores = 0; # all available
    };
  };

  # ---------------------------------------------------------------------------
  # AH build prerequisites (system-level)
  # ---------------------------------------------------------------------------
  #
  # These are the *toolchains* the AH test suite needs.  They match the
  # versions referenced by `agent-harbor/main/flake.nix` (rust-overlay/fenix
  # latest stable channel) and `pixi.toml` (just, nodejs, ninja).  Pinning to
  # a specific Rust toolchain is intentionally NOT done at this layer because
  # the AH devshell brings its own pinned toolchain via fenix; the
  # `pkgs.rustup`/`pkgs.rustc` here is for the bootstrap probes
  # (`rustc --version`) that the M34 verification test exercises.
  environment.systemPackages = with pkgs; [
    # Core build toolchains referenced by AH flake inputs + pixi
    rustc
    cargo
    clippy
    rustfmt
    rust-analyzer
    cargo-nextest

    nim2 # Nim 2.x — agentfs Nim bindings + vm-harness library
    nimble

    pixi # AH pixi.toml workspace manager
    just # AH Justfile driver

    mutagen # ah-mutagen-sync host↔guest source sync
    mutagen-compose

    # System libraries used by the AH workspace at build/test time
    pkg-config
    openssl
    openssl.dev
    cmake
    ninja
    gnumake
    gcc
    binutils
    libseccomp # AH sandbox tests on Linux
    libcap
    fuse3 # AgentFS FUSE host
    fuse3.dev
    libuv # ah-background-proc

    # Filesystem testing
    btrfs-progs
    e2fsprogs
    xfsprogs

    # Networking / IPC
    socat
    netcat-openbsd
    iproute2

    # Test harness utilities
    procps # ps, top, free — used by the M33 instrumentation
    util-linux # /usr/bin/time -v (GNU time)
    time
    lsof
    sysstat # sar, iostat, mpstat
    htop
    bottom # tui resource monitor — handy for live triage debugging
    strace
    perf-tools

    # Source-control + project tooling
    git
    git-lfs
    gitMinimal
    gh
    bash
    coreutils
    findutils
    gawk
    gnused
    gnugrep
    gnutar
    gzip
    xz
    zstd
    curl
    wget
    jq
    yq

    # Node.js — webui/e2e-tests workspace + electron-app
    nodejs
    yarn-berry

    # Python — AH python-libs/setup-tests and scripts/*.py helpers
    python3
    python3Packages.pip
    python3Packages.virtualenv
    python3Packages.pyyaml
    python3Packages.requests
    python3Packages.psutil # used by some M33 sampling scripts

    # Editors (minimal — interactive triage convenience only)
    vim
    nano
  ];

  # ---------------------------------------------------------------------------
  # Runtime services the AH test suite expects
  # ---------------------------------------------------------------------------
  programs.fuse.userAllowOther = true;

  # Btrfs may be exercised by AH snapshot/restore tests.
  boot.supportedFilesystems = [
    "btrfs"
    "ext4"
    "vfat"
    "fuse"
  ];

  # ---------------------------------------------------------------------------
  # AH resource-cap defaults — published via environment for M37 to read.
  # ---------------------------------------------------------------------------
  #
  # These environment variables are not consumed by NixOS itself; they are
  # baked into /etc/profile so downstream tooling (the M37 host-starvation
  # guard, the M36 `just test-in-vm` wrapper) can read the guest's intended
  # resource ceiling without having to grep the launcher script.
  environment.variables = {
    AH_TEST_GUEST_VCPUS = toString defaultVcpus;
    AH_TEST_GUEST_MEMORY_MIB = toString defaultMemoryMiB;
    AH_TEST_GUEST_DISK_MIB = toString defaultDiskSizeMiB;
    # Pinned recommendation for `cargo nextest` until M33 refines per-target
    # caps.  The conservative starting point is half the vCPU count to leave
    # headroom for linker forks + FUSE worker threads.
    AH_TEST_RECOMMENDED_TEST_THREADS = toString (defaultVcpus / 2);
  };

  # ---------------------------------------------------------------------------
  # Image build hints (consumed by the host-side builder in ./default.nix).
  # ---------------------------------------------------------------------------
  system.stateVersion = "25.11";

  # Tag the guest so post-boot `nixos-version` calls + the verification tests
  # can detect we're inside the AH test guest, not a generic NixOS install.
  environment.etc."ah-test-guest.version".text = ''
    image: nixos-ah-test-guest
    arch: aarch64-linux
    vcpus_default: ${toString defaultVcpus}
    memory_mib_default: ${toString defaultMemoryMiB}
    disk_mib_default: ${toString defaultDiskSizeMiB}
  '';
}
