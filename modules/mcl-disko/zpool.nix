{
  lib,
  poolName,
  poolMode,
  poolExtraDatasets,
}:
let
  translateDataSetToDiskoConfig =
    dataset@{ snapshot, refreservation, ... }:
    lib.recursiveUpdate dataset {
      type = "zfs_fs";
      options = {
        "com.sun:auto-snapshot" = if dataset.snapshot then "on" else "off";
        canmount = "on";
      } // (if (refreservation != null) then { inherit refreservation; } else { });
    };

  restructuredDatasets = builtins.mapAttrs (
    n: v:
    (builtins.removeAttrs (translateDataSetToDiskoConfig poolExtraDatasets.${n}) [
      "refreservation"
      "snapshot"
    ])
  ) poolExtraDatasets;
in
{
  ${poolName} = {
    type = "zpool";
    mode = if poolMode == "stripe" then "" else poolMode;
    rootFsOptions = {
      acltype = "posixacl";
      atime = "off";
      canmount = "off";
      checksum = "sha512";
      compression = "lz4";
      xattr = "sa";
      mountpoint = "none";
      "com.sun:auto-snapshot" = "false";
    };
    options = {
      autotrim = "on";
      listsnapshots = "on";
    };

    postCreateHook = "zfs snapshot ${poolName}@blank";

    datasets = lib.recursiveUpdate {
      root = {
        mountpoint = "/";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "false";
          mountpoint = "legacy";
        };
      };

      "root/nix" = {
        mountpoint = "/nix";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "false";
          canmount = "on";
          mountpoint = "legacy";
          refreservation = "100GiB";
        };
      };

      "root/var" = {
        mountpoint = "/var";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "true";
          canmount = "on";
          mountpoint = "legacy";
        };
      };

      "root/var/lib" = {
        mountpoint = "/var/lib";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "true";
          canmount = "on";
          mountpoint = "legacy";
        };
      };

      "root/home" = {
        mountpoint = "/home";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "true";
          canmount = "on";
          mountpoint = "legacy";
          refreservation = "200GiB";
        };
      };

      "root/var/lib/docker" = {
        mountpoint = "/var/lib/docker";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "false";
          canmount = "on";
          mountpoint = "legacy";
          refreservation = "100GiB";
        };
      };

      "root/var/lib/containers" = {
        mountpoint = "/var/lib/containers";
        type = "zfs_fs";
        options = {
          "com.sun:auto-snapshot" = "false";
          canmount = "on";
          mountpoint = "legacy";
          refreservation = "100GiB";
        };
      };
    } restructuredDatasets;
  };
}
