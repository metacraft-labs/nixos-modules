# Shared Terraform CI groundwork

Company-agnostic tooling for the Terraform _operating layer_ every consumer
repo needs to drive infrastructure through the reusable CI workflow
(`.github/workflows/reusable-terraform-ci.yml`). Consumers supply their own
roots, backends, credentials, and identifiers; this directory ships only the
reusable discovery/validation machinery.

## `terraform-ci-matrix`

Discovers managed Terraform roots (any directory under `terraform/` holding a
`metadata.json`), validates each against the shared contract, and emits the
GitHub Actions matrix a repo's thin `terraform.yml` caller feeds into the
reusable workflow.

Unlike a company-specific generator, it hardcodes **no** provider names,
credential paths, or per-root smoke tests — everything comes from each root's
`metadata.json`. A root can be added before its CI keys exist: `agenix-token`
credentials are only emitted once the referenced encrypted secrets are present.

```bash
terraform-ci-matrix --root-dir . --pretty            # local troubleshooting
terraform-ci-matrix --github-output "$GITHUB_OUTPUT" # writes matrix=<json>
```

## `metadata.json` contract

Each managed root carries a `metadata.json` validated against
[`metadata.schema.json`](./metadata.schema.json). Required: `state_key`,
`state_sensitivity` (`standard` | `sensitive`), `backend_config_file`,
`credential_mode` (`aws-oidc` | `agenix-token` | `none`), `enable_checkov`,
`provider_allowlist`. `agenix-token` roots also require `credentials_env_name`
and `agenix_{plan,apply}_secret_path`. Optional: `smoke_test_command`,
`split_boundary` (prose; see the root-layering runbook).

The one fixed rule: the state key must match its sensitivity —
`terraform/<config>.tfstate` for `standard`, `terraform-sensitive/<config>.tfstate`
for `sensitive`, where `<config>` is the root path minus the leading
`terraform/`. This keeps sensitive state on an auditable key prefix.

## Tests

`tests/test-matrix.sh` covers discovery and negative validation offline (no
credentials, no network).
