{ self, config, ... }:
{
  imports = [
    self.modules.nixos.lido-validator-ejector
  ];

  services.lido-validator-ejector = {
    enable = true;
    args = {
      messages-location = config.services.lido-withdrawals-automation.args.output-folder;
      blocks-preload = 100000;
      http-port = 8989;
      run-metrics = true;
      run-health-check = true;
      logger-level = "info";
      logger-format = "simple";
      logger-secrets = [
        "MESSAGES_PASSWORD"
        "EXECUTION_NODE"
        "CONSENSUS_NODE"
      ];
      dry-run = false;
    };
  };
}
