{
  description = "Metacraft Nixos Modules";

  nixConfig = {
    extra-substituters = [
      "https://mcl-public-cache.cachix.org"
      "https://dlang-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "mcl-public-cache.cachix.org-1:OcUzMeoSAwNEd3YCaEbNjLV5/Gd+U5VFxdN2WGHfpCI="
      "dlang-community.cachix.org-1:eAX1RqX4PjTDPCAp/TvcZP+DYBco2nJBackkAJ2BsDQ="
    ];
  };

  inputs = {
    nixos-2311.url = "github:NixOS/nixpkgs/nixos-23.11";
    nixos-2405.url = "github:NixOS/nixpkgs/nixos-24.05";
    nixos-2411.url = "github:NixOS/nixpkgs/nixos-24.11";

    nixpkgs.follows = "nixos-2411";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      url = "github:nix-community/home-manager/release-24.11";
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

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    hercules-ci-effects = {
      url = "github:hercules-ci/hercules-ci-effects";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    ethereum-nix = {
      url = "github:metacraft-labs/ethereum.nix";
      inputs = {
        nixpkgs.follows = "nixos-2405";
        nixpkgs-2311.follows = "nixos-2311";
        nixpkgs-unstable.follows = "nixpkgs-unstable";
        flake-parts.follows = "flake-parts";
        flake-utils.follows = "flake-utils";
        systems.follows = "systems";
        flake-compat.follows = "flake-compat";
        treefmt-nix.follows = "treefmt-nix";
        fenix.follows = "fenix";
      };
    };

    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        darwin.follows = "nix-darwin";
        home-manager.follows = "home-manager";
      };
    };

    devenv = {
      url = "github:cachix/devenv";
      inputs = {
        cachix.follows = "cachix";
        nixpkgs.follows = "nixpkgs";
        git-hooks.follows = "git-hooks-nix";
        flake-compat.follows = "flake-compat";
      };
    };

    cachix = {
      url = "github:cachix/cachix";
      inputs = {
        flake-compat.follows = "flake-compat";
        devenv.follows = "devenv";
        nixpkgs.follows = "nixpkgs-unstable";
        git-hooks.follows = "git-hooks-nix";
      };
    };

    nixos-images = {
      url = "github:nix-community/nixos-images";
      inputs = {
        nixos-stable.follows = "nixos-2405";
        nixos-unstable.follows = "nixpkgs-unstable";
      };
    };

    nixos-anywhere = {
      url = "github:numtide/nixos-anywhere";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        nixos-images.follows = "nixos-images";
        flake-parts.follows = "flake-parts";
        disko.follows = "disko";
        treefmt-nix.follows = "treefmt-nix";
      };
    };

    nix2container = {
      url = "github:nlewo/nix2container";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
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
      # Please refrain from adding the following line:
      # inputs.nixpkgs.follows = "nixpkgs";
      #
      # See: https://github.com/nix-community/nixd/blob/main/nixd/docs/editor-setup.md#installation---get-a-working-executable:~:text=do%20NOT%20override%20nixpkgs%20revision
    };

    validator-ejector = {
      url = "github:metacraft-labs/validator-ejector?ref=add/nix-package";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    terranix = {
      url = "github:terranix/terranix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
      };
    };

    vscode-server = {
      url = "github:nix-community/nixos-vscode-server";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    microvm = {
      url = "github:astro/microvm.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    dlang-nix = {
      url = "github:PetarKirov/dlang.nix?branch=feat/build-dub-package&rev=dab4c199ad644dc23b0b9481e2e5a063e9492b84";
      inputs = {
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
      };
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      crane,
      ...
    }:
    let
      inherit (nixpkgs) lib;
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-parts.flakeModules.modules
        ./checks
        ./modules
        ./packages
        ./shells
      ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { system, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        };
      flake.lib.create =
        {
          rootDir,
          machinesDir ? null,
          usersDir ? null,
        }:
        let
          utils = import ./lib { inherit usersDir rootDir machinesDir; };
        in
        {
          dirs = {
            lib = self + "/lib";
            services = self + "/services";
            modules = self + "/modules";
            machines = rootDir + "/machines";
          };
          libs = {
            make-config = import ./lib/make-config.nix {
              inherit
                lib
                rootDir
                machinesDir
                usersDir
                ;
            };
            inherit utils;
          };

          modules = {
            users = import ./modules/users.nix utils;
          };
        };
    };
}
