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
          http = {
            port = mkOption {
              type = types.port;
              default = 4040;
              example = 8080;
            };
            address = mkOption {
              type = types.str;
              default = "127.0.0.1";
              example = "0.0.0.0";
            };
          };

          grpc = {
            port = mkOption {
              type = types.port;
              default = 9095;
              example = 9096;
            };
            address = mkOption {
              type = types.str;
              default = "127.0.0.1";
              example = "0.0.0.0";
            };
          };

          grpc = {
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
              -server.http-listen-port ${cfg.args.http.port} \
              -server.http-listen-address ${cfg.args.http.address} \
              -server.grpc-listen-port ${cfg.args.grpc.address} \
              -server.grpc-listen-address ${cfg.args.grpc.address} \
              -log.level ${cfg.log.level} \
              -log.format ${cfg.log.format}
            '';
          };
        };
      };
    };
}
