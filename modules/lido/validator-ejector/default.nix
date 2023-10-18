{withSystem, ...}: {
  flake.nixosModules.lido-validator-ejector = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.lido-validator-ejector;
    package = withSystem pkgs.stdenv.hostPlatform.system (
      {config, ...}:
        config.packages.validator-ejector
    );
  in {
    options.services.lido-validator-ejector = with lib; {
      enable = mkEnableOption (lib.mdDoc "Lido Validator Ejector");

      environments = {
        execution-node = mkOption {
          type = types.str;
          example = "http://1.2.3.4:8545";
          description = ''
            Ethereum Execution Node endpoint.
          '';
        };

        consensus-node = mkOption {
          type = types.str;
          example = "http://1.2.3.4:5051";
          description = ''
            Ethereum Consensus Node endpoint.
          '';
        };

        locator-address = mkOption {
          type = types.str;
          example = "0x123";
          description = ''
            Address of the Locator contract Goerli / Mainnet.
          '';
        };

        staking-module-id = mkOption {
          type = types.int;
          example = 123;
          description = ''
            Staking Module ID for which operator ID is set, currently only one exists - (NodeOperatorsRegistry) with id 1.
          '';
        };

        operator-id = mkOption {
          type = types.int;
          example = 123;
          description = ''
            Operator ID in the Node Operators registry, easiest to get from Operators UI: Goerli/Mainnet.
          '';
        };

        messages-location = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "messages";
          description = ''
            Local folder or external storage bucket url to load json exit message files from. Required if you are using exit messages mode.
          '';
        };

        validator-exit-webhook = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "http://webhook";
          description = ''
            POST validator info to an endpoint instead of sending out an exit message in order to initiate an exit. Required if you are using webhook mode.
          '';
        };

        oracle-addresses-allowlist = mkOption {
          type = types.listOf types.str;
          example = ["0x123"];
          description = ''
            Allowed Oracle addresses to accept transactions from Goerli / Mainnet.
          '';
        };

        messages-password = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "password";
          description = ''
            Password to decrypt encrypted exit messages with. Needed only if you encrypt your exit messages.
          '';
        };

        messages-password-file = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "password_inside.txt";
          description = ''
            Path to a file with password inside to decrypt exit messages with.
            Needed only if you have encrypted exit messages. If used, MESSAGES_PASSWORD
            (not MESSAGES_PASSWORD_FILE) needs to be added to LOGGER_SECRETS in order to be sanitized.
          '';
        };

        blocks-preload = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 50000;
          description = ''
            Amount of blocks to load events from on start. Increase if daemon was not running for some time. Defaults to a week of blocks.
          '';
        };

        blocks-loop = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 900;
          description = ''
            Amount of blocks to load events from on every poll. Defaults to 3 hours of blocks.
          '';
        };

        job-interval = mkOption {
          type = types.nullOr types.int;
          default = null;
          example = 384000;
          description = ''
            Time interval in milliseconds to run checks. Defaults to time of 1 epoch
          '';
        };

        http-port = mkOption {
          type = types.nullOr types.port;
          default = null;
          example = 8989;
          description = ''
            Port to serve metrics and health check on.
          '';
        };

        run-metrics = mkOption {
          type = types.nullOr types.bool;
          default = null;
          example = false;
          description = ''
            Enable metrics endpoint.
          '';
        };

        run-health-check = mkOption {
          type = types.nullOr types.bool;
          default = null;
          example = true;
          description = ''
            Enable health check endpoint
          '';
        };

        logger-level = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "info";
          description = ''
            Severity level from which to start showing errors eg info will hide debug messages
          '';
        };

        logger-format = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "simple";
          description = ''
            Simple or JSON log output: simple/json
          '';
        };

        logger-secrets = mkOption {
          type = types.listOf types.str;
          default = [];
          example = ["MESSAGES_PASSWORD"];
          description = ''
            JSON string array of either env var keys to sanitize in logs or exact values
          '';
        };

        dry-run = mkOption {
          type = types.nullOr types.bool;
          default = null;
          example = false;
          description = ''
            Run the service without actually sending out exit messages
          '';
        };
      };
    };

    config = {
      systemd.services.lido-validator-ejector = lib.mkIf cfg.enable {
        description = "Lido Validator Ejector";

        wantedBy = ["multi-user.target"];

        environment =
          lib.filterAttrs
          (k: v: (v != "null") && (v != "") && (v != null))
          {
            EXECUTION_NODE = cfg.environments.execution-node;
            CONSENSUS_NODE = cfg.environments.consensus-node;
            LOCATOR_ADDRESS = cfg.environments.locator-address;
            STAKING_MODULE_ID = builtins.toJSON cfg.environments.staking-module-id;
            OPERATOR_ID = builtins.toJSON cfg.environments.operator-id;
            MESSAGES_LOCATION = cfg.environments.messages-location;
            VALIDATOR_EXIT_WEBHOOK = cfg.environments.validator-exit-webhook;
            ORACLE_ADDRESSES_ALLOWLIST = builtins.toJSON cfg.environments.oracle-addresses-allowlist;
            MESSAGES_PASSWORD = cfg.environments.messages-password;
            MESSAGES_PASSWORD_FILE = cfg.environments.messages-password-file;
            BLOCKS_PRELOAD = builtins.toJSON cfg.environments.blocks-preload;
            BLOCKS_LOOP = builtins.toJSON cfg.environments.blocks-loop;
            JOB_INTERVAL = builtins.toJSON cfg.environments.job-interval;
            HTTP_PORT = builtins.toJSON cfg.environments.http-port;
            RUN_METRICS = builtins.toJSON cfg.environments.run-metrics;
            RUN_HEALTH_CHECK = builtins.toJSON cfg.environments.run-health-check;
            LOGGER_LEVEL = cfg.environments.logger-level;
            LOGGER_FORMAT = cfg.environments.logger-format;
            LOGGER_SECRETS = builtins.toJSON cfg.environments.logger-secrets;
            DRY_RUN = builtins.toJSON cfg.environments.dry-run;
          };

        path = [package];

        serviceConfig = {
          ExecStart = "${lib.getExe package}";

          WorkingDirectory = "${package}/libexec/validator-ejector";
        };
      };
    };
  };
}
