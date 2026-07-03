{ lib, ... }:
{
  perSystem =
    {
      inputs',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs versionAtLeast;
      inherit (pkgs.stdenv.hostPlatform) system isLinux;
    in
    let
      nix = pkgs.nix-eval-jobs.passthru.nix;
      overrideNix = pkg: pkg.override { inherit nix; };
    in
    rec {
      legacyPackages = {
        inputs = {
          nixpkgs = rec {
            inherit (pkgs) nix-eval-jobs;
            # NOTE: Do not override `nix` here — hercules-ci-cnix-store (a
            # transitive dep) is compiled against nixpkgs' default Nix and the
            # C++ ABI breaks when a different version is spliced in.
            cachix = pkgs.haskell.lib.justStaticExecutables pkgs.haskellPackages.cachix;
            inherit nix;
            nixos-rebuild-ng = overrideNix pkgs.nixos-rebuild-ng;
            nix-fast-build = pkgs.nix-fast-build.override { inherit nix-eval-jobs; };
          };
          agenix = inputs'.agenix.packages;
          devenv = inputs'.devenv.packages;
          disko = inputs'.disko.packages // {
            default = overrideNix inputs'.disko.packages.default;
          };
          dlang-nix = inputs'.dlang-nix.packages;
          ethereum-nix = inputs'.ethereum-nix.packages;
          fenix = inputs'.fenix.packages;
          git-hooks-nix = inputs'.git-hooks-nix.packages;
          microvm = inputs'.microvm.packages;
          nix-fast-build = inputs'.nix-fast-build.packages;
          nixos-anywhere = inputs'.nixos-anywhere.packages // {
            default = overrideNix inputs'.nixos-anywhere.packages.default;
          };
          terranix = inputs'.terranix.packages;
          treefmt-nix = inputs'.treefmt-nix.packages;
        };

        rustToolchain =
          with inputs'.fenix.packages;
          with latest;
          combine [
            cargo
            clippy
            rust-analyzer
            rust-src
            rustc
            rustfmt
            targets.wasm32-wasi.latest.rust-std
          ];
      };

      packages = {
        attic-migrate-flake = pkgs.writeShellApplication {
          name = "attic-migrate-flake";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/attic-migrate-flake} "$@"
          '';
        };
        cachix-deploy-metrics = pkgs.callPackage ./cachix-deploy-metrics { };
        consumer-flake-cachix-inventory-tool = pkgs.writeShellApplication {
          name = "consumer-flake-cachix-inventory";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/consumer-flake-cachix-inventory} "$@"
          '';
        };
        consumer-flake-no-cachix-residual-tool = pkgs.writeShellApplication {
          name = "consumer-flake-no-cachix-residual";
          runtimeInputs = [ pkgs.python3 ];
          text = ''
            exec python3 ${../scripts/consumer-flake-no-cachix-residual} "$@"
          '';
        };
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation { };
        pyroscope = pkgs.callPackage ./pyroscope { };
        random-alerts = pkgs.callPackage ./random-alerts { };
        mcl = pkgs.callPackage ./mcl {
          dCompiler = inputs'.dlang-nix.packages."ldc-binary-1_38_0";
          inherit (legacyPackages.inputs.nixpkgs) cachix nix nix-eval-jobs;
        };
      }
      // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
        aztec = pkgs.callPackage ./aztec { };
      }
      // optionalAttrs isLinux {
        # Ephemeral-Windows-Runners-GARM M0 — the GARM control-plane package
        # (garm daemon + garm-cli), consumed by `services.garm` and its VM gate.
        garm = pkgs.callPackage ./garm { };
        deployment-event-metrics = pkgs.callPackage ./deployment-event-metrics { };
        folder-size-metrics = pkgs.callPackage ./folder-size-metrics { };
        ci-image = pkgs.callPackage ./ci-image {
          inherit (inputs'.nix2container.packages) nix2container;
        };
        yaml-automation-runner = pkgs.callPackage ./vm-automation { };
      };
    };
}
