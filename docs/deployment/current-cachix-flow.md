# Current Cachix Deployment Flow

The current production-capable deploy path is the reusable GitHub Actions
workflow documented in [current-flow-inventory.json](current-flow-inventory.json).
As of c056211 the in-CI Cachix Deploy activation was removed: the
`run-cachix-deploy` gate, the `mcl deploy-spec` activation step, and all
`CACHIX_*` workflow inputs no longer exist. A single `push-deployment-caches`
gate now controls deployment-closure publication to the Attic deployment cache
backend, and activation is performed out-of-band by an operator via
`mcl deploy-ssh` / `mcl deploy-reconcile`.

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
6. When `inputs.push-deployment-caches` is true, `build` runs
   `mcl cache push-closure` for each deployment target and the configured
   `deployment-cache-push-backends` (`attic` by default, with `none` as the
   only non-Attic option), using the Attic CI transport (`--transport
attic-ci`).
7. `results` runs on the JSON-encoded `results-runner` input, which defaults
   to self-hosted Linux fleet runner labels. It prints the final matrix and
   updates the pull request comment.
8. There is no longer an in-CI activation step. The removed `run-cachix-deploy`
   gate and `mcl deploy-spec` step have no replacement in the workflow;
   activation happens out-of-band via `mcl deploy-ssh` / `mcl deploy-reconcile`.

## Target Activation Flow

In-CI activation was removed in c056211. The workflow no longer evaluates a
deploy spec, no longer writes a `cachix-deploy-spec.json`, and no longer runs
`cachix deploy activate`. The reusable workflow now stops at building and (when
`push-deployment-caches` is enabled) publishing deployment closures to the Attic
deployment cache.

Activation is performed out-of-band by an operator after CI publishes the
closure. The supported activation paths are:

- `mcl deploy-ssh` for a supervised, signed, forced-command SSH push to a
  single target; and
- `mcl deploy-reconcile` for the state-directory reconciler / pull-agent path.

The manual `cachix deploy activate` fallback has been retired; it is no longer
available to operators and was never part of the CI workflow. The new paths emit
a deployment event stream so target-side
restore, switch, generation number, health-check, and rollback status are
captured — gaps the previous Cachix Deploy path left outside the workflow.

## Deployment Inputs

| Input                | Current source                                                                                      | Notes                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Flake attr           | Build matrix `matrix.attrPath`                                                                      | Out-of-band activation selects the desired system path explicitly.                          |
| Target machine       | Build matrix `matrix.name` (deployment target name)                                                 | Must match the target-side reconciler / SSH apply identity.                                 |
| Store path           | Build matrix `matrix.output`                                                                        | Expected to be a NixOS system toplevel.                                                     |
| Closure size         | Not recorded by the workflow today                                                                  | M1+ event emission should record closure count and bytes.                                   |
| Attic cache          | GitHub variables `ATTIC_CACHE`, `ATTIC_SUBSTITUTER`, `ATTIC_TRUSTED_PUBLIC_KEY`                     | Used when `deployment-cache-push-backends` includes `attic`.                                |
| Substituters         | GitHub variable `SUBSTITUTERS` plus default cache URLs supplied to `mcl`                            | Used for Nix setup and cache-status checks.                                                 |
| Trusted public keys  | GitHub variable `TRUSTED_PUBLIC_KEYS`                                                               | Required for substituter trust on runners.                                                  |
| Results runner       | Workflow input `results-runner`, JSON default `["self-hosted", "nixos", "x86-64-v2", "bare-metal"]` | Keeps deploy orchestration on self-hosted runners by default.                               |
| Deploy token         | Removed in c056211 (`CACHIX_ACTIVATE_TOKEN` no longer passed to CI)                                 | There is no in-CI activation step; activation is out-of-band.                               |
| Cache push token     | Secret `ATTIC_TOKEN`                                                                                | Used by Attic cache pushes and cache-status checks; `CACHIX_AUTH_TOKEN` removed in c056211. |
| Source access tokens | `NIX_GITHUB_TOKEN`, `NIX_GITLAB_TOKEN`, `NIX_GITLAB_DOMAIN`                                         | Used by Nix access-token setup.                                                             |
| Health checks        | Not modeled in the reusable workflow                                                                | Future events should model check command, timeout, attempts, and result.                    |

## Historical Cachix Deploy Monitoring Path

The monitoring path that observed Cachix Deploy has been retired together with
the rest of the Cachix Deploy flow. The in-repo NixOS module, package, and D
exporter were removed; the only remaining source is the infrastructure service
definition:

- `metacraft-labs/infra/services/monitoring/cachix-deploy-metrics/default.nix`

That infrastructure service enabled `services.cachix-deploy-metrics`. Its
configuration bound the exporter on all addresses, read the Cachix API token
through `auth-token-path`, passed a Cachix Deploy `workspace`, and derived
`agent-names` from the server machine directories under the infrastructure tree.
Concrete private workspace and host names are recorded only in
[private-inventory.md](private-inventory.md).

`services.cachix-deploy-metrics` was a Prometheus exporter: it ran with
`--port`, `--bind-addresses`, `--scrape-interval`, `--auth-token-path`,
`--workspace`, and `--agent-names`, then served Prometheus text format at
`/metrics` on default port `9160` with a one-second scrape interval. It read the
token from `--auth-token` or `--auth-token-path`, then polled the Cachix Deploy
API endpoint `https://app.cachix.org/api/v1/deploy/agent/<workspace>/<agent>`
and mapped the API `lastDeployment` state into these metrics:

- `cachix_deploy_status`
- `cachix_deploy_counter`
- `cachix_deploy_last_started_time`
- `cachix_deploy_last_finished_time`
- `cachix_deploy_in_progress_duration_seconds`

That path observed Cachix Deploy API state for the last deployment per agent. It
never consumed the deployment event stream, target journald,
switch-to-configuration logs, health-check output, rollback evidence, or a
cross-system correlation id, which is why later milestones rely on event and
desired-state status artifacts rather than that exporter.

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
