{ ... }:
{
  imports = [
    ./desktop-vms
    ./deployment-docs.nix
    ./deployment-cache.nix
    ./deployment-monitoring.nix
    ./deployment-reconciler.nix
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
