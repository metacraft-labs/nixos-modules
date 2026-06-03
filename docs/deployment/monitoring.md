# Deployment Monitoring

M3 derives monitoring from the deployment JSONL event stream defined in
[event-model.md](event-model.md). The exporter reads one or more deployment
event files plus Attic nginx JSON access logs and exposes Prometheus text at
`/metrics`.

## Metrics

Deployment event metrics:

- `mcl_deployment_phase_duration_seconds`
- `mcl_deployment_phase_failures_total`
- `mcl_deployment_closure_paths`
- `mcl_deployment_closure_bytes`
- `mcl_deployment_cache_upload_bytes_total`
- `mcl_deployment_cache_restore_failures_total`
- `mcl_deployment_last_successful_timestamp_seconds`
- `mcl_deployment_last_phase_success_timestamp_seconds`
- `mcl_deployment_in_progress_age_seconds`
- `mcl_deployment_target_expected`
- `mcl_deployment_target_seen`
- `mcl_deployment_target_last_seen_timestamp_seconds`

Attic nginx cache metrics:

- `mcl_attic_nginx_requests_total`
- `mcl_attic_nginx_bytes_total`
- `mcl_attic_nginx_cache_object_failures_total`

`mcl_deployment_in_progress_age_seconds` is emitted only when the latest event
for a deployment, target, and phase is `pending` or `running`. A later terminal
event for the same deployment phase clears the in-progress sample on the next
scrape.

The `*_total` metrics are derived by replaying retained JSONL log files. They
behave as counters while the files are append-only and retained; rotation or
manual deletion can reset them.

## Prometheus Queries

Common incident questions:

| Question                                                    | Query                                                                                     |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| Which deployment phases are failing?                        | `sum by (target, phase, error_code) (increase(mcl_deployment_phase_failures_total[6h]))`  |
| Which targets failed cache restore?                         | `sum by (target, error_code) (increase(mcl_deployment_cache_restore_failures_total[6h]))` |
| Is a deploy stuck?                                          | `max by (target, phase) (mcl_deployment_in_progress_age_seconds) > 3600`                  |
| Which expected targets have not emitted events?             | `mcl_deployment_target_expected unless mcl_deployment_target_seen == 1`                   |
| Which target has not completed recently?                    | `time() - mcl_deployment_last_successful_timestamp_seconds > 86400`                       |
| How large are deployment closures?                          | `max by (target, phase) (mcl_deployment_closure_bytes)`                                   |
| How much data was uploaded to deployment caches?            | `sum by (backend, cache, status) (increase(mcl_deployment_cache_upload_bytes_total[6h]))` |
| How many Attic uploads/downloads are flowing through nginx? | `sum by (operation, method, status) (increase(mcl_attic_nginx_requests_total[6h]))`       |
| Are clients seeing cache object failures?                   | `sum by (operation, status) (increase(mcl_attic_nginx_cache_object_failures_total[1h]))`  |
| What is Attic byte volume?                                  | `sum by (operation, direction, status) (increase(mcl_attic_nginx_bytes_total[6h]))`       |

## Loki Queries

The private infra repository wires the same files into promtail. Useful LogQL
queries:

- Deployment events by target:
  `{job="deployment-events", target=~".+"}`
- Failed deployment events:
  `{job="deployment-events"} | json | command_status="failed"`
- Attic nginx failures:
  `{job="attic-nginx-access"} | json | status=~"4..|5.."`
- Cache object failures:
  `{job="attic-nginx-access"} | json | method=~"GET|HEAD|PUT|POST|PATCH" | status=~"4..|5.."`

## Current Limit

Current Cachix-backed production deployments only prove
`activate-requested`. Target-side `agent-restore`, `switch`, `healthcheck`,
`rollback`, and `complete` events require the M4 direct apply/reconciler
reporter before the last-successful-deploy metric can prove end-to-end target
activation.
