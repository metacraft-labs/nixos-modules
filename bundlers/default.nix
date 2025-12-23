{
  lib,
  flake-parts-lib,
  inputs,
  ...
}:
{
  imports = [
    (flake-parts-lib.mkTransposedPerSystemModule {
      name = "bundlers";
      option = lib.mkOption {
        type = lib.types.lazyAttrsOf (lib.types.functionTo lib.types.package);
        default = { };
      };
      file = ./flake.nix;
    })
  ];

  perSystem =
    {
      pkgs,
      inputs',
      config,
      ...
    }:
    let
      nfpmConfig =
        pkg:
        pkgs.writeText "${pkg.pname}-nfpm-config.yaml" (
          builtins.toJSON {
            name = pkg.pname;
            inherit (pkg)
              version
              ;
            inherit (pkg.meta)
              homepage
              description
              ;
            license = pkg.meta.license.spdxId or null;
            contents = [
              {
                src = lib.getExe pkg;
                dst = "/usr/bin/${pkg.meta.mainProgram or (lib.getName pkg)}";
              }
            ];
          }
        );

      installerFor =
        packager: pkg:
        pkgs.runCommand "${pkg.pname}-${packager}-pkg" { } ''
          mkdir -p "$out"
          cd "$out"
          ${lib.getExe pkgs.nfpm} package \
            --config ${nfpmConfig pkg} \
            --packager ${packager} \
            --target "$out"
        '';

      installers = [
        "deb"       # Debian/Ubuntu
        "rpm"       # Fedora/RHEL/SUSE
        "apk"       # Alpine
        "archlinux" # Arch
      ];

      nfpmBundlers = lib.pipe installers [
        (lib.map (i: {
          name = "to${lib.toUpper (lib.substring 0 1 i)}${lib.substring 1 (-1) i}";
          value = installerFor i;
        }))
        lib.listToAttrs
      ];
    in
    {
      bundlers = {
        toAppimage = inputs'.nix-appimage.bundlers.default;
      } // nfpmBundlers;
    };
}
