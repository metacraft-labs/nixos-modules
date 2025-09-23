{
  lib,
  disk,
  isSecondary,
  espSize,
  swapSize,
  primaryPartitionType,
  poolName,
}:
{
  type = "disk";
  device = disk;
  content = {
    type = if primaryPartitionType == "legacyBoot" then "table" else "gpt";
    partitions =
      if primaryPartitionType == "legacyBoot" then
        import ./zfs-legacy-boot.nix {
          inherit
            isSecondary
            espSize
            swapSize
            poolName
            ;
        }
      else if primaryPartitionType == "ext4" then
        import ./ext4.nix { inherit espSize; }
      else
        import ./zfs.nix {
          inherit
            disk
            isSecondary
            espSize
            swapSize
            poolName
            ;
        };
  }
  // lib.optionalAttrs (primaryPartitionType == "legacyBoot") {
    format = "gpt";
  };
}
