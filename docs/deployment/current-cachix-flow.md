# Current Cachix Deployment Flow

The current production-capable deploy path is the reusable GitHub Actions
workflow documented in [current-flow-inventory.json](current-flow-inventory.json).
Deployment cache publication and legacy Cachix Deploy activation have separate
workflow gates. `push-deployment-caches` publishes deployment target closures
to the configured deployment cache backends. `run-cachix-deploy` keeps the
legacy activation path available and also implies deployment cache publication
for backward compatibility.

## CI Flow

1. `compute-mcl-ref` computes the reusable workflow revision and exposes an
   `mcl` command such as `nix run ...#mcl`.
2. `shard-matrix` runs `mcl shard-matrix` to discover systems and shard work.
3. `eval-matrix` runs `mcl ci-matrix --flake-attribute-path ... --is-initial`
   for each evaluation shard and uploads matrix artifacts.
4. `merge-matrices` runs `mcl merge-ci-matrices` and publishes the merged
   package table.
5. `build` runs `nix build -L --no-link --keep-going --show-trace
'.#${{ matrix.attrPath }}'` for each matrix item.
6. When `inputs.push-deployment-caches || inputs.run-cachix-deploy` is true,
   `build` runs `mcl cache push-closure` for each deployment target and the
   configured `deployment-cache-push-backends`.
7. `results` runs on the JSON-encoded `results-runner` input, which defaults
   to self-hosted Linux fleet runner labels. It prints the final matrix and
   updates the pull request comment.
8. When `inputs.run-cachix-deploy` is true, `results` checks out the repository
   and runs `mcl deploy-spec`.

## Target Activation Flow

`mcl deploy-spec` evaluates `legacyPackages.x86_64-linux.serverMachines`.
For each evaluated machine, it checks whether the system output is already
available through the configured binary cache URLs. If any server machine is
missing from cache, the command fails before activation.

When all target system outputs are cached, `mcl deploy-spec` writes a
`cachix-deploy-spec.json` file under the local result directory. The spec maps
agent names to Nix store paths:

```json
{
  "agents": {
    "target-name": "/nix/store/hash-nixos-system-target-name-version"
  }
}
```

`mcl deploy-spec` then runs `cachix deploy activate <spec> --async`. The remote
Cachix Deploy service records an activation request. The target-side
`cachix-agent` restores the requested store path and invokes the system
activation switch. The reusable workflow does not currently collect target-side
journald logs, activation generation, health-check output, or rollback status.

## Deployment Inputs

| Input                | Current source                                                                                        | Notes                                                                     |
| -------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Flake attr           | Build matrix `matrix.attrPath`; deploy command evaluates `legacyPackages.x86_64-linux.serverMachines` | The deploy attr is fixed in `mcl deploy-spec`.                            |
| Target machine       | Evaluated package name, then Cachix Deploy agent name                                                 | Must match the target-side agent identity.                                |
| Store path           | Build matrix `matrix.output`; deploy spec agent value                                                 | Expected to be a NixOS system toplevel.                                   |
| Closure size         | Not recorded by the workflow today                                                                    | M1+ event emission should record closure count and bytes.                 |
| Cachix cache name    | GitHub variable `CACHIX_CACHE`                                                                        | Used by setup, optional Cachix cache push, and `mcl` cache-status checks. |
| Attic cache          | GitHub variables `ATTIC_CACHE`, `ATTIC_SUBSTITUTER`, `ATTIC_TRUSTED_PUBLIC_KEY`                       | Used when `deployment-cache-push-backends` includes `attic`.              |
| Substituters         | GitHub variable `SUBSTITUTERS` plus default cache URLs supplied to `mcl`                              | Used for Nix setup and cache-status checks.                               |
| Trusted public keys  | GitHub variable `TRUSTED_PUBLIC_KEYS`                                                                 | Required for substituter trust on runners.                                |
| Results runner       | Workflow input `results-runner`, JSON default `["self-hosted", "nixos", "x86-64-v2", "bare-metal"]`   | Keeps deploy orchestration on self-hosted runners by default.             |
| Deploy token         | Secret `CACHIX_ACTIVATE_TOKEN`                                                                        | Passed only to the deploy step environment.                               |
| Cache push tokens    | Secrets `CACHIX_AUTH_TOKEN`, `ATTIC_TOKEN`                                                            | Used by setup, optional cache pushes, and cache-status checks.            |
| Source access tokens | `NIX_GITHUB_TOKEN`, `NIX_GITLAB_TOKEN`, `NIX_GITLAB_DOMAIN`                                           | Used by Nix access-token setup.                                           |
| Health checks        | Not modeled in the reusable workflow                                                                  | Future events should model check command, timeout, attempts, and result.  |

## Current Cachix Deploy Monitoring Path

The existing monitoring path is implemented by the following sources:

- `metacraft-labs/infra/services/monitoring/cachix-deploy-metrics/default.nix`
- `modules/cachix-deploy-metrics/default.nix`
- `packages/cachix-deploy-metrics/default.nix`
- `packages/cachix-deploy-metrics/main.d`

The infrastructure service imports the shared NixOS module and enables
`services.cachix-deploy-metrics`. Its current configuration binds the exporter
on all addresses, reads the Cachix API token through `auth-token-path`, passes a
Cachix Deploy `workspace`, and derives `agent-names` from the server machine
directories under the infrastructure tree. Concrete private workspace and host
names are recorded only in [private-inventory.md](private-inventory.md).

The shared NixOS module turns that configuration into the
`cachix-deploy-metrics` systemd service. The service is a Prometheus exporter:
it runs the packaged binary with `--port`, `--bind-addresses`,
`--scrape-interval`, `--auth-token-path`, `--workspace`, and `--agent-names`,
then serves Prometheus text format at `/metrics`. The module default port is
`9160`; the observed infrastructure service inherits that port and sets a
one-second scrape interval through the module default.

The package builds the D exporter from `packages/cachix-deploy-metrics/main.d`.
The exporter reads the token either from `--auth-token` or `--auth-token-path`,
then polls the Cachix Deploy API endpoint
`https://app.cachix.org/api/v1/deploy/agent/<workspace>/<agent>`. It maps the
API `lastDeployment` state into these metrics:

- `cachix_deploy_status`
- `cachix_deploy_counter`
- `cachix_deploy_last_started_time`
- `cachix_deploy_last_finished_time`
- `cachix_deploy_in_progress_duration_seconds`

This path observes Cachix Deploy API state for the last deployment per agent.
It does not consume the new M0 deployment event stream, target journald,
switch-to-configuration logs, health-check output, rollback evidence, or a
cross-system correlation id. Those gaps are why later milestones need event and
desired-state status artifacts rather than relying on the current exporter
alone.

## Observability Gaps

- The current workflow reports build and cache-push status but not target
  restoration, switch, generation number, health-check, or rollback state.
- `cachix deploy activate --async` returns before target activation completes.
- Target-side failure details remain outside the workflow unless an operator
  separately checks agent logs.
- The current Cachix Deploy metrics exporter observes Cachix Deploy API status
  only; it is not fed by the new event stream.
- There is no deployment correlation id propagated through the workflow,
  `mcl`, target logs, metrics, and status artifacts.
