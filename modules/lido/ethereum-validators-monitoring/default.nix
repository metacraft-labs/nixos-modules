{ withSystem, ... }:
{
  flake.nixosModules.ethereum-validators-monitoring =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      db = config.services.ethereum-validators-monitoring.db;
      eachService = config.services.ethereum-validators-monitoring.instances;
      inherit (import ../../lib.nix { inherit lib; }) toEnvVariables;

      args = import ./args.nix lib;

      monitoringOptions = with lib; {
        options = {
          enable = mkEnableOption (lib.mdDoc "Ethereum Validators Monitoring");
          inherit args;
        };
      };
    in
    {
      options.services.ethereum-validators-monitoring = with lib; {
        instances = mkOption {
          type = types.attrsOf (types.submodule monitoringOptions);
          default = { };
          description = mdDoc "Specification of one or Ethereum Validators Monitoring instances.";
        };

        db = {
          host = mkOption {
            type = types.str;
            description = "Clickhouse server host.";
          };

          user = mkOption {
            type = types.str;
            description = "Clickhouse server user.";
          };

          password-file = mkOption {
            type = types.path;
            description = "Clickhouse server password file.";
          };

          name = mkOption {
            type = types.str;
            description = "Clickhouse server DB name.";
          };

          port = mkOption {
            type = types.port;
            default = 8123;
            description = "Clickhouse server port.";
          };
        };
      };

      config = lib.mkIf (eachService != { }) {
        systemd.services.ethereum-validators-monitoring-preStart = {
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];
          script = ''
            umask 177
            mkdir -p /var/lib/ethereum-validators-monitoring
            echo DB_PASSWORD="$(cat ${db.password-file})" > /var/lib/ethereum-validators-monitoring/env
            echo CLICKHOUSE_PASSWORD="$(cat ${db.password-file})" > /var/lib/ethereum-validators-monitoring/clickhouse-env
          '';
        };

        virtualisation.oci-containers = {
          backend = "docker";
          containers =
            (lib.mapAttrs' (
              name:
              let
                serviceName = "ethereum-validators-monitoring-${name}";
              in
              cfg:
              lib.nameValuePair serviceName (
                lib.mkIf cfg.enable {
                  image = "lidofinance/ethereum-validators-monitoring:4.5.1";
                  environment = (toEnvVariables cfg.args) // {
                    DB_HOST = db.host;
                    DB_USER = db.user;
                    DB_NAME = db.name;
                    DB_PORT = toString db.port;
                  };
                  environmentFiles = [ "/var/lib/ethereum-validators-monitoring/env" ];
                  ports = [ "${toString cfg.args.external-http-port}:${toString cfg.args.external-http-port}" ];
                  dependsOn = [ "clickhouse-server" ];
                  extraOptions = [
                    "--network=host"
                  ];
                }
              )
            ) eachService)
            // {
              clickhouse-server = {
                image = "yandex/clickhouse-server";
                environment = {
                  CLICKHOUSE_USER = db.user;
                  CLICKHOUSE_DB = db.name;
                };
                environmentFiles = [ "/var/lib/ethereum-validators-monitoring/clickhouse-env" ];
                ports = [ "${toString db.port}:${toString db.port}" ];
                volumes = [ "./.volumes/clickhouse:/var/lib/clickhouse" ];
                extraOptions = [
                  "--network=host"
                ];
              };

              clickhouse-client = {
                image = "yandex/clickhouse-client";
                entrypoint = "/usr/bin/env";
                cmd = [
                  "sleep"
                  "infinity"
                ];
                extraOptions = [
                  "--network=host"
                ];
              };

              cadvisor = {
                image = "zcube/cadvisor:latest";
                ports = [ "8080:8080" ];
                volumes = [
                  "/:/rootfs:ro"
                  "/var/run:/var/run:rw"
                  "/sys:/sys:ro"
                  "/var/lib/docker/:/var/lib/docker:ro"
                ];
                extraOptions = [
                  "--network=host"
                ];
              };
            };
        };
      };
    };
}
