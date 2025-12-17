lib: {
  shardAttrs =
    attrs: shardSize:
    let
      attrNames = builtins.attrNames attrs;
      shardCount = builtins.ceil ((0.0 + (builtins.length attrNames)) / shardSize);
      attrNameShards = lib.pipe (lib.range 0 (shardCount - 1)) [
        (builtins.map (i: lib.sublist (i * shardSize) shardSize attrNames))
      ];
      padWidth = lib.pipe shardCount [
        builtins.toString
        builtins.stringLength
      ];
      shards = lib.pipe attrNameShards [
        (lib.imap0 (
          i: shard: {
            name = "shard-${lib.fixedWidthNumber padWidth i}";
            value = lib.genAttrs shard (key: attrs.${key});
          }
        ))
        lib.listToAttrs
      ];
    in
    shards;
}
