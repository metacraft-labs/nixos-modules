{
  lib,
  self,
  ...
}:
let
  system = "x86_64-linux";
  pkgs = import self.inputs.nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  mkMachine = x: {
    "${lib.removeSuffix ".nix" x}" = lib.nixosSystem {
      specialArgs = { inherit self system; };
      modules = lib.unique [
        {
          nixpkgs.system = system;
        }
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
        "machine_${lib.removeSuffix ".nix" x}" = (
          import (./modules + "/${x}") {
            inherit
              self
              pkgs
              ;
          }
        );
      }) (builtins.attrNames (builtins.readDir ./modules))
    )
  );
}
