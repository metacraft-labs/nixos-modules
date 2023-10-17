{
  description = "Metacraft Nixos Modules";

  inputs = {
    nixos-2305.url = "github:NixOS/nixpkgs/nixos-23.05";

    nixpkgs.follows = "nixos-2305";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-23.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-darwin = {
      url = "github:LnL7/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    systems.url = "github:nix-systems/default";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-stable.follows = "nixpkgs";
      inputs.flake-compat.follows = "flake-compat";
      inputs.flake-utils.follows = "flake-utils";
    };

    hercules-ci-effects = {
      url = "github:hercules-ci/hercules-ci-effects";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.hercules-ci-agent.follows = "hercules-ci-agent";
      inputs.flake-parts.follows = "flake-parts";
    };

    hercules-ci-agent = {
      url = "github:hercules-ci/hercules-ci-agent";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    ethereum-nix = {
      url = "github:metacraft-labs/ethereum.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";
      inputs.flake-parts.follows = "flake-parts";
      inputs.flake-compat.follows = "flake-compat";
      inputs.hercules-ci-effects.follows = "hercules-ci-effects";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.darwin.follows = "nix-darwin";
      inputs.home-manager.follows = "home-manager";
    };

    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.pre-commit-hooks.follows = "pre-commit-hooks";
      inputs.flake-compat.follows = "flake-compat";
    };

    cachix = {
      url = "github:cachix/cachix";
      inputs.flake-compat.follows = "flake-compat";
      inputs.devenv.follows = "devenv";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
      inputs.pre-commit-hooks.follows = "pre-commit-hooks";
    };

    nixos-images = {
      url = "github:nix-community/nixos-images";
      inputs.nixos-2305.follows = "nixos-2305";
      inputs.nixos-unstable.follows = "nixpkgs-unstable";
    };

    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixos-images.follows = "nixos-images";
      inputs.flake-parts.follows = "flake-parts";
      inputs.disko.follows = "disko";
      inputs.nixos-2305.follows = "nixos-2305";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    cachix-deploy = {
      url = "github:cachix/cachix-deploy-flake";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.disko.follows = "disko";
      inputs.home-manager.follows = "home-manager";
      inputs.darwin.follows = "nix-darwin";
      inputs.nixos-anywhere.follows = "nixos-anywhere";
    };

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils-plus = {
      url = "github:gytis-ivaskevicius/flake-utils-plus";
      inputs.flake-utils.follows = "flake-utils";
    };

    nixd = {
      url = "github:nix-community/nixd";
      inputs.flake-parts.follows = "flake-parts";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    validator-ejector = {
      url = "github:metacraft-labs/validator-ejector?ref=add/nix-package";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    cachix-deploy,
    home-manager,
    ...
  }: let
    lib = import "${nixpkgs}/lib";
    flake = import "${self}/flake.nix";
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
      perSystem = {
        pkgs,
        lib,
        system,
        unstablePkgs,
        inputs',
        ...
      }: let
        cachix-deploy-lib = cachix-deploy.lib pkgs;
        inherit (pkgs.lib) hasSuffix;
        utils = import "${self}/lib";
      in {
        imports = [
          (import ./packages {inherit pkgs inputs';})
        ];
        devShells.default = import ./shells/default.nix {inherit pkgs flake inputs';};
        devShells.ci = import ./shells/ci.nix {inherit pkgs;};
      };
      flake.lib.create = {
        rootDir,
        machinesDir ? null,
        usersDir ? null,
      }: {
        dirs = {
          lib = self + "/lib";
          services = self + "/services";
          modules = self + "/modules";
          machines = rootDir + "/machines";
        };
        libs = {
          make-config = import ./lib/make-config.nix {inherit lib rootDir machinesDir usersDir;};
          utils = import ./lib {inherit usersDir rootDir machinesDir;};
        };
      };
    };
}
