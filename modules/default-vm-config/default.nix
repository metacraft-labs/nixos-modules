{
  lib,
  config,
  flakeArgs,
  dirs,
  ...
}: {
  imports = [
    "${dirs.services}/hello-agenix"
  ];

  virtualisation.vmVariant = {
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.grub.enable = lib.mkForce false;

    networking.hostName = lib.mkForce "${config.networking.hostName}-vm";

    # following configuration is added only when building VM with build-vm
    virtualisation = {
      memorySize = 4096; # Use 4096MiB memory.
      cores = 4;
      diskSize = 8192;

      forwardPorts = [
        {
          from = "host";
          host.port = 2222;
          guest.port = 22;
        }
        {
          from = "host";
          host.port = 8080;
          guest.port = 80;
        }
        {
          from = "host";
          host.port = 8443;
          guest.port = 443;
        }
      ];
    };

    services.xserver.enable = true;
    services.xserver.displayManager.gdm.enable = true;
    services.xserver.desktopManager.gnome.enable = true;

    security.sudo.wheelNeedsPassword = false;

    # Add all normal users to the wheel group
    users.users = lib.pipe config.users.users [
      (lib.filterAttrs (n: u: u.isNormalUser))
      (builtins.mapAttrs
        (n: u: {
          extraGroups = ["wheel"];
          password = "1234";
          initialPassword = "1234";
        }))
    ];
    users.includedUsers = ["bean" "johnny"];

    system.activationScripts.agenixInstall.deps = ["installSSHHostKeys"];

    system.activationScripts.installSSHHostKeys.text = ''

      mkdir -p /etc/ssh
      (
        umask u=rw,g=r,o=r
        cp ${dirs.modules}/default-vm-config/example_keys/system.pub /etc/ssh/ssh_host_ed25519_key.pub
      )
      (
        umask u=rw,g=,o=
        cp ${dirs.modules}/default-vm-config/example_keys/system /etc/ssh/ssh_host_ed25519_key
      )

    '';
  };
}
