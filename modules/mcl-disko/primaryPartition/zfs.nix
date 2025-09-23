{
  disk,
  isSecondary,
  espSize,
  swapSize,
  poolName,
}:
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
