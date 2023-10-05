{
  config,
  pkgs,
  ...
}: {
  services.yubikey-agent.enable = true;
  environment.systemPackages = with pkgs; [yubikey-manager];
}
