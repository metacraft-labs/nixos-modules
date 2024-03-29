{pkgs, ...}: {
  services.xserver.enable = true;
  services.xserver.displayManager.gdm.enable = true;
  services.xserver.desktopManager.gnome.enable = true;

  # Needed for Home Manager to be able to update DConf settings
  # See: https://github.com/nix-community/home-manager/blob/f911ebbec927e8e9b582f2e32e2b35f730074cfc/modules/misc/dconf.nix#L25-L26
  programs.dconf.enable = true;

  hardware.pulseaudio.enable = false;
  # bluezx needs pulseeaudio CLI tools to be installed
  environment.systemPackages = [pkgs.pulseaudio];

  security.rtkit.enable = true;

  services.blueman.enable = true;

  services.pipewire = {
    enable = true;
    alsa = {
      enable = true;
    };
    pulse.enable = true;
  };
}
