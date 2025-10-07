{
  lib,
  disk,
  isSecondary,
  espSize,
  swapSize,
  poolName,
  randomEncryption,
}:
{
  "ESP" = {
    priority = 0;
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
    priority = 1;
    device = "${disk}-part2";
    end = if swapSize != null then "-${swapSize}" else "100%";
    type = "BF00";
    content = {
      type = "zfs";
      pool = "${poolName}";
    };
  };
}
// lib.optionalAttrs (swapSize != null) {
  "swap" = {
    priority = 2;
    device = "${disk}-part3";
    size = swapSize;
    content = {
      type = "swap";
      inherit randomEncryption;
    };
  };
}
