# Shared Cloudflare Terraform library

Company-agnostic tooling for adopting and managing Cloudflare via
Terraform/OpenTofu. Consumers supply their own zones, accounts, and reviewed
adoption set; this directory ships only the reusable inventory tool. See the
[import-phase methodology](../../docs/Terraform-Import-Phase.md).

## `cloudflare-inventory` — read-only inventory

Captures the live Cloudflare state (zones, DNS, Pages projects/domains, R2
buckets, account-scoped resources) into `.result/` as raw JSON plus a redacted
Markdown inventory. Read-only (GET only); never prints credentials.

```bash
# API token (preferred)
CLOUDFLARE_API_TOKEN=… CF_ZONES="example.com example.dev" \
  "${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --account-id <id>

# or interactive Wrangler login
"${nixos-modules-tf}/terraform/cloudflare/cloudflare-inventory" --login --zone example.com
```

Nothing is hardcoded: pass `--zone` (repeatable) or `CF_ZONES`, `--account-id`
(repeatable) or `CF_ACCOUNT_ID`, `--all-zones` for every accessible zone, and
`CF_WRANGLER_CMD` / `CF_WRANGLER_SCOPES` to tune the Wrangler fallback.

## `cloudflare-import-blocks` — shared import-block generator

Emits credential-free `import {}` blocks for a Cloudflare root from the root's
reviewed **import-id data model**, `terraform/cloudflare/<name>-prod/import-ids.json`:

```json
{
  "version": 1,
  "imports": [
    { "to": "cloudflare_dns_record.this[\"apex\"]", "id": "<zone_id>/<record_id>" },
    { "to": "cloudflare_r2_bucket.this[\"downloads\"]", "id": "<account_id>/downloads/default" }
  ]
}
```

```bash
"${nixos-modules-tf}/terraform/cloudflare/cloudflare-import-blocks" \
  --config cloudflare/<name>-prod --root-dir "$PWD" --scope all   # or dns|pages|r2|workers
```

Output lands in `.result/terraform/cloudflare/<name>-prod/imports.tf` and is
**never committed** (committed blocks make OpenTofu's mocked `tofu test` attempt
real imports). The **adoption set is per-repo data** — each org's zones, DNS
records, Pages projects, and R2 buckets differ — so `import-ids.json` lives in
the repo, but the **generator is shared** (engine/config split, mirroring GitHub
governance).

## `cloudflare-import-ci` — shared import-only apply harness

The `plan|apply` harness that the dispatchable `cloudflare-import.yml` workflow
runs: renders the Terranix root, regenerates the import blocks into `.result/`,
`tofu init` against the S3 backend, plans with `-detailed-exitcode`, counts
import/add/change/destroy/replace, and **refuses any plan that is not
import-only** (≥1 import, 0 of everything else). `apply` mode additionally
requires the typed confirmation `apply-reviewed-imports`. Company-agnostic: the
root/config/backend/token come from the environment. See the
[import-phase methodology](../../docs/Terraform-Import-Phase.md).
