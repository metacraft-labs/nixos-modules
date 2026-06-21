{ withSystem, ... }:
{
  flake.modules.nixos.deployment-pull-agent =
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
        getExe
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      allowedSigners = pkgs.writeText "mcl-deployment-agent-allowed-signers" (
        concatMapStringsSep "\n" (key: "${cfg.manifestPrincipal} ${key}") cfg.manifestPublicKeys + "\n"
      );

      args = [
        "--target ${escapeShellArg cfg.targetName}"
        "--allowed-signers ${escapeShellArg allowedSigners}"
        "--state-dir ${escapeShellArg cfg.stateDir}"
        "--event-log ${escapeShellArg cfg.eventLog}"
        "--max-attempts ${toString cfg.maxAttempts}"
        "--fetch-timeout-seconds ${toString cfg.fetchTimeoutSeconds}"
      ]
      ++ map (source: "--manifest ${escapeShellArg source}") cfg.manifestSources
      ++ map (dir: "--manifest-dir ${escapeShellArg dir}") cfg.manifestDirectories
      ++ lib.optionals cfg.dryRun [ "--dry-run" ]
      ++ lib.optionals (cfg.restoreCommand != "") [
        "--restore-command ${escapeShellArg cfg.restoreCommand}"
      ]
      ++ lib.optionals (cfg.switchCommand != "") [
        "--switch-command ${escapeShellArg cfg.switchCommand}"
      ]
      ++ lib.optionals (cfg.rollbackCommand != "") [
        "--rollback-command ${escapeShellArg cfg.rollbackCommand}"
      ]
      ++ lib.optionals (cfg.generationCommand != "") [
        "--generation-command ${escapeShellArg cfg.generationCommand}"
      ];

      agentCommand = concatMapStringsSep " " (x: x) ([ "${getExe cfg.package} deploy-agent" ] ++ args);
    in
    {
      options.services.mcl-deploy-agent = {
        enable = mkEnableOption "target-side pull agent for signed mcl deployment manifests";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the mcl binary.";
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

        interval = mkOption {
          type = types.str;
          default = "15min";
          description = "systemd OnUnitActiveSec interval for polling desired state.";
        };

        jitter = mkOption {
          type = types.str;
          default = "5min";
          description = "systemd RandomizedDelaySec for polling.";
        };

        lockFile = mkOption {
          type = types.str;
          default = "/run/lock/mcl-deploy-agent-${cfg.targetName}.lock";
          description = "flock lock file that prevents concurrent apply attempts on this target.";
        };

        dryRun = mkOption {
          type = types.bool;
          default = false;
          description = "Verify manifests and write state/events without restore or switch.";
        };

        restoreCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for closure restore tests. Empty uses the production Nix restore path.";
        };

        switchCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for switch tests. Empty uses the desired system switch-to-configuration.";
        };

        rollbackCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override for rollback tests. Empty uses the previous generation switch-to-configuration.";
        };

        generationCommand = mkOption {
          type = types.str;
          default = "";
          description = "Optional root command override that prints the current generation. Empty uses /run/current-system.";
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
        ];

        environment.systemPackages = [ cfg.package ];

        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0750 root root -"
          "d /var/log/mcl/deployments 0755 root root -"
        ]
        ++ map (dir: "d ${dir} 0750 root root -") cfg.manifestDirectories;

        systemd.services.mcl-deploy-agent = {
          description = "Pull and apply signed mcl desired-state manifests for ${cfg.targetName}";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.util-linux}/bin/flock -n ${escapeShellArg cfg.lockFile} ${agentCommand}";
            CacheDirectory = "mcl-deploy-agent";
            Environment = [
              "HOME=/var/cache/mcl-deploy-agent"
              "XDG_CACHE_HOME=/var/cache/mcl-deploy-agent"
            ];
            NoNewPrivileges = true;
            ProtectHome = true;
            PrivateTmp = true;
          };
        };

        systemd.timers.mcl-deploy-agent = {
          description = "Poll signed mcl desired-state manifests for ${cfg.targetName}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnActiveSec = cfg.interval;
            OnUnitActiveSec = cfg.interval;
            RandomizedDelaySec = cfg.jitter;
            Persistent = true;
          };
        };
      };
    };
}
