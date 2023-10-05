let
  utils = import ../../../../lib;

  system = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDhSCyJDqWDYjyIVXG5zCwWjlLZKmET+BuombIAybhHg root@solunska-server";
  userKeys = utils.allUserKeysForGroup ["devops"];
in {
  "password.age".publicKeys = [system] ++ userKeys;
}
