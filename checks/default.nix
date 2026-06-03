{ ... }:
{
  imports = [
    ./desktop-vms
    ./deployment-docs.nix
    ./deployment-cache.nix
    ./deployment-incus-rehearsal.nix
    ./deployment-monitoring.nix
    ./deployment-production-cutover.nix
    ./deployment-pull-agent.nix
    ./deployment-reconciler.nix
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
