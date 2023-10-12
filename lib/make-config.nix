{
  lib,
  rootDir,
  machinesDir,
  usersDir,
  ...
}: rec {
  getMachines = type: (lib.pipe (builtins.readDir "${machinesDir}/${type}") [
    (lib.filterAttrs (n: v: v == "directory" && !(lib.hasPrefix "_" n)))
    builtins.attrNames
  ]);

  allServers = getMachines "server";
  allDesktops = getMachines "desktop";
  allMachines = allServers ++ allDesktops;

  nixosConfigurations = machines: configurations:
    (lib.genAttrs machines (configurations false))
    // (lib.mapAttrs' (name: value: lib.nameValuePair "${name}-vm" value)
      (lib.genAttrs machines (configurations true)));
}
