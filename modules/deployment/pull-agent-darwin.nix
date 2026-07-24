{ withSystem, ... }:
{
  flake.modules.darwin.deployment-pull-agent =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.mcl-deploy-agent;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.mcl);
      inherit (lib)
        concatMapStringsSep
        escapeShellArg
        escapeShellArgs
        getExe
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      allowedSigners = pkgs.writeText "mcl-deployment-agent-allowed-signers" (
        concatMapStringsSep "\n" (key: "${cfg.manifestPrincipal} ${key}") cfg.manifestPublicKeys + "\n"
      );

      agentArguments = [
        "--target"
        cfg.targetName
        "--allowed-signers"
        allowedSigners
        "--state-dir"
        cfg.stateDir
        "--event-log"
        cfg.eventLog
        "--max-attempts"
        (toString cfg.maxAttempts)
        "--fetch-timeout-seconds"
        (toString cfg.fetchTimeoutSeconds)
        "--activation-mode"
        "nix-darwin"
        "--system-profile"
        cfg.systemProfile
      ]
      ++ lib.concatMap (source: [
        "--manifest"
        source
      ]) cfg.manifestSources
      ++ lib.concatMap (dir: [
        "--manifest-dir"
        dir
      ]) cfg.manifestDirectories
      ++ lib.optionals cfg.dryRun [ "--dry-run" ]
      ++ lib.optionals (cfg.preSwitchHook != "") [
        "--pre-switch-hook"
        cfg.preSwitchHook
      ]
      ++ lib.optionals (cfg.postSwitchHook != "") [
        "--post-switch-hook"
        cfg.postSwitchHook
      ];

      # The plist deliberately names only this generation-independent path.
      # Once launchd has opened the wrapper, it may safely activate a system
      # whose environment contains a different wrapper and mcl package.
      stableEntrypoint = "/run/current-system/sw/bin/mcl-deploy-agent";
      entrypointPackage = pkgs.writeShellApplication {
        name = "mcl-deploy-agent";
        runtimeInputs = [
          cfg.package
          pkgs.coreutils
          pkgs.curl
          pkgs.nix
          pkgs.openssh
          pkgs.util-linux
        ];
        text = ''
          exec flock -n ${escapeShellArg cfg.lockFile} ${
            escapeShellArgs (
              [
                (getExe cfg.package)
                "deploy-agent"
              ]
              ++ agentArguments
            )
          }
        '';
      };

      durableDirectories = lib.unique (
        [
          cfg.stateDir
          (builtins.dirOf cfg.eventLog)
          (builtins.dirOf cfg.standardOutLog)
          (builtins.dirOf cfg.standardErrorLog)
          (builtins.dirOf cfg.lockFile)
        ]
        ++ cfg.manifestDirectories
      );
    in
    {
      options.services.mcl-deploy-agent = {
        enable = mkEnableOption "root nix-darwin pull agent for signed mcl deployment manifests";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl binary used by the generation-stable wrapper.";
        };

        targetName = mkOption {
          type = types.str;
          default = config.networking.hostName;
          description = "Expected manifest target name. The agent rejects every other target.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/mcl/deployments";
          description = "Target-local durable deployment state directory.";
        };

        eventLog = mkOption {
          type = types.str;
          default = "/var/log/mcl/deployments/${cfg.targetName}.jsonl";
          description = "Target-side deployment event JSONL log path.";
        };

        standardOutLog = mkOption {
          type = types.str;
          default = "/var/log/mcl/deployments/${cfg.targetName}-agent.stdout.log";
          description = "Durable stdout log for the launchd job.";
        };

        standardErrorLog = mkOption {
          type = types.str;
          default = "/var/log/mcl/deployments/${cfg.targetName}-agent.stderr.log";
          description = "Durable stderr log for the launchd job.";
        };

        manifestPrincipal = mkOption {
          type = types.str;
          default = "mcl-deployment";
          description = "OpenSSH allowed-signers principal for deployment manifest signatures.";
        };

        manifestPublicKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "OpenSSH public keys trusted to sign deployment manifests.";
        };

        manifestSources = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Exact signed manifest files or HTTP(S) URLs polled by the agent.";
        };

        manifestDirectories = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Directories containing signed manifests for this target only.";
        };

        maxAttempts = mkOption {
          type = types.ints.positive;
          default = 3;
          description = "Maximum apply attempts for one deployment before marking it non-retryable.";
        };

        fetchTimeoutSeconds = mkOption {
          type = types.ints.positive;
          default = 30;
          description = "Timeout used when fetching HTTP(S) manifest sources.";
        };

        intervalSeconds = mkOption {
          type = types.ints.positive;
          default = 15 * 60;
          description = "launchd StartInterval, in seconds, for polling desired state.";
        };

        lockFile = mkOption {
          type = types.str;
          default = "/var/run/mcl-deploy-agent-${cfg.targetName}.lock";
          description = "Non-blocking flock file that prevents overlapping polls for this target.";
        };

        systemProfile = mkOption {
          type = types.str;
          default = "/nix/var/nix/profiles/system";
          description = "nix-darwin system profile selected atomically before activation.";
        };

        preSwitchHook = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = "Optional executable readiness hook called with DESIRED PREVIOUS.";
        };

        postSwitchHook = mkOption {
          type = types.coercedTo types.package toString types.str;
          default = "";
          description = "Optional executable cleanup hook called with DESIRED PREVIOUS OUTCOME.";
        };

        dryRun = mkOption {
          type = types.bool;
          default = false;
          description = "Verify manifests and write state/events without restore or activation.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.manifestPublicKeys != [ ];
            message = "services.mcl-deploy-agent.manifestPublicKeys must not be empty.";
          }
          {
            assertion = cfg.manifestSources != [ ] || cfg.manifestDirectories != [ ];
            message = "services.mcl-deploy-agent needs at least one manifest source or directory.";
          }
          {
            assertion =
              lib.hasPrefix "/" cfg.stateDir
              && lib.hasPrefix "/" cfg.eventLog
              && lib.hasPrefix "/" cfg.standardOutLog
              && lib.hasPrefix "/" cfg.standardErrorLog
              && lib.hasPrefix "/" cfg.lockFile
              && lib.hasPrefix "/" cfg.systemProfile;
            message = "services.mcl-deploy-agent durable paths and systemProfile must be absolute.";
          }
        ];

        environment.systemPackages = [
          cfg.package
          entrypointPackage
        ];

        # This runs before nix-darwin reconciles launchd jobs, so launchd can
        # open its stdout/stderr paths on the first load.
        system.activationScripts.preActivation.text = lib.mkAfter ''
          ${concatMapStringsSep "\n" (dir: ''
            ${pkgs.coreutils}/bin/install -d -m 0750 ${escapeShellArg dir}
          '') durableDirectories}
          ${pkgs.coreutils}/bin/touch ${escapeShellArg cfg.eventLog} \
            ${escapeShellArg cfg.standardOutLog} ${escapeShellArg cfg.standardErrorLog}
          ${pkgs.coreutils}/bin/chmod 0640 ${escapeShellArg cfg.eventLog} \
            ${escapeShellArg cfg.standardOutLog} ${escapeShellArg cfg.standardErrorLog}
        '';

        launchd.daemons.mcl-deploy-agent = {
          serviceConfig = {
            Label = "org.metacraft-labs.mcl-deploy-agent";
            ProgramArguments = [ stableEntrypoint ];
            UserName = "root";
            GroupName = "wheel";
            RunAtLoad = true;
            StartInterval = cfg.intervalSeconds;
            StandardOutPath = cfg.standardOutLog;
            StandardErrorPath = cfg.standardErrorLog;
            ProcessType = "Background";
            ThrottleInterval = 10;
          };
        };
      };
    };
}
