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
}
