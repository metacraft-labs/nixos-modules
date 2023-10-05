{pkgs, ...}: {
  home.packages = with pkgs; [
    ## Disk partitioning:
    # gptfdisk parted

    ## Monitoring:
    btop
    # iotop
    # nethogs

    ## Inspecting devices:
    usbutils
    pciutils

    ## Archival and compression (unzip is installed via sys/*.nix):
    p7zip
    unrar
  ];
}
