# YAML Automation Configs

This directory contains YAML configuration files for automating OS installation in VMs.
These configs use VNC + OCR to interact with the GUI during unattended setup.

## Available Configs

### macOS

- **macos-ventura.yml** - macOS Ventura (13.x) Setup Assistant automation
- **macos-sonoma.yml** - macOS Sonoma (14.x) Setup Assistant automation
- **macos-sequoia.yml** - macOS Sequoia (15.x) Setup Assistant automation
- **macos-tahoe.yml** - macOS Tahoe (16.x) Setup Assistant automation

### Windows

- **windows-11.yml** - Windows 11 OOBE (Out-of-Box Experience) automation

## Format

The YAML format uses native structures for type safety, validation, and IDE support.
See [YAML-AUTOMATION-SCHEMA.md](YAML-AUTOMATION-SCHEMA.md) for the complete schema.

```yaml
boot_wait: 30 # Seconds to wait after VM boots

boot_commands:
  # Wait for text to appear via OCR
  - wait:
      text: 'Continue'
      timeout: 300

  # Click on text
  - click: 'Continue'

  # Click last occurrence (for duplicates)
  - click:
      text: 'Agree'
      index: -1

  # Click exact coordinates
  - click_at:
      x: 960
      y: 540

  # Type text
  - type: 'hello world'

  # Press keys
  - key: enter
  - key: tab

  # Hotkey combination
  - hotkey:
      modifiers: [cmd]
      key: space

  # Wait N seconds
  - delay: 2

health_check:
  type: ssh
  host: 127.0.0.1
  port: 22
  user: admin
  password: admin
  timeout: 30
  retries: 10
  retry_delay: 15
  command: 'sw_vers'
```

## Usage

### From Nix

```nix
# In your flake.nix
let
  vmImages = import (nixos-modules + /vm-images) { inherit pkgs; };
in {
  packages.macos-vm = vmImages.darwin.makeDarwinVM {
    name = "my-macos-vm";
    baseSystemImg = vmImages.fetchMacOSBaseSystem { release = "sonoma"; sha256 = "..."; };
    installAssistantIso = vmImages.fetchMacOSInstallAssistant { majorVersion = 14; sha256 = "..."; };
    # Reference config from this directory
    automationConfig = nixos-modules + /packages/vm-automation/configs/macos-sonoma.yml;
  };
}
```

### Standalone

```bash
# Build the automation runner
nix build .#yaml-automation-runner

# Run automation
./result/bin/yaml-automation-runner \
  --config configs/macos-sequoia.yml \
  --vnc-host 127.0.0.1 \
  --vnc-port 5900 \
  --debug
```

## Debug Mode

When `--debug` is enabled, the engine saves:

- **Annotated screenshots** with red crosshairs marking click points
- **OCR JSON dumps** with full text recognition results

Debug files are saved to `/tmp/unattended-<timestamp>/`

## Quick Reference

### Wait Commands

```yaml
- wait:
    text: 'Continue'
    timeout: 300 # optional, default: 120
```

### Click Commands

```yaml
# Simple click (first occurrence)
- click: 'Continue'

# Click with options
- click:
    text: 'Agree'
    index: -1 # -1 = last, 0 = first
    offset:
      x: 50 # pixels right (+) or left (-)
      y: 0

# Coordinate click
- click_at:
    x: 960
    y: 540
```

### Typing

```yaml
- type: 'hello world'
```

### Keys

```yaml
- key: enter
- key: tab
- key: space
- key: backspace
- key: escape
- key: up    # arrow keys
- key: f1    # function keys
```

### Hotkeys

```yaml
- hotkey:
    modifiers: [cmd, shift]
    key: t
```

### Timing

```yaml
- delay: 2   # seconds (can be float: 0.5)
```

## Tips

### Handling Duplicate Text

When text appears multiple times (e.g., "Agree" in license AND button):

```yaml
# Click last "Agree" (usually the button)
- click:
    text: 'Agree'
    index: -1
```

### Coordinate Fallback

If OCR fails to recognize text:

```yaml
- click_at:
    x: 960
    y: 540
```

### Account Credentials

All macOS configs create:
- Username: `admin`
- Password: `admin`

### Port Forwarding

The `health_check.port` in configs is the guest port (22 for SSH).
Configure actual port forwarding in your VM builder:

```nix
vmImages.darwin.makeDarwinVM {
  sshPort = 2225;  # Host port -> guest port 22
  ...
}
```
