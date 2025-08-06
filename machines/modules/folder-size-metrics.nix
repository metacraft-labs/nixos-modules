{ self, ... }:
{
  imports = [
    self.modules.nixos.folder-size-metrics
  ];

  services.folder-size-metrics = {
    enable = true;
    # args = { #Unchanged
    #   port = 8888;
    #   base-path = "/var/lib";
    #   interval-sec = 60;
    # };
  };
}
