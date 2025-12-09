{
  inputs = {
    nixos-modules.url = "github:metacraft-labs/nixos-modules?rev=a6302392aa47a0820d4e1fbd3e565df6c2d01084";
    nixpkgs.follows = "nixos-modules/nixpkgs";
    flake-parts.follows = "nixos-modules/flake-parts";
  };

  outputs =
    inputs@{
      flake-parts,
      nixos-modules,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = [ nixos-modules.flakeModules.shardSplit ];

      mcl.matrix.shard = {
        size = 10;
        attributePath = [
          "legacyPackages"
          "ci-checks"
        ];
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
    };
}
