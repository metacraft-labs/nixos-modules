# Rehearsal Harness Inventory

M0 only inventories current prior art. It does not add or change a rehearsal
runtime.

## Observed Current State

The infrastructure repository contains useful pieces for future rehearsal
harness work:

- Nix build recipes for machine toplevels, VMs, and MicroVM-style containers.
- Commands to start and stop built VM or container artifacts.
- Direct remote switch deployment through `nixos-rebuild-ng`.
- Cachix Deploy spec generation and activation commands.
- Server default virtualisation configuration that enables Incus.
- GitHub runner MicroVM/container configuration with forwarded SSH ports.

I did not find checked-in Incus/LXC rehearsal scripts with `--check-env`,
`--check-runtime`, `--dry-run`, runtime launch, service smoke checks, and
pending-runtime diagnostics. Those modes are therefore a desired harness
interface, not existing named scripts in the current observed tree.

## Generic Harness Utilities To Extract Later

- Build a NixOS system or LXC-compatible image from a flake attr.
- Print a dry-run deployment plan with target, store path, closure summary,
  cache backend, and activation transport.
- Check local prerequisites for Nix, Incus or LXC, KVM, network bridge support,
  and unprivileged container support.
- Check runtime readiness and produce pending-runtime diagnostics when the
  local daemon is absent or not initialized.
- Launch isolated test targets with deterministic names and logs.
- Prefill closures through an abstract cache backend.
- Apply desired-state manifests through a generic target-side wrapper.
- Run service smoke checks and map failures to `healthcheck` events.
- Capture target journald, deployment JSONL, metrics snapshots, and final
  desired-state status artifacts.
- Destroy rehearsal targets and garbage-collect test state.
