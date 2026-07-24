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
- A pre-switch readiness hook that exits with status 75 records `deferred`,
  remains retryable, and does not increment `attempts`. Other hook failures are
  ordinary apply failures and consume an attempt.
- Wrong target, invalid signature, ambiguous latest sequence, and exhausted
  retry budget are explicit non-retryable states.
- Already converged deployments short-circuit without another apply attempt.

## Platform Activation And Lifecycle Hooks

`mcl deploy-apply` and `mcl deploy-agent` default to
`--activation-mode nixos`. That mode retains the existing detached
`systemd-run` invocation of `switch-to-configuration`; existing callers do not
need new arguments.

`--activation-mode nix-darwin` uses the native nix-darwin transaction:

1. Resolve the generation currently selected by `--system-profile` (default
   `/nix/var/nix/profiles/system`).
2. Atomically select the desired generation with `nix-env --profile ... --set`.
3. Execute the desired generation's `activate` directly, without
   `systemd-run`.
4. If activation fails, atomically restore the previous profile and execute
   the previous generation's `activate` before reporting failure. Automatic
   health-check rollback uses the same pair of operations.

The optional lifecycle hooks are executable paths, not shell fragments. The
agent invokes them with separate arguments so generation values cannot be
reinterpreted as shell syntax:

```text
PRE_SWITCH_HOOK  DESIRED_GENERATION PREVIOUS_GENERATION
POST_SWITCH_HOOK DESIRED_GENERATION PREVIOUS_GENERATION OUTCOME
```

The pre-switch hook runs after closure restoration and generation discovery,
but before any profile or system switch. Exit 75 means “not ready yet” and is
the only deferred result. Once readiness succeeds, the post-switch hook runs
after success, activation failure, health-check failure, and rollback. Its
`OUTCOME` is one of `succeeded`, `switch-failed`, `healthcheck-failed`, or
`rolled-back`. A failed post-switch hook prevents a successful deployment from
being marked converged.

Lifecycle events remain within the checked-in deployment event schema: hook
execution uses the existing `switch` phase and distinguishes `pre-switch` from
`post-switch` with `metadata.lifecycleStage`. Readiness deferral uses command
status `skipped`, exit code 75, error code `deployment_deferred`, and
`error.retryable = true`; it does not introduce a new phase or status value.
Darwin activation events report target kind `darwin`.

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

## nix-darwin Module

The opt-in Darwin module is
`flake.modules.darwin.deployment-pull-agent`. It uses the same
`services.mcl-deploy-agent` target, manifest trust, source, state, event,
timeout, and retry options where their platform semantics match. Darwin uses
`intervalSeconds` for launchd's integer `StartInterval`, and adds
`systemProfile`, `preSwitchHook`, `postSwitchHook`, `standardOutLog`, and
`standardErrorLog`.

The module installs a root LaunchDaemon with `RunAtLoad` and periodic polling.
Its plist deliberately contains `/run/current-system/sw/bin/mcl-deploy-agent`
instead of a Nix store path. That stable wrapper is exported through
`environment.systemPackages`; only after launch does it resolve the current
generation's `mcl`, trust file, and lifecycle hooks. A nix-darwin activation
can therefore replace the system environment without unloading the process
that is applying it.

Every invocation takes a non-blocking `flock` supplied by the wrapper's Darwin
runtime closure. State and deployment JSONL events remain under
`/var/lib/mcl/deployments` and `/var/log/mcl/deployments` by default, while
launchd stdout and stderr use durable files beside the event log. The module's
pre-activation fragment creates those root-owned paths before launchd loads
the daemon. No `sudo` or passwordless privilege rule is involved: launchd runs
the system daemon directly as `root:wheel`.

Example:

```nix
{
  imports = [ inputs.nixos-modules.modules.darwin.deployment-pull-agent ];

  services.mcl-deploy-agent = {
    enable = true;
    targetName = config.networking.hostName;
    manifestPublicKeys = [ "ssh-ed25519 ..." ];
    manifestSources = [ "https://example.invalid/deployments/m3/latest.json" ];
    intervalSeconds = 15 * 60;
    maxAttempts = 3;
    preSwitchHook = pkgs.writeShellScript "deployment-ready" ''
      # Exit 75 to defer without spending an attempt.
    '';
    postSwitchHook = pkgs.writeShellScript "deployment-cleanup" ''
      # Receives DESIRED PREVIOUS OUTCOME.
    '';
  };
}
```

Like the NixOS module, importing the Darwin module does not enable it.

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
- Darwin module contract checks for its root LaunchDaemon, stable entrypoint,
  polling interval, durable paths, real activation arguments, and retry bound.
- Darwin public-entrypoint integration coverage for a trusted activation,
  unavailable desired state, wrong-target and invalid-signature rejection,
  JSON-schema-valid events, and non-destructive lock contention.

Still required before production enablement:

- Full-topology Incus/LXC rehearsal covering runner, cache, publisher,
  unreachable target, reconnection, and latest-only apply.
- Production canary with Cachix Deploy still available as fallback.
- Approval gates for sensitive targets at the manifest publishing layer.
