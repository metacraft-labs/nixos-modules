{
  pkgs,
  unstablePkgs,
  ...
}: {
  home.packages = with pkgs; [
    ## Browsers:
    google-chrome
    firefox # opera

    ## Audio & video players:
    vlc
    mpv

    ## Office:
    libreoffice

    ## IM / Video:
    discord
    slack
    tdesktop
    # teams
    zoom-us

    ## Text editors / IDEs
    unstablePkgs.vscode

    ## API clients:
    # insomnia
    postman

    ## Remote desktop:
    # remmina
    # teamviewer

    ## Terminal emulators:
    # alacritty
    tilix

    ## X11, OpenGL, Vulkan:
    xclip
    gnomeExtensions.dash-to-dock
    glxinfo
    vulkan-tools

    ## System:
    gparted
    wireshark-qt
  ];
}
