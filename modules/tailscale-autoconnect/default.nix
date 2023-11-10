{withSystem, ...}: {
  flake.nixosModules.tailscale-autoconnect = {
    lib,
    pkgs,
    config,
    ...
  }: let
    cfg = config.services.mcl.tailscale-autoconnect;
  in
    with lib; {
      options.services.mcl.tailscale-autoconnect = {
        enable = mkEnableOption (mdDoc "Enable automatic connection to Tailscale");

        auth-key = mkOption {
          type = types.str;
          description = mdDoc "Path to the auth-key file";
        };
      };

      config = {
        systemd.services.tailscale-autoconnect = lib.mkIf cfg.enable {
          description = "Automatic connection to Tailscale";
          after = ["network-pre.target" "tailscale.service"];
          wants = ["network-pre.target" "tailscale.service"];
          wantedBy = ["multi-user.target"];
          serviceConfig.Type = "oneshot";
          script = with pkgs; ''
            # wait for tailscaled to settle
            sleep 2

            # check if we are already authenticated to tailscale
            status="$(${tailscale}/bin/tailscale status -json | ${jq}/bin/jq -r .BackendState)"
            if [ $status = "Running" ]; then # if so, then do nothing
              exit 0
            fi

            # otherwise authenticate with tailscale
            ${tailscale}/bin/tailscale up --ssh --authkey file:${cfg.auth-key}
          '';
        };
      };
    };
}
