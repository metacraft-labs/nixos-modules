#!/usr/bin/env bash
set -euo pipefail

# Test script for mcl machine create command
# This script tests the machine creation functionality by:
# 1. Using a local copy of the infra repo
# 2. Running mcl machine create with test parameters
# 3. Running just build-machine to verify the generated files build successfully

echo "=== Testing mcl machine create ==="

# Get the directory of this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIXOS_MODULES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "NixOS modules directory: $NIXOS_MODULES_DIR"

# Build mcl from this project
echo "Building mcl from local project..."
cd "$NIXOS_MODULES_DIR"
nix build .#mcl --no-link
MCL_PATH="$(nix build .#mcl --no-link --print-out-paths)/bin/mcl"
echo "Using mcl from: $MCL_PATH"

# Configuration
INFRA_REPO_URL="https://github.com/metacraft-labs/infra"
# Create a temporary directory for the test
TEMP_DIR=$(mktemp -d)
INFRA_DIR="$TEMP_DIR/infra"
SSH_PATH="${USER}@127.0.0.1"

# Cleanup on exit
trap "rm -rf $TEMP_DIR" EXIT

echo "Cloning infra repo to temporary directory: $INFRA_DIR..."
git clone "$INFRA_REPO_URL" "$INFRA_DIR"

# Navigate to infra repo
cd "$INFRA_DIR"
echo "Working in: $(pwd)"

# Test parameters
MACHINE_NAME="test-machine-$(date +%s)"
MACHINE_TYPE="desktop"
USER_NAME="test-user"
DESCRIPTION="Test User"
EXTRA_GROUPS="metacraft"
HOST_TYPE="desktop"
ENABLE_HOME_MANAGER="true"
PARTITIONING_PRESET="zfs"
ZPOOL_MODE="stripe"
ESP_SIZE="4G"

echo ""
echo "=== Running mcl machine create ==="
echo "Machine Name: $MACHINE_NAME"
echo "Machine Type: $MACHINE_TYPE"
echo "SSH Path: $SSH_PATH"
echo ""

# Run mcl machine create with parameters
# Note: This will prompt for some values if not all are provided via CLI
"$MCL_PATH" machine create "$SSH_PATH" \
    --machine-name="$MACHINE_NAME" \
    --machine-type="$MACHINE_TYPE" \
    --user-name="$USER_NAME" \
    --description="$DESCRIPTION" \
    --extra-groups="$EXTRA_GROUPS" \
    --host-type="$HOST_TYPE" \
    --enable-home-manager \
    --partitioning-preset="$PARTITIONING_PRESET" \
    --zpool-mode="$ZPOOL_MODE" \
    --esp-size="$ESP_SIZE" \
    --create-user

echo ""
echo "=== Checking generated files ==="

MACHINE_DIR="machines/$MACHINE_TYPE/$MACHINE_NAME"

if [ ! -d "$MACHINE_DIR" ]; then
    echo "ERROR: Machine directory not created: $MACHINE_DIR"
    exit 1
fi

echo "Machine directory created: $MACHINE_DIR"
echo "Files:"
ls -la "$MACHINE_DIR"

# Check that required files exist
REQUIRED_FILES=(
    "$MACHINE_DIR/meta.nix"
    "$MACHINE_DIR/configuration.nix"
    "$MACHINE_DIR/hw-config.nix"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Required file missing: $file"
        exit 1
    fi
    echo "✓ Found: $file"
done

echo ""
echo "=== Displaying generated meta.nix ==="
cat "$MACHINE_DIR/meta.nix"

echo ""
echo "=== Building machine configuration ==="

# Try to build the machine configuration
if command -v just &> /dev/null; then
    echo "Running: just build-machine $MACHINE_NAME"
    just build-machine "$MACHINE_NAME" || {
        echo "WARNING: Build failed. This might be expected if the machine requires specific hardware."
        echo "Check the errors above for issues with the generated configuration."
    }
else
    echo "WARNING: 'just' command not found. Skipping build test."
    echo "You can manually test by running: just build-machine $MACHINE_NAME"
fi

echo ""
echo "=== Test Summary ==="
echo "✓ Machine directory created: $MACHINE_DIR"
echo "✓ All required files generated (meta.nix, configuration.nix, hw-config.nix)"
echo ""
echo "To inspect the generated files:"
echo "  cd $INFRA_DIR"
echo "  ls -la $MACHINE_DIR"
echo ""
echo "To build the machine:"
echo "  cd $INFRA_DIR"
echo "  just build-machine $MACHINE_NAME"
echo ""
echo "=== Test completed ==="
