{
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
]
