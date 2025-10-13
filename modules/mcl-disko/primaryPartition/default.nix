{
  lib,
  disk,
  isSecondary,
  espSize,
  swapSize,
  partitioningPreset,
  poolName,
  randomEncryption,
}:
{
  type = "disk";
  device = disk;
  content = {
    type = if partitioningPreset == "zfs-legacy-boot" then "table" else "gpt";
    partitions =
      if partitioningPreset == "zfs-legacy-boot" then
        import ./zfs-legacy-boot.nix {
          inherit
            lib
            isSecondary
            espSize
            swapSize
            poolName
            randomEncryption
            ;
        }
      else if partitioningPreset == "ext4" then
        import ./ext4.nix {
          inherit
            lib
            espSize
            swapSize
            randomEncryption
            ;
        }
      else
        import ./zfs.nix {
          inherit
            lib
            disk
            isSecondary
            espSize
            swapSize
            poolName
            randomEncryption
            ;
        };
  }
  // lib.optionalAttrs (partitioningPreset == "zfs-legacy-boot") {
    format = "gpt";
  };
}
