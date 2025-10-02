{ self, ... }:
{
  imports = [
    self.modules.nixos.random-alerts
  ];

  #TODO: Figure out the arguments for this service and enable it
}
