{ pkgs, lib, ... }:

pkgs.python3Packages.buildPythonApplication {
  pname = "deployment-event-metrics";
  version = "unstable";

  src = ./.;
  pyproject = false;

  installPhase = ''
    runHook preInstall
    install -Dm755 deployment_event_metrics.py "$out/bin/deployment-event-metrics"
    runHook postInstall
  '';

  doCheck = true;
  checkPhase = ''
    python3 deployment_event_metrics.py --self-test
  '';

  meta = {
    mainProgram = "deployment-event-metrics";
    platforms = lib.platforms.linux;
  };
}
