{ pkgs, ... }:
pkgs.writers.writePython3Bin "folder-size-metrics.py" {
  libraries = [
    pkgs.python3Packages.prometheus-client
  ];
} ./src/app.py
