---
name: deployment-e2e-rehearsal
description: Use when running deployment migration rehearsals in NixOS VM tests or Incus/LXC topology simulations, including check-env, check-runtime, dry-run, runtime launch, failure injections, and production evidence gates.
---

# Deployment E2E Rehearsal

## Prerequisites

- Run deterministic NixOS VM checks before any Incus/LXC runtime rehearsal.
- For Incus/LXC, confirm a local daemon, unprivileged container support, bridge
  networking, writable test storage, and no production target credentials.
- Treat a `pending-runtime` result as an honest blocker only when the local
  daemon or required Incus/LXC storage prerequisites are unavailable; do not
  mark production enablement complete from check-env or dry-run alone.

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
nix build .#checks.x86_64-linux.deployment-production-cutover-simulation-vm
nix build .#checks.x86_64-linux.deployment-no-default-cachix-deploy-call
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
bash scripts/deployment-incus-rehearsal.sh break-glass --check-env
bash scripts/deployment-incus-rehearsal.sh break-glass --check-runtime
bash scripts/deployment-incus-rehearsal.sh break-glass --dry-run
bash scripts/deployment-incus-rehearsal.sh break-glass
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
   partial and record the missing daemon or storage prerequisite.
6. Save artifacts before destroying containers. The script prints the artifact
   directory; set `MCL_DEPLOYMENT_INCUS_ARTIFACT_DIR` to choose it explicitly.
7. Set `MCL_DEPLOYMENT_INCUS_KEEP=1` only when a failed run needs prefixed
   containers and networks preserved for debugging.

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
For break-glass coverage, the topology must also represent a failed canary
deploy, reject arbitrary deploy-key shell access, accept only a signed
break-glass manifest through forced-command SSH, and preserve final generation
evidence in target-side artifacts.

## Evidence

- NixOS VM check result paths.
- Incus/LXC check-env, check-runtime, dry-run, runtime logs, and the printed
  runtime artifact directory.
- Topology inventory, target roles, network graph, generated credentials, and
  failure injection list.
- Deployment event JSONL, target journals, cache logs, metrics snapshot, and
  final desired-state status for every target.
- Per-container assertion JSON proving role metadata, target group, network
  attachment count, and Avahi policy.
- Explicit comparison between rehearsal roles and production rollout groups
  before production enablement.
- M8 cutover gate evidence proving Cachix Deploy is legacy fallback and the
  Attic/direct path has local shadow and supervised simulation artifacts.

## Stop And Ask

Stop before using production SSH keys, cache tokens, manifest signing keys, or
hostnames in rehearsal containers; before weakening a failed check; before
marking a runtime-pending result as passed; or before enabling production
targets without the full evidence set. Stop before removing Cachix Deploy
fallback without two successful live canary cycles.

## Rollback

Destroy rehearsal containers and networks after artifact capture. If a runtime
scenario touches a real host by mistake, stop the rehearsal immediately and use
break-glass rollback under human supervision.
