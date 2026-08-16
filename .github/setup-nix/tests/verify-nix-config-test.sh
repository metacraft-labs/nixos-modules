#!/usr/bin/env bash
# Contract test for `.github/setup-nix/verify-nix-config.sh`.
#
# WHAT THIS PROVES, AND WHY IT IS NOT VACUOUS
# -------------------------------------------
# The defect being guarded against is an installer that no-ops on a runner where
# Nix is ALREADY present, reports success, and leaves `experimental-features`
# unapplied. A test that only exercised the healthy path would pass just as
# happily with no guard at all, which is the same "check reporting accurately
# about the wrong thing" failure the guard exists to end.
#
# So each negative case here does two things in order:
#
#   1. FIXTURE MUTATION CHECK — first prove the fixture genuinely reproduces the
#      defect, by running a plain `nix` command under it and requiring that the
#      command fails the way a real job step would. If the fixture cannot break
#      Nix, the case is declared broken rather than silently passing.
#   2. GUARD CHECK — only then require that verify-nix-config.sh exits non-zero.
#
# Without step 1, a change that made the fixture inert (say, Nix ignoring
# NIX_CONFIG) would turn every negative case into a green no-op.
#
# The suite additionally asserts that action.yml actually INVOKES the guard, so
# deleting the step from the action fails this test rather than quietly
# restoring the original silent-success behaviour.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
setup_nix_dir="$(cd -- "$script_dir/.." && pwd)"
guard="$setup_nix_dir/verify-nix-config.sh"
action_yml="$setup_nix_dir/action.yml"

assertions=0
failures=0

pass() {
  assertions=$((assertions + 1))
  echo "ok   — $*"
}

fail() {
  assertions=$((assertions + 1))
  failures=$((failures + 1))
  echo "FAIL — $*" >&2
}

[ -f "$guard" ] || {
  echo "FAIL — the guard script is missing: $guard" >&2
  echo "       verify-nix-config.sh is what makes this action verify, rather than" >&2
  echo "       merely assert, that the Nix configuration took effect." >&2
  exit 1
}
[ -f "$action_yml" ] || {
  echo "FAIL — action.yml is missing: $action_yml" >&2
  exit 1
}

if ! command -v nix >/dev/null 2>&1; then
  echo "FAIL — nix is not on PATH; this suite must run where a real Nix exists," >&2
  echo "       because it verifies real Nix behaviour rather than a mock of it." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. The action must actually invoke the guard.
# ---------------------------------------------------------------------------
# Match the INVOCATION, not any mention. A comment or an input description that
# merely names the script is not the action running it, and an assertion that
# accepted prose would be satisfied by an action that verifies nothing.
invocation_pattern='github.action_path }}/verify-nix-config.sh'
if grep -qF "$invocation_pattern" "$action_yml"; then
  pass "action.yml invokes verify-nix-config.sh"
else
  fail "action.yml does not invoke verify-nix-config.sh — the action would go back to reporting success without checking that its configuration applied"
fi

# The guard must run in the action AFTER nix.conf is written and BEFORE the
# first step that actually uses Nix (`Start Attic watch-store` runs `nix shell`).
# Otherwise the first casualty of a bad config is still an obscure error in an
# unrelated step.
configure_line="$(grep -n 'name: Configure Nix' "$action_yml" | head -n1 | cut -d: -f1 || true)"
verify_line="$(grep -nF "$invocation_pattern" "$action_yml" | head -n1 | cut -d: -f1 || true)"
attic_line="$(grep -n 'name: Start Attic watch-store' "$action_yml" | head -n1 | cut -d: -f1 || true)"
if [ -n "$configure_line" ] && [ -n "$verify_line" ] && [ -n "$attic_line" ] &&
  [ "$configure_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$attic_line" ]; then
  pass "the guard runs after 'Configure Nix' and before the first Nix-using step"
else
  fail "the guard is not ordered between 'Configure Nix' and 'Start Attic watch-store' (configure=$configure_line verify=$verify_line attic=$attic_line)"
fi

# ---------------------------------------------------------------------------
# 2. Healthy path — the guard must not cry wolf.
# ---------------------------------------------------------------------------
healthy_features="nix-command flakes"
if NIX_CONFIG="experimental-features = $healthy_features" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="$healthy_features" \
  bash "$guard" >/dev/null 2>&1; then
  pass "guard exits 0 when every requested experimental feature is in effect"
else
  fail "guard rejected a correctly configured Nix — it would block healthy jobs"
fi

