# Terraform Import / Adoption Phase

Company-agnostic methodology for adopting **existing** infrastructure into
Terraform without recreating it — the one-time "import phase" every infra repo
goes through before steady-state management. It complements the
[bootstrap runbook](./Terraform-Bootstrap-Runbook.md) (which stands up Layer 0
from nothing) and the
[methodology](./Terraform-Agent-Development-Methodology.md): bootstrap creates
net-new state/roles; the import phase brings **already-existing** org resources
(GitHub repos/teams/settings, Cloudflare zones/DNS/R2, …) under management.

The guiding principle: **inventory with read-only credentials, model the
reviewed reality as data, generate import blocks with no credentials, prove the
plan is import-only, then apply once.** Steady-state changes afterward use the
normal PR/plan/apply workflow.

## The ladder (M0 → M7)

Each stage is gated on the previous one. Stages M1 and M6 are the only ones that
touch credentials; everything in between is offline and reviewable in a PR.

### M0 — Boundary and change freeze

Pick the exact resource surface to adopt (one provider/root at a time) and
freeze manual changes to it while the import is in flight. Record who holds the
operator credentials and which account/org owns the state backend. Adoption is
per-root: do GitHub governance and Cloudflare as separate passes.

### M1 — Read-only inventory _(credentials)_

Run the shared inventory tool with **read-only** operator credentials to capture
the live state. Output is raw JSON plus a redacted human-readable summary under
`.result/` (never committed); secret **values** are never read — only names and
metadata.

```bash
# GitHub (needs gh auth or GITHUB_TOKEN with org read)
GITHUB_OWNER=<org> "${nixos-modules-tf}/terraform/github/github-inventory" --owner <org> --all-repos
# Cloudflare (needs CLOUDFLARE_API_TOKEN or `--login`)
CF_ZONES="<zone-a> <zone-b>" "${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --account-id <id>
```

Review the redacted `inventory.md` — this is the human checkpoint that decides
what is in scope.

### M2 — Reviewed data model

Translate the reviewed inventory into a **committed data model** in the repo:

- GitHub: `bootstrap/github/<org>-governance-prod/governance.nix` — the repos,
  teams, memberships, branch protection, Environments, Actions permissions and
  variables, and labels to manage. Feeds the shared
  [`governance.nix` engine](../terraform/github/README.md).
- Cloudflare: `terraform/cloudflare/<name>-prod/inventory.md` — the reviewed
  zones/DNS/Pages/R2 adoption set (Cloudflare's adoption set is inherently
  per-repo data).

Anything intentionally left out is recorded as **deferred** so the exclusion is
explicit, not an oversight.

### M3 — Secret backup and rotation

Before importing secret resources, back up and (where policy requires) rotate the
underlying credentials into agenix `.age` files. Secret **values** never enter
Terraform state as plaintext — only GitHub-encrypted payloads (M4). See the
per-repo secret manifest (`secrets/manifest.nix`) and the
[secret-rotation methodology](./GitHub-Secret-Rotation.md).

### M4 — Encrypted payload rendering

Render the GitHub-encrypted (libsodium sealed-box) payloads from the `.age`
sources with `github-governance-secrets-render`, producing the
`secrets/payloads.generated.nix` + `secrets/managed.generated.nix` the engine
consumes. This keeps plaintext out of state and out of the process table.

### M5 — Generate import blocks _(no credentials)_

Generate credential-free `import {}` blocks from the reviewed data model:

```bash
"${nixos-modules-tf}/terraform/github/github-governance-import-blocks" \
  --owner <org> --root-config github/<org>-governance-prod \
  --root-dir "$PWD" --scope all
```

The output lands in `.result/bootstrap/github/<org>-governance-prod/imports.tf`
and is **never committed** — its presence would make OpenTofu's mocked test
context attempt provider imports, breaking offline tests. Each root's
`IMPORTS.md` documents the resource-class-by-resource-class import IDs and an
imperative `tofu import` fallback.

### M6 — Import-only apply _(credentials, gated)_

Run the protected apply path (CI `workflow_dispatch` or the `just` target). The
shared `github-governance-import-ci` harness **refuses any plan that is not
import-only** — it requires ≥1 import action and exactly 0 add/change/destroy/
replace, and (for apply) a typed confirmation. This is the safety property that
makes the import phase a true no-op adoption: state changes, reality does not.

The only permitted non-import creates are the governance-app org secrets
(`GH_GOVERNANCE_APP_*`), bootstrapped separately via
`just github-governance-app-secrets-apply`.

### M7 — Drift detection and steady state

Once imported, enable scheduled drift detection (the DRIFT role/plan) and switch
to the normal workflow: changes land as PRs, plan on PR, apply on merge through
the `production` Environment. The import blocks are not needed again unless you
adopt a new resource class — regenerate on demand.

## Why import blocks are never committed

The generated `imports.tf` lives only under `.result/` (gitignored). The
adoption is a one-time bootstrap enforced by **process** (the import-only apply
gate), not by committing then deleting files. This keeps the repo's offline
`tofu test` clean, because mocked test runs would otherwise try to import.

## What is shared vs per-repo

| Piece                                                                                       | Where                                                   |
| ------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| Inventory tools, GitHub import-block generator, CI import harness                           | shared — `nixos-modules/terraform/{github,cloudflare}/` |
| This methodology + root-layering                                                            | shared — `nixos-modules/docs/`                          |
| `governance.nix` data model, `inventory.md`, `IMPORTS.md`, secret manifest, `.age` material | per-repo (the org's reviewed reality)                   |

Cloudflare's import-block set is inherently per-repo data (each org's zones and
accounts differ), so only the Cloudflare **inventory** tool is shared; each repo
generates its own Cloudflare import blocks from its reviewed `inventory.md`.
