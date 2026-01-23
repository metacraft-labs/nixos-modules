# YAML-based automation engine for GUI automation via VNC + OCR
#
# This package provides a Python-based automation engine that:
# - Parses YAML configuration files (Lume format)
# - Connects to VNC servers for framebuffer capture and input injection
# - Uses Tesseract OCR for text recognition on Linux
# - Executes boot commands sequentially with proper timing
# - Performs SSH health checks with retries
# - Saves debug screenshots with annotations
#
# Usage:
#   nix build .#yaml-automation-runner
#   ./result/bin/yaml-automation-runner \
#     --config configs/windows-11.yml \
#     --vnc-host 127.0.0.1 \
#     --vnc-port 5900 \
#     --debug
#
# Based on: vendor/vm-research/cua/libs/lume/src/Unattended/*.swift
# Architecture: specs/Internal/Multi-OS-VM-Infrastructure-Architecture.md

{ pkgs, lib }:

let
  # Python environment with all required dependencies
  # NOTE: vncdotool is not available in nixpkgs. For full VNC support,
  # users need to install it manually or we need to create a custom package.
  # The automation engine will detect its absence and provide instructions.
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      pyyaml # YAML parsing
      pytesseract # OCR integration (wrapper for tesseract)
      pillow # Image processing
      # vncdotool     # VNC client library (not in nixpkgs)
      paramiko # SSH client for health checks
    ]
  );

  # Main automation engine script
  automationEngine = ./automation_engine.py;

  # Example YAML configurations
  exampleConfigs = ./configs;

in
pkgs.stdenv.mkDerivation {
  pname = "yaml-automation-runner";
  version = "0.1.0";

  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  buildInputs = [
    pythonEnv
    pkgs.tesseract # Tesseract OCR engine
  ];

  # No build phase needed - just install scripts
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    mkdir -p $out/lib/yaml-automation
    mkdir -p $out/share/yaml-automation/configs

    # Install the automation engine
    cp ${automationEngine} $out/lib/yaml-automation/automation_engine.py
    chmod +x $out/lib/yaml-automation/automation_engine.py

    # Copy example configs
    if [ -d "${exampleConfigs}" ]; then
      cp -r ${exampleConfigs}/* $out/share/yaml-automation/configs/ || true
    fi

    # Create wrapper script that sets up the environment
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/yaml-automation-runner \
      --add-flags "$out/lib/yaml-automation/automation_engine.py" \
      --prefix PATH : ${lib.makeBinPath [ pkgs.tesseract ]}

    runHook postInstall
  '';

  meta = with lib; {
    description = "YAML-based automation engine for GUI automation via VNC + OCR";
    longDescription = ''
      Cross-platform automation engine that executes YAML-based automation
      configs (Lume format) for unattended OS installation and setup.

      Supports:
      - VNC framebuffer capture and input injection
      - Tesseract OCR for text recognition (Linux)
      - Index-based text selection for duplicate text
      - SSH health checks with retries
      - Debug mode with annotated screenshots
    '';
    license = licenses.mit;
    platforms = platforms.linux; # Currently Linux-only (Tesseract)
    maintainers = [ ];
  };
}
