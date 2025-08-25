{
  self,
  lib,
  system,
  ...
}:
{
  imports = lib.map (x: ./. + "/${x}") (
    builtins.attrNames (
      lib.removeAttrs (builtins.readDir ./.) [
        "base.nix"
        "all.nix"
      ]
    )
  );

  environment.systemPackages = lib.attrValues self.packages."${system}";
}
