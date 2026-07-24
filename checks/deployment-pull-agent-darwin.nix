top@{ config, inputs, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      self',
      ...
    }:
    let
      flake = top.config.flake;
      manifestPrivateKey = pkgs.writeText "mcl-darwin-pull-agent-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
      stableEntrypoint = "/run/current-system/sw/bin/mcl-deploy-agent";

      fakeMcl =
        generation:
        pkgs.writeShellApplication {
          name = "mcl";
          text = ''
            if [[ -n "''${MCL_DARWIN_PREREQUISITE_MARKER:-}" ]]; then
              touch "$MCL_DARWIN_PREREQUISITE_MARKER"
            fi
            printf '%s\n' ${lib.escapeShellArg generation}
          '';
        };
      failingRuntimePrerequisite = pkgs.writeShellApplication {
        name = "mcl-deploy-runtime-prerequisite";
        text = "exit 75";
      };

      staticSystem =
        package:
        inputs.nix-darwin.lib.darwinSystem {
          system = pkgs.stdenv.hostPlatform.system;
          modules = [
            flake.modules.darwin.deployment-pull-agent
            {
              networking.hostName = "m3";
              system.stateVersion = 6;
              services.mcl-deploy-agent = {
                enable = true;
                inherit package;
                targetName = "m3";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestSources = [ "https://deployments.example.invalid/m3/latest.json" ];
                manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
                stateDir = "/var/lib/mcl/test-deployments";
                eventLog = "/var/log/mcl/deployments/test-agent.jsonl";
                standardOutLog = "/var/log/mcl/deployments/test-agent.stdout.log";
                standardErrorLog = "/var/log/mcl/deployments/test-agent.stderr.log";
                intervalSeconds = 421;
                lockFile = "/var/run/mcl-test-pull-agent.lock";
                maxAttempts = 5;
                fetchTimeoutSeconds = 11;
                systemProfile = "/nix/var/nix/profiles/system";
                preSwitchHook = "/run/current-system/sw/bin/mcl-deploy-pre-switch";
                postSwitchHook = "/run/current-system/sw/bin/mcl-deploy-post-switch";
                runtimePrerequisite = lib.getExe failingRuntimePrerequisite;
              };
            }
          ];
        };

      staticA = staticSystem (fakeMcl "generation-a");
      staticB = staticSystem (fakeMcl "generation-b");
      staticServiceA = staticA.config.launchd.daemons.mcl-deploy-agent.serviceConfig;
      staticServiceB = staticB.config.launchd.daemons.mcl-deploy-agent.serviceConfig;
      staticEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "Darwin pull-agent entrypoint package is absent from environment.systemPackages")
          staticA.config.environment.systemPackages;
      staticEntrypointPackageB =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "second Darwin pull-agent entrypoint package is absent from environment.systemPackages")
          staticB.config.environment.systemPackages;
      staticSystemEntrypoint = "${staticA.config.system.path}/bin/mcl-deploy-agent";
      staticSystemEntrypointB = "${staticB.config.system.path}/bin/mcl-deploy-agent";
      staticActivation = staticA.config.system.activationScripts.preActivation.text;
      prerequisiteRoot = "/tmp/mcl-darwin-pull-agent-prerequisite";
      prerequisiteSystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "m3-prerequisite";
            system.stateVersion = 6;
            services.mcl-deploy-agent = {
              enable = true;
              package = fakeMcl "prerequisite-must-not-run";
              targetName = "m3-prerequisite";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestSources = [ "https://deployments.example.invalid/m3/latest.json" ];
              stateDir = "${prerequisiteRoot}/state";
              eventLog = "${prerequisiteRoot}/events.jsonl";
              standardOutLog = "${prerequisiteRoot}/stdout.log";
              standardErrorLog = "${prerequisiteRoot}/stderr.log";
              lockFile = "${prerequisiteRoot}/agent.lock";
              runtimePrerequisite = lib.getExe failingRuntimePrerequisite;
            };
          }
        ];
      };
      prerequisiteEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "prerequisite Darwin pull-agent entrypoint package is absent")
          prerequisiteSystem.config.environment.systemPackages;

      disabledSystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "disabled-m3";
            system.stateVersion = 6;
          }
        ];
      };

      staticFailures = lib.flatten [
        (lib.optional (
          disabledSystem.config.launchd.daemons ? mcl-deploy-agent
        ) "Darwin pull agent is not disabled by default")
        (lib.optional (
          staticServiceA.ProgramArguments != [ stableEntrypoint ]
        ) "LaunchDaemon does not use the generation-stable entrypoint")
        (lib.optional (staticServiceA.UserName != "root") "LaunchDaemon is not explicitly root-owned")
        (lib.optional (
          staticServiceA.GroupName != "wheel"
        ) "LaunchDaemon is not assigned to the root wheel group")
        (lib.optional (staticServiceA.RunAtLoad != true) "LaunchDaemon does not poll at load")
        (lib.optional (staticServiceA.StartInterval != 421) "LaunchDaemon polling interval drifted")
        (lib.optional (
          staticServiceA.StandardOutPath != "/var/log/mcl/deployments/test-agent.stdout.log"
        ) "LaunchDaemon stdout is not durable")
        (lib.optional (
          staticServiceA.StandardErrorPath != "/var/log/mcl/deployments/test-agent.stderr.log"
        ) "LaunchDaemon stderr is not durable")
        (lib.optional (
          staticServiceA.Label != "org.metacraft-labs.mcl-deploy-agent"
        ) "LaunchDaemon label drifted")
        (lib.optional (
          staticServiceA != staticServiceB
        ) "generation-specific packages change the LaunchDaemon plist")
        (lib.optional (
          staticEntrypointPackage == staticEntrypointPackageB
        ) "generation-specific packages do not change the resolved wrapper")
        (lib.optional (lib.hasInfix "/nix/store" (builtins.toJSON staticServiceA)) "LaunchDaemon plist embeds a generation-specific store path")
        (lib.optional (lib.hasInfix "sudo" (builtins.toJSON staticServiceA)) "LaunchDaemon plist requires sudo")
        (lib.optional (
          !lib.hasInfix "/var/lib/mcl/test-deployments" staticActivation
        ) "activation does not create the durable state directory")
        (lib.optional (
          !lib.hasInfix "/var/log/mcl/deployments/test-agent.jsonl" staticActivation
        ) "activation does not create the JSONL event log")
        (lib.optional (
          !lib.hasInfix "/var/run" staticActivation
        ) "activation does not prepare the lock directory")
      ];

      launchdContractCheck = pkgs.runCommand "test-darwin-pull-agent-launchd-contract" { } ''
        ${lib.optionalString (staticFailures != [ ]) ''
          printf '%s\n' ${lib.escapeShellArgs staticFailures} >&2
          exit 1
        ''}
        entrypoint=${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
        system_entrypoint=${lib.escapeShellArg staticSystemEntrypoint}
        test -x "$entrypoint"
        test -L "$system_entrypoint"
        test "$(readlink "$system_entrypoint")" = "$entrypoint"
        grep -F -- '--target m3' "$entrypoint" >/dev/null
        grep -F -- '--state-dir /var/lib/mcl/test-deployments' "$entrypoint" >/dev/null
        grep -F -- '--event-log /var/log/mcl/deployments/test-agent.jsonl' "$entrypoint" >/dev/null
        grep -F -- '--max-attempts 5' "$entrypoint" >/dev/null
        grep -F -- '--fetch-timeout-seconds 11' "$entrypoint" >/dev/null
        grep -F -- '--activation-mode nix-darwin' "$entrypoint" >/dev/null
        grep -F -- '--system-profile /nix/var/nix/profiles/system' "$entrypoint" >/dev/null
        grep -F -- '--pre-switch-hook /run/current-system/sw/bin/mcl-deploy-pre-switch' "$entrypoint" >/dev/null
        grep -F -- '--post-switch-hook /run/current-system/sw/bin/mcl-deploy-post-switch' "$entrypoint" >/dev/null
        prerequisite_line=$(grep -nF -- ${lib.escapeShellArg (lib.getExe failingRuntimePrerequisite)} "$entrypoint" | head -n1 | cut -d: -f1)
        flock_line=$(grep -nF -- 'flock -n /var/run/mcl-test-pull-agent.lock' "$entrypoint" | head -n1 | cut -d: -f1)
        test -n "$prerequisite_line"
        test -n "$flock_line"
        test "$prerequisite_line" -lt "$flock_line"
        grep -F -- 'flock -n /var/run/mcl-test-pull-agent.lock' "$entrypoint" >/dev/null
        ! grep -F -- 'sudo' "$entrypoint"

        prerequisite_entrypoint=${lib.escapeShellArg (lib.getExe prerequisiteEntrypointPackage)}
        rm -rf ${lib.escapeShellArg prerequisiteRoot}
        export MCL_DARWIN_PREREQUISITE_MARKER=${lib.escapeShellArg prerequisiteRoot}/mcl-ran
        if "$prerequisite_entrypoint"; then
          echo 'failing runtime prerequisite was ignored' >&2
          exit 1
        else
          test "$?" -eq 75
        fi
        test ! -e ${lib.escapeShellArg prerequisiteRoot}
        mkdir -p "$out"
        printf '%s\n' 'test_darwin_pull_agent_launchd_contract: passed' > "$out/result"
      '';

      generationStabilityCheck =
        pkgs.runCommand "test-darwin-pull-agent-entrypoint-survives-generation-change" { }
          ''
            test ${lib.escapeShellArg (toString staticServiceA.Label)} = ${lib.escapeShellArg (toString staticServiceB.Label)}
            test ${lib.escapeShellArg (builtins.toJSON staticServiceA.ProgramArguments)} = ${lib.escapeShellArg (builtins.toJSON staticServiceB.ProgramArguments)}
            test ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)} != ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}
            test -x ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
            test -x ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}
            test -L ${lib.escapeShellArg staticSystemEntrypoint}
            test -L ${lib.escapeShellArg staticSystemEntrypointB}
            test "$(readlink ${lib.escapeShellArg staticSystemEntrypoint})" = ${lib.escapeShellArg (lib.getExe staticEntrypointPackage)}
            test "$(readlink ${lib.escapeShellArg staticSystemEntrypointB})" = ${lib.escapeShellArg (lib.getExe staticEntrypointPackageB)}
            mkdir -p "$out"
            printf '%s\n' 'test_darwin_pull_agent_entrypoint_survives_generation_change: passed' > "$out/result"
          '';

      integrationRoot = "/tmp/mcl-deployment-pull-agent-darwin-integration";
      lockRoot = "/tmp/mcl-deployment-pull-agent-darwin-lock";
      preSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-pre-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf '%s\n%s\n' "$1" "$2" > "$MCL_DARWIN_TEST_ROOT/pre-switch-ran"
      '';
      postSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-post-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf '%s\n%s\n%s\n' "$1" "$2" "$3" > "$MCL_DARWIN_TEST_ROOT/post-switch-ran"
      '';
      blockingPreSwitchHook = pkgs.writeShellScript "mcl-darwin-pull-agent-blocking-pre-switch" ''
        set -eu
        test -n "''${MCL_DARWIN_TEST_ROOT:-}"
        printf 'entered\n' >> "$MCL_DARWIN_TEST_ROOT/pre-switch-runs"
        touch "$MCL_DARWIN_TEST_ROOT/pre-switch-entered"
        sleep 8
        exit 75
      '';

      integrationSystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "m3";
            system.stateVersion = 6;
            services.mcl-deploy-agent = {
              enable = true;
              package = self'.packages.mcl;
              targetName = "m3";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestDirectories = [ "${integrationRoot}/inbox" ];
              stateDir = "${integrationRoot}/state";
              eventLog = "${integrationRoot}/events.jsonl";
              standardOutLog = "${integrationRoot}/stdout.log";
              standardErrorLog = "${integrationRoot}/stderr.log";
              lockFile = "${integrationRoot}/agent.lock";
              systemProfile = "${integrationRoot}/system-profile";
              inherit preSwitchHook postSwitchHook;
              maxAttempts = 2;
              fetchTimeoutSeconds = 7;
            };
          }
        ];
      };
      integrationEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "integration Darwin pull-agent entrypoint package is absent")
          integrationSystem.config.environment.systemPackages;

      generation =
        name:
        pkgs.runCommand "mcl-darwin-pull-agent-generation-${name}" { } ''
          mkdir -p "$out"
          cat > "$out/activate" <<'EOF'
          #!${pkgs.runtimeShell}
          set -eu
          test -n "''${MCL_DARWIN_TEST_ROOT:-}"
          printf '%s\n' "$(dirname "$0")" >> "$MCL_DARWIN_TEST_ROOT/activation-runs"
          EOF
          chmod +x "$out/activate"
        '';
      previousGeneration = generation "previous";
      desiredGeneration = generation "desired";
      profileClosure = pkgs.closureInfo {
        rootPaths = [
          previousGeneration
          desiredGeneration
        ];
      };

      lockSystem = inputs.nix-darwin.lib.darwinSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.darwin.deployment-pull-agent
          {
            networking.hostName = "m3";
            system.stateVersion = 6;
            services.mcl-deploy-agent = {
              enable = true;
              package = self'.packages.mcl;
              targetName = "m3";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestDirectories = [ "${lockRoot}/inbox" ];
              stateDir = "${lockRoot}/state";
              eventLog = "${lockRoot}/events.jsonl";
              standardOutLog = "${lockRoot}/stdout.log";
              standardErrorLog = "${lockRoot}/stderr.log";
              lockFile = "${lockRoot}/agent.lock";
              systemProfile = "${lockRoot}/system-profile";
              preSwitchHook = blockingPreSwitchHook;
              inherit postSwitchHook;
              maxAttempts = 1;
            };
          }
        ];
      };
      lockEntrypointPackage =
        lib.findFirst (package: lib.getName package == "mcl-deploy-agent")
          (throw "lock-test Darwin pull-agent entrypoint package is absent")
          lockSystem.config.environment.systemPackages;

      darwinIntegrationCheck =
        pkgs.runCommand "deployment-pull-agent-darwin-integration"
          {
            nativeBuildInputs = [
              self'.packages.mcl
              pkgs.coreutils
              pkgs.jq
              pkgs.nix
              pkgs.openssh
              (pkgs.python3.withPackages (pythonPackages: [ pythonPackages.jsonschema ]))
            ];
          }
          ''
            set -euo pipefail
            cleanup() {
              rm -rf ${lib.escapeShellArg integrationRoot} ${lib.escapeShellArg lockRoot}
            }
            trap cleanup EXIT
            cleanup

            key="$TMPDIR/manifest-key"
            cp ${manifestPrivateKey} "$key"
            chmod 0600 "$key"

            make_manifest() {
              local target=$1
              local desired=$2
              local sequence=$3
              local output=$4
              mcl deploy-plan \
                --target "$target" \
                --system aarch64-darwin \
                --desired-system-path "$desired" \
                --git-revision 0123456789abcdef0123456789abcdef01234567 \
                --sequence "$sequence" \
                --signing-key "$key" \
                --signing-key-id mcl-deployment \
                --output "$output"
            }

            validate_event_log() {
              python - "$1" ${../docs/deployment/event-schema.json} <<'PY'
            import json
            import pathlib
            import sys

            from jsonschema import Draft202012Validator, FormatChecker

            event_log = pathlib.Path(sys.argv[1])
            schema = json.loads(pathlib.Path(sys.argv[2]).read_text())
            Draft202012Validator.check_schema(schema)
            validator = Draft202012Validator(schema, format_checker=FormatChecker())
            events = [json.loads(line) for line in event_log.read_text().splitlines() if line.strip()]
            if not events:
                raise AssertionError(f"event log is empty: {event_log}")
            for index, event in enumerate(events, start=1):
                errors = sorted(validator.iter_errors(event), key=lambda error: list(error.path))
                if errors:
                    rendered = "; ".join(error.message for error in errors)
                    raise AssertionError(f"{event_log}:{index}: {rendered}")
            PY
            }

            entrypoint=${lib.escapeShellArg (lib.getExe integrationEntrypointPackage)}
            system_entrypoint=${lib.escapeShellArg "${integrationSystem.config.system.path}/bin/mcl-deploy-agent"}
            test -x "$entrypoint"
            test -L "$system_entrypoint"
            test "$(readlink "$system_entrypoint")" = "$entrypoint"
            mkdir -p ${lib.escapeShellArg integrationRoot}/inbox
            export MCL_DARWIN_TEST_ROOT=${lib.escapeShellArg integrationRoot}
            export HOME=${lib.escapeShellArg integrationRoot}/home
            export XDG_CACHE_HOME=${lib.escapeShellArg integrationRoot}/cache
            export NIX_CONFIG='experimental-features = nix-command'
            export NIX_STATE_DIR=${lib.escapeShellArg integrationRoot}/nix-state
            export NIX_PROFILES_DIR="$NIX_STATE_DIR/profiles"
            export NIX_USER_PROFILE_DIR="$NIX_PROFILES_DIR/per-user/$(id -un)"
            mkdir -p \
              "$HOME" \
              "$XDG_CACHE_HOME" \
              "$NIX_STATE_DIR/gcroots/auto" \
              "$NIX_STATE_DIR/temproots" \
              "$NIX_USER_PROFILE_DIR"
            nix-store --init
            nix-store --load-db < ${profileClosure}/registration
            nix-env --profile ${lib.escapeShellArg integrationRoot}/system-profile --set ${previousGeneration}

            # test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests:
            # an absent desired state fails closed before any lifecycle hook.
            "$entrypoint"
            jq -e '.currentState == "waiting" and .attempts == 0 and .retryable == true' \
              ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
            test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
            test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

            make_manifest other-target ${desiredGeneration} 1 ${lib.escapeShellArg integrationRoot}/inbox/wrong-target.json
            if "$entrypoint"; then
              echo 'agent accepted a wrong-target manifest' >&2
              exit 1
            fi
            jq -e '.currentState == "non-retryable" and .errorCode == "wrong_target" and .observedTarget == "other-target"' \
              ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
            test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
            test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

            rm -rf ${lib.escapeShellArg integrationRoot}/inbox/* ${lib.escapeShellArg integrationRoot}/state
            make_manifest m3 ${desiredGeneration} 2 ${lib.escapeShellArg integrationRoot}/inbox/tampered.json
            jq '.desiredSystemPath = "${previousGeneration}"' \
              ${lib.escapeShellArg integrationRoot}/inbox/tampered.json > ${lib.escapeShellArg integrationRoot}/inbox/tampered.tmp
            mv ${lib.escapeShellArg integrationRoot}/inbox/tampered.tmp ${lib.escapeShellArg integrationRoot}/inbox/tampered.json
            if "$entrypoint"; then
              echo 'agent accepted a manifest whose signed content was changed' >&2
              exit 1
            fi
            jq -e '.currentState == "non-retryable" and .errorCode == "invalid_signature" and .retryable == false' \
              ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
            test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${previousGeneration}
            test ! -e ${lib.escapeShellArg integrationRoot}/pre-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/post-switch-ran
            test ! -e ${lib.escapeShellArg integrationRoot}/activation-runs

            # A correctly signed target manifest proves that this same generated
            # entrypoint can reach the real profile, lifecycle, and activation path.
            rm -rf ${lib.escapeShellArg integrationRoot}/inbox/* ${lib.escapeShellArg integrationRoot}/state
            make_manifest m3 ${desiredGeneration} 3 ${lib.escapeShellArg integrationRoot}/inbox/trusted.json
            "$entrypoint"
            jq -e '.currentState == "succeeded" and .attempts == 1' \
              ${lib.escapeShellArg integrationRoot}/state/agent-status/m3.json >/dev/null
            test "$(nix-store --realise ${lib.escapeShellArg integrationRoot}/system-profile)" = ${desiredGeneration}
            test "$(cat ${lib.escapeShellArg integrationRoot}/activation-runs)" = ${desiredGeneration}
            test "$(sed -n '1p' ${lib.escapeShellArg integrationRoot}/pre-switch-ran)" = ${desiredGeneration}
            test "$(sed -n '2p' ${lib.escapeShellArg integrationRoot}/pre-switch-ran)" = ${previousGeneration}
            test "$(sed -n '1p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = ${desiredGeneration}
            test "$(sed -n '2p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = ${previousGeneration}
            test "$(sed -n '3p' ${lib.escapeShellArg integrationRoot}/post-switch-ran)" = succeeded
            validate_event_log ${lib.escapeShellArg integrationRoot}/events.jsonl
            jq -e -s '
              length > 0 and
              all(.[]; .target.kind == "darwin" and .target.name == "m3") and
              any(.[]; .phase == "complete" and .command.status == "succeeded")
            ' ${lib.escapeShellArg integrationRoot}/events.jsonl >/dev/null

            # test_darwin_pull_agent_lock_contention_is_non_destructive: the first
            # real agent invocation holds the module's flock while readiness waits.
            mkdir -p ${lib.escapeShellArg lockRoot}/inbox
            export MCL_DARWIN_TEST_ROOT=${lib.escapeShellArg lockRoot}
            export HOME=${lib.escapeShellArg lockRoot}/home
            export XDG_CACHE_HOME=${lib.escapeShellArg lockRoot}/cache
            export NIX_CONFIG='experimental-features = nix-command'
            export NIX_STATE_DIR=${lib.escapeShellArg lockRoot}/nix-state
            export NIX_PROFILES_DIR="$NIX_STATE_DIR/profiles"
            export NIX_USER_PROFILE_DIR="$NIX_PROFILES_DIR/per-user/$(id -un)"
            mkdir -p \
              "$HOME" \
              "$XDG_CACHE_HOME" \
              "$NIX_STATE_DIR/gcroots/auto" \
              "$NIX_STATE_DIR/temproots" \
              "$NIX_USER_PROFILE_DIR"
            nix-store --init
            nix-store --load-db < ${profileClosure}/registration
            nix-env --profile ${lib.escapeShellArg lockRoot}/system-profile --set ${previousGeneration}
            make_manifest m3 ${desiredGeneration} 4 ${lib.escapeShellArg lockRoot}/inbox/desired.json

            lock_entrypoint=${lib.escapeShellArg (lib.getExe lockEntrypointPackage)}
            "$lock_entrypoint" > ${lib.escapeShellArg lockRoot}/first.stdout 2> ${lib.escapeShellArg lockRoot}/first.stderr &
            first_pid=$!
            for _ in $(seq 1 100); do
              test -e ${lib.escapeShellArg lockRoot}/pre-switch-entered && break
              kill -0 "$first_pid"
              sleep 0.1
            done
            test -e ${lib.escapeShellArg lockRoot}/pre-switch-entered
            if "$lock_entrypoint" > ${lib.escapeShellArg lockRoot}/contender.stdout 2> ${lib.escapeShellArg lockRoot}/contender.stderr; then
              echo 'concurrent Darwin pull-agent invocation acquired the held lock' >&2
              exit 1
            fi
            wait "$first_pid"
            test "$(wc -l < ${lib.escapeShellArg lockRoot}/pre-switch-runs | tr -d ' ')" = 1
            test "$(nix-store --realise ${lib.escapeShellArg lockRoot}/system-profile)" = ${previousGeneration}
            test ! -e ${lib.escapeShellArg lockRoot}/activation-runs
            test ! -e ${lib.escapeShellArg lockRoot}/post-switch-ran
            jq -e '.currentState == "deferred" and .attempts == 0 and .maxAttempts == 1 and .retryable == true' \
              ${lib.escapeShellArg lockRoot}/state/agent-status/m3.json >/dev/null
            validate_event_log ${lib.escapeShellArg lockRoot}/events.jsonl
            jq -e -s '
              all(.[]; .target.kind == "darwin" and .target.name == "m3") and
              any(.[];
                .phase == "switch" and
                .command.status == "skipped" and
                .command.exitCode == 75 and
                .error.code == "deployment_deferred" and
                .error.retryable == true)
            ' ${lib.escapeShellArg lockRoot}/events.jsonl >/dev/null

            mkdir -p "$out"
            printf '%s\n' 'test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests: passed' > "$out/hostile"
            printf '%s\n' 'test_darwin_pull_agent_lock_contention_is_non_destructive: passed' > "$out/lock"
            printf '%s\n' 'deployment-pull-agent-darwin-integration: passed' > "$out/result"
          '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        test_darwin_pull_agent_launchd_contract = launchdContractCheck;
        test_darwin_pull_agent_entrypoint_survives_generation_change = generationStabilityCheck;
        test_darwin_pull_agent_rejects_untrusted_and_wrong_target_manifests = darwinIntegrationCheck;
        test_darwin_pull_agent_lock_contention_is_non_destructive = darwinIntegrationCheck;
        deployment-pull-agent-darwin-integration = darwinIntegrationCheck;
      };
    };
}
