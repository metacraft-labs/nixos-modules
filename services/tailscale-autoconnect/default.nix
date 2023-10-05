{
  config,
  dirs,
  ...
}: {
  imports = [
    "${dirs.modules}/tailscale-autoconnect"
    (import "${dirs.lib}/import-agenix.nix" "tailscale-autoconnect")
  ];

  services.mcl.tailscale-autoconnect = {
    enable = true;
    auth-key = config.age.secrets."tailscale-autoconnect/auth-key".path;
  };
}
