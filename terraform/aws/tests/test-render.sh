#!/usr/bin/env bash
# Renders the example caller and checks the bootstrap produces the expected
# Layer-0 resources. Offline (Nix eval only); no AWS credentials.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../example.nix")"
need=(aws_s3_bucket aws_dynamodb_table aws_iam_openid_connect_provider aws_iam_role)
fail=0
for t in "${need[@]}"; do
  n="$(jq --arg t "$t" '.resource[$t] | length' <<<"$json")"
  [[ "$n" -ge 1 ]] || { echo "FAIL: expected resource $t"; fail=1; }
done
# No real-account leakage from the example.
# The example must render only placeholder identifiers — flag any 12-digit AWS
# account id other than the 000000000000 placeholder (no real value embedded here).
if jq -e '.. | strings | select(test("[0-9]{12}") and (contains("000000000000") | not))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi
[[ "$fail" == 0 ]] && echo "OK: tf-bootstrap example renders expected Layer-0 resources" || exit 1
