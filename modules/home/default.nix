{
  base-config = {
    env-vars = import ./base-config/env-vars.nix;
    git = import ./base-config/git.nix;
    home = import ./base-config/home.nix;
    pkg-sets = {
      cli-utils = import ./base-config/pkg-sets/cli-utils.nix;
      nix-related = import ./base-config/pkg-sets/nix-related.nix;
    };
    shells = {
      bash = import ./base-config/shells/bash.nix;
      direnv = import ./base-config/shells/direnv.nix;
      fish = import ./base-config/shells/fish.nix;
      nushell = import ./base-config/shells/nushell.nix;
    };
    all = import ./base-config;
  };

  desktop-config = {
    dconf = import ./desktop-config/dconf.nix;
    pkg-sets = {
      gnome-themes = import ./desktop-config/pkg-sets/gnome-themes.nix;
      gui = import ./desktop-config/pkg-sets/gui.nix;
      system-utils = import ./desktop-config/pkg-sets/system-utils.nix;
    };
  };
}
