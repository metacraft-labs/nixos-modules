{
  pkgs,
  username,
  ...
}: {
  programs.git = {
    enable = true;
    package = pkgs.gitFull;
    delta.enable = true;
    includes = [
      {path = ../../../users + "/${username}/.gitconfig";}
    ];
  };

  home.packages = with pkgs; [
    git-filter-repo
  ];
}
