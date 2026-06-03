# Production Cutover Gate

M8 is a production gate, not an automatic rollout. The first pass is limited to
local simulation, evidence checks, and operator documentation. No live target is
selected until M7 full-topology runtime evidence is green and a human approves
the canary target.

## Required Evidence

The gate file is
[production-cutover-gates.json](production-cutover-gates.json). It requires:

- successful M7 runtime evidence for all topology scenarios;
- a runtime command log proving the new path did not call Cachix Deploy
  activation;
- deployment event JSONL and status summaries;
- cache logs and target journal snippets;
- final state for every rollout group;
- two successful live canary cycles before default Cachix Deploy removal.

## First Target Policy

The generic policy intentionally does not name a production host. The only
selected target in this pass is `local-production-cutover-canary`, a local
simulation target. A private infrastructure repository may list candidates, but
the live canary remains unselected until the evidence gate and human approval
are both present.

## Shadow Deploy

The shadow path builds or selects the desired system path, pushes the closure to
Attic, verifies substitute coverage, creates a signed manifest, and runs the
direct SSH reconciler in dry-run mode. It must not switch a real host.

Expected evidence:

- Attic cache-push event with complete substitute coverage;
- signed desired-state manifest;
- dry-run `activate-requested` event with `pending` status;
- no target-side switch or rollback event;
- no Cachix Deploy activation command.

## Supervised Local Cutover Simulation

The local VM simulation applies the same signed manifest to a test target over
the forced-command SSH path. It verifies target-side restore, switch,
healthcheck, summary artifacts, rollback drill evidence, and final generation.
This proves the operator evidence format without mutating production hosts.

## Cachix Deploy Fallback

Cachix Deploy is legacy fallback during M8. It remains callable explicitly for a
rollback window, but the new Attic/direct cutover path must not depend on it.
Default Cachix Deploy removal is blocked until the M7 gate is green, a live
canary target is approved, two successful live canary cycles are recorded, and
all rollout batches have migrated.

## Removal Gate

Do not remove Cachix Deploy activation from default production CI or remove the
Cachix cache dependency until the gate records:

1. green M7 full-topology runtime evidence;
2. selected live canary target and approval record;
3. two successful live canary cycles;
4. completed batch rollout evidence;
5. explicit rollback-window closeout.
