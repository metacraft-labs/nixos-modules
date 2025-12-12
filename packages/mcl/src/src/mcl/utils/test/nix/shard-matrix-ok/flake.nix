{
  inputs = {
    # nixos-modules.url = "path:../../../../../../../../../";
    nixos-modules.url = "github:metacraft-labs/nixos-modules?rev=5a74e7c75fe50d89daf05a73450262ee24b45c79";
    nixpkgs.follows = "nixos-modules/nixpkgs";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
      nixos-modules,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } ({ config, lib, ... }: {
      systems = [ "x86_64-linux" ];
      imports = [ nixos-modules.modules.flake.shardSplit ];

      mcl.matrix.shard = {
        size = 10;
        perSystemAttributePath = [
          "legacyPackages"
          "ci-checks"
        ];
        systemsToBuild = config.systems;
      };

      perSystem =
        {
          pkgs,
          lib,
          ...
        }:
        {
          legacyPackages.ci-checks = lib.pipe (lib.range 0 100) [
            (map builtins.toString)
            (
              x:
              lib.genAttrs x (
                i:
                pkgs.runCommandLocal "test-${i}" { } ''
                  echo 'The answer is ${i}!' > $out
                ''
              )
            )
          ];
        };
    });
}
