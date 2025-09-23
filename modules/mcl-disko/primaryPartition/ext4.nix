{ espSize }:
{
  ESP = {
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
    size = "100%";
    content = {
      type = "filesystem";
      format = "ext4";
      mountpoint = "/";
    };
  };
}
