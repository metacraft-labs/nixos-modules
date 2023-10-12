moduleName: {
  config,
  lib,
  dirs,
  ...
}: let
  machineConfigPath = config.mcl.host-info.configPath;
  secretDir = "${machineConfigPath}/secrets/${moduleName}";
  vmConfig = "${dirs.modules}/default-vm-config";
  vmSecretDir = "${vmConfig}/secrets/${moduleName}";
  secrets = import "${dirs.services}/${moduleName}/agenix.nix";
in {
  age.secrets = secrets secretDir;

  virtualisation.vmVariant = {
    age.secrets = lib.mkForce (secrets vmSecretDir);
  };
}
