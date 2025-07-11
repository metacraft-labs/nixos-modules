{ ... }:
{
  imports = [
    ./packages-ci-matrix.nix
    ./pre-commit.nix
    ./vm-tests.nix
  ];
}
