lib:
with lib; {
  log-level = mkOption {
    type = types.nullOr (types.enum ["error" "warning" "notice" "info" "debug"]);
    default = null;
    description = "Application log level.";
  };

  log-format = mkOption {
    type = types.nullOr (types.enum ["simple" "json"]);
    default = null;
    description = "Application log format.";
  };

  working-mode = mkOption {
    type = types.nullOr (types.enum ["finalized" "head"]);
    default = null;
    description = "Application working mode.";
  };

  http-port = mkOption {
    type = types.port;
    default = 8080;
    description = ''
      Port for Prometheus HTTP server in application on the container.
      Note: if this variable is changed, it also should be updated in prometheus.yml
    '';
  };

  external-http-port = mkOption {
    type = types.port;
    default = 8080;
    description = "Port for Prometheus HTTP server in application that is exposed to the host.";
  };

  db-max-retries = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Max retries for each query to DB.";
  };

  db-min-backoff-sec = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Min backoff for DB query retrier (sec).";
  };

  db-max-backoff-sec = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Max backoff for DB query retrier (sec).";
  };

  dry-run = mkOption {
    type = types.nullOr types.bool;
    default = null;
    description = "Run application in dry mode. This means that it runs a main cycle once every 24 hours.";
  };

  node-env = mkOption {
    type = types.nullOr (types.enum ["development" "production" "staging" "testnet" "test"]);
    default = null;
    description = "Node.js environment.";
  };

  eth-network = mkOption {
    type = types.nullOr (types.enum [1 5 17000 1337702]);
    description = "Ethereum network ID for connection execution layer RPC.";
  };

  el-rpc-urls = mkOption {
    type = types.nullOr types.str;
    description = "Ethereum execution layer comma-separated RPC URLs.";
  };

  cl-api-urls = mkOption {
    type = types.nullOr types.str;
    description = "Ethereum consensus layer comma-separated API URLs.";
  };

  cl-api-retry-delay-ms = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer request retry delay (ms).";
  };

  cl-api-get-response-timeout = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer GET response (header) timeout (ms).";
  };

  cl-api-max-retries = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer max retries for all requests.";
  };

  cl-api-get-block-info-max-retries = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer max retries for fetching block info. Independent of CL_API_MAX_RETRIES.";
  };

  fetch-interval-slots = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Count of slots in Ethereum consensus layer epoch.";
  };

  chain-slot-time-seconds = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer time slot size (sec).";
  };

  start-epoch = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer epoch for start application.";
  };

  dencun-fork-epoch = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Ethereum consensus layer epoch when the Dencun hard fork has been released. This value must be set only for custom networks that support the Dencun hard fork. If the value of this variable is not specified for a custom network, it is supposed that this network doesn't support Dencun. For officially supported networks (Mainnet, Goerli and Holesky) this value should be omitted.";
  };

  validator-registry-source = mkOption {
    type = types.nullOr (types.enum ["lido" "keysapi" "file"]);
    default = null;
    description = "Validators registry source.";
  };

  validator-registry-file-source-path = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Validators registry file source path.
      Note: it makes sense to change default value if VALIDATOR_REGISTRY_SOURCE is set to "file"
    '';
  };

  validator-registry-lido-source-sqlite-cache-path = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Validators registry lido source sqlite cache path.
      Note: it makes sense to change default value if VALIDATOR_REGISTRY_SOURCE is set to "lido"
    '';
  };

  validator-registry-keysapi-source-urls = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Note: will be used only if VALIDATOR_REGISTRY_SOURCE is set to "keysapi"
      Comma-separated list of URLs to Lido Keys API service.
    '';
  };

  validator-registry-keysapi-source-retry-delay-ms = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Retry delay for requests to Lido Keys API service (ms).";
  };

  validator-registry-keysapi-source-response-timeout = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Response timeout (ms) for requests to Lido Keys API service (ms).";
  };

  validator-registry-keysapi-source-max-retries = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Max retries for each request to Lido Keys API service.";
  };

  validator-use-stuck-keys-file = mkOption {
    type = types.nullOr types.bool;
    default = null;
    description = "Use a file with list of validators that are stuck and should be excluded from the monitoring metrics.";
  };

  validator-stuck-keys-file-path = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''
      Path to file with list of validators that are stuck and should be excluded from the monitoring metrics.
      Note: will be used only if VALIDATOR_USE_STUCK_KEYS_FILE is true
    '';
  };

  sync-participation-distance-down-from-chain-avg = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Distance (down) from Blockchain Sync Participation average after which we think that our sync participation is bad.";
  };

  sync-participation-epochs-less-than-chain-avg = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Number epochs after which we think that our sync participation is bad and alert about that.";
  };

  bad-attestation-epochs = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Number epochs after which we think that our attestation is bad and alert about that.";
  };

  critical-alerts-alertmanager-url = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "If passed, application sends additional critical alerts about validators performance to Alertmanager.";
  };

  critical-alerts-min-val-count = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "Critical alerts will be sent for Node Operators with validators count greater this value.";
  };

  critical-alerts-alertmanager-labels = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = ''Additional labels for critical alerts. Must be in JSON string format. Example - '{" a ":" valueA "," b ":" valueB "};'.'';
  };
}
