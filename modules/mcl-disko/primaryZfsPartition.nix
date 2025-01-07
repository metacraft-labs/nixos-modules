{
  disk,
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
    partitions = {
      ESP = {
        device = "${disk}-part1";
        priority = 0;
        size = espSize;
        type = "EF00";
        content = {
          type = "filesystem";
          format = "vfat";
          mountpoint = "/boot";
          mountOptions = [ "umask=0077" ];
        };
      };

      zfs = {
        device = "${disk}-part2";
        priority = 1;
        end = "-${swapSize}";
        type = "BF00";
        content = {
          type = "zfs";
          pool = "${poolName}";
        };
      };

      swap = {
        device = "${disk}-part3";
        priority = 2;
        size = if legacyBoot == true then "100%" else swapSize;
        content = {
          type = "swap";
          randomEncryption = true;
        };
      };
    };
  };
}
