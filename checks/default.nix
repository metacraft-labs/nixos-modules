{ ... }:
{
  imports = [
    ./desktop-vms
    ./deployment-docs.nix
    ./deployment-cache.nix
    ./linux-vm-cloud-init
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
