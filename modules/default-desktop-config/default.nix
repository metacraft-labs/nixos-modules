{lib, ...}: {
  imports = [
    ../default-server-config
    ./boot.nix
    ./gnome_desktop_env.nix
    ./ledger-nano-udev-rules.nix
    ./packages.nix
    ./sleep.nix
    ./virtualisation.nix
  ];

  mcl.sleep.enable = lib.mkDefault false;
}
