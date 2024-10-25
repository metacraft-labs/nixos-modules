# Nixos-Modules

This repository contains a collection of Nix packages and NixOS modules, commonly used by the Metacraft Labs development team.

## Use CI workflow

In order to reuse a ci workflow from this repo (ci/update-flake-lock/update-flake-packages), you must have the following in your yml file in your repository:

```yml
jobs:
  call-ci:
    uses: metacraft-labs/nixos-modules/.github/workflows/ci.yml@main
    secrets: inherit
```

## MCL command

The mcl tool contained in this repository has a number of commands which can be given to it as a commandline argument. They are:

### ci_matrix

Evaluates each package, and compares it to it's last cached version, creating a table listing which packages are cached, which aren't, and which failed.
This command is not meant to be run manually, but rather to be ran by the CI.

ENV Variables:
- IS_INITIAL: `true` or `false`
- CACHIX_CACHE: Which cachix cache to search
- CACHIX_AUTH_TOKEN: The auth token for the cache
- FLAKE_PRE: Flake path prefix
- FLAKE_POST: Flake path postfix

Usage: Use `mcl ci` instead

### ci

Evaluates each package, and compares it to it's last cached version, creating a table listing which packages are cached, which aren't, and which failed.

ENV Variables:
- IS_INITIAL: `true` or `false`
- CACHIX_CACHE: Which cachix cache to search
- CACHIX_AUTH_TOKEN: The auth token for the cache
- FLAKE_PRE: Flake path prefix
- FLAKE_POST: Flake path postfix

Usage: `mcl ci`

### deploy_spec

Deploys machine specs to cachix.

Usage: `mcl deploy_spec`

### get_fstab

ENV Variables:
- IS_INITIAL: `true` or `false`
- CACHIX_CACHE: Which cachix cache to search
- CACHIX_AUTH_TOKEN: The auth token for the cache
- [Optional] CACHIX_STORE_URL: URL for the cachix store
- [Optional] CACHIX_DEPLOY_WORKSPACE: Workspace for cachix deploy (defaults to CACHIX_CACHE if not set)
- MACHINE_NAME: Which machine to serach
- DEPLOYMENT_ID: Id of cachix deployment

Usage: `mcl get_fstab`

### host_info

Returns system information, software (OS, Bios) and hardware (CPU, GPU, Ram, MB, Disks) as json.

Usage: `mcl host_info`

### machine_create

Create a starting nix configuration for target machine.

ENV Variables:
- SSH_PATH: SSH path of target machine

The remaining ENV variables are optional, and if missing will be prompted at runtime.
- CREATE_USER: bool
- USER_NAME: string
- MACHINE_NAME: string
- DESCRIPTION: string
- IS_NORMAL_USER: bool
- EXTRA_GROUPS: comma-delimited list of additional groups to add to the created user
- MACHINE_TYPE: enum (desktop, server, container)
- DISKS: comma-delimited list of device names (as per /dev) to add to the nix configuration

Usage: `mcl machine_create`

### shard_matrix

Splits the list of packages under `checks` into n number of shards. Requires manual configuration using modules/shard-split. See this repo and `nix-blockchain-development`

ENV Variables:
- [Optional] GITHUB_OUTPUT: If set, exports results to GITHUB_INPUT env variable

Usage: `mcl shard_matrix`
