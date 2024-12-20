{ inputs' }:
inputs'.nixpkgs-unstable.legacyPackages.grafana-agent.overrideAttrs (old: {
  subPackages = old.subPackages ++ [ "cmd/grafana-agent-flow" ];
})
