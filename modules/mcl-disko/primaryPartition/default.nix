{
  lib,
  disk,
  isSecondary,
  espSize,
  swapSize,
  partitioningPreset,
  poolName,
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
            ;
        }
      else if partitioningPreset == "ext4" then
        import ./ext4.nix { inherit lib espSize swapSize; }
      else
        import ./zfs.nix {
          inherit
            lib
            disk
            isSecondary
            espSize
            swapSize
            poolName
            ;
        };
  }
  // lib.optionalAttrs (partitioningPreset == "zfs-legacy-boot") {
    format = "gpt";
  };
}
