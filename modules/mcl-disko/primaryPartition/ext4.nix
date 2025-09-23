{
  lib,
  espSize,
  swapSize,
}:
{
  ESP = {
    priority = 0;
    type = "EF00";
    size = espSize;
    content = {
      type = "filesystem";
      format = "vfat";
      mountpoint = "/boot";
      mountOptions = [ "umask=0077" ];
    };
  };
  nixos = {
    priority = 1;
    start = espSize;
    end = if swapSize != null then "-${swapSize}" else "100%";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };

}
// lib.optionalAttrs (swapSize != null) {
  "swap" = {
    priority = 2;
    size = swapSize;
    content = {
      type = "swap";
      randomEncryption = true;
    };
  };
}
