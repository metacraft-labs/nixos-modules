#!/usr/bin/env bash
# Renders the governance example and checks the engine produces the expected
# github_* resources and outputs. Offline (Nix eval only); no credentials.
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
json="$(nix eval --json --impure --expr "import ${here}/../governance.example.nix")"
fail=0

# Core governance resources the example models.
need=(
  github_actions_organization_permissions
  github_repository
  github_branch_default
  github_team_repository
  github_branch_protection
  github_repository_environment
  github_actions_repository_permissions
  github_actions_variable
  github_issue_label
  github_membership
)
for t in "${need[@]}"; do
  n="$(jq --arg t "$t" '.resource[$t] | length' <<<"$json")"
  [[ "$n" -ge 1 ]] || { echo "FAIL: expected resource $t"; fail=1; }
done

# The team data source is emitted for the granted team.
[[ "$(jq '.data.github_team | length' <<<"$json")" -ge 1 ]] || { echo "FAIL: expected github_team data source"; fail=1; }

# Manifest counting output is wired through.
[[ "$(jq '.output.secret_manifest_count.value' <<<"$json")" == "1" ]] || { echo "FAIL: secret_manifest_count"; fail=1; }
# The declared-but-unmanaged secret renders no secret resource and needs no payload.
[[ "$(jq 'has("github_actions_organization_secret") | not' <<<"$(jq .resource <<<"$json")")" == "true" ]] \
  || { echo "FAIL: unexpected managed secret resource without payload"; fail=1; }

# No company literals leak from the example.
if jq -e '.. | strings | select(test("agent-harbor|555209622233"))' <<<"$json" >/dev/null 2>&1; then
  echo "FAIL: example rendered company-specific literals"; fail=1
fi

[[ "$fail" == 0 ]] && echo "OK: governance example renders expected github_* resources" || exit 1
