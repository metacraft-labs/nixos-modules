lib: {
  shardAttrs =
    attrs: shardSize:
    let
      attrNames = builtins.attrNames attrs;
      shardCount = builtins.ceil ((0.0 + (builtins.length attrNames)) / shardSize);
      attrNameShards = lib.pipe (lib.range 0 (shardCount - 1)) [
        (builtins.map (i: lib.sublist (i * shardSize) shardSize attrNames))
      ];
      shards = lib.pipe attrNameShards [
        (lib.imap0 (
          i: shard: {
            name = builtins.toString i;
            value = lib.genAttrs shard (key: attrs.${key});
          }
        ))
        lib.listToAttrs
      ];
    in
    shards;
}
