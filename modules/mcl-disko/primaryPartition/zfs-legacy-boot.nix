{
  lib,
  isSecondary,
  espSize,
  swapSize,
  poolName,
}:
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
    end = if swapSize != null then "-${swapSize}" else "100%";
    part-type = "primary";
    content = {
      type = "zfs";
      pool = "${poolName}";
    };
  }
]
++ lib.optionals (swapSize != null) [
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
]
