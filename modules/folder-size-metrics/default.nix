{ withSystem, ... }:
{
  flake.modules.nixos.folder-size-metrics =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.folder-size-metrics;
      package = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.folder-size-metrics
      );
      inherit (import ../lib.nix { inherit lib; }) toEnvVariables;
    in
    {
      options.services.folder-size-metrics = with lib; {
        enable = mkEnableOption (lib.mdDoc "Folder Size Metrics");
        args = {
          port = mkOption {
            type = types.nullOr types.port;
            default = null;
            example = 8888;
          };

          base-path = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "/var/lib";
          };

          interval-sec = mkOption {
            type = types.int;
            default = 60;
          };
        };
      };
      config = {
        systemd.services.folder-size-metrics = lib.mkIf cfg.enable {
          description = "Folder Size Metrics";

          wantedBy = [ "multi-user.target" ];

          environment = toEnvVariables cfg.args;

          path = [ package ];

          serviceConfig = {
            ExecStart = "${lib.getExe package}";
          };
        };
      };
    };
}
