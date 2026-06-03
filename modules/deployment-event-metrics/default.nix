{ withSystem, ... }:
{
  flake.modules.nixos.deployment-event-metrics =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.deployment-event-metrics;
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.deployment-event-metrics
      );
      inherit (lib)
        concatMapStringsSep
        escapeShellArg
        getExe
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      args = [
        "--port ${toString cfg.port}"
        "--bind-addresses ${escapeShellArg (builtins.concatStringsSep "," cfg.bind-addresses)}"
      ]
      ++ map (path: "--event-log ${escapeShellArg path}") cfg.event-log-files
      ++ map (path: "--event-dir ${escapeShellArg path}") cfg.event-dirs
      ++ map (path: "--nginx-log ${escapeShellArg path}") cfg.nginx-log-files
      ++ map (target: "--expected-target ${escapeShellArg target}") cfg.expected-targets;
    in
    {
      options.services.deployment-event-metrics = {
        enable = mkEnableOption "Prometheus exporter for deployment JSONL and Attic nginx logs";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          description = "Package providing the deployment-event-metrics binary.";
        };

        port = mkOption {
          type = types.port;
          default = 9161;
          description = "Port number for the deployment event metrics exporter.";
        };

        bind-addresses = mkOption {
          type = types.listOf types.str;
          default = [ "127.0.0.1" ];
          description = "Addresses to bind for the Prometheus HTTP endpoint.";
        };

        event-log-files = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Specific deployment JSONL files to read.";
        };

        event-dirs = mkOption {
          type = types.listOf types.str;
          default = [ "/var/log/mcl/deployments" ];
          description = "Directories containing deployment *.jsonl files.";
        };

        nginx-log-files = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Attic nginx JSONL access logs to parse for cache metrics.";
        };

        expected-targets = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Deployment targets expected to appear in the event stream.";
        };
      };

      config = mkIf cfg.enable {
        systemd.tmpfiles.rules = map (path: "d ${path} 0755 root root -") cfg.event-dirs;

        systemd.services.deployment-event-metrics = {
          description = "Prometheus exporter for Metacraft deployment events";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            ExecStart = "${getExe cfg.package} ${concatMapStringsSep " " (x: x) args}";
            Restart = "on-failure";
            RestartSec = "10s";
            NoNewPrivileges = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            PrivateTmp = true;
          };
        };
      };
    };
}
