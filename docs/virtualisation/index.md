# Virtualisation Modules

This documentation covers the VM infrastructure provided by nixos-modules, enabling you to create, manage, and automate virtual machines for various use cases.

## Overview

The virtualisation modules are organized into three main components:

| Module                                      | Purpose                     | Use Case                                  |
| ------------------------------------------- | --------------------------- | ----------------------------------------- |
| [Desktop VMs](./desktop-vms.md)             | High-performance local VMs  | Development, gaming, daily use            |
| [VM Images](./vm-images.md)                 | Automated VM image building | CI/CD, testing, reproducible environments |
| [Automation Engine](./automation-engine.md) | GUI automation via VNC+OCR  | Unattended OS installation                |

## Choosing the Right Module

### Desktop VMs (`virtualisation.desktopVMs`)

**Use when:** You need to run VMs on your local machine for daily work.

- NixOS module for declarative VM configuration
- Optimized for performance (CPU pinning, hugepages)
- Supports Windows, Linux, and macOS guests
- SPICE/VNC display with clipboard and USB sharing
- VirtIO-FS for fast file sharing

```nix
# Example: Desktop VM configuration
virtualisation.desktopVMs = {
  enable = true;
  profile = "always-on";
  vms.windows-dev = {
    enable = true;
    memory = "16G";
    vcpus = 8;
    osType = "windows";
  };
};
```

[Read the Desktop VMs documentation →](./desktop-vms.md)

### VM Images (`import nixos-modules/vm-images`)

**Use when:** You need to build VM images programmatically for CI/CD or testing.

- Nix functions for building VM images
- Supports Ubuntu (cloud-init), macOS, and Windows
- Automated unattended installation
- Reproducible builds via Nix

```nix
# Example: Build a Windows VM image
let
  vmImages = import (nixos-modules + /vm-images) { inherit pkgs; };
in
vmImages.windows.makeWindowsVM {
  name = "ci-windows";
  windowsIso = ./Win11.iso;
  virtioDriversIso = vmImages.fetchVirtIODrivers { sha256 = "..."; };
  username = "agent";
  password = "agent";
};
```

[Read the VM Images documentation →](./vm-images.md)

### Automation Engine (`yaml-automation-runner`)

**Use when:** You need to automate GUI interactions during OS installation.

- YAML-based automation scripts
- VNC screen capture with OCR text recognition
- Keyboard and mouse simulation
- Debug mode with annotated screenshots

```yaml
# Example: macOS setup automation
boot_commands:
  - wait:
      text: 'Welcome'
      timeout: 120
  - click: 'Continue'
  - type: 'username'
```

[Read the Automation Engine documentation →](./automation-engine.md)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     nixos-modules                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │   Desktop VMs    │  │    VM Images     │  │   Automation   │ │
│  │   NixOS Module   │  │   Nix Library    │  │     Engine     │ │
│  ├──────────────────┤  ├──────────────────┤  ├────────────────┤ │
│  │ - libvirt/QEMU   │  │ - Linux builder  │  │ - VNC client   │ │
│  │ - CPU pinning    │  │ - macOS builder  │  │ - OCR (easyocr)│ │
│  │ - Hugepages      │  │ - Windows builder│  │ - YAML parser  │ │
│  │ - Memory balloon │  │ - ISO fetchers   │  │ - Key/mouse    │ │
│  │ - VirtIO-FS      │  │                  │  │   simulation   │ │
│  └────────┬─────────┘  └────────┬─────────┘  └───────┬────────┘ │
│           │                     │                    │          │
│           │                     └────────────────────┘          │
│           │                              │                      │
│           │                    Uses for unattended install      │
│           v                              v                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                      libvirt/QEMU                         │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Links

- [Desktop VMs - Quick Start](./desktop-vms.md#quick-start)
- [Desktop VMs - Profiles](./desktop-vms.md#profiles)
- [VM Images - Building Windows VMs](./vm-images.md#windows-vms)
- [VM Images - Building macOS VMs](./vm-images.md#macos-vms)
- [VM Images - Building Linux VMs](./vm-images.md#linux-vms)
- [Automation Engine - Command Reference](./automation-engine.md#command-reference)
- [Automation Engine - Debugging](./automation-engine.md#debugging)

## Related Resources

- [Libvirt Documentation](https://libvirt.org/docs.html)
- [QEMU Documentation](https://www.qemu.org/docs/master/)
- [VirtIO-FS](https://virtio-fs.gitlab.io/)
- [OSX-KVM Project](https://github.com/kholia/OSX-KVM)
- [Windows VirtIO Drivers](https://github.com/virtio-win/virtio-win-pkg-scripts)
