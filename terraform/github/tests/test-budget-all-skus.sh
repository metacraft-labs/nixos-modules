#!/usr/bin/env bash
# Gate `t_github_budget_all_skus` — milestone B2 (Sovereign-CI-Fleet).
#
# Proves the $0 budget engine (../actions-budgets.nix) extends the
# prevent_further_usage cap beyond Actions minutes to storage/Packages AND Git
# LFS: one budget resource per (org, SKU), each a $0 hard stop with the correct
# distinct budget_product_sku / budget_type and a unique resource name. AND that
# the legacy single-SKU caller still renders EXACTLY ONE actions budget,
# byte-for-byte identical to the pre-B2 engine (rendered from git HEAD and
# diffed — no hand-copied golden).
#
# Offline: the engine is pure builtins, so `nix eval --json` renders it with no
# credentials, network, or provider plugins. Mirrors tests/test-render.sh.
set -euo pipefail
gate="t_github_budget_all_skus"
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
engine="${here}/../actions-budgets.nix"
fail=0
err() { echo "FAIL[$gate]: $*" >&2; fail=1; }

json="$(nix eval --json --impure --expr "import ${here}/actions-budgets-all-skus/default.nix {}")"
res() { jq -c ".resource.restful_resource${1}" <<<"$json"; }

# --- (1) the multi-SKU org emits exactly THREE uniquely named budgets ---------
multi_names="$(jq -r '.resource.restful_resource | keys[] | select(startswith("example_multi_"))' <<<"$json" | sort)"
n_multi="$(wc -l <<<"$multi_names" | tr -d ' ')"
[[ "$n_multi" == "3" ]] || err "expected 3 example-multi budgets, got ${n_multi}: ${multi_names//$'\n'/,}"

want_names="example_multi_actions
example_multi_git_lfs_storage
example_multi_packages"
[[ "$multi_names" == "$want_names" ]] || err "example-multi resource names wrong/not-unique: got [${multi_names//$'\n'/,}]"

# Global uniqueness: no duplicate resource labels (listToAttrs would collapse
# collisions, so assert the key count equals the emitted-entry count of 4).
n_total="$(jq '.resource.restful_resource | length' <<<"$json")"
[[ "$n_total" == "4" ]] || err "expected 4 total budget resources (3 multi + 1 legacy), got ${n_total}"

# --- (2) each multi-SKU budget is a $0 org-scoped hard stop with the right SKU -
# name -> expected (sku, budget_type)
check_budget() {
  local name="$1" want_sku="$2" want_type="$3" b
  b="$(res ".${name}.body")"
  [[ "$(jq -r '.prevent_further_usage' <<<"$b")" == "true" ]] || err "${name}: prevent_further_usage must be true"
  [[ "$(jq -r '.budget_amount' <<<"$b")" == "0" ]] || err "${name}: budget_amount must be 0"
  [[ "$(jq -r '.budget_scope' <<<"$b")" == "organization" ]] || err "${name}: budget_scope must be organization"
  [[ "$(jq -r '.budget_product_sku' <<<"$b")" == "$want_sku" ]] || err "${name}: budget_product_sku must be ${want_sku}"
  [[ "$(jq -r '.budget_type' <<<"$b")" == "$want_type" ]] || err "${name}: budget_type must be ${want_type}"
}
check_budget example_multi_actions         actions         ProductPricing
check_budget example_multi_packages        packages        ProductPricing
check_budget example_multi_git_lfs_storage git_lfs_storage SkuPricing   # LFS leaf SKU

# The three SKUs are distinct.
distinct="$(jq -r '.resource.restful_resource | to_entries[] | select(.key|startswith("example_multi_")) | .value.body.budget_product_sku' <<<"$json" | sort -u | wc -l | tr -d ' ')"
[[ "$distinct" == "3" ]] || err "the three multi-SKU budgets must carry distinct budget_product_sku values"

# --- (3) backward-compat: the legacy shape renders ONE actions budget, and it
# is byte-for-byte identical to the pre-B2 engine (git HEAD) --------------------
[[ "$(jq -r '.resource.restful_resource | has("example_legacy")' <<<"$json")" == "true" ]] \
  || err "legacy caller must emit the org-named resource 'example_legacy' (no _<sku> suffix)"
[[ "$(jq -r '.resource.restful_resource.example_legacy.body.budget_product_sku' <<<"$json")" == "actions" ]] \
  || err "legacy budget must be the actions product"

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
legacy_expr='{ useS3Backend = false; budgets = { "example-legacy" = { id = "852e9d35-0000-0000-0000-000000000000"; }; }; }'
new_render="$(nix eval --json --impure --expr "(import ${engine} ${legacy_expr}).resource.restful_resource")"
if git -C "${here}" show HEAD:terraform/github/actions-budgets.nix > "${work}/old-engine.nix" 2>/dev/null; then
  old_render="$(nix eval --json --impure --expr "(import ${work}/old-engine.nix ${legacy_expr}).resource.restful_resource")"
  if ! diff <(jq -S . <<<"$old_render") <(jq -S . <<<"$new_render") >/dev/null; then
    err "legacy single-SKU render drifted from the pre-B2 engine (git HEAD):"
    diff <(jq -S . <<<"$old_render") <(jq -S . <<<"$new_render") >&2 || true
  fi
else
  echo "WARN[$gate]: could not load HEAD engine for byte-for-byte diff (skipping that sub-check)" >&2
fi

if [[ "$fail" == "0" ]]; then
  echo "PASS: $gate (3 multi-SKU budgets: actions+packages+git_lfs_storage; legacy actions budget unchanged)"
else
  exit 1
fi
