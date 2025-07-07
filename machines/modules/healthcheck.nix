{ self, pkgs, ... }:
{
  imports = [
    self.modules.nixos.healthcheck
  ];

  systemd.services.test = {
    description = "";
    enable = true;
    path = with pkgs; [
    ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "10s";

      ExecStart = ''
        sleep 10; # Simulate a startup delay.
        echo "Starting test service...";
        echo "Test" > /tmp/test.log
        while true ; do
          echo "Test" | nc -l 8080
        done
      '';
    };
  };

  # --- Health Check Configuration ---
  mcl.services.test.healthcheck = {
    runtimePackages = with pkgs; [
      netcat
      curl
    ];

    # READINESS: Use the notify pattern to signal when the service is truly ready.
    readiness-probe = {
      enable = true;
      command = "ls /tmp/test.log";
      interval = 2;
      statusWaitingMessage = "Test starting, waiting...";
      statusReadyMessage = "Test is ready.";
    };

    # LIVENESS: After startup, use a timer to periodically check health.
    liveness-probe = {
      enable = true;
      command = "[ \"$(nc -w 2 localhost 8080)\" = \"Test2\" ]";
      initialDelay = 15;
      interval = 30; # Check every 30 seconds.
      timeout = 5;
    };
  };
}
