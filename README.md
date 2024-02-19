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
