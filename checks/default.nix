{ ... }:
{
  imports = [
    ./desktop-vms
    ./deployment-docs.nix
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
