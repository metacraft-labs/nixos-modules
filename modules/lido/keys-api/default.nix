{withSystem, ...}: {
  flake.nixosModules.lido-keys-api = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.lido-keys-api;
    package = withSystem pkgs.stdenv.hostPlatform.system (
      {config, ...}:
        config.packages.lido-keys-api
    );
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

        global-trottle-limit = mkOption {
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
        containers.lido-keys-api = {
          image = "lidofinance/lido-keys-api:stable";
          environment =
            lib.filterAttrs
            (k: v: (v != "null") && (v != "") && (v != null))
            {
              PORT = cfg.args.port;
              CORS_WHITELIST_REGEXP = cfg.args.cors-whitelist-regexp;
              GLOBAL_THROTTLE_TTL = cfg.args.global-throttle-ttl;
              GLOBAL_THROTTLE_LIMIT = cfg.args.global-trottle-limit;
              GLOBAL_CACHE_TTL = cfg.args.global-cache-ttl;
              SENTRY_DSN = cfg.args.sentry-dsn;
              LOG_LEVEL = cfg.args.log-level;
              LOG_FORMAT = cfg.args.log-format;
              PROVIDERS_URLS = cfg.args.providers-urls;
              CHRONIX_PROVIDER_MAINNET_URL = cfg.args.chronix-provider-mainnet-url;
              CHAIN_ID = cfg.args.chain-id;
              DB_NAME = cfg.args.db-name;
              DB_PORT = cfg.args.db-port;
              DB_HOST = cfg.args.db-host;
              DB_USER = cfg.args.db-user;
              DB_PASSWORD = cfg.args.db-password;
              PROVIDER_JSON_RPC_MAX_BATCH_SIZE = cfg.args.provider-json-rpc-max-batch-size;
              PROVIDER_CONCURRENT_REQUESTS = cfg.args.provider-concurrent-requests;
              PROVIDER_BATCH_AGGREGATION_WAIT_MS = cfg.args.provider-batch-aggregation-wait-ms;
              CL_API_URLS = cfg.args.cl-api-urls;
              VALIDATOR_REGISTRY_ENABLE = cfg.args.validator-registry-enable;
            };
        };
      };

      #   systemd.services.lido-keys-api = lib.mkIf cfg.enable {
      #     description = "Lido Keys API";

      #     wantedBy = ["multi-user.target"];

      #     environment =
      #       lib.filterAttrs
      #       (k: v: (v != "null") && (v != "") && (v != null))
      #       {
      #         PORT = cfg.args.port;
      #         CORS_WHITELIST_REGEXP = cfg.args.cors-whitelist-regexp;
      #         GLOBAL_THROTTLE_TTL = cfg.args.global-throttle-ttl;
      #         GLOBAL_THROTTLE_LIMIT = cfg.args.global-trottle-limit;
      #         GLOBAL_CACHE_TTL = cfg.args.global-cache-ttl;
      #         SENTRY_DSN = cfg.args.sentry-dsn;
      #         LOG_LEVEL = cfg.args.log-level;
      #         LOG_FORMAT = cfg.args.log-format;
      #         PROVIDERS_URLS = cfg.args.providers-urls;
      #         CHRONIX_PROVIDER_MAINNET_URL = cfg.args.chronix-provider-mainnet-url;
      #         CHAIN_ID = cfg.args.chain-id;
      #         DB_NAME = cfg.args.db-name;
      #         DB_PORT = cfg.args.db-port;
      #         DB_HOST = cfg.args.db-host;
      #         DB_USER = cfg.args.db-user;
      #         DB_PASSWORD = cfg.args.db-password;
      #         PROVIDER_JSON_RPC_MAX_BATCH_SIZE = cfg.args.provider-json-rpc-max-batch-size;
      #         PROVIDER_CONCURRENT_REQUESTS = cfg.args.provider-concurrent-requests;
      #         PROVIDER_BATCH_AGGREGATION_WAIT_MS = cfg.args.provider-batch-aggregation-wait-ms;
      #         CL_API_URLS = cfg.args.cl-api-urls;
      #         VALIDATOR_REGISTRY_ENABLE = cfg.args.validator-registry-enable;
      #       };

      #     path = [package];

      #     serviceConfig = {
      #       ExecStart = "asd";
      #       WorkingDirectory = "asdf";
      #     };
      #   };
    };
  };
}
