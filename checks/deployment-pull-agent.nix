top@{ config, ... }:
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
      manifestPrivateKey = pkgs.writeText "mcl-manifest-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7QAAAJifNGKYnzRi
        mAAAAAtzc2gtZWQyNTUxOQAAACDhvqWTBaFX/XLEIco2ux47m8yJz7xl+vTsiB2LGk7h7Q
        AAAEBvBnhoTQhoz/liGXDGeodsQFCPZfx7B/f10DxJy+VHP+G+pZMFoVf9csQhyja7Hjub
        zInPvGX69OyIHYsaTuHtAAAAEW1jbC1tYW5pZmVzdC10ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
      '';
      manifestPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOG+pZMFoVf9csQhyja7HjubzInPvGX69OyIHYsaTuHt mcl-manifest-test";
      oldSystemPath = "/nix/store/11111111111111111111111111111111-nixos-system-target-old";
      newSystemPath = "/nix/store/22222222222222222222222222222222-nixos-system-target-new";
      wrongTargetSystemPath = "/nix/store/33333333333333333333333333333333-nixos-system-other-target";
      tamperedSystemPath = "/nix/store/44444444444444444444444444444444-nixos-system-target-tampered";
      initialGeneration = "/nix/store/00000000000000000000000000000000-nixos-system-target-initial";
      successGeneration = "/nix/store/55555555555555555555555555555555-nixos-system-target-success-generation";
      restoreScript = pkgs.writeShellScript "mcl-test-pull-restore" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf 'restore\n' >> /var/lib/mcl-test/restore-runs
      '';
      generationScript = pkgs.writeShellScript "mcl-test-pull-generation" ''
        set -euo pipefail
        if [ -f /var/lib/mcl-test/current-generation ]; then
          cat /var/lib/mcl-test/current-generation
        else
          printf '%s\n' ${lib.escapeShellArg initialGeneration}
        fi
      '';
      switchScript = pkgs.writeShellScript "mcl-test-pull-switch" ''
        set -euo pipefail
        mkdir -p /var/lib/mcl-test
        printf '%s\n' ${lib.escapeShellArg successGeneration} > /var/lib/mcl-test/current-generation
        printf 'success\n' >> /var/lib/mcl-test/switch-runs
      '';
      healthScript = pkgs.writeShellScript "mcl-test-pull-health" ''
        set -euo pipefail
        test "$(cat /var/lib/mcl-test/current-generation)" = ${lib.escapeShellArg successGeneration}
      '';
      fakeClosureEnv = "MCL_DEPLOY_FAKE_CLOSURE_COUNT=1 MCL_DEPLOY_FAKE_CLOSURE_TOTAL_BYTES=4096";
      healthCommand = "generation|5|${healthScript}";
      commonTargetModule =
        { ... }:
        {
          imports = [ flake.modules.nixos.deployment-pull-agent ];
          networking.hostName = "target";
          environment.systemPackages = [
            self'.packages.mcl
            pkgs.python3
          ];
          services.mcl-deploy-agent = {
            enable = true;
            package = self'.packages.mcl;
            targetName = "target";
            manifestPublicKeys = [ manifestPublicKey ];
            manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
            eventLog = "/var/log/mcl/deployments/target.jsonl";
            interval = "1min";
            jitter = "0";
            lockFile = "/run/lock/mcl-test-pull-agent.lock";
            restoreCommand = "${restoreScript}";
            switchCommand = "${switchScript}";
            generationCommand = "${generationScript}";
          };
        };
      slowMcl = pkgs.writeShellApplication {
        name = "mcl";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          set -euo pipefail
          if [ "''${1:-}" != deploy-agent ]; then
            echo "fake mcl only supports deploy-agent" >&2
            exit 64
          fi

          mkdir -p /var/lib/mcl-test
          printf 'start:%s\n' "$$" >> /var/lib/mcl-test/agent-runs
          touch /var/lib/mcl-test/agent-started
          sleep 12
          printf 'end:%s\n' "$$" >> /var/lib/mcl-test/agent-runs
        '';
      };
      staticSystem = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.deployment-pull-agent
          {
            networking.hostName = "target-a";
            services.mcl-deploy-agent = {
              enable = true;
              package = self'.packages.mcl;
              targetName = "target-a";
              manifestPublicKeys = [ manifestPublicKey ];
              manifestSources = [ "/var/lib/mcl/deployments/target-a/latest.json" ];
              manifestDirectories = [ "/var/lib/mcl/deployments/inbox" ];
              stateDir = "/var/lib/mcl/test-deployments";
              eventLog = "/var/log/mcl/deployments/test-agent.jsonl";
              interval = "7min";
              jitter = "73s";
              lockFile = "/run/lock/mcl-test-pull-agent.lock";
              maxAttempts = 5;
              fetchTimeoutSeconds = 11;
              dryRun = true;
            };
          }
        ];
      };
      staticService = staticSystem.config.systemd.services.mcl-deploy-agent;
      staticTimer = staticSystem.config.systemd.timers.mcl-deploy-agent;
      staticExecStart = staticService.serviceConfig.ExecStart;
      staticEnvironment = staticService.serviceConfig.Environment or [ ];
      staticFailures = lib.flatten [
        (lib.optional (
          !lib.hasInfix "flock -n /run/lock/mcl-test-pull-agent.lock" staticExecStart
        ) "pull-agent service does not use configured flock lock")
        (lib.optional (
          !lib.hasInfix "deploy-agent" staticExecStart
        ) "pull-agent service does not call mcl deploy-agent")
        (lib.optional (
          !lib.hasInfix "--target target-a" staticExecStart
        ) "pull-agent service does not pass target")
        (lib.optional (
          !lib.hasInfix "--manifest /var/lib/mcl/deployments/target-a/latest.json" staticExecStart
        ) "pull-agent service does not pass exact manifest source")
        (lib.optional (
          !lib.hasInfix "--manifest-dir /var/lib/mcl/deployments/inbox" staticExecStart
        ) "pull-agent service does not pass manifest directory")
        (lib.optional (
          !lib.hasInfix "--state-dir /var/lib/mcl/test-deployments" staticExecStart
        ) "pull-agent service does not pass state dir")
        (lib.optional (
          !lib.hasInfix "--event-log /var/log/mcl/deployments/test-agent.jsonl" staticExecStart
        ) "pull-agent service does not pass event log")
        (lib.optional (
          !lib.hasInfix "--max-attempts 5" staticExecStart
        ) "pull-agent service does not pass max attempts")
        (lib.optional (
          !lib.hasInfix "--fetch-timeout-seconds 11" staticExecStart
        ) "pull-agent service does not pass fetch timeout")
        (lib.optional (
          !lib.hasInfix "--dry-run" staticExecStart
        ) "pull-agent service does not pass dry-run")
        (lib.optional (
          staticService.serviceConfig.CacheDirectory != "mcl-deploy-agent"
        ) "pull-agent service does not provision a writable cache directory")
        (lib.optional (
          !(builtins.elem "HOME=/var/cache/mcl-deploy-agent" staticEnvironment)
        ) "pull-agent service does not set HOME to its writable cache directory")
        (lib.optional (
          !(builtins.elem "XDG_CACHE_HOME=/var/cache/mcl-deploy-agent" staticEnvironment)
        ) "pull-agent service does not set XDG_CACHE_HOME to its writable cache directory")
        (lib.optional (
          staticTimer.timerConfig.OnActiveSec != "7min"
        ) "timer initial activation interval drifted")
        (lib.optional (staticTimer.timerConfig.OnUnitActiveSec != "7min") "timer interval drifted")
        (lib.optional (
          (staticTimer.timerConfig.OnBootSec or null) != null
        ) "timer must not poll immediately on live activation")
        (lib.optional (staticTimer.timerConfig.RandomizedDelaySec != "73s") "timer jitter drifted")
        (lib.optional (staticTimer.timerConfig.Persistent != true) "timer is not persistent")
      ];
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-pull-agent-latest-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-latest-vm";

          nodes.target = commonTargetModule;

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")

            with subtest("publish two signed desired states for the target"):
                target.succeed("install -d -m 0750 /var/lib/mcl/deployments/inbox")
                target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                target.succeed(
                    "${fakeClosureEnv} mcl deploy-plan "
                    "--target target "
                    "--desired-system-path ${oldSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 41 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/old.json"
                )
                target.succeed(
                    "${fakeClosureEnv} mcl deploy-plan "
                    "--target target "
                    "--desired-system-path ${newSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234568 "
                    "--sequence 42 "
                    "--health-command ${lib.escapeShellArg healthCommand} "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/new.json"
                )

            with subtest("agent applies only the newest valid manifest"):
                target.succeed("systemctl start mcl-deploy-agent.service")
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/restore-runs)\" = 1")
                target.succeed("test \"$(wc -l < /var/lib/mcl-test/switch-runs)\" = 1")
                target.succeed("grep -qx success /var/lib/mcl-test/switch-runs")
                target.succeed("test \"$(cat /var/lib/mcl-test/current-generation)\" = '${successGeneration}'")

            with subtest("status and events are target-local and pull-agent labelled"):
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "ids = {event['deploymentId'] for event in events}\n"
                    "assert ids == {'gh-local-unknown-target'}, ids\n"
                    "paths = {event['storePaths']['system'] for event in events}\n"
                    "assert paths == {'${newSystemPath}'}, paths\n"
                    "assert all(event['target']['name'] == 'target' for event in events), events\n"
                    "assert all(event['target']['transport'] == 'pull-agent' for event in events), events\n"
                    "assert all(event['backend']['controller'] == 'mcl-deploy-agent' for event in events), events\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('agent-restore', 'succeeded') in phases, phases\n"
                    "assert ('switch', 'succeeded') in phases, phases\n"
                    "assert ('healthcheck', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['sequence'] == 42, status\n"
                    "assert status['currentState'] == 'succeeded', status\n"
                    "assert status['attempts'] == 1, status\n"
                    "PY"
                )
          '';
        };

        deployment-pull-agent-rejects-invalid-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-rejects-invalid-vm";

          nodes.target = commonTargetModule;

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")
            target.succeed("install -d -m 0750 /var/lib/mcl/deployments/inbox")
            target.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")

            with subtest("wrong target manifest is non-retryable and does not apply"):
                target.succeed(
                    "${fakeClosureEnv} mcl deploy-plan "
                    "--target other-target "
                    "--desired-system-path ${wrongTargetSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/wrong-target.json"
                )
                target.fail("systemctl start mcl-deploy-agent.service")
                target.fail("test -e /var/lib/mcl-test/restore-runs")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['currentState'] == 'non-retryable', status\n"
                    "assert status['errorCode'] == 'wrong_target', status\n"
                    "assert status['observedTarget'] == 'other-target', status\n"
                    "PY"
                )

            with subtest("tampered signature is non-retryable and does not apply"):
                target.succeed("rm -f /var/lib/mcl/deployments/inbox/*.json")
                target.succeed("systemctl reset-failed mcl-deploy-agent.service")
                target.succeed(
                    "${fakeClosureEnv} mcl deploy-plan "
                    "--target target "
                    "--desired-system-path ${tamperedSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 2 "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /var/lib/mcl/deployments/inbox/tampered.json"
                )
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "path = '/var/lib/mcl/deployments/inbox/tampered.json'\n"
                    "manifest = json.load(open(path))\n"
                    "manifest['desiredSystemPath'] = '/nix/store/66666666666666666666666666666666-nixos-system-target-tampered-after-sign'\n"
                    "json.dump(manifest, open(path, 'w'), separators=(',', ':'))\n"
                    "PY"
                )
                target.fail("systemctl start mcl-deploy-agent.service")
                target.fail("test -e /var/lib/mcl-test/restore-runs")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "status = json.load(open('/var/lib/mcl/deployments/agent-status/target.json'))\n"
                    "assert status['target'] == 'target', status\n"
                    "assert status['currentState'] == 'non-retryable', status\n"
                    "assert status['errorCode'] == 'invalid_signature', status\n"
                    "assert status['retryable'] is False, status\n"
                    "PY"
                )
          '';
        };

        deployment-pull-agent-lock-contention-vm = pkgs.testers.nixosTest {
          name = "deployment-pull-agent-lock-contention-vm";

          nodes.target =
            { ... }:
            {
              imports = [ flake.modules.nixos.deployment-pull-agent ];
              services.mcl-deploy-agent = {
                enable = true;
                package = slowMcl;
                targetName = "target";
                manifestPublicKeys = [ manifestPublicKey ];
                manifestSources = [ "/var/lib/mcl/deployments/inbox/latest.json" ];
                interval = "1min";
                jitter = "0";
                lockFile = "/run/lock/mcl-test-pull-agent.lock";
              };
            };

          testScript = ''
            start_all()
            target.wait_for_unit("multi-user.target")

            with subtest("service-held lock rejects concurrent agent apply"):
                target.succeed("systemctl start --no-block mcl-deploy-agent.service")
                target.wait_until_succeeds("test -e /var/lib/mcl-test/agent-started")
                target.fail("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-pull-agent.lock ${lib.getExe slowMcl} deploy-agent --manual-contender")
                target.succeed("test \"$(grep -c '^start:' /var/lib/mcl-test/agent-runs)\" = 1")
                target.succeed("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs || true)\" = 0")

            with subtest("lock releases after the service exits"):
                target.wait_until_succeeds("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs)\" = 1")
                target.succeed("${pkgs.util-linux}/bin/flock -n /run/lock/mcl-test-pull-agent.lock ${lib.getExe slowMcl} deploy-agent --after-service")
                target.succeed("test \"$(grep -c '^start:' /var/lib/mcl-test/agent-runs)\" = 2")
                target.succeed("test \"$(grep -c '^end:' /var/lib/mcl-test/agent-runs)\" = 2")
          '';
        };

        deployment-pull-agent-static = pkgs.runCommand "deployment-pull-agent-static" { } ''
          ${lib.optionalString (staticFailures != [ ]) ''
            cat > failures.txt <<'EOF'
            ${lib.concatStringsSep "\n" staticFailures}
            EOF
            cat failures.txt >&2
            exit 1
          ''}
          cat > "$out" <<'EOF'
          deployment pull agent rendered expected lock, sources, retry budget, timer, and dry-run options.
          EOF
        '';
      };
    };
}
