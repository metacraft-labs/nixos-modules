{
  usersDir,
  rootDir,
  machinesDir,
  ...
}:
let
  inherit (import ./current-flake.nix) lib;
  inherit (builtins)
    attrValues
    map
    filter
    concatLists
    length
    listToAttrs
    typeOf
    split
    tail
    ;
  inherit (lib) pipe filterAttrs strings;
  inherit (strings) concatStringsSep;
in
rec {
  isSubsetOf = needle: haystack: length (lib.lists.intersectLists needle haystack) == length needle;

  haveCommonElements = needle: haystack: length (lib.lists.intersectLists needle haystack) > 0;

  allUsersMembersOfAllGroups = groups: allUsersMembersOfAllGroups' usersInfo groups;
  allUsersMembersOfAllGroups' =
    users: groups:
    if groups == [ ] then
      { }
    else
      filterAttrs (key: value: isSubsetOf groups (value.extraGroups or [ ])) users;

  allUsersMembersOfAnyGroup = groups: allUsersMembersOfAnyGroup' usersInfo groups;
  allUsersMembersOfAnyGroup' =
    users: groups:
    if groups == [ ] then
      { }
    else
      filterAttrs (key: value: haveCommonElements groups (value.extraGroups or [ ])) users;

  missing = attrs: key: !(attrs ? "${key}");

  allAssignedGroups = predefinedGroups: allAssignedGroups' usersInfo predefinedGroups;
  allAssignedGroups' =
    users: predefinedGroups:
    pipe users [
      attrValues
      (map (u: u.extraGroups or [ ]))
      concatLists
      lib.lists.unique
      (filter (g: missing predefinedGroups g))
      (map (g: {
        name = g;
        value = { };
      }))
      listToAttrs
    ];

  allUserKeysForGroup = groups: allUserKeysForGroup' usersInfo groups;
  allUserKeysForGroup' =
    users: groups:
    concatLists (
      map (value: value.openssh.authorizedKeys.keys or [ ]) (
        attrValues (allUsersMembersOfAnyGroup' users groups)
      )
    );

  zfsFileSystems =
    datasetList:
    let
      zfsRoot = "zfs_root";
      splitPath = path: filter (x: (typeOf x) == "string") (split "/" path);
      pathTail = path: concatStringsSep "/" (tail (splitPath path));
      makeZfs = zfsDataset: {
        name = "/" + pathTail zfsDataset;
        value = {
          device = "${zfsRoot}/${zfsDataset}";
          fsType = "zfs";
          options = [ "zfsutil" ];
        };
      };
    in
    listToAttrs (map makeZfs datasetList);

  allUsers = builtins.attrNames (
    lib.filterAttrs (n: v: v == "directory") (builtins.readDir "${usersDir}")
  );

  readUserInfo = user: import "${usersDir}/${user}/user-info.nix";

  usersInfo = lib.genAttrs allUsers (name: (readUserInfo name).userInfo);
}
