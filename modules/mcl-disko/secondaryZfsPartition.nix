{
  lib,
  poolName,
  disk,
}:
{
  type = "disk";
  device = disk;
  content = {
    type = "gpt";
    partitions = {
      zfs = {
        device = "${disk}-part1";
        size = "100%";
        content = {
          type = "zfs";
          pool = "${poolName}";
        };
      };
    };
  };
}
