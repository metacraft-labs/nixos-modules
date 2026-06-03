top@{ config, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      rehearsal = top.config.flake.lib.deploymentIncusRehearsal;
      repoRoot = ../.;
      topology = "${repoRoot}/tests/deployment/incus-topology-example.json";
      image = rehearsal.mkDeploymentRehearsalImage {
        inherit pkgs;
        name = "generic-target";
        role = "target";
        targetGroup = "home-lab-gpu";
        networks = [
          "control"
          "cache"
          "home-lab"
        ];
        avahi = true;
        manifestText = builtins.toJSON {
          schemaVersion = 1;
          role = "target";
          targetGroup = "home-lab-gpu";
          avahi = true;
        };
      };
      scriptPath = "${repoRoot}/scripts/deployment-incus-rehearsal.sh";
      scenarios = [
        "full-topology"
        "full-topology-failures"
        "offline-latest-only"
        "forced-command"
        "pull-agent"
      ];
      runtimePath = lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.jq
        pkgs.nix
        pkgs.python3
        pkgs.time
      ];
    in
    {
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-incus-rehearsal-image = image;
      };

      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-incus-rehearsal-script-static =
          pkgs.runCommand "deployment-incus-rehearsal-script-static" { }
            ''
                export PATH=${runtimePath}:$PATH
                export MCL_DEPLOYMENT_INCUS_TOPOLOGY=${topology}
                export MCL_DEPLOYMENT_INCUS_RUNTIME_PROBE_TIMEOUT=1
                export MCL_DEPLOYMENT_INCUS_SYSTEM=${pkgs.stdenv.hostPlatform.system}

              bash -n ${scriptPath}

              for scenario in ${lib.concatStringsSep " " scenarios}; do
                bash ${scriptPath} "$scenario" --check-env
                bash ${scriptPath} "$scenario" --dry-run > "$scenario.dry-run"
                grep -q "deployment-incus-rehearsal: scenario=$scenario" "$scenario.dry-run"
                grep -q "forcedCommandPrincipal=mcl-deploy-rehearsal" "$scenario.dry-run"
                grep -q "manifestPrincipal=mcl-deployment-rehearsal" "$scenario.dry-run"
                grep -q "home-lab-gpu" "$scenario.dry-run"
                grep -q "hetzner" "$scenario.dry-run"
                grep -q "workstation" "$scenario.dry-run"

                set +e
                bash ${scriptPath} "$scenario" > "$scenario.run.out" 2> "$scenario.run.err"
                status=$?
                set -e
                test "$status" -eq 69
                grep -q "pending-runtime" "$scenario.run.err"
              done

              set +e
              bash ${scriptPath} full-topology --check-runtime > check-runtime.out 2> check-runtime.err
              status=$?
              set -e
              test "$status" -eq 69
              grep -q "pending-runtime" check-runtime.err

              python3 - <<'PY'
              import json
              from pathlib import Path

              topology = json.loads(Path("${topology}").read_text())
              roles = topology["roles"]
              networks = {network["name"] for network in topology["networks"]}
              scenarios = {scenario["name"] for scenario in topology["scenarios"]}

              required_networks = {"control", "cache", "home-lab", "hetzner", "workstation"}
              assert required_networks <= networks, networks
              assert {
                  "full-topology",
                  "full-topology-failures",
                  "offline-latest-only",
                  "forced-command",
                  "pull-agent",
              } <= scenarios, scenarios

              by_group = {}
              for role in roles:
                  by_group.setdefault(role.get("targetGroup"), []).append(role)
                  role_networks = set(role["networks"])
                  assert role_networks <= networks, role
                  if role.get("targetGroup") in {"home-lab-gpu", "solunska"}:
                      assert role["avahi"] is True, role
                      assert "home-lab" in role_networks, role
                  if role.get("targetGroup") in {"hetzner", "workstation"}:
                      assert role["avahi"] is False, role
                  if role.get("targetGroup") == "hetzner":
                      assert "hetzner" in role_networks, role
                  if role.get("targetGroup") == "workstation":
                      assert "workstation" in role_networks, role

              assert by_group["home-lab-gpu"], by_group
              assert by_group["solunska"], by_group
              assert by_group["hetzner"], by_group
              assert by_group["workstation"], by_group
              assert any(role["role"] == "orchestrator" for role in roles), roles
              assert any(role["role"] == "attic-cache" for role in roles), roles
              assert any(role["role"] == "monitoring" for role in roles), roles

              controls = {
                  scenario["name"]: " ".join(scenario["controls"]).lower()
                  for scenario in topology["scenarios"]
              }
              required_controls = {
                  "full-topology": [
                      "runner",
                      "attic",
                      "monitoring",
                      "hetzner",
                      "workstation",
                      "deploy",
                  ],
                  "full-topology-failures": [
                      "partition",
                      "missing cache",
                      "invalid",
                      "signature",
                      "switch failure",
                      "health-check failure",
                      "rollback",
                      "lock contention",
                  ],
                  "offline-latest-only": [
                      "deployment 41",
                      "deployment 42",
                      "offline",
                      "only deployment 42 applies",
                  ],
                  "forced-command": [
                      "arbitrary shell",
                      "rejected",
                      "signed manifest",
                      "signature",
                  ],
                  "pull-agent": [
                      "signed manifests",
                      "partition",
                      "newer desired state",
                      "latest",
                  ],
              }
              for scenario, tokens in required_controls.items():
                  text = controls[scenario]
                  missing = [token for token in tokens if token not in text]
                  assert not missing, (scenario, missing, text)
              PY

              touch "$out"
            '';
      };
    };
}
