{ self, ... }:
{
  imports = [
    self.modules.nixos.mcl-secrets
  ];

  #TODO: Figure out the arguments for this service and enable it
}
