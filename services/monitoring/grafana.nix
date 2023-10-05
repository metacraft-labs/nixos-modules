{
  config,
  lib,
  ...
}: let
  http_addr = "localhost";
  http_port = 3000;
  domain = "grafana.metacraft-labs.com";
in {
  imports = [
    ../nginx
  ];
  services.grafana = {
    enable = true;
    settings = {
      security.admin_user = "zahary";
      server = {
        inherit http_addr http_port domain;
      };
    };
    provision = {
      enable = true;
      datasources.settings = {
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            access = "proxy";
            url = "http://${http_addr}:${toString config.services.prometheus.port}";
          }
          {
            name = "Loki";
            type = "loki";
            access = "proxy";
            url = "http://${http_addr}:${toString config.services.loki.configuration.server.http_listen_port}";
          }
        ];
      };
    };
  };

  services.nginx.virtualHosts."${domain}" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://${toString http_addr}:${toString http_port}/";
      proxyWebsockets = true;
    };
  };
  security.acme.certs."${domain}" = {};

  networking.firewall.allowedTCPPorts = lib.mkBefore [3000];
}
