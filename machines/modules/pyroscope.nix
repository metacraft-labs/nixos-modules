{ self, ... }:
{
  imports = [
    self.modules.nixos.pyroscope
  ];

  services.pyroscope = {
    enable = true;
  };
}
