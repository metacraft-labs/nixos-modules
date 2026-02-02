# YAML Automation Schema

This document defines the YAML schema for VM automation configs.

## Overview

Uses native YAML structures for type safety, validation, IDE support, and maintainability.

## Top-Level Structure

```yaml
# Seconds to wait after VM boots before starting automation
boot_wait: 60

# Maximum time for entire installation (optional)
max_install_time: 3600

# List of automation commands (executed sequentially)
boot_commands:
  - <command>
  - <command>
  ...

# SSH health check to verify setup completed
health_check:
  type: ssh
  host: 127.0.0.1
  port: 22
  user: admin
  password: admin
  timeout: 30
  retries: 10
  retry_delay: 15
  command: "sw_vers"  # Command to run for health check
```

## Command Types

### 1. Wait for Text (OCR-based)

Wait for text to appear on screen using OCR.

```yaml
- wait:
    text: 'Continue'
    timeout: 300 # seconds (default: 120)
```

### 2. Delay

Fixed time delay in seconds.

```yaml
- delay: 5 # seconds (can be float: 2.5)
```

### 3. Type Text

Type a string (sent as keyboard events).

```yaml
- type: 'hello world'
```

### 4. Click on Text

Click on text found via OCR.

```yaml
# Simple click (first occurrence)
- click: 'Continue'

# Click with parameters
- click:
    text: 'Agree'
    index: -1 # -1 = last occurrence, 0 = first, 1 = second, etc.
    offset: # optional offset from text center
      x: 50 # pixels right (+) or left (-)
      y: 0 # pixels down (+) or up (-)
```

### 5. Click at Coordinates

Click at absolute screen coordinates.

```yaml
- click_at:
    x: 815
    y: 480
```

### 6. Special Keys

Press special keys (enter, tab, space, escape, arrows, function keys).

```yaml
# Simple form (just key name)
- key: enter
- key: tab
- key: space
- key: escape
- key: backspace

# Arrow keys
- key: up
- key: down
- key: left
- key: right

# Function keys
- key: f1
- key: f2
# ... through f12
```

### 7. Hotkeys (Key Combinations)

Press key combinations with modifiers.

```yaml
- hotkey:
    modifiers: [cmd, shift] # or [ctrl, alt], etc.
    key: t

# Common examples:
- hotkey:
    modifiers: [cmd]
    key: space # Spotlight on macOS

- hotkey:
    modifiers: [shift]
    key: tab
```

**Modifier names:**

- `shift` - Shift key
- `ctrl` - Control key
- `alt` - Alt key (Option on macOS)
- `cmd` / `meta` / `super` - Command key (macOS) / Windows key (Linux/Windows)

### 8. Mouse Movement

Move mouse to coordinates (without clicking).

```yaml
- move_mouse:
    x: 960
    y: 540
```

## Complete Example

```yaml
boot_wait: 60

boot_commands:
  # Wait for installer
  - wait:
      text: 'Continue'
      timeout: 300

  - delay: 5

  # Open terminal with hotkey
  - hotkey:
      modifiers: [shift, cmd]
      key: t

  - delay: 3

  # Wait for terminal
  - wait:
      text: 'Terminal'
      timeout: 30

  # Type command
  - type: 'echo hello'
  - key: enter

  # Navigate with keyboard
  - key: tab
  - delay: 1
  - key: space

  # Click on button
  - click: 'Agree'

  # Click with offset (50 pixels right of text)
  - click:
      text: 'Label'
      offset:
        x: 50
        y: 0

  # Click at absolute coordinates
  - click_at:
      x: 815
      y: 480

health_check:
  type: ssh
  host: 127.0.0.1
  port: 22
  user: admin
  password: admin
  timeout: 30
  retries: 10
  retry_delay: 15
  command: 'uname -a'
```

## Schema Validation

The automation runner should validate:

1. **boot_wait** is a positive number
2. Each command has required fields for its type
3. **timeout** values are positive integers
4. **coordinates** (x, y) are non-negative integers
5. **modifiers** are from the allowed list
6. **keys** are from the allowed list (enter, tab, space, a-z, 0-9, f1-f12, arrows, etc.)

## Parser Implementation Notes

For the yaml-automation-runner Python implementation:

```python
def parse_command(cmd):
    """Parse a command from YAML dict."""

    if not isinstance(cmd, dict):
        raise ValueError(f"Invalid command type: {type(cmd)}. Expected dict.")

    return _parse_native_command(cmd)

def _parse_native_command(cmd):
    """Parse YAML command dict into normalized command format."""

    # Single-key commands: {key: value}
    if len(cmd) == 1:
        cmd_type, params = next(iter(cmd.items()))

        # Simple value commands
        if cmd_type == "delay":
            return Delay(duration=params)
        if cmd_type == "type":
            return TypeText(text=params)
        if cmd_type == "key":
            return KeyPress(key=params)
        if cmd_type == "click" and isinstance(params, str):
            return ClickText(text=params)

        # Structured commands
        if cmd_type == "wait":
            return WaitForText(**params)
        if cmd_type == "click":
            return ClickText(**params)
        if cmd_type == "click_at":
            return ClickAt(**params)
        if cmd_type == "hotkey":
            return Hotkey(**params)
        if cmd_type == "move_mouse":
            return MoveMouse(**params)

    raise ValueError(f"Unknown command type: {cmd}")
```
