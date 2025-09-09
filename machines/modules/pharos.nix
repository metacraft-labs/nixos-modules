{ self, ... }:
{
  imports = [
    self.modules.nixos.pharos
  ];

  services.pharos = {
    enable = true;
    network = "testnet";
  };
}
