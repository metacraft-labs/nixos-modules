{
  i18n = import ./i18n.nix;
  networking = import ./networking.nix;
  nix = import ./nix.nix;
  packages = import ./packages.nix;
  services = import ./services.nix;
  motd = import ./motd.nix;
  users = import ./users.nix;
  zfs_snapshots = import ./zfs_snapshots.nix;
}
