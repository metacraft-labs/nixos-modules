{ lib, self, ... }:
{
  perSystem =
    {
      pkgs,
      self',
      ...
    }:
    let
      deploymentEvents = pkgs.writeText "deployment-events.jsonl" ''
        {"schemaVersion":1,"deploymentId":"dep-1","correlationId":"corr-1","phase":"cache-push","target":{"name":"app-server-01","system":"x86_64-linux","kind":"server","transport":"cachix-agent"},"backend":{"cache":"example-cache","controller":"attic","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01","closure":{"count":2,"totalBytes":1234,"rootHashes":["0123456789abcdfghijklmnpqrsvwxyz"]}},"timestamps":{"startedAt":"2026-05-13T09:00:00Z","finishedAt":"2026-05-13T09:00:05Z"},"command":{"name":"attic push","argv":["attic","push"],"status":"succeeded","exitCode":0}}
        {"schemaVersion":1,"deploymentId":"dep-1","correlationId":"corr-1","phase":"agent-restore","target":{"name":"app-server-01","system":"x86_64-linux","kind":"server","transport":"cachix-agent"},"backend":{"cache":"example-cache","controller":"cachix-deploy","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01"},"timestamps":{"startedAt":"2026-05-13T09:00:05Z","finishedAt":"2026-05-13T09:00:08Z"},"command":{"name":"restore","argv":["restore"],"status":"failed","exitCode":1},"error":{"code":"cache_restore_failed","message":"restore failed","retryable":true}}
        {"schemaVersion":1,"deploymentId":"dep-2","correlationId":"corr-2","phase":"switch","target":{"name":"app-server-02","system":"x86_64-linux","kind":"server","transport":"direct-ssh"},"backend":{"cache":"example-cache","controller":"direct-ssh","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-02"},"timestamps":{"startedAt":"2026-05-13T09:00:10Z"},"command":{"name":"switch","argv":["switch"],"status":"running","exitCode":null}}
        {"schemaVersion":1,"deploymentId":"dep-3","correlationId":"corr-3","phase":"switch","target":{"name":"app-server-03","system":"x86_64-linux","kind":"server","transport":"direct-ssh"},"backend":{"cache":"example-cache","controller":"direct-ssh","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-03"},"timestamps":{"startedAt":"2026-05-13T09:00:10Z"},"command":{"name":"switch","argv":["switch"],"status":"running","exitCode":null}}
        {"schemaVersion":1,"deploymentId":"dep-3","correlationId":"corr-3","phase":"switch","target":{"name":"app-server-03","system":"x86_64-linux","kind":"server","transport":"direct-ssh"},"backend":{"cache":"example-cache","controller":"direct-ssh","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-03"},"timestamps":{"startedAt":"2026-05-13T09:00:10Z","finishedAt":"2026-05-13T09:00:15Z"},"command":{"name":"switch","argv":["switch"],"status":"succeeded","exitCode":0}}
        {"schemaVersion":1,"deploymentId":"dep-1","correlationId":"corr-1","phase":"complete","target":{"name":"app-server-01","system":"x86_64-linux","kind":"server","transport":"direct-ssh"},"backend":{"cache":"example-cache","controller":"direct-ssh","substituters":["https://cache.example/example-cache"]},"storePaths":{"system":"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01"},"timestamps":{"startedAt":"2026-05-13T09:00:08Z","finishedAt":"2026-05-13T09:00:09Z"},"command":{"name":"complete","argv":["complete"],"status":"succeeded","exitCode":0}}
      '';

      atticNginxFixture = pkgs.writeText "attic-nginx.access.jsonl" ''
        {"time":"2026-05-13T09:00:00+00:00","method":"PUT","uri":"/example-cache/nar/abc","status":"200","request_length":"4096","body_bytes_sent":"12"}
        {"time":"2026-05-13T09:00:01+00:00","method":"GET","uri":"/example-cache/nar/abc","status":"200","request_length":"240","body_bytes_sent":"1234"}
        {"time":"2026-05-13T09:00:02+00:00","method":"GET","uri":"/example-cache/nar/missing","status":"404","request_length":"240","body_bytes_sent":"64"}
      '';

      assertMetric = metric: ''
        if ! grep -Fq '${metric}' "$metrics"; then
          echo "missing expected metric: ${metric}" >&2
          cat "$metrics" >&2
          exit 1
        fi
      '';

      commonNode = {
        imports = [ self.modules.nixos.deployment-event-metrics ];
        services.deployment-event-metrics = {
          enable = true;
          port = 9161;
          bind-addresses = [ "0.0.0.0" ];
          event-log-files = [ "${deploymentEvents}" ];
          nginx-log-files = [ "${atticNginxFixture}" ];
          expected-targets = [
            "app-server-01"
            "app-server-02"
            "app-server-03"
            "app-server-04"
          ];
        };
        environment.systemPackages = [
          pkgs.curl
        ];
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        deployment-metrics-vm = pkgs.testers.nixosTest {
          name = "deployment-metrics-vm";

          nodes.exporter = commonNode;

          testScript = ''
            start_all()
            exporter.wait_for_unit("deployment-event-metrics.service")
            exporter.wait_for_open_port(9161)
            metrics = exporter.succeed("curl -fsS http://127.0.0.1:9161/metrics")
            assert 'mcl_deployment_phase_duration_seconds{cache="example-cache",controller="attic",phase="cache-push",status="succeeded",target="app-server-01",transport="cachix-agent"} 5' in metrics, metrics
            assert 'mcl_deployment_cache_upload_bytes_total{backend="attic",cache="example-cache",status="succeeded",target="app-server-01"} 1234' in metrics, metrics
            assert 'mcl_deployment_cache_restore_failures_total{cache="example-cache",controller="cachix-deploy",error_code="cache_restore_failed",target="app-server-01",transport="cachix-agent"} 1' in metrics, metrics
            assert 'mcl_deployment_last_successful_timestamp_seconds{target="app-server-01"}' in metrics, metrics
            assert 'mcl_deployment_target_seen{target="app-server-02"} 1' in metrics, metrics
            assert 'mcl_deployment_target_seen{target="app-server-04"} 0' in metrics, metrics
            assert 'mcl_deployment_in_progress_age_seconds{cache="example-cache",controller="direct-ssh",phase="switch",status="running",target="app-server-02",transport="direct-ssh"}' in metrics, metrics
            assert 'mcl_deployment_in_progress_age_seconds{cache="example-cache",controller="direct-ssh",phase="switch",status="running",target="app-server-03",transport="direct-ssh"}' not in metrics, metrics
          '';
        };

        deployment-attic-nginx-logs-vm = pkgs.testers.nixosTest {
          name = "deployment-attic-nginx-logs-vm";

          nodes.cache =
            { lib, ... }:
            {
              imports = [ self.modules.nixos.deployment-event-metrics ];
              services.nginx = {
                enable = true;
                commonHttpConfig = ''
                  log_format mcl_attic_cache escape=json '{"time":"$time_iso8601","method":"$request_method","uri":"$uri","status":"$status","request_length":"$request_length","body_bytes_sent":"$body_bytes_sent"}';
                '';
                virtualHosts."attic.test" = {
                  listen = [
                    {
                      addr = "0.0.0.0";
                      port = 8080;
                    }
                  ];
                  locations."/" = {
                    extraConfig = ''
                      access_log /var/log/nginx/attic-cache.access.jsonl mcl_attic_cache;
                      return 200 "ok\n";
                    '';
                  };
                  locations."/missing" = {
                    extraConfig = ''
                      access_log /var/log/nginx/attic-cache.access.jsonl mcl_attic_cache;
                      return 404 "missing\n";
                    '';
                  };
                };
              };
              services.deployment-event-metrics = {
                enable = true;
                port = 9161;
                bind-addresses = [ "0.0.0.0" ];
                event-log-files = [ "${deploymentEvents}" ];
                nginx-log-files = [ "/var/log/nginx/attic-cache.access.jsonl" ];
              };
              environment.systemPackages = [
                pkgs.curl
              ];
              networking.firewall.allowedTCPPorts = [
                8080
                9161
              ];
            };

          testScript = ''
            start_all()
            cache.wait_for_unit("nginx.service")
            cache.wait_for_unit("deployment-event-metrics.service")
            cache.wait_for_open_port(8080)
            cache.wait_for_open_port(9161)
            cache.succeed("curl -fsS -H 'Host: attic.test' -X PUT --data-binary payload http://127.0.0.1:8080/upload")
            cache.succeed("curl -fsS -H 'Host: attic.test' http://127.0.0.1:8080/download")
            cache.fail("curl -fsS -H 'Host: attic.test' http://127.0.0.1:8080/missing")
            metrics = cache.succeed("curl -fsS http://127.0.0.1:9161/metrics")
            assert 'mcl_attic_nginx_requests_total{method="PUT",operation="upload",status="200"} 1' in metrics, metrics
            assert 'mcl_attic_nginx_requests_total{method="GET",operation="download",status="200"} 1' in metrics, metrics
            assert 'mcl_attic_nginx_cache_object_failures_total{method="GET",operation="download",status="404"} 1' in metrics, metrics
          '';
        };

        deployment-dashboard-query-fixtures =
          pkgs.runCommand "deployment-dashboard-query-fixtures"
            {
              nativeBuildInputs = [
                self'.packages.deployment-event-metrics
                pkgs.gnugrep
              ];
            }
            ''
              set -euo pipefail
              metrics="$PWD/metrics.prom"
              deployment-event-metrics \
                --event-log ${deploymentEvents} \
                --nginx-log ${atticNginxFixture} \
                --expected-target app-server-01 \
                --expected-target app-server-02 \
                --once > "$metrics"

              ${assertMetric "mcl_deployment_phase_duration_seconds"}
              ${assertMetric "mcl_deployment_phase_failures_total"}
              ${assertMetric "mcl_deployment_cache_upload_bytes_total"}
              ${assertMetric "mcl_deployment_cache_restore_failures_total"}
              ${assertMetric "mcl_attic_nginx_requests_total"}
              ${assertMetric "mcl_attic_nginx_cache_object_failures_total"}

              grep -Fq 'mcl_deployment_phase_failures_total' ${../docs/deployment/monitoring.md}
              grep -Fq 'mcl_deployment_cache_restore_failures_total' ${../docs/deployment/monitoring.md}
              grep -Fq 'mcl_deployment_in_progress_age_seconds' ${../docs/deployment/monitoring.md}
              grep -Fq 'mcl_attic_nginx_cache_object_failures_total' ${../docs/deployment/monitoring.md}
              grep -Fq '{job="deployment-events"} | json | command_status="failed"' ${../docs/deployment/monitoring.md}

              mkdir -p "$out"
              cp "$metrics" "$out/metrics.prom"
            '';
      };
    };
}
