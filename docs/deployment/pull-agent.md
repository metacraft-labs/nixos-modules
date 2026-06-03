# Deployment Pull Agent

M5 adds an optional target-side pull path for hosts that cannot be reached
reliably by the push reconciler. It is a prototype and is not enabled on
production machines by the generic module.

## Controller Shape

The selected M5 shape is hybrid:

- CI or a cron reconciler remains responsible for building closures, pushing
  them to Cachix or Attic, creating signed desired-state manifests, and
  publishing only the manifests a target is allowed to read.
- The target-side `mcl-deploy-agent` service polls configured manifest files,
  directories, or HTTP(S) URLs and applies the latest signed manifest for its
  own target.
- No persistent central controller is introduced in M5. A persistent service
  can still be added later if full-topology rehearsals prove that the simpler
  publisher plus pull-agent model is insufficient.
- Cachix Deploy remains the production fallback while this path is tested.

This keeps the new target-side behavior small and preserves the M4 signed
manifest and `deploy-apply` format. The agent does not define a second desired
state protocol.

## Target Rules

The agent is intentionally strict:

- Every manifest loaded from its configured sources must target the agent's
  configured `targetName`; a manifest for any other target is non-retryable.
- Every manifest must verify against the configured OpenSSH allowed-signers
  file or trusted public key before any state change or apply attempt.
- If multiple manifests share the highest sequence but have different
  deployment IDs, the result is non-retryable because the desired state is
  ambiguous.
- Only the highest valid sequence is applied.

Publishers should therefore expose per-target manifest paths or pre-filtered
directories. A shared mixed-target directory is rejected by design.

## State And Reporting

The pull agent reuses the M4 deployment state directory and event stream:

- Desired/current/failed/superseded/converged state stays under
  `/var/lib/mcl/deployments`.
- Agent status is written only to
  `/var/lib/mcl/deployments/agent-status/<target>.json`.
- Target-side deployment events are emitted by the existing `deploy-apply`
  path with `target.transport = "pull-agent"` and
  `backend.controller = "mcl-deploy-agent"`.

The current reporter coverage is the M4 event stream: restore, switch,
healthcheck, rollback, and complete events. Dedicated journald extraction and
more detailed switch progress capture are deferred until the full-topology
rehearsal defines the operator artifact format.

## Locking And Retries

The NixOS module wraps the agent in `flock -n` using a per-target lock file.
Concurrent agent or apply attempts for the same host fail instead of
overlapping.

Retry handling is bounded:

- Source read or fetch failures are retryable.
- Apply failures are retryable until `maxAttempts` is reached.
- Wrong target, invalid signature, ambiguous latest sequence, and exhausted
  retry budget are explicit non-retryable states.
- Already converged deployments short-circuit without another apply attempt.

## NixOS Module

The generic module is `flake.modules.nixos.deployment-pull-agent` and exposes
`services.mcl-deploy-agent`.

Example:

```nix
{
  imports = [ inputs.nixos-modules.modules.nixos.deployment-pull-agent ];

  services.mcl-deploy-agent = {
    enable = true;
    targetName = config.networking.hostName;
    manifestPublicKeys = [ "ssh-ed25519 ..." ];
    manifestSources = [ "https://example.invalid/deployments/${config.networking.hostName}/latest.json" ];
    interval = "15min";
    jitter = "5min";
    maxAttempts = 3;
  };
}
```

Production integrations should wire private source URLs, trust material, target
selection, and any approval policy in the infrastructure repository. The
generic module should remain opt-in.

## Verification

Implemented M5 coverage:

- Focused D unit tests for latest-only selection, wrong-target rejection, and
  retry budget behavior.
- Static NixOS module rendering check for service, timer, source, lock, and
  retry options.
- NixOS VM test proving the agent applies only the latest signed manifest for
  its own host.
- NixOS VM test proving wrong-target and invalid-signature manifests are
  rejected without restore or switch.
- NixOS VM test proving the service-held lock rejects a concurrent contender
  and releases after the service exits.

Still required before production enablement:

- Full-topology Incus/LXC rehearsal covering runner, cache, publisher,
  unreachable target, reconnection, and latest-only apply.
- Production canary with Cachix Deploy still available as fallback.
- Approval gates for sensitive targets at the manifest publishing layer.
