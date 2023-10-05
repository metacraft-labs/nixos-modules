{
  config,
  lib,
  ...
}: let
  hostname = config.networking.hostName;
in {
  users = {
    motdFile = "/run/motd";
    mcl.includedGroups = ["devops"];
    mutableUsers = false;
  };
  security.pam.services.login.showMotd = lib.mkForce false;
}
