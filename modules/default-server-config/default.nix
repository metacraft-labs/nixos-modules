{dirs, ...}: {
  imports = [
    "${dirs.modules}/host-info.nix"
    "${dirs.modules}/users.nix"
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
