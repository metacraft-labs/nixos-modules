{ ... }:
{
  flake.modules.nixos.healthcheck =
    # /etc/nixos/modules/systemd-healthcheck.nix
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      mkProbeOptions = x: {
        options =
          {
            enable = lib.mkEnableOption "the ${x} probe";

            command = lib.mkOption {
              type = lib.types.str;
              description = "The command to execute for the ${x} check. Any necessary programs should be added to the healthcheck.runtimePackages option.";
            };

            initialDelay = lib.mkOption {
              type = lib.types.int;
              default = 15;
              description = "Seconds to wait after the service is up before the first ${x} probe.";
            };

            interval = lib.mkOption {
              type = lib.types.int;
              default = if x == "liveness" then 30 else 2;
              description = "How often (in seconds) to perform the ${x} probe.";
            };

            timeout = lib.mkOption {
              type = lib.types.int;
              default = 10;
              description = "Seconds after which the ${x} probe command times out.";
            };
            retryCount = lib.mkOption {
              type = lib.types.int;
              default = 10;
              description = "Number of times to retry the ${x} probe before considering it failed. (-1 means infinite retries)";
            };
          }
          // lib.optionalAttrs (x == "readiness") {
            statusWaitingMessage = lib.mkOption {
              type = lib.types.str;
              default = "Service starting, waiting for ready signal...";
              description = "The status message to send to systemd while waiting.";
            };

            statusReadyMessage = lib.mkOption {
              type = lib.types.str;
              default = "Service is ready.";
              description = ''
                The status message to send when the service is ready.
                Use %OUTPUT% to substitute the output of the check command.
              '';
            };
          };
      };

      # Options for the liveness probe (timer-based check)
      livenessProbeOptions = mkProbeOptions "liveness";

      # Options for the readiness probe (notify-based check)
      readinessProbeOptions = mkProbeOptions "readiness";
    in
    {

      config =
        let
          servicesWithHealthcheck = lib.filterAttrs (
            _name: service: service.healthcheck != null
          ) config.mcl.services;
        in
        {
          systemd = {
            timers = lib.mapAttrs' (
              mainServiceName: serviceConfig:
              let
                cfg = serviceConfig.healthcheck;
              in
              {
                name = "${mainServiceName}-liveness-check";
                value = lib.mkIf (cfg != null && cfg.liveness-probe.enable) {
                  description = "Timer for ${mainServiceName} liveness probe";
                  timerConfig = {
                    Unit = "${mainServiceName}-liveness-check.service";
                  };
                  wantedBy = [ "${mainServiceName}.service" ];
                };
              }
            ) servicesWithHealthcheck;

            services =
              let
                mainServices = lib.mapAttrs (
                  mainServiceName: serviceConfig:
                  let
                    cfg = serviceConfig.healthcheck;
                  in
                  (lib.mkIf (cfg.readiness-probe.enable) (
                    let
                      probeCfg = cfg.readiness-probe;
                    in
                    {
                      # We have to force it to be a notify service, in order to use systemd-notify.
                      serviceConfig.Type = lib.mkForce "notify";
                      # If the TimeoutStartSec is not infinity, it can cause the service to fail, because the readiness probe is considered part of the startup.
                      serviceConfig.TimeoutStartSec = lib.mkForce "infinity";

                      # We add a ExecStartPost with a script that runs the readiness probe
                      serviceConfig.ExecStartPre =
                        let
                          scriptPath = lib.makeBinPath (
                            [
                              pkgs.systemd
                              pkgs.curl
                              pkgs.gawk
                            ]
                            ++ (cfg.runtimePackages or [ ])
                            ++ (serviceConfig.path or [ ])
                          );
                        in
                          pkgs.writeShellScript "${mainServiceName}-readiness-check" ''
                            #!${pkgs.runtimeShell}
                            set -o nounset

                            export NOTIFY_SOCKET
                            monitor() {
                              export PATH="${scriptPath}:$PATH"

                              echo "Health check: starting background readiness probe for ${mainServiceName}." 1>>/tmp/banica1 2>>/tmp/banica2
                              sleep ${toString probeCfg.initialDelay}
                              retryCount=${toString probeCfg.retryCount}
                              while true; do
                                if (timeout ${toString probeCfg.timeout}s ${probeCfg.command} &> /dev/null); then
                                  echo "Health check: probe successful. Notifying systemd that the service is ready." 1>>/tmp/banica1 2>>/tmp/banica2
                                  systemd-notify --ready --status="${probeCfg.statusReadyMessage}" 1>>/tmp/banica1 2>>/tmp/banica2
                                  exit 0
                                else
                                  echo "Health check: probe not successful. Notifying systemd that the service is still waiting. Retrying in ${toString probeCfg.interval} seconds..." 1>>/tmp/banica1 2>>/tmp/banica2
                                  systemd-notify --status="${probeCfg.statusWaitingMessage}" 1>>/tmp/banica1 2>>/tmp/banica2
                                  if [[ ''${retryCount} -ne -1 ]]; then
                                    retryCount=$((retryCount - 1))
                                    if [[ ''${retryCount} -le 0 ]]; then
                                      echo "Health check: probe failed after maximum retries. Exiting." 1>>/tmp/banica1 2>>/tmp/banica2
                                      exit 1
                                    fi
                                  fi
                                fi
                                sleep ${toString probeCfg.interval}
                              done
                            }

                            monitor &
                          '';
                    }
                  ))
                ) servicesWithHealthcheck;
                healthCheckServices = lib.mapAttrs' (
                  mainServiceName: serviceConfig:
                  let
                    cfg = serviceConfig.healthcheck;
                  in
                  {
                    name = "${mainServiceName}-liveness-check";
                    value = lib.mkIf (cfg != null && cfg.liveness-probe.enable) (
                      let
                        probeCfg = cfg.liveness-probe;
                        checkScript = pkgs.writeShellScript "liveness-check" ''
                          #!${pkgs.runtimeShell}
                          retryCount=${toString probeCfg.retryCount}
                          sleep ${toString probeCfg.initialDelay}
                          echo "Executing liveness probe for ${mainServiceName}..."
                          # If the command fails, explicitly restart the main service
                          while true; do
                            if ! (timeout ${toString probeCfg.timeout}s ${probeCfg.command}  &> /dev/null); then
                              echo "(timeout ${toString probeCfg.timeout}s ${probeCfg.command})"
                              echo "Liveness probe for ${mainServiceName} failed. Triggering restart..."
                              ${lib.getExe' pkgs.systemd "systemctl"} restart ${mainServiceName}.service &
                              if [[ ''${retryCount} -ne -1 ]]; then
                                retryCount=$((retryCount - 1))
                                if [[ ''${retryCount} -le 0 ]]; then
                                  echo "Liveness probe failed after maximum retries. Exiting."
                                  exit 1
                                fi
                              fi
                            fi
                            sleep ${toString probeCfg.interval}
                          done
                        '';
                      in
                      {
                        description = "Liveness check for ${mainServiceName}";
                        # This check needs systemctl in its path.
                        path = [ pkgs.systemd ] ++ (cfg.runtimePackages or [ ]);
                        serviceConfig = {
                          Type = "oneshot";
                          ExecStart = "${checkScript}";
                        };
                      }
                    );
                  }
                ) servicesWithHealthcheck;
              in
              mainServices // healthCheckServices;
          };
        };

      options.mcl.services = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule (
            { ... }:
            {
              options = {
                healthcheck = lib.mkOption {
                  default = null;
                  description = "Declarative health checks for this systemd service.";
                  type = lib.types.nullOr (
                    lib.types.submodule {
                      options = {
                        # Programs to add to the PATH for the health check.
                        runtimePackages = lib.mkOption {
                          type = lib.types.listOf lib.types.package;
                          default = [ ];
                          description = "Additional programs to add to the PATH for health checks.";
                        };

                        # The new readiness probe that uses the notify pattern.
                        readiness-probe = lib.mkOption {
                          type = lib.types.submodule readinessProbeOptions;
                          default = { };
                        };

                        # The liveness probe (timer-based).
                        liveness-probe = lib.mkOption {
                          type = lib.types.submodule livenessProbeOptions;
                          default = { };
                        };
                      };
                    }
                  );
                };
              };

            }
          )
        );
      };
    };
}
