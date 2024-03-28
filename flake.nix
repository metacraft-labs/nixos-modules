{
  description = "Metacraft Nixos Modules";

  inputs = {
    nixos-2311.url = "github:NixOS/nixpkgs/nixos-23.11";

    nixpkgs.follows = "nixos-2311";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-23.11";
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
      inputs.flake-parts.follows = "flake-parts";
    };

    ethereum-nix = {
      url = "github:metacraft-labs/ethereum.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-unstable.follows = "nixpkgs-unstable";
      inputs.flake-parts.follows = "flake-parts";
      inputs.flake-utils.follows = "flake-utils";
      inputs.systems.follows = "systems";
      inputs.flake-compat.follows = "flake-compat";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.darwin.follows = "nix-darwin";
      inputs.home-manager.follows = "home-manager";
    };

    devenv = {
      url = "github:cachix/devenv";
      inputs.cachix.follows = "cachix";
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
      inputs.nixos-2311.follows = "nixos-2311";
      inputs.nixos-unstable.follows = "nixpkgs-unstable";
    };

    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixos-images.follows = "nixos-images";
      inputs.flake-parts.follows = "flake-parts";
      inputs.disko.follows = "disko";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
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

    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    vscode-server = {
      url = "github:nix-community/nixos-vscode-server?rev=7e581626a07486b1779ef02320e7e310feb11611";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    ...
  }: let
    lib = import "${nixpkgs}/lib";
    flake = import "${self}/flake.nix";
  in
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        ./modules/lido
        ./modules/tailscale-autoconnect
        ./modules/grafana-agent-flow
        ./modules/pyroscope
        ./packages
      ];
      systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
      perSystem = {
        pkgs,
        inputs',
        ...
      }: {
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
