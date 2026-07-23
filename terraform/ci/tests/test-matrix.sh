#!/usr/bin/env bash
# Self-contained tests for terraform-ci-matrix (positive discovery + negative
# validation). No credentials or network required.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
matrix="${here}/../terraform-ci-matrix"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

mkroot() { mkdir -p "$tmp/$1"; cat > "$tmp/$1/metadata.json"; }

# Two valid roots.
mkroot terraform/github/governance <<'J'
{ "state_key":"terraform/github/governance.tfstate","state_sensitivity":"standard",
  "backend_config_file":"backends/gh.hcl","credential_mode":"agenix-token",
  "credentials_env_name":"GITHUB_TOKEN","agenix_plan_secret_path":"a.age","agenix_apply_secret_path":"b.age",
  "enable_checkov":false,"provider_allowlist":["integrations/github"] }
J
mkroot terraform/aws/prod <<'J'
{ "state_key":"terraform/aws/prod.tfstate","state_sensitivity":"standard","backend_config_file":"backends/aws.hcl",
  "credential_mode":"aws-oidc","enable_checkov":true,"provider_allowlist":["hashicorp/aws"] }
J
out="$("$matrix" --root-dir "$tmp")"
n="$(jq '.include | length' <<<"$out")"
[[ "$n" == "2" ]] || { echo "FAIL: expected 2 roots, got $n"; fail=1; }
jq -e '.include[] | select(.root=="terraform/aws/prod") | .uses_aws_oidc == true' <<<"$out" >/dev/null \
  || { echo "FAIL: aws root should set uses_aws_oidc"; fail=1; }

# Invalid: state_key does not match sensitivity naming rule.
badtmp="$(mktemp -d)"; mkdir -p "$badtmp/terraform/x/y"
cat > "$badtmp/terraform/x/y/metadata.json" <<'J'
{ "state_key":"wrong.tfstate","state_sensitivity":"standard","backend_config_file":"b.hcl",
  "credential_mode":"none","enable_checkov":false,"provider_allowlist":["hashicorp/aws"] }
J
if "$matrix" --root-dir "$badtmp" >/dev/null 2>&1; then echo "FAIL: bad state_key should exit non-zero"; fail=1; fi
rm -rf "$badtmp"

[[ "$fail" == "0" ]] && echo "OK: terraform-ci-matrix tests passed" || exit 1
