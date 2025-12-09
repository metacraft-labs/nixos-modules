# Machine.d Refactoring - Implementation Summary

## Date: December 9, 2024

## Overview

Successfully refactored `machine.d` to generate a `meta.nix` file with enhanced configuration options, updated the disko structure, improved user information fields, and implemented dynamic group retrieval using nix eval.

## Changes Implemented

### 1. Removed `Group` enum and implemented dynamic group retrieval

- **Removed**: `enum Group` (lines 21-28)
- **Updated**: `getGroups()` function to use nix eval for dynamic group retrieval from the users module
- **Benefit**: Always have current, valid group names from the actual users configuration

### 2. Updated `EmailInfo` struct

- **Added fields**:
  - `descriptionBG` (optional, Bulgarian description)
  - `emailAliases` (optional array of emails)
  - `githubUsername` (optional)
  - `discordUsername` (optional)
- **Updated**: `getUser()` function to handle these new fields

### 3. Created new `MetaConfiguration` struct

- Replaces the need for most configuration in `MachineConfiguration`
- **Fields**:
  - `mcl.host-info.type` - Host type (notebook/desktop/server)
  - `mcl.host-info.sshKey` - SSH key (required for servers, optional for desktops)
  - `mcl.users.mainUser` - Main user for the machine
  - `mcl.users.includedUsers` - Array of additional users
  - `mcl.users.includedGroups` - Array of groups to include
  - `mcl.users.enableHomeManager` - Boolean for home-manager
  - `mcl.secrets.extraKeysFromGroups` - Array of groups for SSH keys
  - `nixpkgs.hostPlatform` - Platform string (from host-info)
  - `networking.hostId` - Random host ID
  - `system.stateVersion` - Calculated from current date

### 4. Updated disko structure

- **Old structure**: Nested `DISKO.makeZfsPartitions` with complex replacement logic
- **New structure**: Flat `mcl.disko` configuration
  ```d
  struct MCLDisko {
      bool enable = true;
      string partitioningPreset; // "zfs", "zfs-legacy", or "ext4"
      struct Zpool {
          string mode; // "mirror", "raidz1", "raidz2", "raidz3", "stripe"
      }
      Zpool zpool;
      string espSize; // default "4G"
      struct Swap {
          string size;
      }
      Swap swap;
      string[] disks;
  }
  ```

### 5. Added CLI arguments to `CreateMachineArgs`

**Meta.nix configuration**:

- `--host-type` (notebook/desktop/server)
- `--main-user` (defaults to created/selected user)
- `--included-users` (comma-separated)
- `--included-groups` (comma-separated, validated against nix eval)
- `--enable-home-manager` (bool)
- `--extra-keys-from-groups` (comma-separated)

**User information**:

- `--description-bg` (Bulgarian description)
- `--email-aliases` (comma-separated emails)
- `--github-username`
- `--discord-username`

**Disko configuration**:

- `--partitioning-preset` (zfs/zfs-legacy/ext4)
- `--zpool-mode` (mirror/raidz1/raidz2/raidz3/stripe)
- `--esp-size` (default 4G)
- `--swap-size` (override automatic calculation)

### 6. Updated `createMachine()` function

- **Now generates**: `meta.nix`, `configuration.nix`, and `hw-config.nix`
- **State version calculation**: Automatically calculates based on current date
  - Format: `YY.05` for May releases, `YY.11` for November releases
  - Current implementation: December 2024 → "24.11"
- **Platform detection**: Extracts platform from host-info (x86_64-linux, aarch64-darwin, etc.)
- **SSH key handling**:
  - Required for servers
  - Optional for desktops/notebooks
- **Host type**:
  - Automatic for servers
  - Prompt for desktops (notebook vs desktop)

### 7. Added helper functions

- `calculateStateVersion()` - Computes NixOS state version from current date
- `detectPlatform(Info info)` - Extracts platform string from host-info
- `getValidUsers()` - Retrieves valid user names

### 8. File generation structure

- **meta.nix**: New file with all meta configuration (host type, users, platform, state version, secrets)
- **configuration.nix**: Simplified user configuration (kept for backward compatibility)
- **hw-config.nix**: Hardware configuration with updated disko structure

### 9. Bug fixes

- Fixed double semicolon in `EFI` struct (`mkDefault(true);;` → `mkDefault(true);`)
- Fixed typo in hw-config filename (`hw-config..nix` → `hw-config.nix`)

### 10. Test script

- **Location**: `scripts/test-machine-create.sh`
- **Purpose**: Test machine creation with local infra repo
- **Features**:
  - Clones/updates infra repo
  - Runs `mcl machine create` with test parameters
  - Verifies file generation
  - Optionally runs `just build-machine` to validate build

## New Files Created

1. `/home/monyarm/code/repos/nixos-modules/scripts/test-machine-create.sh` - Test script

## Files Modified

1. `/home/monyarm/code/repos/nixos-modules/packages/mcl/src/src/mcl/commands/machine.d` - Main implementation

## Testing Instructions

### Manual Test

```bash
cd /home/monyarm/code/repos/nixos-modules
./scripts/test-machine-create.sh
```

### Build Test (in infra repo)

```bash
cd ~/code/repos/infra
just build-machine <machine-name>
```

## Example Usage

### Basic usage

```bash
mcl machine create user@host --machine-name=my-machine --machine-type=desktop
```

### Full configuration

```bash
mcl machine create user@host \
  --machine-name=my-server \
  --machine-type=server \
  --user-name=john \
  --description="John Doe" \
  --extra-groups=devops,codetracer \
  --host-type=server \
  --main-user=john \
  --included-users=jane,bob \
  --included-groups=devops \
  --enable-home-manager \
  --extra-keys-from-groups=devops \
  --github-username=johndoe \
  --partitioning-preset=zfs \
  --zpool-mode=mirror \
  --esp-size=4G \
  --swap-size=96G \
  --disks=nvme0,nvme1
```

## Notes

- The implementation maintains backward compatibility where possible
- All user inputs are validated (groups, users, etc.)
- Proper error handling for nix eval failures with fallback
- New CLI options are documented in help text via `@Description` annotations

## State Version Calculation Logic

```
Current month < May → Previous year.11
May ≤ Current month < November → Current year.05
Current month ≥ November → Current year.11

Example (December 2024):
  Month = 12 (December)
  12 ≥ 11 → "24.11"
```

## Platform Detection Logic

Maps architecture from host-info to Nix platform strings:

- x86_64 + Linux → "x86_64-linux"
- x86_64 + Darwin → "x86_64-darwin"
- aarch64 + Linux → "aarch64-linux"
- aarch64 + Darwin → "aarch64-darwin"
- Default → "x86_64-linux"

## Next Steps

1. Test the implementation with the test script
2. Verify generated files build successfully
3. Document new CLI options in README.md
4. Update examples in documentation

## Breaking Changes

- None - the implementation maintains backward compatibility
- Old CLI arguments still work
- New arguments are optional with sensible defaults
- New files (meta.nix) are generated in addition to existing ones
