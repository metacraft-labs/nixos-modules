{
  pkgs,
  config,
  lib,
  ...
}: {
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "esphome"
      "met"
      "radio_browser"
    ];
    config = {
      default_config = {};
      http = {
        server_host = "localhost";
        trusted_proxies = ["localhost"];
        use_x_forwarded_for = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = lib.mkIf (config.services.tailscale.enable == true) [8123];
}
