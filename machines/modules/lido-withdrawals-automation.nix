{ self, ... }:
{
  imports = [
    self.modules.nixos.lido-withdrawals-automation
  ];

  services.lido-withdrawals-automation = {
    enable = true;
    args = {
      operator-id = "";
      password = "";
      percentage = 10;
      output-folder = "/ethereum/lido/withdrawal-automation";
      overwrite = "always";
    };
  };
}
