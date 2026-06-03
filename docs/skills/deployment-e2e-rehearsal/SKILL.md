---
name: deployment-e2e-rehearsal
description: Use when running deployment migration rehearsals in NixOS VM tests or Incus/LXC topology simulations, including check-env, check-runtime, dry-run, runtime launch, failure injections, and production evidence gates.
---

# Deployment E2E Rehearsal

## Prerequisites

- Run deterministic NixOS VM checks before any Incus/LXC runtime rehearsal.
- For Incus/LXC, confirm a local daemon, unprivileged container support, bridge
  networking, writable test storage, and no production target credentials.
- Treat a `pending-runtime` result as an honest blocker when no local daemon or
  complete runtime evidence is available; do not mark production enablement
  complete from check-env or dry-run alone.

## Commands

```sh
nix build .#checks.x86_64-linux.deployment-attic-push-substitute-vm
nix build .#checks.x86_64-linux.deployment-cache-corruption-vm
nix build .#checks.x86_64-linux.deployment-direct-ssh-success-vm
nix build .#checks.x86_64-linux.deployment-direct-ssh-rollback-vm
nix build .#checks.x86_64-linux.deployment-direct-ssh-attic-restore-vm
nix build .#checks.x86_64-linux.deployment-reconciler-timer-retry-vm
nix build .#checks.x86_64-linux.deployment-reconciler-lock-contention-vm
nix build .#checks.x86_64-linux.deployment-pull-agent-latest-vm
nix build .#checks.x86_64-linux.deployment-pull-agent-rejects-invalid-vm
nix build .#checks.x86_64-linux.deployment-pull-agent-lock-contention-vm
nix build .#checks.x86_64-linux.deployment-scheduled-canary-local-vm
nix build .#checks.x86_64-linux.deployment-incus-rehearsal-image
nix build .#checks.x86_64-linux.deployment-incus-rehearsal-script-static
bash scripts/deployment-incus-rehearsal.sh full-topology --check-env
bash scripts/deployment-incus-rehearsal.sh full-topology --check-runtime
bash scripts/deployment-incus-rehearsal.sh full-topology --dry-run
bash scripts/deployment-incus-rehearsal.sh full-topology
bash scripts/deployment-incus-rehearsal.sh full-topology-failures --check-env
bash scripts/deployment-incus-rehearsal.sh full-topology-failures --dry-run
bash scripts/deployment-incus-rehearsal.sh full-topology-failures
bash scripts/deployment-incus-rehearsal.sh offline-latest-only --check-env
bash scripts/deployment-incus-rehearsal.sh offline-latest-only --dry-run
bash scripts/deployment-incus-rehearsal.sh offline-latest-only
bash scripts/deployment-incus-rehearsal.sh forced-command --check-env
bash scripts/deployment-incus-rehearsal.sh forced-command --dry-run
bash scripts/deployment-incus-rehearsal.sh forced-command
bash scripts/deployment-incus-rehearsal.sh pull-agent --check-env
bash scripts/deployment-incus-rehearsal.sh pull-agent --dry-run
bash scripts/deployment-incus-rehearsal.sh pull-agent
```

## Workflow

1. Run the focused NixOS VM checks for the component being changed.
2. Run Incus/LXC `--check-env` to validate host tools and storage.
3. Run `--check-runtime` to validate daemon, bridge, image, and launch
   permissions.
4. Run `--dry-run` to print topology, target roles, networks, credentials,
   failure injections, and evidence paths without starting containers.
5. Run the runtime scenario only when the previous steps pass and no production
   credentials are mounted. If the script reports `pending-runtime`, keep M7
   partial and record the daemon or runtime-evidence blocker.
6. Save artifacts before destroying containers.

## Topology Model

The full topology must include these roles: controller or CI runner, Attic cache,
monitoring or status collector, directly reachable server targets, NAT-like or
intermittently reachable targets, and optional workstation or pull-agent
targets.

The network model must include separate control, cache, home-lab-like,
remote-server-like, and optional workstation segments. Failure injections must
cover target network partition, stale desired state, and newer desired state
while offline. It must also cover cache object missing or corruption,
forced-command SSH misuse, health-check failure, rollback, and lock contention.

## Evidence

- NixOS VM check result paths.
- Incus/LXC check-env, check-runtime, dry-run, and runtime logs.
- Topology inventory, target roles, network graph, generated credentials, and
  failure injection list.
- Deployment event JSONL, target journals, cache logs, metrics snapshot, and
  final desired-state status for every target.
- Explicit comparison between rehearsal roles and production rollout groups
  before production enablement.

## Stop And Ask

Stop before using production SSH keys, cache tokens, manifest signing keys, or
hostnames in rehearsal containers; before weakening a failed check; before
marking a runtime-pending result as passed; or before enabling production
targets without the full evidence set.

## Rollback

Destroy rehearsal containers and networks after artifact capture. If a runtime
scenario touches a real host by mistake, stop the rehearsal immediately and use
break-glass rollback under human supervision.
