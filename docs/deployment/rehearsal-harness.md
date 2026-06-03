# Rehearsal Harness Inventory

M0 inventoried prior art and did not add a rehearsal runtime. M7 adds the
generic command shape and image builder described here.

## Observed Current State

The infrastructure repository contains useful pieces for future rehearsal
harness work:

- Nix build recipes for machine toplevels, VMs, and MicroVM-style containers.
- Commands to start and stop built VM or container artifacts.
- Direct remote switch deployment through `nixos-rebuild-ng`.
- Cachix Deploy spec generation and activation commands.
- Server default virtualisation configuration that enables Incus.
- GitHub runner MicroVM/container configuration with forwarded SSH ports.

M7 adds `scripts/deployment-incus-rehearsal.sh` with `--check-env`,
`--check-runtime`, `--dry-run`, topology runtime launch, and `pending-runtime`
diagnostics when the local daemon or storage prerequisites are unavailable. The
generic script validates declarative topology inventories, creates only
prefixed Incus resources, and retains the existing Attic cache runtime scenario.
Private topologies wrap this generic script from the infrastructure repository.

## Generic Harness Utilities

- Build a NixOS LXC-compatible image from a flake attr.
- Print a dry-run deployment plan with target, store path, closure summary,
  cache backend, and activation transport.
- Check local prerequisites for Nix, Incus or LXC, KVM, network bridge support,
  and unprivileged container support.
- Check runtime readiness and produce pending-runtime diagnostics only when the
  local daemon is absent, not initialized, or missing required storage.
- Build and import the configured generic NixOS LXC image attr.
- Launch isolated test targets with prefixed names, segmented networks, and
  generated rehearsal-only credentials.
- Prefill closures through an abstract cache backend.
- Apply desired-state manifests through a generic target-side wrapper.
- Run service smoke checks and map failures to `healthcheck` events.
- Capture target journald snippets, deployment JSONL, topology summary,
  runtime command log, per-container assertion output, and final desired-state
  status artifacts under `MCL_DEPLOYMENT_INCUS_ARTIFACT_DIR` or a printed
  temporary directory.
- Destroy rehearsal targets and garbage-collect test state.

Set `MCL_DEPLOYMENT_INCUS_KEEP=1` to keep prefixed containers, networks, and the
imported image alias for debugging. Cleanup never deletes non-prefixed
resources.
