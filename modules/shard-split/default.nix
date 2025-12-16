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
      cfg = config.flake.mcl.shard-matrix;

      systemsToBuildErrorMessage = throw "Provided `systemsToBuild` ${builtins.toString cfg.systemsToBuild} does not yield a reuslt from the flake outputs";
    in
    {
      options = {
        flake.mcl.shard-matrix = {
          shardSize = mkOption {
            type = types.numbers.positive;
            default = 1;
            description = "Number of items per shard";
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

          result = {
            shards = mkOption {
              type = types.attrsOf (types.attrsOf types.package);
              readOnly = true;
              description = ''
                An attribute set of attribute sets of derivations to be built
                by `nix-eval-jobs` for checking purposes
              '';
              example = {
                "0" = {
                  "hello-0.0.1/aarch64-darwin" = "derivation";
                  "hello-0.0.1/x86_64-linux" = "derivation";
                  "hello-0.0.2/aarch64-darwin" = "derivation";
                  "hello-0.0.2/x86_64-linux" = "derivation";
                };
                "1" = {
                  "bye-0.0.1/aarch64-darwin" = "derivation";
                  "bye-0.0.1/x86_64-linux" = "derivation";
                  "bye-0.0.2/aarch64-darwin" = "derivation";
                  "bye-0.0.2/x86_64-linux" = "derivation";
                };
              };
              default = lib.pipe cfg.systemsToBuild [
                (lib.flip lib.genAttrs (
                  system:
                  lib.attrByPath cfg.perSystemAttributePath systemsToBuildErrorMessage config.allSystems.${system}
                ))
                (lib.concatMapAttrs (system: lib.mapAttrs' (name: lib.nameValuePair "${name}/${system}")))
                (lib.flip shardAttrs cfg.shardSize)
              ];
            };
            shardsPerSystem = mkOption {
              type = types.attrsOf (types.attrsOf (types.attrsOf types.package));
              readOnly = true;
              description = ''
                An `system`-indexed attribute set of attribute sets of
                attribute sets of derivations to be built by `nix-eval-jobs`
                for checking purposes
              '';
              example = {
                "aarch64-darwin" = {
                  "0" = {
                    "hello-0.0.1" = "derivation";
                    "hello-0.0.2" = "derivation";
                  };
                  "1" = {
                    "bye-0.0.1" = "derivation";
                    "bye-0.0.2" = "derivation";
                  };
                };
                "x86_64-linux" = {
                  "0" = {
                    "hello-0.0.1" = "derivation";
                    "hello-0.0.2" = "derivation";
                  };
                  "1" = {
                    "bye-0.0.1" = "derivation";
                    "bye-0.0.2" = "derivation";
                  };
                };
              };
              default = lib.genAttrs cfg.systemsToBuild (
                system:
                let
                  attrs =
                    lib.attrByPath cfg.perSystemAttributePath systemsToBuildErrorMessage
                      config.allSystems.${system};
                in
                shardAttrs attrs cfg.shardSize
              );
            };
            shardCount = mkOption {
              type = types.ints.unsigned;
              readOnly = true;
              default = builtins.length (builtins.attrNames cfg.result.shards);
            };
            shardCountPerSystem = mkOption {
              type = types.attrsOf types.ints.unsigned;
              readOnly = true;
              default = lib.genAttrs cfg.systemsToBuild (
                system: builtins.length (builtins.attrNames cfg.result.shardsPerSystem.${system})
              );
            };
          };
        };
      };
    };
}
