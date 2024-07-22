{lib, ...}: let
  inherit (import ../../lib/shard-attrs.nix lib) shardAttrs;
in {
  flake.flakeModules.shardSplit = {config, ...}: let
    cfg = config.mcl.matrix.shard;
  in {
    options.mcl.matrix.shard = with lib; {
      size = mkOption {
        type = types.numbers.positive;
        default = 1;
        description = "Number of shards to use for parallel builds";
      };
      attributePath = mkOption {
        type = types.listOf types.str;
        default = ["legacyPackages" "checks"];
        description = "The attribute path to split into shards";
      };
    };

    config = {
      perSystem = {self', ...}: let
        inherit (cfg) size attributePath;
        attrs = lib.attrByPath attributePath {} self';
        shards = shardAttrs attrs size;
      in {
        legacyPackages.mcl.matrix = {
          shardCount = builtins.length (builtins.attrValues shards);
          shardSize = cfg.size;
          inherit shards attributePath;
        };
      };
    };
  };
}
