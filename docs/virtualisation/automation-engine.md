# Automation Engine

A YAML-based GUI automation framework for unattended OS installation. Uses VNC screen capture with OCR (Optical Character Recognition) to interact with graphical installers.

## Overview

The automation engine enables fully automated OS installation by:

1. Connecting to a VM's VNC display
2. Capturing screenshots and recognizing text with OCR
3. Simulating keyboard and mouse input based on YAML scripts
4. Verifying installation success via SSH health check

This is used internally by the [VM Images](./vm-images.md) module for macOS and Windows installation automation.

## Quick Start

### Running the Automation Engine

```bash
# Build the automation runner
nix build .#yaml-automation-runner

# Run automation against a VM
./result/bin/yaml-automation-runner \
  --config configs/macos-sequoia.yml \
  --vnc-host 127.0.0.1 \
  --vnc-port 5900 \
  --debug
```

### Basic Configuration

```yaml
# my-automation.yml
boot_wait: 30 # Seconds to wait after VM boots

boot_commands:
  # Wait for text to appear
  - wait:
      text: 'Welcome'
      timeout: 120

  # Click on text
  - click: 'Continue'

  # Type text
  - type: 'username'

  # Press Enter
  - key: enter

  # Wait before next step
  - delay: 2

# Verify installation succeeded
health_check:
  type: ssh
  user: myuser
  password: mypassword
  timeout: 30
  retries: 5
  retry_delay: 10
```

## Command Reference

### Wait Commands

Wait for text to appear on screen before proceeding.

```yaml
# Basic wait (120 second timeout)
- wait:
    text: 'Welcome to Setup'

# Custom timeout
- wait:
    text: 'Installing...'
    timeout: 300 # 5 minutes
```

**Parameters:**

- `text` (required): Text to search for (case-sensitive)
- `timeout` (optional): Maximum wait time in seconds (default: 120)

### Click Commands

Click on text found via OCR.

```yaml
# Click first occurrence of text
- click: 'Continue'

# Click with options
- click:
    text: 'Agree'
    index: -1 # Click last occurrence
    xoffset: 50 # Offset from text center
    yoffset: 0
```

**Parameters:**

- `text` (required): Text to click on
- `index` (optional): Which occurrence to click (0 = first, -1 = last)
- `xoffset` (optional): Horizontal offset from text center in pixels
- `yoffset` (optional): Vertical offset from text center in pixels

### Click at Coordinates

Click at exact screen coordinates (fallback when OCR fails).

```yaml
# Click center of 1920x1080 screen
- click_at:
    x: 960
    y: 540
```

### Type Commands

Type text character by character.

```yaml
- type: 'Hello, World!'
- type: 'my-password-123'
```

### Key Commands

Press individual keys.

```yaml
- key: enter
- key: tab
- key: space
- key: backspace
- key: esc
- key: up
- key: down
- key: left
- key: right
- key: f1
- key: f12
```

### Hotkey Commands

Press key combinations.

```yaml
# macOS Spotlight
- hotkey:
    modifiers: [cmd]
    key: space

# macOS Quit
- hotkey:
    modifiers: [cmd]
    key: q

# Windows Security
- hotkey:
    modifiers: [ctrl, alt]
    key: delete

# Multiple modifiers
- hotkey:
    modifiers: [cmd, shift]
    key: enter
```

**Available modifiers:** `cmd`, `ctrl`, `alt`, `shift`

### Delay Commands

Wait a fixed amount of time.

```yaml
# Wait 2 seconds
- delay: 2

# Wait 500 milliseconds
- delay: 0.5
```

## Health Check

Verify installation completed successfully via SSH.

```yaml
health_check:
  type: ssh
  user: testuser
  password: testpassword
  timeout: 30 # Per-attempt timeout in seconds
  retries: 5 # Number of connection attempts
  retry_delay: 10 # Seconds between attempts
```

The health check:

1. Waits for SSH to become available
2. Connects with provided credentials
3. Runs basic commands to verify the system is responsive
4. Reports success or failure

## Debugging

### Enable Debug Mode

```bash
./result/bin/yaml-automation-runner \
  --config config.yml \
  --vnc-host 127.0.0.1 \
  --vnc-port 5900 \
  --debug
```

### Debug Output

Debug mode saves to `/tmp/unattended-<timestamp>/`:

| File                           | Description                   |
| ------------------------------ | ----------------------------- |
| `screenshot-001.png`           | Raw screenshot                |
| `screenshot-001-annotated.png` | Screenshot with click markers |
| `screenshot-001-ocr.json`      | Full OCR results              |
| `automation.log`               | Command execution log         |

### Annotated Screenshots

In debug mode, screenshots are annotated with:

- **Red crosshairs**: Where clicks occurred
- **Bounding boxes**: Detected text regions
- **Labels**: Recognized text

### OCR JSON Format

```json
{
  "texts": [
    {
      "text": "Continue",
      "confidence": 0.98,
      "bbox": {
        "x": 850,
        "y": 600,
        "width": 120,
        "height": 30
      }
    }
  ]
}
```

## Example Configurations

### macOS Setup Assistant

