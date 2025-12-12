{ lib, flake-parts-lib, ... }:
let
  inherit (import ../../lib/shard-attrs.nix lib) shardAttrs;
in
{
  flake.modules.flake.shardSplit =
    { config, ... }:
    let
      cfg = config.mcl.matrix.shard;
    in
    {
      options = let
        inherit (lib)
          mkOption
          types
          ;
      in {
        perSystem = flake-parts-lib.mkPerSystemOption ({ config, self', ... }: {
          mcl.matrix = let
            inherit (cfg) size perSystemAttributePath;
            attrs = lib.attrByPath perSystemAttributePath { } self';
            shards = shardAttrs attrs size;
          in {
            shards = mkOption {
              type = types.attrOf types.package;
              readOnly = true;
              default = shards;
            };
            shardCount = mkOption {
              type = types.ints.unsigned;
              readOnly = true;
              default = builtins.length (builtins.attrValues shards);
            };
            perSystemAttributePath = mkOption {
              type = types.listOf types.str;
              default = perSystemAttributePath;
            };
          };
        });
        mcl.matrix.shard = {
          size = mkOption {
            type = types.numbers.positive;
            default = 1;
            description = "Number of shards to use for parallel builds";
          };
          perSystemAttributePath = mkOption {
            type = types.listOf types.str;
            description = ''
              Flake attribute path (with each system from `systemsToBuild` interpolated after the first attribute) to extract packages from to split into shards.

              `["legacyPackages", "checks"]` -> `outputs.legacyPackages.''${system}.checks`
            '';
            default = [
              "legacyPackages"
              "checks"
            ];
          };
          systemsToBuild = mkOption {
            type = types.listOf types.str;
            default = [
              "x86_64-linux"
              "aarch64-linux"
              # NOTE: disabled because unneeded
              # "x86_64-darwin"
              "aarch64-darwin"
            ];
          };
        };
      };

      config = {
        perSystem =
          { self', system, ... }:
          let
            inherit (cfg) size perSystemAttributePath;
            attrs = lib.attrByPath perSystemAttributePath { } self';
            shards = shardAttrs attrs size;
          in
          {
            legacyPackages.mcl.matrix = lib.mkIf (lib.elem system cfg.systemsToBuild) {
              shardCount = builtins.length (builtins.attrValues shards);
              shardSize = cfg.size;
              inherit shards perSystemAttributePath;
            };
          };
      };
    };
}
