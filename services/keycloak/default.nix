{
  config,
  dirs,
  ...
}: {
  imports = [
    ../nginx
    (import "${dirs.lib}/import-agenix.nix" "keycloak")
  ];

  services.nginx.virtualHosts = {
    "keycloak.metacraft-labs.com" = {
      forceSSL = true;
      enableACME = true;
      locations = {
        "/" = {
          proxyPass = "http://localhost:${toString config.services.keycloak.settings.http-port}/";
        };
      };
    };
  };

  security.acme.certs."keycloak.metacraft-labs.com" = {};

  services.postgresql.enable = true;

  services.keycloak = {
    enable = true;

    database = {
      type = "postgresql";
      createLocally = true;

      username = "keycloak";
      passwordFile = config.age.secrets."keycloak/password".path;
    };

    settings = {
      hostname = "keycloak.com";
      http-relative-path = "/";
      http-port = 38080;
      proxy = "passthrough";
      http-enabled = true;
    };
  };
}
