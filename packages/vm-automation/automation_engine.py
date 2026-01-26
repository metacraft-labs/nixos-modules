#!/usr/bin/env python3
# Copyright 2026 Schelling Point Labs Inc
# SPDX-License-Identifier: AGPL-3.0-only

"""
YAML-based automation engine for GUI automation via VNC + OCR

This script implements the Lume unattended setup pattern for cross-platform
VM automation. It parses YAML configuration files and executes automation
commands via VNC, using OCR for text recognition.

Architecture: specs/Internal/Multi-OS-VM-Infrastructure-Architecture.md
Reference: vendor/vm-research/cua/libs/lume/src/Unattended/*.swift
"""

import argparse
import asyncio
import json
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml
from PIL import Image, ImageDraw

# OCR backend
import pytesseract

# VNC client
# NOTE: vncdotool is not available in nixpkgs, so we use a minimal VNC client
# For full implementation, we would need to either:
# 1. Create a custom vncdotool Nix package
# 2. Use QEMU's sendkey/mouse_move commands via QMP protocol
# 3. Implement a minimal RFB protocol client
# For now, this is a placeholder implementation
try:
    from vncdotool import api
    VNC_AVAILABLE = True
except ImportError:
    VNC_AVAILABLE = False
    print("WARNING: vncdotool not available, VNC functionality disabled")

# SSH client for health checks
import paramiko


