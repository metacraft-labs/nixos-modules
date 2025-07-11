{
  lib,
  self,
  ...
}:
let
  system = "x86_64-linux";
  mkMachine = x: {
    "${lib.removeSuffix ".nix" x}" = lib.nixosSystem {
      specialArgs = { inherit self system; };
      modules = lib.unique [
        ./modules/base.nix
        ./modules/${x}
      ];
    };
  };
in
{
  flake.nixosConfigurations = (
    lib.mergeAttrsList (lib.map (x: mkMachine x) (builtins.attrNames (builtins.readDir ./modules)))
  );
  flake.modules.nixos = (
    lib.mergeAttrsList (
      lib.map (x: {
        "machine_${lib.removeSuffix ".nix" x}" = (import (./modules + "/${x}"));
      }) (builtins.attrNames (builtins.readDir ./modules))
    )
  );
}
