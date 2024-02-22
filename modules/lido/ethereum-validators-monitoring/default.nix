{withSystem, ...}: {
  flake.nixosModules.ethereum-validators-monitoring = {
    pkgs,
    config,
    lib,
    ...
  }: let
    db = config.services.ethereum-validators-monitoring.db;
    eachService = config.services.ethereum-validators-monitoring.network;
    inherit (import ../../lib.nix {inherit lib;}) toEnvVariables;

    args = import ./args.nix lib;

    evmOptions = with lib; {
      options = {
        enable = mkEnableOption (lib.mdDoc "Ethereum Validators Monitoring");
        inherit args;
      };
    };
  in {
    options.services.ethereum-validators-monitoring = with lib; {
      network = mkOption {
        type = types.attrsOf (types.submodule evmOptions);
        default = {};
        description = mdDoc "Specification of one or more Ethereum Validators Monitoring services.";
      };

      db = {
        db-host = mkOption {
          type = types.nullOr types.str;
          description = "Clickhouse server host.";
        };

        db-user = mkOption {
          type = types.nullOr types.str;
          description = "Clickhouse server user.";
        };

        db-password = mkOption {
          type = types.nullOr types.str;
          description = "Clickhouse server password.";
        };

        db-name = mkOption {
          type = types.nullOr types.str;
          description = "Clickhouse server DB name.";
        };

        db-port = mkOption {
          type = types.nullOr types.port;
          default = 8123;
          description = "Clickhouse server port.";
        };
      };
    };

    config = lib.mkIf (eachService != {}) {
      virtualisation.oci-containers = {
        backend = "docker";
        containers =
          (lib.mapAttrs'
            (
              name: let
                serviceName = "ethereum-validators-monitoring-${name}";
              in
                cfg:
                  lib.nameValuePair serviceName (lib.mkIf cfg.enable {
                    image = "lidofinance/ethereum-validators-monitoring:4.5.1";
                    environment =
                      (toEnvVariables cfg.args)
                      // {
                        DB_HOST = db.db-host;
                        DB_USER = db.db-user;
                        DB_PASSWORD = db.db-password;
                        DB_NAME = db.db-name;
                        DB_PORT = toString db.db-port;
                      };
                    ports = ["${toString cfg.args.external-http-port}:${toString cfg.args.external-http-port}"];
                    dependsOn = ["clickhouse-server"];
                    extraOptions = [
                      "--network=host"
                    ];
                  })
            )
            eachService)
          // {
            clickhouse-server = {
              image = "yandex/clickhouse-server";
              environment = {
                CLICKHOUSE_USER = db.db-user;
                CLICKHOUSE_PASSWORD = db.db-password;
                CLICKHOUSE_DB = db.db-name;
              };
              ports = ["${toString db.db-port}:${toString db.db-port}"];
              volumes = ["./.volumes/clickhouse:/var/lib/clickhouse"];
              extraOptions = [
                "--network=host"
              ];
            };

            clickhouse-client = {
              image = "yandex/clickhouse-client";
              entrypoint = "/usr/bin/env";
              cmd = ["sleep" "infinity"];
              extraOptions = [
                "--network=host"
              ];
            };

            cadvisor = {
              image = "zcube/cadvisor:latest";
              ports = ["8080:8080"];
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