@dataclass
class TextObservation:
    """
    Represents a piece of text found via OCR.

    Attributes:
        text: The recognized text string
        bbox: Bounding box as (x, y, width, height) in pixels (top-left origin)
        confidence: OCR confidence score (0.0 to 1.0)
        center: Center point (x, y) in pixels
    """
    text: str
    bbox: Tuple[int, int, int, int]  # (x, y, w, h)
    confidence: float

    @property
    def center(self) -> Tuple[int, int]:
        """Calculate center point of bounding box"""
        x, y, w, h = self.bbox
        return (x + w // 2, y + h // 2)


class UnattendedSetup:
    """
    Main automation engine that executes YAML-based automation configs.

    This class implements the core logic for:
    - YAML config parsing
    - VNC framebuffer capture and input injection
    - OCR text recognition with Tesseract
    - Command execution with proper timing
    - SSH health checks
    - Debug screenshot saving
    """

    def __init__(self, config_path: str, vnc_host: str, vnc_port: int,
        vm_ip: Optional[str] = None, debug: bool = False):
        """
        Initialize the automation engine.

        Args:
            config_path: Path to YAML configuration file
            vnc_host: VNC server hostname or IP
            vnc_port: VNC server port
            vm_ip: VM IP address for SSH health checks (defaults to vnc_host)
            debug: Enable debug mode (saves annotated screenshots)
        """
        self.config_path = config_path
        self.vnc_host = vnc_host
        self.vnc_port = vnc_port
        self.vm_ip = vm_ip or vnc_host
        self.debug = debug

        # Load YAML configuration
        with open(config_path, 'r') as f:
            self.config = yaml.safe_load(f)

        # VNC client (initialized lazily)
        self.vnc = None

        # Timing configuration
        self.poll_interval = 1.0  # OCR polling interval in seconds
        self.inter_command_delay = 0.2  # Delay between commands in seconds

        # Debug mode setup
        self.command_index = 0
        if self.debug:
            self.debug_dir = Path(f"/tmp/unattended-{datetime.now().strftime('%Y%m%d-%H%M%S')}")
            self.debug_dir.mkdir(parents=True, exist_ok=True)
            print(f"Debug mode enabled: screenshots will be saved to {self.debug_dir}")

    def connect_vnc(self):
        """Connect to VNC server"""
        if not VNC_AVAILABLE:
            raise RuntimeError(
                "VNC functionality not available. vncdotool is not installed.\n"
                "To enable VNC support, add vncdotool to your Python environment."
            )
        if self.vnc is None:
            print(f"Connecting to VNC server at {self.vnc_host}:{self.vnc_port}")
            self.vnc = api.connect(f'{self.vnc_host}::{self.vnc_port}')
            print("VNC connection established")

    async def run(self):
        """Execute full unattended setup"""
        try:
            # Connect to VNC
            self.connect_vnc()

            # Wait for boot
            boot_wait = self.config.get('boot_wait', 30)
            print(f"Waiting {boot_wait} seconds for VM to boot...")
            await asyncio.sleep(boot_wait)

            # Execute commands
            boot_commands = self.config.get('boot_commands', [])
            print(f"Executing {len(boot_commands)} boot commands")

            for i, cmd_str in enumerate(boot_commands):
                self.command_index = i
                print(f"[{i+1}/{len(boot_commands)}] {cmd_str}")

                cmd = self.parse_command(cmd_str)
                await self.execute_command(cmd)

                # Inter-command delay for stability
                await asyncio.sleep(self.inter_command_delay)

            print("All boot commands executed successfully")

            # Health check
            if 'health_check' in self.config:
                await self.run_health_check(self.config['health_check'])

            print("Unattended setup completed successfully!")

        except Exception as e:
            print(f"ERROR: Unattended setup failed: {e}", file=sys.stderr)
            raise
        finally:
            # Clean up VNC connection
            if self.vnc is not None:
                self.vnc.disconnect()

    def parse_command(self, cmd_str: str) -> Dict[str, Any]:
        """
        Parse a command string into a structured command dict.

        Command format: <command args>

        Examples:
            <wait 'Continue'> -> {'type': 'wait', 'text': 'Continue', 'timeout': 120}
            <click 'Agree', index=-1> -> {'type': 'click', 'text': 'Agree', 'index': -1}
            <click_at 960,540> -> {'type': 'click_at', 'x': 960, 'y': 540}
            <type 'hello'> -> {'type': 'type', 'text': 'hello'}
            <cmd+space> -> {'type': 'hotkey', 'modifiers': ['cmd'], 'key': 'space'}
            <enter> -> {'type': 'keypress', 'key': 'enter'}
            <delay 2> -> {'type': 'delay', 'duration': 2.0}

        Args:
            cmd_str: Command string in angle-bracket format

        Returns:
            Dict with command type and arguments

        Raises:
            ValueError: If command format is invalid
        """
        # Extract content from angle brackets
        match = re.match(r'<(.+?)>', cmd_str.strip())
        if not match:
            raise ValueError(f"Invalid command format: {cmd_str}")

        content = match.group(1)

        # Parse different command types

        # Wait for text: <wait 'text', timeout=120>
        if content.startswith('wait '):
            pattern = r"wait '(.+?)'(?:, timeout=(\d+))?"
            m = re.match(pattern, content)
            if not m:
                raise ValueError(f"Invalid wait command: {content}")
            text = m.group(1)
            timeout = int(m.group(2)) if m.group(2) else 120
            return {'type': 'wait', 'text': text, 'timeout': timeout}

        # Click text: <click 'text', index=-1, xoffset=10, yoffset=5>
        elif content.startswith('click '):
            pattern = r"click '(.+?)'(?:, index=(-?\d+))?(?:, xoffset=(-?\d+))?(?:, yoffset=(-?\d+))?"
            m = re.match(pattern, content)
            if not m:
                raise ValueError(f"Invalid click command: {content}")
            return {
                'type': 'click',
                'text': m.group(1),
                'index': int(m.group(2)) if m.group(2) else None,
                'xoffset': int(m.group(3)) if m.group(3) else 0,
                'yoffset': int(m.group(4)) if m.group(4) else 0
            }

        # Click at coordinates: <click_at 960,540>
        elif content.startswith('click_at '):
            coords = content.split()[1]
            x, y = map(int, coords.split(','))
            return {'type': 'click_at', 'x': x, 'y': y}

        # Type text: <type 'hello'>
        elif content.startswith('type '):
            m = re.match(r"type '(.+?)'", content)
            if not m:
                raise ValueError(f"Invalid type command: {content}")
            text = m.group(1)
            return {'type': 'type', 'text': text}

        # Delay: <delay 2>
        elif content.startswith('delay '):
            duration = float(content.split()[1])
            return {'type': 'delay', 'duration': duration}

        # Hotkey: <cmd+space>, <shift+tab>, <ctrl+alt+delete>
        elif '+' in content:
            parts = content.split('+')
            modifiers = parts[:-1]
            key = parts[-1]
            return {'type': 'hotkey', 'modifiers': modifiers, 'key': key}

        # Simple keypress: <enter>, <tab>, <esc>, <space>, etc.
        else:
            return {'type': 'keypress', 'key': content}

    async def execute_command(self, cmd: Dict[str, Any]):
        """
        Execute a single command.

        Args:
            cmd: Command dict from parse_command()
        """
        cmd_type = cmd['type']

        if cmd_type == 'wait':
            await self.wait_for_text(cmd['text'], cmd['timeout'])

        elif cmd_type == 'click':
            await self.click_on_text(
                cmd['text'],
                cmd.get('index'),
                cmd.get('xoffset', 0),
                cmd.get('yoffset', 0)
            )

        elif cmd_type == 'click_at':
            self.vnc.mouseMove(cmd['x'], cmd['y'])
            self.vnc.mousePress(1)  # Left button

        elif cmd_type == 'type':
            # Type text character by character
            self.vnc.type(cmd['text'])

        elif cmd_type == 'keypress':
            # Press a single key
            key = cmd['key']
            self.vnc.keyPress(key)

        elif cmd_type == 'hotkey':
            # Press hotkey combination (modifiers + key)
            modifiers = cmd['modifiers']
            key = cmd['key']

            # Hold down modifiers
            for mod in modifiers:
                self.vnc.keyDown(mod)

            # Press main key
            self.vnc.keyPress(key)

            # Release modifiers in reverse order
            for mod in reversed(modifiers):
                self.vnc.keyUp(mod)

        elif cmd_type == 'delay':
            await asyncio.sleep(cmd['duration'])

        else:
            raise ValueError(f"Unknown command type: {cmd_type}")

    async def wait_for_text(self, text: str, timeout: int):
        """
        Poll OCR until text appears on screen.

        Args:
            text: Text to wait for
            timeout: Timeout in seconds

        Raises:
            TimeoutError: If text not found within timeout
        """
        deadline = time.time() + timeout
        poll_count = 0

        while time.time() < deadline:
            poll_count += 1

            # Capture framebuffer
            screenshot_path = f"/tmp/fb-{os.getpid()}.png"
            self.vnc.captureScreen(screenshot_path)

            # Run OCR
            observations = self.recognize_text(screenshot_path)

            print(f"  OCR poll {poll_count}: found {len(observations)} text elements")

            # Check if text is present
            if self.find_text(text, observations):
                print(f"  Text '{text}' found!")
                return

            # Wait before next poll
            await asyncio.sleep(self.poll_interval)

        # Timeout - save debug screenshot if enabled
        if self.debug:
            observations = self.recognize_text(screenshot_path)
            self.save_debug_screenshot(
                screenshot_path, None, text, failed=True, observations=observations
            )

        raise TimeoutError(f"Text '{text}' not found after {timeout}s")

    def recognize_text(self, image_path: str) -> List[TextObservation]:
        """
        Run OCR on an image and return text observations.

        This function uses Tesseract OCR to recognize text in the image.
        Only observations with confidence >= 0.3 (30%) are returned.

        Args:
            image_path: Path to image file

        Returns:
            List of TextObservation objects, sorted top-to-bottom
        """
        image = Image.open(image_path)
        width, height = image.size

        # Run Tesseract OCR with bounding boxes
        # Output format: Dict with keys: text, conf, left, top, width, height
        data = pytesseract.image_to_data(image, output_type=pytesseract.Output.DICT)

        observations = []
        for i in range(len(data['text'])):
            # Filter by confidence threshold (0.3 = 30%)
            conf = float(data['conf'][i])
            if conf < 30:  # Tesseract uses 0-100 scale
                continue

            text = data['text'][i].strip()
            if not text:
                continue

            # Bounding box in pixels (top-left origin)
            x = data['left'][i]
            y = data['top'][i]
            w = data['width'][i]
            h = data['height'][i]

            observations.append(TextObservation(
                text=text,
                bbox=(x, y, w, h),
                confidence=conf / 100.0  # Convert to 0-1 range
            ))

        # Sort top-to-bottom (by y coordinate)
        observations.sort(key=lambda o: o.bbox[1])

        return observations

    def find_text(self, pattern: str, observations: List[TextObservation],
        index: Optional[int] = None) -> Optional[TextObservation]:
        """
        Find text in observations using multi-strategy matching.

        Matching strategy (in order):
        1. Exact match (case-insensitive)
        2. Substring match (case-insensitive)
        3. Regex match (if pattern contains regex metacharacters)

        Args:
            pattern: Text pattern to search for
            observations: List of text observations from OCR
            index: Optional index for selecting from multiple matches
            (0 = first, -1 = last, etc.)

        Returns:
            Matching TextObservation or None if not found
        """
        # Strategy 1: Exact match (case-insensitive)
        matches = [o for o in observations if o.text.lower() == pattern.lower()]

        # Strategy 2: Substring match (case-insensitive)
        if not matches:
            matches = [o for o in observations if pattern.lower() in o.text.lower()]

        # Strategy 3: Regex match (if pattern looks like regex)
        # TODO: Add regex matching if needed

        if not matches:
            return None

        # Select by index if specified
        if index is not None:
            if index >= 0:
                # Positive index: 0 = first, 1 = second, ...
                return matches[index] if index < len(matches) else None
            else:
                # Negative index: -1 = last, -2 = second to last, ...
                return matches[index] if abs(index) <= len(matches) else None

        # Return first match by default
        return matches[0]

    async def click_on_text(self, text: str, index: Optional[int],
        xoffset: int, yoffset: int):
        """
        Find text via OCR and click on it.

        Args:
            text: Text to click on
            index: Optional index for selecting from multiple matches
            xoffset: Horizontal offset from text center (pixels)
            yoffset: Vertical offset from text center (pixels)

        Raises:
            ValueError: If text not found
        """
        # Capture framebuffer
        screenshot_path = f"/tmp/fb-{os.getpid()}.png"
        self.vnc.captureScreen(screenshot_path)

        # Run OCR
        observations = self.recognize_text(screenshot_path)

        # Find text
        observation = self.find_text(text, observations, index)
        if not observation:
            # Save debug screenshot if enabled
            if self.debug:
                self.save_debug_screenshot(
                    screenshot_path, None, text, failed=True, observations=observations
                )
            raise ValueError(f"Text '{text}' not found on screen")

        # Calculate click point
        cx, cy = observation.center
        click_x = cx + xoffset
        click_y = cy + yoffset

        print(f"  Clicking '{text}' at ({click_x}, {click_y})")

        # Save debug screenshot before clicking
        if self.debug:
            self.save_debug_screenshot(
                screenshot_path, (click_x, click_y), text, failed=False,
                observations=observations
            )

        # Perform click
        self.vnc.mouseMove(click_x, click_y)
        self.vnc.mousePress(1)  # Left button

    def save_debug_screenshot(self, image_path: str, click_point: Optional[Tuple[int, int]],
        search_text: str, failed: bool,
        observations: List[TextObservation]):
        """
        Save annotated screenshot with OCR results for debugging.

        This saves two files:
        1. PNG with red crosshair marking the click point
        2. JSON with full OCR tree and metadata

        Args:
            image_path: Path to source image
            click_point: (x, y) coordinates of click point (None if failed)
            search_text: The text that was being searched for
            failed: Whether the operation failed
            observations: List of all OCR observations
        """
        # Load image
        image = Image.open(image_path).convert('RGB')
        draw = ImageDraw.Draw(image)

        # Draw red crosshair at click point
        if click_point:
            cx, cy = click_point
            size = 20
            # Horizontal line
            draw.line([(cx - size, cy), (cx + size, cy)], fill='red', width=3)
            # Vertical line
            draw.line([(cx, cy - size), (cx, cy + size)], fill='red', width=3)
            # Circle
            draw.ellipse(
                [(cx - size, cy - size), (cx + size, cy + size)],
                outline='red', width=2
            )

        # Save annotated PNG
        status = 'FAILED' if failed else 'click'
        # Sanitize text for filename (remove special chars, limit length)
        safe_text = re.sub(r'[^a-zA-Z0-9_-]', '_', search_text)[:30]
        filename = f"{self.command_index:03d}-{status}-{safe_text}.png"
        image_out_path = self.debug_dir / filename
        image.save(image_out_path)

        # Save OCR JSON
        ocr_data = {
            'timestamp': datetime.now().isoformat(),
            'commandIndex': self.command_index,
            'searchText': search_text,
            'failed': failed,
            'clickPoint': {'x': click_point[0], 'y': click_point[1]} if click_point else None,
            'observations': [
                {
                    'text': o.text,
                    'confidence': o.confidence,
                    'bbox': {
                        'x': o.bbox[0],
                        'y': o.bbox[1],
                        'w': o.bbox[2],
                        'h': o.bbox[3]
                    },
                    'center': {'x': o.center[0], 'y': o.center[1]},
                    'matchesSearch': search_text.lower() in o.text.lower()
                }
                for o in observations
            ]
        }

        json_out_path = self.debug_dir / f"{filename[:-4]}-ocr.json"
        with open(json_out_path, 'w') as f:
            json.dump(ocr_data, f, indent=2)

        print(f"  Debug: saved {image_out_path}")

    async def run_health_check(self, config: Dict[str, Any]):
        """
        Run SSH health check with retries.

        Args:
            config: Health check configuration dict with keys:
                - type: "ssh" (only type currently supported)
                - user: SSH username
                - password: SSH password
                - timeout: Connection timeout in seconds (default: 30)
                - retries: Number of retry attempts (default: 3)
                - retry_delay: Delay between retries in seconds (default: 5)

        Raises:
            RuntimeError: If health check fails after all retries
        """
        if config['type'] != 'ssh':
            raise ValueError(f"Unknown health check type: {config['type']}")

        timeout = config.get('timeout', 30)
        retries = config.get('retries', 3)
        retry_delay = config.get('retry_delay', 5)

        print(f"Running SSH health check (retries={retries}, timeout={timeout}s)")

        for attempt in range(1, retries + 1):
            print(f"  Health check attempt {attempt}/{retries}")

            try:
                # Try SSH connection
                ssh = paramiko.SSHClient()
                ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
                ssh.connect(
                    hostname=self.vm_ip,
                    username=config['user'],
                    password=config['password'],
                    timeout=timeout
                )

                # Run test command
                stdin, stdout, stderr = ssh.exec_command("echo 'SSH OK'")
                exit_status = stdout.channel.recv_exit_status()

                if exit_status == 0:
                    print("  Health check PASSED: SSH connection successful")
                    ssh.close()
                    return

                ssh.close()

            except Exception as e:
                print(f"  SSH attempt failed: {e}")

            # Wait before retry (unless this was the last attempt)
            if attempt < retries:
                await asyncio.sleep(retry_delay)

        raise RuntimeError(f"Health check FAILED after {retries} attempts")


def main():
    """Main entry point"""
    parser = argparse.ArgumentParser(
        description='YAML-based automation engine for GUI automation via VNC + OCR'
    )
    parser.add_argument(
        '--config',
        required=True,
        help='Path to YAML configuration file'
    )
    parser.add_argument(
        '--vnc-host',
        default='127.0.0.1',
        help='VNC server hostname or IP (default: 127.0.0.1)'
    )
    parser.add_argument(
        '--vnc-port',
        type=int,
        default=5900,
        help='VNC server port (default: 5900)'
    )
    parser.add_argument(
        '--vm-ip',
        help='VM IP address for SSH health checks (default: same as vnc-host)'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug mode (save annotated screenshots)'
    )

    args = parser.parse_args()

    # Create automation engine
    setup = UnattendedSetup(
        config_path=args.config,
        vnc_host=args.vnc_host,
        vnc_port=args.vnc_port,
        vm_ip=args.vm_ip,
        debug=args.debug
    )

    # Run automation
    try:
        asyncio.run(setup.run())
        sys.exit(0)
    except Exception as e:
        print(f"FATAL: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
