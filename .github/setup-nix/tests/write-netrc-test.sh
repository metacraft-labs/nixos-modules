#!/usr/bin/env bash
# Contract test for write-netrc.sh — the credential path that makes a
# `type = "git"` private flake input fetchable.
#
# It exercises the REAL script (via SETUP_NIX_NETRC_HOME) rather than a copy of
# its logic. That matters: a test that re-implements the netrc writing would
# pass whatever the action actually does, which is the defect class this suite
# exists to catch.
#
# The load-bearing assertion is the NEGATIVE one. Every check here would still
# pass if the script wrote the credential to the wrong path, so §3 pins the
# path git actually reads (~/.netrc) separately from the path Nix reads
# ($HOME/.config/nix/netrc), and §5 proves the test can fail at all.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$script_dir/write-netrc.sh"
failures=0

check() { # check <description> <condition-exit-code>
  if [[ "$2" -eq 0 ]]; then
    echo "  ok:   $1"
  else
    echo "  FAIL: $1"
    failures=$((failures + 1))
  fi
}

echo "write-netrc-test: exercising $target"

# ── §1 with a token: both files gain exactly one github.com stanza ──────────
home1="$(mktemp -d)"
SETUP_NIX_NETRC_HOME="$home1" SETUP_NIX_GITHUB_TOKEN="tok-secret-1" \
  bash "$target" >/dev/null 2>&1
rc=$?
check "runs successfully when a token is supplied" "$rc"

grep -qE '^[[:space:]]*machine[[:space:]]+github\.com' "$home1/.netrc" 2>/dev/null
check "writes the github.com stanza to ~/.netrc (the file GIT reads)" $?

grep -q 'tok-secret-1' "$home1/.netrc" 2>/dev/null
check "the token reaches ~/.netrc" $?

grep -q 'tok-secret-1' "$home1/.config/nix/netrc" 2>/dev/null
check "the token also reaches Nix's netrc ($HOME/.config/nix/netrc)" $?

# ── §2 permissions: a world-readable credential is a finding, not a detail ──
for f in "$home1/.netrc" "$home1/.config/nix/netrc"; do
  perms="$(stat -c '%a' "$f" 2>/dev/null)"
  [[ "$perms" == "600" ]]
  check "$(basename "$f") is mode 600 (was: ${perms:-missing})" $?
done

# ── §3 idempotence: running twice must not append a second stanza ───────────
SETUP_NIX_NETRC_HOME="$home1" SETUP_NIX_GITHUB_TOKEN="tok-secret-1" \
  bash "$target" >/dev/null 2>&1
count="$(grep -cE '^[[:space:]]*machine[[:space:]]+github\.com' "$home1/.netrc" 2>/dev/null)"
[[ "$count" == "1" ]]
check "a second run leaves exactly one stanza (got: ${count:-0})" $?

# ── §4 without a token: nothing is written, and it does NOT fail the job ────
home2="$(mktemp -d)"
SETUP_NIX_NETRC_HOME="$home2" SETUP_NIX_GITHUB_TOKEN="" \
  bash "$target" >/dev/null 2>&1
rc=$?
check "succeeds (does not fail the job) when no token is supplied" "$rc"

if [[ -e "$home2/.netrc" ]]; then
  ! grep -qE 'machine[[:space:]]+github\.com' "$home2/.netrc" 2>/dev/null
  check "writes no github.com stanza without a token" $?
else
  check "writes no github.com stanza without a token" 0
fi

# ── §5 NEGATIVE CONTROL: prove these assertions can fail ────────────────────
# Break the one thing that matters — the path git reads — and require the §1
# check to reject it. Without this, every assertion above could be vacuous.
home3="$(mktemp -d)"
broken="$(mktemp)"
sed 's|"\$home/\.netrc" "\$home/\.config/nix/netrc"|"$home/.config/nix/netrc"|' "$target" > "$broken"
if ! grep -q 'home/.netrc' "$broken"; then
  SETUP_NIX_NETRC_HOME="$home3" SETUP_NIX_GITHUB_TOKEN="tok-secret-3" \
    bash "$broken" >/dev/null 2>&1
  ! grep -qE 'machine[[:space:]]+github\.com' "$home3/.netrc" 2>/dev/null
  check "CONTROL: a variant that skips ~/.netrc is detected by the §1 check" $?
else
  check "CONTROL: mutation helper actually removed ~/.netrc from the target list" 1
fi
rm -f "$broken"
rm -rf "$home1" "$home2" "$home3"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "write-netrc-test: PASS"
  exit 0
fi
echo "write-netrc-test: FAIL ($failures check(s))"
exit 1
