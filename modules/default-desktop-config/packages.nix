{
  config,
  pkgs,
  ...
}: {
  programs = {
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
    git = {
      enable = true;
    };
    neovim = {
      enable = true;
      viAlias = true;
      vimAlias = true;
      defaultEditor = true;
      configure.customRC = ''
        source ~/.config/nvim/init.vim
      '';
    };
  };

  environment.systemPackages = with pkgs; [
    exfat
    ntfs3g
    unzip
    curl
    openssl
    bind
    gnupg
    nmap
    wireguard-tools
    iputils
    pciutils
    nvme-cli
    htop
    file
    ripgrep
    tree
  ];

  fonts.fonts = with pkgs; [
    (nerdfonts.override {fonts = ["DroidSansMono" "FiraCode" "FiraMono"];})
  ];
}
