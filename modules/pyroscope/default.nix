{ withSystem, ... }:
{
  flake.modules.nixos.pyroscope =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.pyroscope;
      package = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.pyroscope);
    in
    {
      options.services.pyroscope = with lib; {
        enable = mkEnableOption (lib.mdDoc "Grafana Agent (Flow mode)");
        args = {
          server = {
            http-listen-port = mkOption {
              type = types.port;
              default = 4040;
              example = 8080;
            };
            http-listen-address = mkOption {
              type = types.str;
              default = "127.0.0.1";
              example = "0.0.0.0";
            };

            grpc-listen-port = mkOption {
              type = types.port;
              default = 9095;
              example = 9096;
            };
            grpc-listen-address = mkOption {
              type = types.str;
              default = "127.0.0.1";
              example = "0.0.0.0";
            };
          };

          log = {
            level = mkOption {
              type = types.enum [
                "debug"
                "info"
                "warn"
                "error"
              ];
              default = "info";
              example = "debug";
            };
            format = mkOption {
              type = types.enum [
                "logfmt"
                "json"
              ];
              default = "logfmt";
              example = "json";
            };
          };
        };
      };

      config = {
        systemd.services.pyroscope = lib.mkIf cfg.enable {
          description = "Pyroscope";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = ''
              ${lib.getExe package} \
              -server.http-listen-port ${toString cfg.args.server.http-listen-port} \
              -server.http-listen-address ${cfg.args.server.http-listen-address} \
              -server.grpc-listen-port ${toString cfg.args.server.grpc-listen-port} \
              -server.grpc-listen-address ${cfg.args.server.grpc-listen-address} \
              -log.level ${cfg.args.log.level} \
              -log.format ${cfg.args.log.format}
            '';
          };
        };
      };
    };
}
