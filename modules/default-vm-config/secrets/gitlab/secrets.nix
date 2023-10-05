let
  system = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDhSCyJDqWDYjyIVXG5zCwWjlLZKmET+BuombIAybhHg root@solunska-server";
in {
  "db_password.age".publicKeys = [system];
  "root_password.age".publicKeys = [system];
  "smtp_password.age".publicKeys = [system];
  "db.age".publicKeys = [system];
  "secret.age".publicKeys = [system];
  "otp.age".publicKeys = [system];
  "jws.age".publicKeys = [system];
}
