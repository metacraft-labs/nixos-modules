{ ... }:
{
  imports = [
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./secret-integration
  ];
}
