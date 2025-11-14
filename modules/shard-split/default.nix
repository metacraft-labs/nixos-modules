{
  lib,
  flake-parts-lib,
  ...
}:
let
  inherit (import ../../lib/shard-attrs.nix lib) shardAttrs;

  inherit (lib)
    mkOption
    types
    ;
in
{
  flake.modules.flake.shardSplit =
    { config, ... }:
    let
      cfg = config.mcl.matrix.shard;
    in
    {
      imports = [
        (flake-parts-lib.mkTransposedPerSystemModule {
          file = ./default.nix;
          name = "mcl-matrices";
          option = mkOption {
            description = ''
              Configuration options for `mcl shard-matrix`.
            '';
            default = { };
            type = types.submodule (
              { config, ... }:
              {
                options = {
                  shards = mkOption {
                    type = types.attrsOf (types.attrsOf types.package);
                    description = ''
                      An attribute set of attribute sets of derivations to be built by `nix-eval-jobs` for checking purposes
                    '';
                  };
                  shardCount = mkOption {
                    type = types.ints.unsigned;
                    default = builtins.length (builtins.attrNames config.shards);
                  };
                  perSystemAttributePath = mkOption {
                    type = types.listOf types.str;
                  };
                };
              }
            );
          };
        })
      ];

      options = {
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
          {
            config,
            self',
            system,
            ...
          }:
          let
            attrs = lib.attrByPath cfg.perSystemAttributePath { } self';

            systemIsEnabled = lib.elem system cfg.systemsToBuild;
            shards = lib.optionalAttrs systemIsEnabled (shardAttrs attrs cfg.size);
          in
          {
            mcl-matrices = {
              shards = lib.mkOptionDefault shards;
              perSystemAttributePath = lib.mkOptionDefault cfg.perSystemAttributePath;
            };
          };
      };
    };
}
