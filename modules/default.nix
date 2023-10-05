{
  default-desktop-config = import ./default-desktop-config;
  default-server-config = import ./default-server-config;
  default-vm-config = import ./default-vm-config;
  home = import ./home;
  hw = import ./hw;
  tailscale-autoconnect = import ./tailscale-autoconnect;
  host-info = import ./host-info.nix;
  users = import ./users.nix;
}
