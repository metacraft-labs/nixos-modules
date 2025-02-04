{ withSystem, inputs, ... }:
{
  flake.modules.nixos.mcl-disko =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    with lib;
    let
      cfg = config.mcl.disko;
    in
    {
      imports = [
        inputs.disko.nixosModules.disko
      ];
      options.mcl.disko = {
        enable = mkEnableOption "Enable Module";

        legacyBoot = mkOption {
          type = types.bool;
          default = false;
          example = true;
          description = "Declare if the configuration is for a Hetzner server or not";
        };

        swapSize = mkOption {
          type = types.str;
          default = "32G";
          example = "32768M";
          description = "The size of the hard disk space used when RAM is full";
        };

        espSize = mkOption {
          type = types.str;
          default = "4G";
          example = "4096M";
          description = "The size of the hard disk space used for the ESP filesystem";
        };

        disks = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "/dev/disk/sda"
            "/dev/disk/sdb"
            "/dev/disk/sdc"
          ];
          description = "The disk partitions to be used when ZFS is being created";
        };

        zpool = {
          name = mkOption {
            type = types.str;
            default = "zfs_root";
            description = "The name of the ZFS Pool";
          };

          mode = mkOption {
            type = types.enum [
              "stripe"
              "mirror"
              "raidz1"
              "raidz2"
              "raidz3"
            ];
            default = "stripe";
            description = "Set ZFS Pool redundancy - e.g. 'mirror', 'raidz1', etc.";
          };

          extraDatasets = mkOption {
            type = types.attrsOf (
              types.submodule (
                { name, ... }:
                {
                  options = {
                    mountpoint = mkOption {
                      type = types.nullOr types.str;
                      default = name;
                      example = "/var/lib";
                      description = "The ZFS dataset mountpoint";
                    };

                    type = mkOption {
                      type = types.enum [
                        "zfs_fs"
                        "zfs_volume"
                      ];
                      default = "zfs_fs";
                      description = "Type of ZFS dataset";
                    };
                    snapshot = mkEnableOption "Whether to enable ZFS snapshots";
                  };

                }
              )
            );
            default = { };
            example = {
              "/opt".snapshot = false;
              "/opt/downloads".snapshot = false;
              "/opt/downloads/vm-images" = {
                snapshot = false;
                options = {
                  quota = "120G";
                };
              };
            };
            description = "Extra ZFS Pool datasets";
          };
        };
      };

      config.disko =
        let
          makePrimaryZfsDisk = import ./primaryZfsPartition.nix;
          makeSecondaryZfsDisk = import ./secondaryZfsPartition.nix;

          first = builtins.head cfg.disks;
          rest = builtins.tail cfg.disks;
          secondaryDisks = builtins.listToAttrs (
            builtins.map (disk: {
              name = disk;
              value =
                if cfg.zpool.mode != "stripe" then
                  makePrimaryZfsDisk {
                    disk = first;
                    espSize = cfg.espSize;
                    swapSize = cfg.swapSize;
                    legacyBoot = cfg.legacyBoot;
                    poolName = cfg.zpool.name;
                  }
                else
                  makeSecondaryZfsDisk {
                    poolName = cfg.zpool.name;
                    inherit disk;
                  };
            }) rest
          );
        in
        lib.mkIf cfg.enable {
          devices = {
            disk = secondaryDisks // {
              "${first}" = makePrimaryZfsDisk {
                disk = first;
                espSize = cfg.espSize;
                swapSize = cfg.swapSize;
                legacyBoot = cfg.legacyBoot;
                poolName = cfg.zpool.name;
              };
            };
            zpool = import ./zpool.nix {
              poolName = cfg.zpool.name;
              poolMode = cfg.zpool.mode;
              poolExtraDatasets = cfg.zpool.extraDatasets;
              inherit lib;
            };
          };
        };
    };
}
