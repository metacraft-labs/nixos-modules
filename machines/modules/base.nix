{ system, lib, ... }:
{
  nixpkgs.system = system;
  fileSystems = {
    "/".device = lib.mkDefault "/dev/sda";
  };
  boot.loader.grub.devices = lib.mkDefault [ "/dev/sda" ];
  virtualisation.vmVariant = {
    virtualization = {
      diskSize = 10 * 1024 * 1024 * 1024; # 10GB
      memorySize = 8192; # 8GB
      cores = 4;
    };
  };
}
