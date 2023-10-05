{
  networking.networkmanager.enable = true;
  systemd.network.wait-online.anyInterface = true;
  systemd.services.NetworkManager-wait-online.enable = false;
}
