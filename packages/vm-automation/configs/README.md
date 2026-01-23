# YAML Automation Configs

This directory contains example YAML configuration files for the automation engine.

## Format

The YAML format follows the [Lume unattended setup pattern](https://cua.ai/docs/lume/guide/fundamentals/unattended-setup):

```yaml
boot_wait: 30 # Seconds to wait after VM boots

boot_commands:
  - "<wait 'text'>" # Wait for text to appear via OCR
  - "<click 'text'>" # Click on text
  - "<click 'text', index=-1>" # Click last occurrence (for duplicates)
  - '<click_at 960,540>' # Click exact coordinates
  - "<type 'hello'>" # Type text
  - '<enter>' # Press key
  - '<cmd+space>' # Hotkey combination
  - '<delay 2>' # Wait N seconds

health_check:
  type: ssh
  user: username
  password: password
  timeout: 30
  retries: 5
  retry_delay: 10
```

## Available Configs

- **macos-sequoia.yml** - Simplified macOS Sequoia Setup Assistant automation
- **windows-11.yml** - Windows 11 OOBE (Out-of-Box Experience) automation

For complete examples, see:

- `vendor/vm-research/cua/libs/lume/resources/unattended-sequoia.yml` (full macOS automation)
- `vendor/vm-research/cua/libs/lume/resources/unattended-tahoe.yml` (macOS 15)

## Usage

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

## Command Reference

### Wait Commands

- `<wait 'text'>` - Wait for text to appear (default timeout: 120s)
- `<wait 'text', timeout=300>` - Wait with custom timeout

### Click Commands

- `<click 'text'>` - Click first occurrence of text
- `<click 'text', index=0>` - Click first occurrence (explicit)
- `<click 'text', index=-1>` - Click last occurrence (useful for duplicate text)
- `<click 'text', xoffset=50>` - Click 50px to the right of text center
- `<click 'text', yoffset=-20>` - Click 20px above text center
- `<click_at 960,540>` - Click exact screen coordinates

### Typing Commands

- `<type 'hello world'>` - Type text character by character

### Key Commands

- `<enter>` - Press Enter
- `<tab>` - Press Tab
- `<space>` - Press Space
- `<backspace>` - Press Backspace
- `<esc>` - Press Escape
- `<up>`, `<down>`, `<left>`, `<right>` - Arrow keys
- `<f1>` through `<f12>` - Function keys

### Hotkey Commands

- `<cmd+space>` - macOS Spotlight (Command + Space)
- `<cmd+q>` - macOS Quit (Command + Q)
- `<ctrl+alt+delete>` - Windows Security (Ctrl + Alt + Delete)
- `<shift+tab>` - Shift + Tab
- `<cmd+shift+enter>` - Multiple modifiers

### Timing Commands

- `<delay 2>` - Wait 2 seconds
- `<delay 0.5>` - Wait 500 milliseconds

## Tips

### Handling Duplicate Text

When text appears multiple times (e.g., "Agree" in license text AND button), use `index`:

```yaml
# Click last "Agree" (usually the button)
- "<click 'Agree', index=-1>"

# Click first "Agree" (if it's on top)
- "<click 'Agree', index=0>"
```

### Coordinate Fallback

If OCR fails to recognize text, use coordinates:

```yaml
# Fallback to clicking center of screen
- '<click_at 960,540>'
```

### Timing Adjustments

- Add `<delay N>` after clicks to wait for UI updates
- Increase `timeout` for slow-loading screens:
  ```yaml
  - "<wait 'Loading...', timeout=300>"
  ```

### SSH Health Check

Always include an SSH health check to verify setup completed:

```yaml
health_check:
  type: ssh
  user: testuser
  password: testpass
  timeout: 30 # Per-attempt timeout
  retries: 5 # Number of attempts
  retry_delay: 10 # Seconds between attempts
```
