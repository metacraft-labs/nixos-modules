{ ... }:
{
  imports = [
    ./desktop-vms
    ./deployment-docs.nix
    ./deployment-cache.nix
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
