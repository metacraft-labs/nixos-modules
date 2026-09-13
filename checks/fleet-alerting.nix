_top@{ ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving RE1 gate: t_fleet_alerting.
  #
  # Proves the GARM runner-fleet alert-rule library (../modules/garm-fleet-alerts)
  # is VALID and FIRES for every runner-chain failure mode, with fault-injection
  # tests — WITHOUT the infra repo. It renders the default-threshold rules
  # (packages.garm-fleet-alert-rules), then runs:
  #
  #   promtool check rules   — the rules parse + are structurally valid.
  #   promtool test rules    — each alert fires on a replayed incident and stays
  #                            silent through a transient (../modules/garm-fleet-alerts/
  #                            tests/fleet-alerting.test.yml).
  #
  # This is the same promtool contract infra's `just check-alert-rules` uses, so
  # a rule that is unfirable-by-construction (the deployment-events failure mode)
  # cannot land here either.
  perSystem =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      rules = config.packages.garm-fleet-alert-rules;
      testFile = ../modules/garm-fleet-alerts/tests/fleet-alerting.test.yml;
      # promtool ships in the `cli` output of the prometheus derivation.
      promtool = "${pkgs.prometheus.cli}/bin/promtool";
    in
    {
      checks.t_fleet_alerting =
        pkgs.runCommand "t_fleet_alerting"
          {
            nativeBuildInputs = [ pkgs.prometheus.cli ];
          }
          ''
            set -euo pipefail
            fail() { echo "[t_fleet_alerting][FAIL] $1" >&2; exit 1; }

            # The unit-test file references the rules by the bare name
            # `garm-fleet-alerts.yml` (rule_files:), so co-locate both.
            cp ${rules}       garm-fleet-alerts.yml
            cp ${testFile}    fleet-alerting.test.yml

            echo "[t_fleet_alerting] promtool check rules"
            ${promtool} check rules garm-fleet-alerts.yml \
              || fail "promtool check rules rejected the library"

            echo "[t_fleet_alerting] promtool test rules (fault injection)"
            ${promtool} test rules fleet-alerting.test.yml \
              || fail "a fault-injection unit test did not fire/stay-silent as asserted"

            # Guard against silent shrinkage: every failure mode the gate names
            # must have an alert. (13 alerts + 5 recording rules: 2 capacity +
            # 3 RC5 over-provision.)
            for a in GarmControllerDown GarmControllerUnhealthy GarmPoolManagerNotRunning \
                     GarmProviderCreateFailures GarmProviderHighErrorRatio \
                     GarmGithubRateLimitLow GarmGithubRateLimitCritical GarmFleetStarvation \
                     GarmFleetOverProvision \
                     GithubAppTokenMintFailing GithubWebhookDeliveryFailing \
                     GithubWebhookEndpointProbeDown GarmWebhookHmacFailures; do
              grep -q "alert: $a" garm-fleet-alerts.yml || fail "alert $a missing from the library"
            done

            echo "[t_fleet_alerting][PASS] library valid; all fault-injection tests fire/stay-silent as asserted"
            touch $out
          '';
    };
}
