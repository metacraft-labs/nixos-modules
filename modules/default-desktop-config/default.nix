{
  all = import ./all.nix;
  boot = import ./boot.nix;
  gnome_desktop_env = import ./gnome_desktop_env.nix;
  ledger-nano-udev-rules = import ./ledger-nano-udev-rules.nix;
  packages = import ./packages.nix;
  services = import ./services.nix;
  sleep = import ./sleep.nix;
  users = import ./users.nix;
  virtualisation = import ./virtualisation.nix;
}
