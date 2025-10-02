{ ... }:
{
  flake.modules.nixos.healthcheck =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib) types;
      mkProbeOptions = x: {
        options =
          {
            enable = lib.mkEnableOption "the ${x} probe";

            command = lib.mkOption {
              type = types.str;
              description = "The command to execute for the ${x} check. Any necessary programs should be added to the healthcheck.runtimePackages option.";
            };

            initialDelay = lib.mkOption {
              type = types.int;
              default = 15;
              description = "Seconds to wait after the service is up before the first ${x} probe.";
            };

            interval = lib.mkOption {
              type = types.int;
              default = if x == "liveness" then 30 else 2;
              description = "How often (in seconds) to perform the ${x} probe.";
            };

            timeout = lib.mkOption {
              type = types.int;
              default = 10;
              description = "Seconds after which the ${x} probe command times out.";
            };

            # TODO: `{success,failure}_treshold`

            retryCount = lib.mkOption {
              type = types.int;
              default = 10;
              description = "Number of times to retry the ${x} probe before considering it failed. (-1 means infinite retries)";
            };
          }
          // lib.optionalAttrs (x == "readiness") {
            statusWaitingMessage = lib.mkOption {
              type = types.str;
              default = "Service starting, waiting for ready signal...";
              description = "The status message to send to systemd while waiting.";
            };

            statusReadyMessage = lib.mkOption {
              type = types.str;
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
          assertions = lib.pipe config.mcl.services [
            (lib.filterAttrs (_: service: service.healthcheck != null))
            (lib.mapAttrsToList (
              name: _:
              let
                serviceConfig = config.systemd.services.${name}.serviceConfig;
              in
              {
                # NOTE: as per <https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#ExecStartPost=>
                assertion = lib.elem serviceConfig.Type [
                  "simple"
                  "idle"
                ];
                message = ''
                  Service ${name} is not of type "simple" or "idle", but ${serviceConfig.Type}.
                  Cannot attach a readiness probe to it.
                '';
              }
            ))
          ];
          systemd = {
            services =
              let
                mainServices = lib.mapAttrs (
                  mainServiceName: serviceConfig:
                  let
                    cfg = serviceConfig.healthcheck;
                    probeCfg = cfg.readiness-probe;
                  in
                  lib.mkIf (cfg != null && probeCfg.enable) {
                    # Timeout is now handled manually by the new `ExecStartPost`
                    serviceConfig.TimeoutStartSec = "infinity";

                    # Add an `ExecStartPost` with a script that runs the readiness probe
                    # WARN: cannot assure that there is no `ExecStartPost` in the original `serviceConfig`
                    #       (in order to avoid overriding/duplication)
                    serviceConfig.ExecStartPost =
                      let
                        scriptPath = lib.makeBinPath (cfg.runtimePackages ++ (serviceConfig.path or [ ]));
                      in
                      lib.getExe (
                        pkgs.writeShellScriptBin "${mainServiceName}-readiness-check" ''
                          set -o nounset

                          export PATH="${scriptPath}:$PATH"

                          echo "Health check: starting background readiness probe for ${mainServiceName}."
                          sleep ${toString probeCfg.initialDelay}
                          retryCount=${toString probeCfg.retryCount}
                          while true; do
                            if (timeout ${toString probeCfg.timeout}s ${probeCfg.command} &> /dev/null); then
                              echo "Health check: probe successful. Notifying systemd that the service is ready."
                              exit 0
                            else
                              echo "Health check: probe not successful. Notifying systemd that the service is still waiting. Retrying in ${toString probeCfg.interval} seconds..."
                              if [[ ''${retryCount} -ne -1 ]]; then
                                retryCount=$((retryCount - 1))
                                if [[ ''${retryCount} -le 0 ]]; then
                                  echo "Health check: probe failed after maximum retries. Exiting."
                                  exit 1
                                fi
                              fi
                            fi
                            sleep ${toString probeCfg.interval}
                          done
                        ''
                      );
                  }
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
                        checkScript = pkgs.writeShellScriptBin "liveness-check" ''
                          #!${pkgs.runtimeShell}
                          echo "Executing liveness probe for ${mainServiceName}..."
                          if ! (timeout ${toString probeCfg.timeout}s ${probeCfg.command} &> /dev/null); then
                            echo "Liveness probe for ${mainServiceName} failed. Triggering restart..."
                            ${lib.getExe' pkgs.systemd "systemctl"} restart ${lib.escapeShellArg mainServiceName}.service
                            exit 1
                          fi
                          echo "Liveness probe for ${mainServiceName} successful."
                        '';
                      in
                      {
                        description = "Liveness check for ${mainServiceName}";
                        path = cfg.runtimePackages;
                        serviceConfig = {
                          Type = "oneshot";
                          ExecStart = "${lib.getExe checkScript}";
                        };
                      }
                    );
                  }
                ) servicesWithHealthcheck;
              in
              mainServices // healthCheckServices;

            timers = lib.mapAttrs' (
              mainServiceName: serviceConfig:
              let
                cfg = serviceConfig.healthcheck;
              in
              {
                name = "${mainServiceName}-liveness-check";
                value = lib.mkIf (cfg != null && cfg.liveness-probe.enable) (
                  let
                    probeCfg = cfg.liveness-probe;
                  in
                  {
                    description = "Timer for ${mainServiceName} liveness probe";
                    wantedBy = [ "timers.target" ];
                    timerConfig = {
                      OnActiveSec = "${toString probeCfg.initialDelay}s";
                      OnUnitInactiveSec = "${toString probeCfg.interval}s";
                    };
                  }
                );
              }
            ) servicesWithHealthcheck;
          };
        };

      options.mcl.services = lib.mkOption {
        default = { };
        type = types.attrsOf (
          types.submodule {
            options = {
              healthcheck = lib.mkOption {
                default = null;
                description = "Declarative health checks for this systemd service.";
                type = types.nullOr (
                  types.submodule {
                    options = {
                      # Programs to add to the PATH for the health check.
                      runtimePackages = lib.mkOption {
                        type = types.listOf types.package;
                        default = [ ];
                        description = "Additional programs to add to the PATH for health checks.";
                      };

                      # The new readiness probe that uses the notify pattern.
                      readiness-probe = lib.mkOption {
                        type = types.submodule readinessProbeOptions;
                        default = { };
                      };

                      # The liveness probe (timer-based).
                      liveness-probe = lib.mkOption {
                        type = types.submodule livenessProbeOptions;
                        default = { };
                      };
                    };
                  }
                );
              };
            };
          }
        );
      };
    };
}
