{ withSystem, ... }:
{
  flake.modules.nixos.random-alerts =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.random-alerts;
      pkg = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.random-alerts);
    in
    {
      options.services.random-alerts = with lib; {
        enable = mkEnableOption (lib.mdDoc "Random Alerts");
        args = {
          urls = mkOption {
            type = types.listOf types.str;
            example = [ "http://localhost:9093" ];
            description = ''
              A list of Alertmanager endpoint URLs used for sending alert notifications.
            '';
          };

          min-wait-time = mkOption {
            type = types.int;
            default = 3600;
            example = 360;
            description = ''Minimum wait time before alert in seconds'';
          };

          max-wait-time = mkOption {
            type = types.int;
            default = 14400;
            example = 6000;
            description = ''Maximum wait time before alert in seconds'';
          };

          alert-duration = mkOption {
            type = types.int;
            default = 3600;
            example = 360;
            description = ''Time after alerts ends in seconds'';
          };

          start-time = mkOption {
            type = types.str;
            default = "00:00:00";
            example = "10:00:00";
            description = ''The start time of alerts in a 24-hour clock'';
          };

          end-time = mkOption {
            type = types.str;
            default = "23:59:59";
            example = "22:00:00";
            description = ''The end time of alerts in a 24-hour clock'';
          };

          log-level = mkOption {
            type = types.enum [
              "info"
              "trace"
              "error"
            ];
            default = "info";
          };
        };
      };

      config =
        let
          concatMapAttrsStringSep =
            sep: f: attrs:
            lib.concatStringsSep sep (lib.attrValues (lib.mapAttrs f attrs));

          filteredArgs = removeAttrs cfg.args [ "urls" ];
          filteredArgsToString = concatMapAttrsStringSep " " (n: v: "--${n}=${toString v}") filteredArgs;
          urlsArg = " --urls=${lib.concatStringsSep "," cfg.args.urls} ";
          args = filteredArgsToString + urlsArg;

        in
        lib.mkIf cfg.enable {
          systemd.services.random-alerts = {
            description = "Random Alerts";

            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              DynamicUser = lib.mkDefault true;
              Restart = lib.mkDefault "on-failure";
              ExecStart = "${lib.getExe pkg} ${args}";
            };
          };
        };
    };
}
