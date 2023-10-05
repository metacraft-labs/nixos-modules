{
  ethereum = import ./ethereum;
  gitlab = import ./gitlab;
  hello-agenix = import ./hello-agenix;
  home-assistant = import ./home-assistant;
  keycloak = import ./keycloak;
  nginx = import ./nginx;
  tailscale-autoconnect = import ./tailscale-autoconnect;
  yubikey-agent = import ./yubikey-agent;
  monitoring = {
    grafana = import ./monitoring/grafana.nix;
    prometheus = import ./monitoring/prometheus.nix;
    loki = import ./monitoring/loki.nix;
    promtail = import ./monitoring/promtail.nix;
    node-exporter = import ./monitoring/node-exporter.nix;
    uptime-kuma = import ./monitoring/uptime-kuma.nix;
  };
}
