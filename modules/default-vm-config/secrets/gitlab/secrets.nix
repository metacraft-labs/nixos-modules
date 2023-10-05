let
  utils = import ../../../../lib;

  system = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDhSCyJDqWDYjyIVXG5zCwWjlLZKmET+BuombIAybhHg root@solunska-server";
  userKeys = utils.allUserKeysForGroup ["devops"];
in {
  "db_password.age".publicKeys = [system] ++ userKeys;
  "root_password.age".publicKeys = [system] ++ userKeys;
  "smtp_password.age".publicKeys = [system] ++ userKeys;
  "db.age".publicKeys = [system] ++ userKeys;
  "secret.age".publicKeys = [system] ++ userKeys;
  "otp.age".publicKeys = [system] ++ userKeys;
  "jws.age".publicKeys = [system] ++ userKeys;
}
