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
    type = if legacyBoot then "table" else "gpt";
    partitions =
      if !legacyBoot then
        {
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
        }
      else
        [
          {
            name = "boot";
            start = "1MiB";
            end = "2MiB";
            part-type = "primary";
            flags = [ "bios_grub" ];
          }
          {
            name = "ESP";
            start = "2MiB";
            end = espSize;
            bootable = true;
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = if isSecondary then null else "/boot";
            };
          }
          {
            name = "zfs";
            start = espSize;
            end = "-${swapSize}";
            part-type = "primary";
            content = {
              type = "zfs";
              pool = "${poolName}";
            };
          }
          {
            name = "swap";
            start = "-${swapSize}";
            end = "100%";
            part-type = "primary";
            content = {
              type = "swap";
              randomEncryption = true;
            };
          }
        ];
  }
  // lib.optionalAttrs legacyBoot {
    format = "gpt";
  };
}