# ---------------------------------------------------------------------------
# 2b. The guard must not be fooled by Nix writing WARNINGS to stderr.
#
# This case exists because the guard originally captured the probe with `2>&1`,
# folding Nix's warnings into the value it then compared against a literal. On
# the real `eph-*` runners the CI user is not in Nix's `trusted-users`, so every
# restricted setting in nix.conf emits a warning, the comparison failed, and a
# perfectly healthy runner was reported broken.
#
# A false alarm is not a harmless failure mode here: a guard that cries wolf
# gets disabled, and then the real defect it was added for goes back to being
# invisible. The healthy-path case above did not catch it because a quiet Nix
# emits nothing on stderr.
# ---------------------------------------------------------------------------
noisy_config="experimental-features = nix-command flakes
setup-nix-bogus-setting = 1"
noisy_probe=""
noisy_probe="$(NIX_CONFIG="$noisy_config" nix eval --raw --expr '"x"' 2>&1 >/dev/null || true)"
if [ -z "$noisy_probe" ]; then
  fail "FIXTURE BROKEN: the noisy fixture produced no stderr output, so it cannot prove the guard tolerates warnings"
else
  pass "fixture makes Nix emit a warning on stderr while the features still work"

  if NIX_CONFIG="$noisy_config" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes" \
    bash "$guard" >/dev/null 2>&1; then
    pass "guard tolerates Nix warnings on stderr instead of misreading them as the probe value"
  else
    fail "guard failed on a HEALTHY Nix that merely wrote a warning to stderr — a false alarm, which gets guards switched off"
  fi
fi

# ---------------------------------------------------------------------------
# 3. THE REGRESSION CASE — a pre-installed Nix with no experimental-features.
#
# This is the exact state `cachix/install-nix-action` leaves behind when it
# prints "Aborting: Nix is already installed" and exits 0.
# ---------------------------------------------------------------------------
broken_env_probe=""
if broken_env_probe="$(NIX_CONFIG="experimental-features =" nix eval --raw --expr '"x"' 2>&1)"; then
  fail "FIXTURE BROKEN: a plain 'nix eval' still succeeded with experimental-features cleared, so this case proves nothing. Guard result ignored."
else
  case "$broken_env_probe" in
    *"'nix-command' is disabled"*)
      pass "fixture reproduces the real defect (nix-command disabled on a pre-installed Nix)"
      ;;
    *)
      fail "FIXTURE BROKEN: 'nix eval' failed for an unexpected reason, not the disabled-feature one: $broken_env_probe"
      ;;
  esac

  if NIX_CONFIG="experimental-features =" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes" \
    bash "$guard" >/dev/null 2>&1; then
    fail "guard PASSED against a pre-installed Nix with no experimental-features — this is the whole defect, undetected"
  else
    pass "guard fails loudly on a pre-installed Nix with no experimental-features"
  fi
fi

# ---------------------------------------------------------------------------
# 4. The partial case — some requested features applied, others silently dropped.
#
# A coarse "can nix run at all" probe waves this through: nix-command and flakes
# work, so every smoke test looks fine, and only a pipe-operator expression far
# downstream fails.
# ---------------------------------------------------------------------------
partial_probe=""
partial_probe="$(NIX_CONFIG="experimental-features = nix-command flakes" nix config show experimental-features 2>&1 || true)"
if printf '%s' "$partial_probe" | tr ' ' '\n' | grep -qxF 'pipe-operators'; then
  fail "FIXTURE BROKEN: pipe-operators is still in effect under the partial fixture, so this case proves nothing"
else
  pass "fixture reproduces a partially applied feature set (pipe-operators absent)"

  if NIX_CONFIG="experimental-features = nix-command flakes" \
    SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command flakes pipe-operators" \
    bash "$guard" >/dev/null 2>&1; then
    fail "guard PASSED while a requested feature (pipe-operators) was not in effect"
  else
    pass "guard fails when only some requested features are in effect"
  fi
fi

# ---------------------------------------------------------------------------
# 5. The guard must not leak credentials.
#
# nix.conf carries `access-tokens`, so the failure diagnostics must report the
# presence of an override, never its value.
# ---------------------------------------------------------------------------
secret="ghp_setupnixcanarytokenvalue0000000000000"
guard_output="$(NIX_CONFIG="experimental-features =
access-tokens = github.com=$secret" \
  SETUP_NIX_REQUIRED_EXPERIMENTAL_FEATURES="nix-command" \
  bash "$guard" 2>&1 || true)"
if printf '%s' "$guard_output" | grep -qF "$secret"; then
  fail "guard printed a credential from NIX_CONFIG into its diagnostics"
else
  pass "guard diagnostics do not echo credentials from NIX_CONFIG"
fi

# ---------------------------------------------------------------------------
echo
echo "verify-nix-config-test: $assertions assertions, $failures failure(s)"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "verify-nix-config-test: PASS"
