{pkgs, ...}: {
  environment.systemPackages = with pkgs; [
    wget
    tmux
    fish
    neovim
    jq
    git
  ];
}
