_top@{ ... }:
{
  # Sovereign-CI-Fleet S2 gate: `t_runner_mode_manager`.
  #
  # Proves the managing service (`.github/workflows/reusable-manage-runner-mode.yml`)
  # decides the AUTHORITATIVE `CI_RUNNER_MODE` from an org's billing usage +
  # budget, FAIL-SAFE to self-hosted on any error, and emits the Prometheus
  # signals the alerting fleet pages on.
  #
  # HERMETIC: the test extracts the REAL `decide` and `metrics` run blocks from
  # the workflow (not copies) and drives them under `env -i` with a stub `gh`
  # that returns canned billing JSON (and a stub that FAILS, for the fail-safe
  # case). The only `gh` on PATH is the stub, and `env -i` strips the
  # environment, so a real network call cannot happen — a regression that
  # reached the live billing API would fail rather than pass.
  #
  # NON-TAUTOLOGICAL: each case pins the exact CI_RUNNER_MODE + failsafe flag
  # for a distinct billing shape, so the decision logic is load-bearing:
  #   * remove the fail-safe (case d error -> github-hosted) and (d)/(d2) flip;
  #   * remove the minutes buffer and (b) flips to github-hosted;
  #   * remove the budget check and (c) flips to github-hosted.
  # The metrics assertions pin the stuck-state dead-man's-switch: a successful
  # run advances last_success; a fail-safe run does not.
  perSystem =
    { pkgs, ... }:
    let
      manageWorkflow = ../.github/workflows/reusable-manage-runner-mode.yml;
      py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
    in
    {
      checks.t_runner_mode_manager =
        pkgs.runCommand "t_runner_mode_manager"
          {
            nativeBuildInputs = [
              py
              pkgs.bash
              pkgs.jq
              pkgs.gawk
              pkgs.gnugrep
              pkgs.coreutils
            ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_runner_mode_manager][FAIL] $1" >&2; exit 1; }

            # Extract the REAL decide + metrics run blocks and confirm the switch
            # is wired from billing secrets/inputs and plumbs its outputs through.
            python3 - <<'PY'
            import yaml
            from pathlib import Path
            wf = yaml.safe_load(open("${manageWorkflow}"))
            steps = wf["jobs"]["manage"]["steps"]
            decide = next(s for s in steps if s.get("id") == "decide")
            metrics = next(s for s in steps if s.get("id") == "metrics")
            env = decide["env"]
            # Billing read must come from the secret, org/thresholds from inputs.
            assert env.get("GH_TOKEN") == "${"$"}{{ secrets.billing_token }}", env.get("GH_TOKEN")
            assert env.get("MIN_REMAIN") == "${"$"}{{ inputs.min_minutes_remaining }}", env.get("MIN_REMAIN")
            assert env.get("MAX_BILLED") == "${"$"}{{ inputs.max_billed_amount }}", env.get("MAX_BILLED")
            # The written variable is the S1-authoritative CI_RUNNER_MODE.
            writestep = next(s for s in steps if "Write CI_RUNNER_MODE" in s.get("name", ""))
            assert "gh variable set CI_RUNNER_MODE" in writestep["run"], writestep["run"]
            # Outputs plumb decide -> job -> workflow_call.
            on = wf.get("on", wf.get(True))
            outs = on["workflow_call"]["outputs"]
            assert "jobs.manage.outputs.mode" in outs["mode"]["value"], outs["mode"]
            job_outs = wf["jobs"]["manage"]["outputs"]
            assert "steps.decide.outputs.mode" in job_outs["mode"], job_outs
            Path("decide.sh").write_text(decide["run"])
            Path("metrics.sh").write_text(metrics["run"])
            PY
            ${pkgs.bash}/bin/bash -n decide.sh  || fail "decide run block is not valid bash"
            ${pkgs.bash}/bin/bash -n metrics.sh || fail "metrics run block is not valid bash"

            # A stub `gh` = the ONLY network boundary. It dispatches on the API
            # path and returns canned billing JSON from env; MOCK_FAIL / the
            # per-endpoint MOCK_FAIL_USAGE make a call fail (unreachable), which
            # the decision must treat as fail-safe self-hosted.
            mkdir -p mockbin
            {
              printf '#!%s\n' "${pkgs.bash}/bin/bash"
              cat <<'SH'
            if [ -n "''${MOCK_FAIL:-}" ]; then
              echo "gh: simulated billing API failure" >&2
              exit 1
            fi
            case "$*" in
              *settings/billing/usage*)
                if [ -n "''${MOCK_FAIL_USAGE:-}" ]; then
                  echo "gh: simulated usage endpoint failure" >&2
                  exit 1
                fi
                printf '{"usageItems":[{"product":"Actions","sku":"Actions Linux","unitType":"minutes","quantity":%s,"netAmount":%s}]}\n' \
                  "''${MOCK_USED:-0}" "''${MOCK_BILLED:-0}"
                ;;
              *settings/billing/actions*)
                printf '{"included_minutes":%s,"total_minutes_used":%s}\n' \
                  "''${MOCK_INCLUDED:-3000}" "''${MOCK_USED:-0}"
                ;;
              variable\ set*)
                : # the write step is not exercised here.
                ;;
              *)
                echo "gh: unexpected call: $*" >&2
                exit 2
                ;;
            esac
            SH
            } > mockbin/gh
            chmod +x mockbin/gh
            export PATH="$PWD/mockbin:${pkgs.jq}/bin:${pkgs.gawk}/bin:${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:$PATH"

            # decide_case NAME EXPECT_MODE EXPECT_FAILSAFE <env assignments...>
            decide_case() {
              local name="$1" want_mode="$2" want_fs="$3"; shift 3
              local out; out="$(mktemp)"
              env -i \
                PATH="$PATH" \
                GITHUB_OUTPUT="$out" \
                ORG="metacraft-labs" \
                MIN_REMAIN="300" \
                INCLUDED_DEFAULT="3000" \
                MAX_BILLED="0" \
                "$@" \
                ${pkgs.bash}/bin/bash decide.sh >/dev/null 2>caselog \
                || { cat caselog >&2; fail "$name: decide exited non-zero"; }
              local got_mode got_fs
              got_mode="$(grep '^mode=' "$out" | tail -1 | cut -d= -f2-)"
              got_fs="$(grep '^failsafe=' "$out" | tail -1 | cut -d= -f2-)"
              [ "$got_mode" = "$want_mode" ] \
                || fail "$name: mode=$got_mode, wanted $want_mode"
              [ "$got_fs" = "$want_fs" ] \
                || fail "$name: failsafe=$got_fs, wanted $want_fs"
              echo "[t_runner_mode_manager][ok] $name -> CI_RUNNER_MODE=$got_mode (failsafe=$got_fs)"
            }

            # (a) healthy, plenty remaining, nothing billed -> github-hosted.
            decide_case "healthy-plenty" "github-hosted" "0" \
              MOCK_INCLUDED="3000" MOCK_USED="100" MOCK_BILLED="0"

            # (b) near exhaustion: remaining (200) below the 300 buffer -> self-hosted.
            decide_case "near-exhaustion" "self-hosted" "0" \
              MOCK_INCLUDED="3000" MOCK_USED="2800" MOCK_BILLED="0"

            # (c) over budget: plenty of minutes but billed 5 USD over the 0 cap
            #     -> self-hosted (budget dimension, independent of minutes).
            decide_case "over-budget" "self-hosted" "0" \
              MOCK_INCLUDED="3000" MOCK_USED="100" MOCK_BILLED="5"

            # (d) billing API unreachable -> fail-safe self-hosted.
            decide_case "billing-error" "self-hosted" "1" \
              MOCK_FAIL="1"

            # (d2) minutes endpoint OK but the enhanced usage endpoint fails ->
            #      still fail-safe self-hosted (the budget read is load-bearing).
            decide_case "usage-endpoint-error" "self-hosted" "1" \
              MOCK_INCLUDED="3000" MOCK_USED="100" MOCK_FAIL_USAGE="1"

            # (e) post-reset: allowance restored (used back to 0) -> github-hosted.
            decide_case "post-reset-plenty" "github-hosted" "0" \
              MOCK_INCLUDED="3000" MOCK_USED="0" MOCK_BILLED="0"

            # ---- Prometheus signals + stuck-state dead-man's-switch ----------
            run_metrics() {
              # run_metrics MODE REMAINING BILLED FAILSAFE TEXTFILE
              env -i PATH="$PATH" \
                ORG="metacraft-labs" \
                MODE="$1" REMAINING="$2" BILLED="$3" FAILSAFE="$4" \
                TEXTFILE="$5" PUSHGATEWAY_URL="" \
                ${pkgs.bash}/bin/bash metrics.sh >/dev/null 2>metricslog \
                || { cat metricslog >&2; fail "metrics exited non-zero"; }
            }
            tf="$PWD/ci-runner-mode.prom"

            # A successful github-hosted run writes the full series and advances
            # last_success to a non-zero timestamp.
            run_metrics "github-hosted" "2900" "0" "0" "$tf"
            grep -q '^ci_runner_mode_self_hosted{org="metacraft-labs"} 0$' "$tf" \
              || fail "metrics: missing/incorrect ci_runner_mode_self_hosted for github-hosted"
            grep -q '^ci_runner_mode{org="metacraft-labs",mode="github-hosted"} 1$' "$tf" \
              || fail "metrics: missing ci_runner_mode mode label"
            grep -q '^ci_runner_mode_included_minutes_remaining{org="metacraft-labs"} 2900$' "$tf" \
              || fail "metrics: missing remaining-minutes gauge"
            grep -q '^ci_runner_mode_failsafe_active{org="metacraft-labs"} 0$' "$tf" \
              || fail "metrics: failsafe flag should be 0 on a healthy run"
            good_ts="$(grep '^ci_runner_mode_last_success_timestamp_seconds' "$tf" | awk '{print $2}')"
            [ "$good_ts" -gt 0 ] 2>/dev/null \
              || fail "metrics: last_success timestamp must advance on a successful run (got '$good_ts')"
            echo "[t_runner_mode_manager][ok] metrics: healthy run wrote series, last_success=$good_ts"

            # A subsequent FAIL-SAFE run must NOT advance last_success (the stuck
            # signal) even though it rewrites the file with self-hosted=1.
            run_metrics "self-hosted" "-1" "-1" "1" "$tf"
            grep -q '^ci_runner_mode_self_hosted{org="metacraft-labs"} 1$' "$tf" \
              || fail "metrics: fail-safe run must record self_hosted=1"
            grep -q '^ci_runner_mode_failsafe_active{org="metacraft-labs"} 1$' "$tf" \
              || fail "metrics: fail-safe run must record failsafe_active=1"
            stuck_ts="$(grep '^ci_runner_mode_last_success_timestamp_seconds' "$tf" | awk '{print $2}')"
            [ "$stuck_ts" = "$good_ts" ] \
              || fail "metrics: fail-safe run advanced last_success ($stuck_ts != $good_ts) — stuck detection broken"
            echo "[t_runner_mode_manager][ok] metrics: fail-safe run held last_success=$stuck_ts (stuck-state dead-man switch)"

            echo "[t_runner_mode_manager][PASS] billing+budget resolve CI_RUNNER_MODE, fail-safe self-hosted, metrics + stuck signal emitted"
            touch $out
          '';
    };
}
