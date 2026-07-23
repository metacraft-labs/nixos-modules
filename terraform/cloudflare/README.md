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

## Import blocks are per-repo

Unlike GitHub governance, the Cloudflare **adoption set is inherently per-repo
data** — each org's zones, DNS records, Pages projects, and R2 buckets differ.
So there is no shared Cloudflare import-block generator: each infra repo commits
its reviewed `terraform/cloudflare/<name>-prod/inventory.md` and generates its
own `imports.tf` from it (kept under `.result/`, never committed — see the
[import-phase methodology](../../docs/Terraform-Import-Phase.md)). Only the
inventory tool and the methodology are shared.
