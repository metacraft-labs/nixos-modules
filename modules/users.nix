{
  usersDir,
  rootDir,
  machinesDir,
}:
{
  config,
  lib,
  ...
}:
let
  cfg = config.users;
  enabled = cfg.includedUsers != [ ] || cfg.includedGroups != [ ];

  utils = import ../lib { inherit usersDir rootDir machinesDir; };
  allUsers = utils.usersInfo;
  allGroups =
    let
      predefinedGroups = config.ids.gids;
    in
    utils.allAssignedGroups' allUsers predefinedGroups;
  allUserNames = builtins.attrNames allUsers;
  allGroupNames = builtins.attrNames allGroups;

  selectedUsers' =
    (lib.getAttrs cfg.includedUsers allUsers)
    // (utils.allUsersMembersOfAnyGroup' allUsers cfg.includedGroups);

  powerUserSystemGroups = [
    "docker"
    "podman"
    "lxd"
    "plugdev"
    "libvirtd"
    "vboxusers"
  ];

  selectedUsers = builtins.mapAttrs (
    user: userConfig:
    userConfig
    // {
      extraGroups = (userConfig.extraGroups or [ ]) ++ powerUserSystemGroups;
    }
  ) selectedUsers';

  selectedGroups =
    let
      predefinedGroups = config.ids.gids;
    in
    utils.allAssignedGroups' selectedUsers predefinedGroups;
in
{
  options.users = with lib; {
    includedUsers = mkOption {
      type = types.listOf (types.enum allUserNames);
      default = [ ];
      example = [
        "zahary"
        "johnny"
      ];
      description = ''
        List of MetaCraft Labs users to be included in the system.
      '';
    };

    includedGroups = mkOption {
      type = types.listOf (types.enum allGroupNames);
      default = [ ];
      example = [
        "devops"
        "dendreth"
      ];
      description = ''
        List of groups of MetaCraft Labs users to be included in the system.
      '';
    };
  };

  config = lib.mkIf enabled {
    users = {
      users = selectedUsers;
      groups = selectedGroups;
    };
  };
}
