{config, ...}: {
  home.sessionVariables = rec {
    DIRENV_WARN_TIMEOUT = "30s";
    CODE = "${config.home.homeDirectory}/code";
    TMPCODE = "${CODE}/tmp";
    REPOS = "${CODE}/repos";
    CFG = "${REPOS}/dotfiles";
    WORK = "${REPOS}/metacraft-labs";
    MINE = "${REPOS}/mine";
  };
}
