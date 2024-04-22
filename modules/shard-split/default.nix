{...}: {
  flake.flakeModules.shardSplit = {
    inputs,
    self,
    config,
    lib,
    ...
  }: {
    options = {
      shardSize = with lib;
        mkOption {
          type = types.int;
          default = 1;
          description = "Number of shards to use for parallel builds";
        };
    };
    config = {
      perSystem = {
        pkgs,
        system,
        unstablePkgs,
        inputs',
        ...
      }: let
        shardAttrs = let
          attrNames = builtins.attrNames self.legacyPackages."${system}".checks;
          len = builtins.length attrNames;
          shardCount = builtins.ceil ((0.0 + len) / config.shardSize);
          shards = builtins.map (i: lib.take config.shardSize (lib.drop (i * config.shardSize) attrNames)) (lib.range 0 (shardCount - 1));
          shardIndices = builtins.map builtins.toString (lib.range 0 (builtins.length shards));
        in
          lib.genAttrs shardIndices (idx: lib.genAttrs (builtins.elemAt shards (builtins.fromJSON idx)) (key: self.legacyPackages."${system}".checks."${key}"));
      in {
        legacyPackages = let
          _shards = shardAttrs;
          _shardCount = builtins.length (builtins.attrNames _shards) - 1;
          shardCount =
            if !pkgs.hostPlatform.isLinux
            then self.legacyPackages.x86_64-linux.shardCount
            else _shardCount;
          shards =
            if !pkgs.hostPlatform.isLinux
            then let
              rShardCount = self.legacyPackages.x86_64-linux.shardCount;
            in
              builtins.listToAttrs (
                builtins.map (i:
                  if (i < _shardCount)
                  then {
                    name = "${builtins.toString i}";
                    value = _shards."${builtins.toString i}";
                  }
                  else {
                    name = "${builtins.toString i}";
                    value = {};
                  }) (lib.range 0 rShardCount)
              )
            else _shards;
        in {
          inherit shards shardCount;
        };
      };
    };
  };
}
