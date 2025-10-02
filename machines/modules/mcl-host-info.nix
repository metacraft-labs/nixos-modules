{ self, ... }:
{
  imports = [
    self.modules.nixos.mcl-host-info
  ];

  mcl.host-info = {
    type = "server";
    isDebugVM = true;
    configPath = ./.;
  };
}
