{ ... }:
{
  imports = [
    ./ci-workflows.nix
    ./desktop-vms
    ./deployment-docs.nix
    ./deployment-cache.nix
    ./deployment-incus-rehearsal.nix
    ./deployment-monitoring.nix
    ./deployment-production-cutover.nix
    ./deployment-pull-agent.nix
    ./deployment-reconciler.nix
    ./consumer-flake-attic.nix
    ./linux-vm-cloud-init
    ./netbird-with-agenix.nix
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
