{
  lib,
  inputs,
  ...
}:
{
  perSystem =
    {
      inputs',
      self',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs;
      inherit (pkgs.stdenv.hostPlatform) system isLinux;
    in
    rec {
      checks =
        self'.packages
        // {
          inherit (self'.legacyPackages) rustToolchain;
          inherit (self'.legacyPackages.inputs.dlang-nix) dub;
          inherit (self'.legacyPackages.inputs.nixpkgs)
            cachix
            nix
            nix-eval-jobs
            nix-fast-build
            nixos-rebuild-ng
            ;
          inherit (self'.legacyPackages.inputs.ethereum-nix) foundry;
        }
        // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
          inherit (self'.legacyPackages.inputs.ethereum-nix) geth;
        }
        // optionalAttrs isLinux {
          disko = self'.legacyPackages.inputs.disko.default;
          nixos-anywhere = self'.legacyPackages.inputs.nixos-anywhere.default;
        }
        // optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) terraform;
          inherit (self'.legacyPackages.inputs.terranix) terranix;
          inherit (self'.legacyPackages.inputs.dlang-nix)
            dscanner
            serve-d
            dmd
            ldc
            ;
          # dlang.nix pins DCD's source with `leaveDotGit = true`, which makes the
          # fixed-output derivation non-reproducible: the packed `.git` directory depends
          # on GitHub's git-server behaviour, so the upstream-pinned hash silently drifted.
          # It only stayed green while a previously-built output was available from the
          # binary cache; once that output was gone the FOD was rebuilt and the hash
          # mismatch surfaced. The build never needs `.git` (it stubs `git` and seds out
          # `git describe`), so re-fetch the worktree deterministically without it.
          # TODO: drop once the upstream fix lands in PetarKirov/dlang.nix.
          dcd = self'.legacyPackages.inputs.dlang-nix.dcd.overrideAttrs (old: {
            src = pkgs.fetchFromGitHub {
              owner = "dlang-community";
              repo = "DCD";
              rev = "v${old.version}";
              fetchSubmodules = true;
              hash = "sha256-c5PAUjS2+DvY1QfI+whu0bqFQl0wDUzUUtfHjRFoieA=";
            };
          });
          inherit (self'.legacyPackages.inputs.ethereum-nix)
            mev-boost
            nethermind
            web3signer
            nimbus
            erigon
            ;
        };
    };
}
