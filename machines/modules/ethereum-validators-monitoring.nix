{ self, ... }:
{
  imports = [
    self.modules.nixos.ethereum-validators-monitoring
  ];

  services.ethereum-validators-monitoring = {
    db = {
      host = "http://localhost:8123/";
      user = "ethereum";
      password-file = ../blankpass.txt;
      name = "ethereum";
    };
    instances = {
      # The Ethereum Validator Monitoring sends out too many requests to servers,
      # which causes attestations to be missing. Therefore, as we lack a
      # dedicated server, we are unable to have e-v-m.
    };
  };
}