```yaml
# macos-sequoia.yml
boot_wait: 30

boot_commands:
  # Language selection
  - wait:
      text: 'English'
      timeout: 120
  - type: 'English'
  - key: enter
  - delay: 2

  # Country selection
  - wait:
      text: 'Country or Region'
  - type: 'United States'
  - key: enter
  - click: 'Continue'
  - delay: 2

  # Create account
  - wait:
      text: 'Create a Computer Account'
  - click: 'Full Name'
  - type: 'agent'
  - key: tab
  - type: 'agent' # Account name
  - key: tab
  - type: 'agent' # Password
  - key: tab
  - type: 'agent' # Verify password
  - click: 'Continue'
  - delay: 5

  # Skip optional setup screens
  - wait:
      text: 'Express Set Up'
  - click: 'Customize Settings'
  - delay: 2

  # Enable SSH via Terminal
  - wait:
      text: 'Desktop'
      timeout: 300
  - hotkey:
      modifiers: [cmd]
      key: space
  - type: 'Terminal'
  - key: enter
  - delay: 3
  - type: 'sudo systemsetup -setremotelogin on'
  - key: enter
  - type: 'agent' # Password for sudo
  - key: enter
  - delay: 2

health_check:
  type: ssh
  user: agent
  password: agent
  timeout: 30
  retries: 10
  retry_delay: 30
```

### Windows 11 OOBE

```yaml
# windows-11.yml
boot_wait: 60

boot_commands:
  # Region selection
  - wait:
      text: 'country or region'
      timeout: 300
  - click: 'United States'
  - click: 'Yes'
  - delay: 3

  # Keyboard layout
  - wait:
      text: 'keyboard layout'
  - click: 'US'
  - click: 'Yes'
  - delay: 2

  # Skip second keyboard
  - wait:
      text: 'second keyboard'
  - click: 'Skip'
  - delay: 2

  # Network - skip for now
  - wait:
      text: 'connect to a network'
      timeout: 60
  # Use Shift+F10 to open command prompt and bypass
  - hotkey:
      modifiers: [shift]
      key: f10
  - delay: 2
  - type: 'OOBE\BYPASSNRO'
  - key: enter
  - delay: 30  # VM will reboot

  # After reboot, continue with local account
  - wait:
      text: 'connect to a network'
      timeout: 300
  - click: "I don't have internet"
  - delay: 2
  - click: 'Continue with limited setup'
  - delay: 2

  # Create local account
  - wait:
      text: 'Who's going to use this device'
  - type: 'agent'
  - click: 'Next'
  - delay: 2

  # Password
  - wait:
      text: 'Create a super memorable password'
  - type: 'agent'
  - click: 'Next'
  - delay: 2

  # Confirm password
  - wait:
      text: 'Confirm your password'
  - type: 'agent'
  - click: 'Next'
  - delay: 2

  # Security questions (skip with empty answers)
  - wait:
      text: 'security questions'
  # ... handle security questions

  # Privacy settings - decline all
  - wait:
      text: 'Choose privacy settings'
      timeout: 120
  - click: 'Next'
  - delay: 2
  - click: 'Next'
  - delay: 2
  - click: 'Accept'
  - delay: 30

  # Wait for desktop
  - wait:
      text: 'Recycle Bin'
      timeout: 300

  # Enable OpenSSH Server
  - hotkey:
      modifiers: [win]
      key: r
  - delay: 1
  - type: 'powershell -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"'
  - key: enter
  - delay: 30

health_check:
  type: ssh
  user: agent
  password: agent
  timeout: 60
  retries: 10
  retry_delay: 30
```

## Tips and Best Practices

### Handling Duplicate Text

When text appears multiple times (e.g., "Agree" in license AND button):

```yaml
# Click the last "Agree" (usually the button)
- click:
    text: 'Agree'
    index: -1

# Or click the first one
- click:
    text: 'Agree'
    index: 0
```

### Coordinate Fallback

When OCR fails to recognize text reliably:

```yaml
# First try OCR
- wait:
    text: 'Continue'
    timeout: 10

# If that fails, use known coordinates
- click_at:
    x: 960
    y: 900
```

### Timing Adjustments

Add delays after actions that trigger UI changes:

```yaml
- click: 'Install'
- delay: 5 # Wait for installation dialog

- wait:
    text: 'Progress'
    timeout: 600 # 10 minutes for long installs
```

### Robust Text Matching

OCR may not perfectly match text. Try:

1. **Partial text**: Use shorter, unique substrings
2. **Coordinates**: Fall back to known positions
3. **Multiple attempts**: Retry with delays

### Screen Resolution

The automation engine works best with consistent screen resolutions. Configure your VM with a fixed resolution (e.g., 1920x1080) for reliable coordinate-based clicks.

## Troubleshooting

### OCR not finding text

1. Enable debug mode and check screenshots
2. Verify text is actually visible on screen
3. Check if text is partially obscured
4. Try waiting longer for animations to complete
5. Use coordinate-based clicks as fallback

### Clicks not registering

1. Check VNC connection is stable
2. Add delays after clicks for UI to respond
3. Verify click coordinates in debug screenshots
4. Some buttons may need double-click

### Health check fails

1. Verify SSH is installed and enabled in guest
2. Check username/password are correct
3. Increase `retries` and `retry_delay`
4. Check guest firewall settings
5. Verify port forwarding to guest

### VNC connection refused

1. Verify VM is running
2. Check VNC port configuration
3. Ensure no firewall blocking VNC
4. Try connecting manually with a VNC client first

## See Also

- [Virtualisation Overview](./index.md) - Overview of all VM modules
- [Desktop VMs](./desktop-vms.md) - NixOS module for local desktop VMs
- [VM Images](./vm-images.md) - Building VM images for CI/CD

## References

- [EasyOCR](https://github.com/JaidedAI/EasyOCR) - The OCR engine used
- [python-vnc-client](https://pypi.org/project/vncdotool/) - VNC client library
- [Lume Unattended Setup](https://cua.ai/docs/lume/guide/fundamentals/unattended-setup) - Original pattern inspiration
