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

      expectedNixVersion = pkgs.nix.version;

      # Eval-time check: verify that all known sources of nix version agree.
      # pkgs.nix is set by the overlay to nix-eval-jobs.passthru.nix.
      # Other packages (nixos-rebuild-ng, nix-fast-build, disko, nixos-anywhere)
      # get nix from pkgs.nix via callPackage or explicit override.
      nixVersionChecks = {
        "pkgs.nix" = pkgs.nix.version;
        "nix-eval-jobs" = pkgs.nix-eval-jobs.passthru.nix.version;
      };

      traceVersions = lib.foldl' (
        acc: name:
        let
          version = nixVersionChecks.${name};
          status = if version == expectedNixVersion then "OK" else "FAIL";
        in
        builtins.trace "${status}: ${name} -> nix ${version}" acc
      ) true (lib.attrNames nixVersionChecks);

      mismatches = lib.filterAttrs (_: v: v != expectedNixVersion) nixVersionChecks;

      nix-version-consistency =
        assert traceVersions;
        assert
          mismatches == { }
          || throw (
            "Nix version mismatch! Expected ${expectedNixVersion}, got:\n"
            + lib.concatStrings (lib.mapAttrsToList (name: version: "  - ${name}: ${version}\n") mismatches)
          );
        pkgs.runCommand "nix-version-consistency" { allowSubstitutes = false; } "touch $out";
    in
    rec {
      checks =
        self'.packages
        // {
          inherit nix-version-consistency;
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
          inherit (self'.legacyPackages.inputs) disko nixos-anywhere;
        }
        // optionalAttrs (system == "x86_64-linux") {
          inherit (pkgs) terraform;
          inherit (self'.legacyPackages.inputs.terranix) terranix;
          inherit (self'.legacyPackages.inputs.dlang-nix)
            dcd
            dscanner
            serve-d
            dmd
            ldc
            ;
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
