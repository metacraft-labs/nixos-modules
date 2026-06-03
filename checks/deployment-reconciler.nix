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
      deployPrivateKey = pkgs.writeText "mcl-deploy-test-key" ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMAAAAJgkvRzyJL0c
        8gAAAAtzc2gtZWQyNTUxOQAAACDxlC1Pq0mEdL5sit20QH3e7/Uax+ldXJQXfKXmfN6eMA
        AAAEB4Us+BAX4cSs+Vg/LReEiceYS1znXvLLIR5yXI9/HM1vGULU+rSYR0vmyK3bRAfd7v
        9RrH6V1clBd8peZ83p4wAAAAD21jbC1kZXBsb3ktdGVzdAECAwQFBg==
        -----END OPENSSH PRIVATE KEY-----
      '';
      deployPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPGULU+rSYR0vmyK3bRAfd7v9RrH6V1clBd8peZ83p4w mcl-deploy-test";
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
      fakeSystemPath = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-target-25.11";

      timerSystem = lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          flake.modules.nixos.deployment-reconciler-timer
          {
            services.mcl-deployment-reconciler = {
              enable = true;
              package = self'.packages.mcl;
              stateDir = "/var/lib/mcl/test-deployments";
              eventLog = "/var/log/mcl/deployments/test-reconciler.jsonl";
              interval = "7min";
              jitter = "73s";
              lockFile = "/run/lock/mcl-test-reconciler.lock";
              targets = [ "target-a" ];
              targetHosts.target-a = "10.0.0.12";
              sshUser = "deploy-test";
              sshOptions = [
                "BatchMode=yes"
                "ConnectTimeout=3"
              ];
              identityFile = "/run/keys/deploy";
              dryRun = true;
            };
          }
        ];
      };
      timerService = timerSystem.config.systemd.services.mcl-deployment-reconciler;
      timer = timerSystem.config.systemd.timers.mcl-deployment-reconciler;
      execStart = timerService.serviceConfig.ExecStart;
      failures = lib.flatten [
        (lib.optional (
          !lib.hasInfix "flock -n /run/lock/mcl-test-reconciler.lock" execStart
        ) "reconciler service does not use configured flock lock")
        (lib.optional (
          !lib.hasInfix "deploy-reconcile" execStart
        ) "reconciler service does not call mcl deploy-reconcile")
        (lib.optional (
          !lib.hasInfix "--state-dir /var/lib/mcl/test-deployments" execStart
        ) "reconciler service does not pass state dir")
        (lib.optional (
          !lib.hasInfix "--target target-a" execStart
        ) "reconciler service does not pass target selector")
        (lib.optional (
          !lib.hasInfix "--target-host 'target-a=10.0.0.12'" execStart
        ) "reconciler service does not pass target host mapping")
        (lib.optional (
          !lib.hasInfix "--identity-file /run/keys/deploy" execStart
        ) "reconciler service does not pass identity file")
        (lib.optional (!lib.hasInfix "--dry-run" execStart) "reconciler service does not pass dry-run")
        (lib.optional (timer.timerConfig.OnUnitActiveSec != "7min") "timer interval drifted")
        (lib.optional (timer.timerConfig.RandomizedDelaySec != "73s") "timer jitter drifted")
        (lib.optional (timer.timerConfig.Persistent != true) "timer is not persistent")
      ];
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-direct-ssh-success-vm = pkgs.testers.nixosTest {
          name = "deployment-direct-ssh-success-vm";

          nodes = {
            controller = {
              environment.systemPackages = [
                self'.packages.mcl
                pkgs.openssh
                pkgs.python3
              ];
            };

            target =
              { ... }:
              {
                imports = [ flake.modules.nixos.deployment-forced-command-apply ];

                networking.hostName = "target";
                environment.systemPackages = [ pkgs.python3 ];
                services.openssh = {
                  enable = true;
                  settings.PasswordAuthentication = false;
                };
                services.mcl-deployment-ssh-apply = {
                  enable = true;
                  package = self'.packages.mcl;
                  targetName = "target";
                  manifestPrincipal = "mcl-deployment";
                  manifestPublicKeys = [ manifestPublicKey ];
                  authorizedKeys = [ deployPublicKey ];
                  dryRun = true;
                };
              };
          };

          testScript = ''
            start_all()
            target.wait_for_unit("sshd.service")

            with subtest("create signed desired-state manifest"):
                controller.succeed("install -m 0600 ${deployPrivateKey} /tmp/deploy-key")
                controller.succeed("install -m 0600 ${manifestPrivateKey} /tmp/manifest-key")
                controller.succeed(
                    "mcl deploy-plan "
                    "--target target "
                    "--desired-system-path ${fakeSystemPath} "
                    "--git-revision 0123456789abcdef0123456789abcdef01234567 "
                    "--sequence 1 "
                    "--signing-key /tmp/manifest-key "
                    "--signing-key-id mcl-deployment "
                    "--output /tmp/manifest.json "
                    "--state-dir /tmp/reconciler-state"
                )

            with subtest("forced command rejects arbitrary shell"):
                controller.fail(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target true"
                )

            with subtest("forced command accepts signed manifest on stdin"):
                controller.succeed(
                    "ssh -i /tmp/deploy-key "
                    "-o StrictHostKeyChecking=no "
                    "-o UserKnownHostsFile=/dev/null "
                    "deploy@target < /tmp/manifest.json"
                )

            with subtest("target recorded dry-run convergence event"):
                target.succeed("test -s /var/log/mcl/deployments/target.jsonl")
                target.succeed(
                    "python3 - <<'PY'\n"
                    "import json\n"
                    "events = [json.loads(line) for line in open('/var/log/mcl/deployments/target.jsonl') if line.strip()]\n"
                    "phases = [(event['phase'], event['command']['status']) for event in events]\n"
                    "assert ('activate-requested', 'succeeded') in phases, phases\n"
                    "assert ('complete', 'succeeded') in phases, phases\n"
                    "assert all(event['deploymentId'] == 'gh-local-unknown-target' for event in events), events\n"
                    "PY"
                )
                target.succeed("test -f /var/lib/mcl/deployments/converged/gh-local-unknown-target.json")
          '';
        };

        deployment-reconciler-timer-static = pkgs.runCommand "deployment-reconciler-timer-static" { } ''
          ${lib.optionalString (failures != [ ]) ''
            cat > failures.txt <<'EOF'
            ${lib.concatStringsSep "\n" failures}
            EOF
            cat failures.txt >&2
            exit 1
          ''}
          cat > "$out" <<'EOF'
          deployment reconciler timer rendered expected lock, interval, jitter, selector, dry-run, and ssh options.
          EOF
        '';
      };
    };
}
