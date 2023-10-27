{withSystem, ...}: {
  flake.nixosModules.lido-keys-api = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.lido-keys-api;
    inherit (import ../../lib.nix {inherit lib;}) toEnvVariables;
  in {
    options.services.lido-keys-api = with lib; {
      enable = mkEnableOption (lib.mdDoc "Lido Keys API");
      args = {
        port = mkOption {
          type = types.nullOr types.port;
          default = null;
          example = 3000;
        };

        cors-whitelist-regexp = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "^https?://(?:.+?\.)?(?:lido|testnet|mainnet)\.fi$";
        };

        global-throttle-ttl = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 5;
          description = ''
            The number of seconds that each request will last in storage
          '';
        };

        global-throttle-limit = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 100;
          description = ''
            The maximum number of requests within the TTL limit
          '';
        };

        global-cache-ttl = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 1;
          description = ''
            Cache expiration time in seconds
          '';
        };

        sentry-dsn = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "";
        };

        log-level = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "debug";
          description = ''
            Log level: debug, info, notice, warning or error
          '';
        };

        log-format = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "json";
          description = ''
            Log format: simple or json
          '';
        };

        providers-urls = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://mainnet.infura.io/v3/XXX,https://eth-mainnet.alchemyapi.io/v2/YYY";
        };

        chronix-provider-mainnet-url = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://mainnet.infura.io/v3/XXX,https://eth-mainnet.alchemyapi.io/v2/YYY";
          description = ''
            provider url for e2e tests
          '';
        };

        chain-id = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 1;
          description = ''
            chain id
            for mainnet 1
            for testnet 5
          '';
        };
        db-name = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "node_operator_keys_service_db";
        };

        db-port = mkOption {
          type = types.nullOr types.port;
          default = null;
          example = 5432;
        };

        db-host = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "localhost";
        };

        db-user = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "postgres";
        };

        db-password = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "postgres";
        };

        provider-json-rpc-max-batch-size = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 100;
        };

        provider-concurrent-requests = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 5;
        };

        provider-batch-aggregation-wait-ms = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 10;
        };

        cl-api-urls = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "https://quiknode.pro/<token>";
        };

        validator-registry-enable = mkOption {
          type = types.nullOr types.bool;
          default = null;
          example = true;
        };
      };
    };

    config = {
      virtualisation.oci-containers = lib.mkIf cfg.enable {
        backend = "docker";
        containers = {
          lido-keys-api = {
            image = "lidofinance/lido-keys-api:stable";
            environment = toEnvVariables cfg.args;
            ports = ["${toString cfg.args.port}:${toString cfg.args.port}"];
            dependsOn = ["postgresql-lido"];
          };

          postgresql-lido = {
            image = "postgres:16-alpine";
            environment = {
              POSTGRES_DB = "${cfg.args.db-name}";
              POSTGRES_USER = "${cfg.args.db-user}";
              POSTGRES_PASSWORD = "${cfg.args.db-password}";
            };
            ports = ["${toString cfg.args.db-port}:${toString cfg.args.db-port}"];
          };
        };
      };
    };
  };
}
