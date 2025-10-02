{ self, ... }:
{
  imports = [
    self.modules.nixos.lido-keys-api
  ];

  services.lido-keys-api = {
    enable = true;
    args = {
      port = 3000;
      cors-whitelist-regexp = "^https?://(?:.+?\.)?(?:lido|testnet|mainnet|holesky)\.fi$";
      global-throttle-ttl = 5;
      global-throttle-limit = 100;
      global-cache-ttl = 1;
      sentry-dsn = "";
      log-level = "debug";
      log-format = "json";
      db-name = "node_operator_keys_service_db";
      db-port = 5432;
      db-host = "127.0.0.1";
      db-user = "postgres";
      db-password = "";
      provider-json-rpc-max-batch-size = 100;
      provider-concurrent-requests = 5;
      provider-batch-aggregation-wait-ms = 10;
      validator-registry-enable = true;
    };
  };

}
