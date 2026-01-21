# Nixos-Modules

This repository contains a collection of Nix packages and NixOS modules, commonly used by the Metacraft Labs development team.

## Documentation

- [Shard Splitting Architecture](docs/shard-splitting-architecture.md) — Distributed CI/CD evaluation with the `shardSplit` flake module

## GitHub Workflows

### CI Workflow

To use this repo's CI workflow, add the following to your repository:

```yml
jobs:
  call-ci:
    uses: metacraft-labs/nixos-modules/.github/workflows/ci.yml@main
    secrets: inherit
```

### Reusable Workflows

The following reusable workflows are available in `.github/workflows/`:

#### [`reusable-flake-checks-ci-matrix.yml`](.github/workflows/reusable-flake-checks-ci-matrix.yml)

Runs flake checks with shard-based parallelization. See [Shard Splitting Architecture](docs/shard-splitting-architecture.md).

```yml
jobs:
  ci:
    uses: metacraft-labs/nixos-modules/.github/workflows/reusable-flake-checks-ci-matrix.yml@main
    secrets:
      CACHIX_AUTH_TOKEN: ${{ secrets.CACHIX_AUTH_TOKEN }}
      CACHIX_ACTIVATE_TOKEN: ${{ secrets.CACHIX_ACTIVATE_TOKEN }}
    with:
      runners: | # json
        {
          "x86_64-linux": ["self-hosted", "nixos", "x86-64-v3", "bare-metal"],
          "aarch64-darwin": ["self-hosted", "macOS", "aarch64-darwin"]
        }
```

#### [`reusable-lint.yml`](.github/workflows/reusable-lint.yml)

Runs pre-commit hooks for linting and formatting checks.

```yml
jobs:
  lint:
    uses: metacraft-labs/nixos-modules/.github/workflows/reusable-lint.yml@main
    secrets:
      NIX_GITHUB_TOKEN: ${{ secrets.NIX_GITHUB_TOKEN }}
      CACHIX_AUTH_TOKEN: ${{ secrets.CACHIX_AUTH_TOKEN }}
```

#### [`reusable-update-flake-lock.yml`](.github/workflows/reusable-update-flake-lock.yml)

Updates `flake.lock` and creates a PR. Supports GPG-signed commits.

```yml
jobs:
  update-flake-lock:
    uses: metacraft-labs/nixos-modules/.github/workflows/reusable-update-flake-lock.yml@main
    secrets:
      CACHIX_AUTH_TOKEN: ${{ secrets.CACHIX_AUTH_TOKEN }}
      CREATE_PR_APP_ID: ${{ secrets.APP_ID }}
      CREATE_PR_APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
      NIX_GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      GIT_GPG_SIGNING_SECRET_KEY: ${{ secrets.GIT_GPG_SIGNING_SECRET_KEY }}
    with:
      runner: '["self-hosted", "Linux", "x86-64-v2"]'
      sign-commits: true
```

#### [`reusable-update-flake-packages.yml`](.github/workflows/reusable-update-flake-packages.yml)

Updates individual flake packages using [`nix-update-action`](https://github.com/metacraft-labs/nix-update-action) and creates PRs.

```yml
jobs:
  update-packages:
    uses: metacraft-labs/nixos-modules/.github/workflows/reusable-update-flake-packages.yml@main
    secrets:
      CACHIX_AUTH_TOKEN: ${{ secrets.CACHIX_AUTH_TOKEN }}
      CREATE_PR_APP_ID: ${{ secrets.APP_ID }}
      CREATE_PR_APP_PRIVATE_KEY: ${{ secrets.APP_PRIVATE_KEY }}
```

## MCL CLI Tool

The `mcl` tool is a Swiss-knife CLI for managing NixOS deployments. For development best practices, see [packages/mcl/AGENTS.md](packages/mcl/AGENTS.md).

### Available Commands

| Command        | Description                                                                                                              |
| -------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `host-info`    | Returns system information (OS, BIOS, CPU, GPU, RAM, disks) as JSON                                                      |
| `hosts`        | Remote host management and network scanning                                                                              |
| `ci`           | Evaluates packages and compares to cached versions                                                                       |
| `shard-matrix` | Splits packages into shards for distributed CI. See [Shard Splitting Architecture](docs/shard-splitting-architecture.md) |
| `deploy-spec`  | Deploys machine specs to Cachix                                                                                          |
| `machine`      | Create and manage NixOS machine configurations                                                                           |

Run `mcl --help` or `mcl <command> --help` for usage details and environment variables.
