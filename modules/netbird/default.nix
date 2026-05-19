{ ... }:
{
  flake.modules.nixos.mcl-netbird =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.mcl.netbird;
      client = config.services.netbird.clients.${cfg.clientName};
      optionalArrayArg =
        flag: value:
        lib.optionalString (value != null) ''
          args+=(${lib.escapeShellArg flag} ${lib.escapeShellArg value})
        '';
    in
    {
      options.mcl.netbird = with lib; {
        enable = mkEnableOption (mdDoc "NetBird client enrolled with an agenix-managed setup key");

        clientName = mkOption {
          type = types.str;
          default = "agent-harbor";
          description = mdDoc "Name of the NetBird client instance.";
        };

        port = mkOption {
          type = types.port;
          default = 13135;
          description = mdDoc "WireGuard UDP port used by this NetBird client.";
        };

        interface = mkOption {
          type = types.str;
          default = "nb-agent-harbor";
          description = mdDoc "Network interface managed by this NetBird client.";
        };

        setupKeyPath = mkOption {
          type = types.path;
          default = "/etc/netbird-agent-harbor/setup-key";
          description = mdDoc "Path where the NetBird setup key is materialized.";
        };

        hostnameOverride = mkOption {
          type = types.nullOr types.str;
          default = config.networking.hostName;
          defaultText = literalExpression "config.networking.hostName";
          description = mdDoc "Hostname registered for this peer in NetBird.";
        };

        managementUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = mdDoc "Optional NetBird management URL.";
        };

        adminUrl = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = mdDoc "Optional NetBird admin URL.";
        };

        logLevel = mkOption {
          type = types.enum [
            "panic"
            "fatal"
            "error"
            "warn"
            "warning"
            "info"
            "debug"
            "trace"
          ];
          default = "info";
          description = mdDoc "NetBird daemon log level.";
        };

        openFirewall = mkOption {
          type = types.bool;
          default = true;
          description = mdDoc "Open the NetBird WireGuard UDP port.";
        };

        useRoutingFeatures = mkOption {
          type = types.enum [
            "none"
            "client"
            "server"
            "both"
          ];
          default = "none";
          description = mdDoc "Enable NetBird routing feature support.";
        };

        extraConfig = mkOption {
          type = (pkgs.formats.json { }).type;
          default = { };
          description = mdDoc "Extra NetBird client configuration merged into 50-nixos.json.";
        };
      };

      config = lib.mkIf cfg.enable {
        mcl.secrets.services."netbird-${cfg.clientName}".secrets.setup-key.path = cfg.setupKeyPath;

        services.netbird = {
          enable = false;
          useRoutingFeatures = cfg.useRoutingFeatures;
          clients.${cfg.clientName} = {
            port = cfg.port;
            interface = cfg.interface;
            logLevel = cfg.logLevel;
            openFirewall = cfg.openFirewall;
            login = {
              enable = true;
              setupKeyFile = cfg.setupKeyPath;
            };
            config =
              cfg.extraConfig
              // lib.optionalAttrs (cfg.managementUrl != null) {
                ManagementURL = cfg.managementUrl;
              }
              // lib.optionalAttrs (cfg.adminUrl != null) {
                AdminURL = cfg.adminUrl;
              };
          };
        };

        systemd.services."${client.service.name}-login" = {
          path = [
            pkgs.coreutils
            pkgs.gnugrep
          ];
          script = lib.mkForce ''
            set -euo pipefail

            status_file="$(mktemp)"
            trap 'rm -f "$status_file"' EXIT

            refresh_status() {
              '${lib.getExe client.wrapper}' status &>"$status_file" || :
            }

            until refresh_status && grep --quiet 'Connected\|NeedsLogin' "$status_file"; do
              sleep 1
            done

            if grep --quiet 'NeedsLogin' "$status_file"; then
              args=(
                up
                --setup-key-file "$NB_SETUP_KEY_FILE"
              )
              ${optionalArrayArg "--hostname" cfg.hostnameOverride}
              ${optionalArrayArg "--management-url" cfg.managementUrl}
              ${optionalArrayArg "--admin-url" cfg.adminUrl}

              '${lib.getExe client.wrapper}' "''${args[@]}"
            fi
          '';
        };
      };
    };
}
