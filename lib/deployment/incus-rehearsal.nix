{
  lib,
  nixpkgs,
}:
rec {
  mkDeploymentRehearsalImage =
    {
      pkgs,
      name,
      role,
      modules ? [ ],
      targetGroup ? null,
      networks ? [ "control" ],
      avahi ? false,
      packages ? [ ],
      manifestText ? "",
    }:
    let
      system = nixpkgs.lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [
          "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
          "${nixpkgs}/nixos/modules/virtualisation/lxc-image-metadata.nix"
          (
            { lib, ... }:
            {
              networking.hostName = name;
              networking.useDHCP = true;
              system.stateVersion = lib.trivial.release;

              image.baseName = "mcl-deployment-rehearsal-${name}-${pkgs.stdenv.hostPlatform.system}";

              environment.systemPackages = [
                pkgs.bash
                pkgs.coreutils
                pkgs.curl
                pkgs.jq
                pkgs.openssh
              ]
              ++ packages;

              environment.etc = {
                "mcl-deployment-rehearsal/role".text = role;
                "mcl-deployment-rehearsal/networks".text = lib.concatStringsSep "\n" networks + "\n";
                "mcl-deployment-rehearsal/manifest.json".text = if manifestText == "" then "{}\n" else manifestText;
              }
              // lib.optionalAttrs (targetGroup != null) {
                "mcl-deployment-rehearsal/target-group".text = targetGroup + "\n";
              };

              services.openssh.enable = true;
              services.avahi = {
                enable = avahi;
                nssmdns4 = avahi;
                openFirewall = avahi;
              };
            }
          )
        ]
        ++ modules;
      };
    in
    pkgs.runCommand "deployment-incus-rehearsal-image-${name}"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
        ];
        passthru = {
          inherit system;
          rootfs = system.config.system.build.tarball;
          metadata = system.config.system.build.metadata;
        };
      }
      ''
        test -e ${system.config.system.build.toplevel}
        rootfs="$(find ${system.config.system.build.tarball}/tarball -maxdepth 1 -type f -name '*.tar.xz' | head -n 1)"
        metadata="$(find ${system.config.system.build.metadata}/tarball -maxdepth 1 -type f -name '*.tar.xz' | head -n 1)"
        test -f "$rootfs"
        test -f "$metadata"

        mkdir -p "$out"
        ln -s "$rootfs" "$out/rootfs.tar.xz"
        ln -s "$metadata" "$out/metadata.tar.xz"
        cat > "$out/manifest.txt" <<EOF
        name=${name}
        role=${role}
        target_group=${if targetGroup == null then "" else targetGroup}
        networks=${lib.concatStringsSep "," networks}
        avahi=${if avahi then "enabled" else "disabled"}
        runtime_status=pending-incus-daemon
        EOF
      '';
}
