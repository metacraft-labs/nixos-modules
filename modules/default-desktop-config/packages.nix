{
  config,
  pkgs,
  defaultUser,
  ...
}: {
  programs = {
    gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
    git = {
      enable = true;
      #   config = {
      # safe.directory = "/home/${defaultUser}/code/repost/dotfiles";
      #   };
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
