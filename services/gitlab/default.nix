{
  pkgs,
  config,
  lib,
  dirs,
  ...
}: let
in {
  imports = [
    ../nginx
    (import "${dirs.lib}/import-agenix.nix" "gitlab")
  ];
  services.gitlab = {
    enable = true;
    port = 443;
    https = true;
    host = "gitlab.metacraft-labs.com";
    user = "gitlab";
    group = "gitlab";
    databasePasswordFile = config.age.secrets."gitlab/db_password".path;
    initialRootPasswordFile = config.age.secrets."gitlab/root_password".path;
    secrets = {
      secretFile = config.age.secrets."gitlab/secret".path;
      otpFile = config.age.secrets."gitlab/otp".path;
      dbFile = config.age.secrets."gitlab/db".path;
      jwsFile = config.age.secrets."gitlab/jws".path;
    };
    smtp = {
      enable = true;
      address = "smtp.mailgun.org";
      port = 587;
      authentication = "plain";
      username = "postmaster@metacraft-labs.com";
      passwordFile = config.age.secrets."gitlab/smtp_password".path;
      domain = "metacraft-labs.com";
    };
  };

  services.nginx.virtualHosts."gitlab.metacraft-labs.com" = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass = "http://unix:/run/gitlab/gitlab-workhorse.socket";
  };

  security.acme.certs."gitlab.metacraft-labs.com" = {};

  networking.firewall.allowedTCPPorts = lib.mkBefore [80 443];
}
