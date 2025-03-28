{
  lib,
  disk,
  isSecondary,
  espSize,
  swapSize,
  legacyBoot,
  poolName,
}:
{
  type = "disk";
  device = disk;
  content = {
    type = "gpt";
    partitions =
      lib.optionals legacyBoot {
        "boot" = {
          device = "${disk}-boot";
          size = "1M";
          type = "EF02";
        };
      }
      // {
        "ESP" = {
          device = "${disk}-part1";
          size = espSize;
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = if isSecondary then null else "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        "zfs" = {
          device = "${disk}-part2";
          end = "-${swapSize}";
          type = "BF00";
          content = {
            type = "zfs";
            pool = "${poolName}";
          };
        };

        "swap" = {
          device = "${disk}-part3";
          size = swapSize;
          content = {
            type = "swap";
            randomEncryption = true;
          };
        };
      };
  };
}
