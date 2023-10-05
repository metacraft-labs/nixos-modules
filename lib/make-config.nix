{
  pkgs,
  lib,
  system,
  unstablePkgs,
  inputs',
  ...
}: let
  cachix-deploy-lib = cachix-deploy.lib pkgs;

  makeHomeConfig = modules: username:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs modules;
      extraSpecialArgs = {inherit username unstablePkgs inputs' inputs;};
    };
in {
  cachix-deploy-bare-metal-spec = cachix-deploy-lib.spec {
    agents =
      lib.pipe self.nixosConfigurations
      [
        (builtins.mapAttrs (name: sys: sys.config.system.build.toplevel))
        (lib.filterAttrs (name: sys: !(lib.hasSuffix "-vm" name)))
      ];
  };

  cachix-deploy-vm-spec = cachix-deploy-lib.spec {
    agents =
      lib.pipe self.nixosConfigurations
      [
        (builtins.mapAttrs (name: sys: sys.config.virtualisation.vmVariant.system.build.toplevel))
        (lib.filterAttrs (name: sys: lib.hasSuffix "-vm" name))
      ];
  };

  homeConfigurations = users:
    lib.genAttrs users (name: {
      desktop =
        makeHomeConfig [
          ./modules/home/base-config
          ./modules/home/desktop-config
          ./users/${name}/home-desktop
        ]
        "${name}";
      server =
        makeHomeConfig [
          ./modules/home/base-config
          ./users/${name}/home-server
        ]
        "${name}";
    });
}
