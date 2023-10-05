{
  config,
  pkgs,
  username,
  ...
}: {
  home = {
    inherit username;
    homeDirectory =
      if pkgs.hostPlatform.isDarwin
      then "/Users/${username}"
      else "/home/${username}";
    stateVersion = "23.05";
  };

  manual.manpages.enable = false;
  programs.home-manager.enable = true;
}
