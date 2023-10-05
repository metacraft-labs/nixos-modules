{dirs, ...}: {
  imports = [
    "../host-info.nix"
    "../users.nix"
    ./i18n.nix
    ./networking.nix
    ./nix.nix
    ./packages.nix
    ./services.nix
    ./motd.nix
    ./users.nix
    ./zfs_snapshots.nix
  ];
}
