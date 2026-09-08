# GARM runner-fleet Prometheus alert-rule LIBRARY (general, parametric,
# company-agnostic).
#
# This is a PURE function: given a set of thresholds it returns the YAML text of
# a Prometheus rule file. Both the NixOS module (./default.nix) and the promtool
# gate (../../checks/fleet-alerting.nix) render from THIS one source, so the
# exact text that ships is the exact text `promtool test rules` replays.
#
# It covers every failure mode in a GARM runner chain, mapped to metric names
# VERIFIED live on a real controller (high-mem-server :9997, 2026-09-08):
#
#   garm_health{controller_id,...}                         -> controller unhealthy
#   up{job="garm"}                                         -> controller/host down
#   garm_organization_pool_manager_status{name,running}    -> pool manager stopped
#   garm_runner_errors_total{operation,provider}           -> provider CreateInstance fails
#   garm_runner_operations_total{operation,provider}       -> (denominator for the ratio)
#   garm_github_rate_limit_remaining{credential_name,...}  -> GitHub throttle imminent
#   garm_scaleset_{status,max_runners,min_idle_runners,    -> capacity / STARVATION
#                  desired_runner_count,info}                  (pool mode: garm_pool_*)
#   garm_job_status{owner,requested_labels,status}         -> queued-job demand
#   garm_webhook_received{valid,reason}                    -> HMAC failures (pool mode only)
#
# Plus the two checks `garm_*` CANNOT see, over metrics published by the
# companion external-checks exporter (../garm-fleet-external-checks):
#
#   github_app_installation_token_mint_ok{app}             -> App key/JWT rejected
#   github_webhook_last_delivery_ok{org,hook_id}           -> webhook delivery broken
#   probe_success{job=~webhookProbeJobRegex}               -> public endpoint down (blackbox)
#
# SCALE-SET vs POOL. The live fleet is in scale-set mode today, so the capacity
# metrics are `garm_scaleset_*`. `mode = "pool"` flips them to `garm_pool_*` for
# after the Phase-C migration. The simple renames (status/max/min) are exact; the
# STARVATION join is genuinely different between the two modes (scale sets expose
# `desired_runner_count` and a `name` that equals the job's requested class;
# pools do not), so the pool-mode starvation expression is a documented, coarser
# owner-scoped variant — see `poolSaturatedExpr`.
{
  lib,
  # The Prometheus scrape job that collects `garm_*` from the controllers.
  garmJob ? "garm",
  # "scaleset" (live today) | "pool" (post Phase-C migration).
  mode ? "scaleset",
  # for: windows.
  controllerDownFor ? "2m",
  controllerUnhealthyFor ? "5m",
  poolManagerDownFor ? "5m",
  providerCreateFailFor ? "5m",
  providerErrorRatioFor ? "10m",
  rateLimitFor ? "5m",
  starvationFor ? "10m",
  appTokenMintFor ? "15m",
  webhookDeliveryFor ? "30m",
  webhookHmacFor ? "10m",
  webhookProbeFor ? "5m",
  # Thresholds.
  providerCreateFailCount ? 3, # >= this many CreateInstance failures in 15m.
  providerErrorRatioCrit ? "0.2", # errors/ops ratio over 15m.
  rateLimitWarn ? 200,
  rateLimitCrit ? 50,
  # Toggle the two external-check alert families (over the exporter metrics).
  externalChecks ? true,
  # Toggle the webhook alert family. Post-Phase-C only: in scale-set mode GARM
  # long-polls GitHub and there are NO webhooks, so `garm_webhook_received` never
  # exists and the exporter has no hook to probe. Authored + tested here; the
  # concrete infra instance keeps this OFF until RC3 lands the public endpoint.
  webhookChecks ? true,
  # The blackbox-exporter job that probes the public webhook hostname(s).
  webhookProbeJobRegex ? ".*webhook.*",
}:
let
  inherit (lib)
    optional
    optionals
    concatStringsSep
    concatMapStringsSep
    splitString
    genList
    concatStrings
    ;

  isPool = mode == "pool";
  s = toString;

  # Indent every non-empty line of a block by `n` spaces (for interpolating a
  # multi-line PromQL expression under a YAML `|` block scalar).
  indentBlock =
    n: str:
    let
      pad = concatStrings (genList (_: " ") n);
    in
    concatStringsSep "\n" (map (l: if l == "" then "" else pad + l) (splitString "\n" str));

  # ── Renderers (data -> YAML). Every rule is emitted through these so the
  # indentation is correct BY CONSTRUCTION, not by hand-aligning strings. ──────
  #
  # Alert: { name, expr, for?, severity, summary, description }.
  # `expr` may be multi-line; it is rendered as a `|` block scalar at col 10.
  # `summary`/`description` are YAML double-quoted — any literal `"` inside must
  # already be written as `\"`.
  mkAlert =
    a:
    concatStringsSep "\n" (
      [
        "      - alert: ${a.name}"
        "        expr: |"
        (indentBlock 10 a.expr)
      ]
      ++ optional (a ? for) "        for: ${a.for}"
      ++ [
        "        labels:"
        "          severity: ${a.severity}"
        "          component: garm-fleet"
        "        annotations:"
        "          summary: \"${a.summary}\""
        "          description: \"${a.description}\""
      ]
    );

  # Recording rule: { record, expr }.
  mkRecord =
    r:
    concatStringsSep "\n" [
      "      - record: ${r.record}"
      "        expr: |"
      (indentBlock 10 r.expr)
    ];

  # Group: { name, comment?, records? [ ], rules [ ] }.
  mkGroup =
    g:
    concatStringsSep "\n" (
      (optionals (g ? comment) (map (c: "  ${c}") g.comment))
      ++ [
        "  - name: ${g.name}"
        "    rules:"
      ]
      ++ map mkRecord (g.records or [ ])
      ++ map mkAlert (g.rules or [ ])
    );

  # Capacity metric family, selected by mode.
  m = {
    maxRunners = if isPool then "garm_pool_max_runners" else "garm_scaleset_max_runners";
    desired = "garm_scaleset_desired_runner_count"; # scale-set only
    info = if isPool then "garm_pool_info" else "garm_scaleset_info";
    ownerLabel = if isPool then "pool_owner" else "scaleset_owner";
  };

  # ── STARVATION join (see header). Scale-set: saturated == desired >= max,
  # joined to queued jobs by (owner, class) where scale-set `name` == the job's
  # `requested_labels`. This is the exact live shape: on 2026-09-08 scaleset
  # id=5 (eph-linux-x64, metacraft-labs) had desired=6, max=6 with an
  # eph-linux-x64 job queued — a real starvation this catches.
  scalesetSaturatedExpr = ''
    max by (garm_owner, garm_class) (
      label_replace(
        label_replace(
          (${m.desired} >= bool ${m.maxRunners})
            * on (id) group_left(${m.ownerLabel}, name) ${m.info},
          "garm_owner", "$1", "${m.ownerLabel}", "(.*)"),
        "garm_class", "$1", "name", "(.*)")
    )'';

  # Pool mode: pools expose no `desired_runner_count` and no class `name` that
  # matches a job's label set, so saturation is "running runners in the pool >=
  # max" and the queued-job join degrades to OWNER scope. Tighten to label-set
  # membership once the pool-mode requested_labels/pool-tags mapping is settled.
  poolSaturatedExpr = ''
    max by (garm_owner) (
      label_replace(
        (
          count by (pool_id) (garm_runner_status{status="running"})
            >= bool label_replace(${m.maxRunners}, "pool_id", "$1", "id", "(.*)")
        )
          * on (pool_id) group_left(${m.ownerLabel})
            label_replace(${m.info}, "pool_id", "$1", "id", "(.*)"),
        "garm_owner", "$1", "${m.ownerLabel}", "(.*)")
    )'';

  queuedJobsExpr = ''
    count by (garm_owner, garm_class) (
      label_replace(
        label_replace(
          garm_job_status{status="queued"},
          "garm_owner", "$1", "owner", "(.*)"),
        "garm_class", "$1", "requested_labels", "(.*)")
    )'';

  starvationExpr =
    if isPool then
      ''
        garm:class_queued_jobs
          and on (garm_owner) (garm:class_saturated == 1)''
    else
      ''
        garm:class_queued_jobs
          and on (garm_owner, garm_class) (garm:class_saturated == 1)'';

  groups = [
    {
      name = "garm-fleet-controller";
      comment = [ "# ── Controller / host reachability & health ──" ];
      rules = [
        {
          name = "GarmControllerDown";
          expr = "up{job=\"${garmJob}\"} == 0";
          for = controllerDownFor;
          severity = "critical";
          summary = "GARM controller unreachable ({{ $labels.instance }})";
          description = "Prometheus cannot scrape GARM at {{ $labels.instance }} (job ${garmJob}) for ${controllerDownFor}. No runners can be created or reaped while the controller is down — check the garm.service unit and the host.";
        }
        {
          name = "GarmControllerUnhealthy";
          expr = "garm_health == 0";
          for = controllerUnhealthyFor;
          severity = "critical";
          summary = "GARM controller reports unhealthy ({{ $labels.controller_id }})";
          description = "garm_health for controller {{ $labels.controller_id }} has been 0 for ${controllerUnhealthyFor} — the process is up but degraded. Check the garm.service journal.";
        }
        {
          name = "GarmPoolManagerNotRunning";
          expr = "garm_organization_pool_manager_status == 0";
          for = poolManagerDownFor;
          severity = "critical";
          summary = "GARM pool manager not running ({{ $labels.name }})";
          description = "The pool manager for org {{ $labels.name }} has been stopped for ${poolManagerDownFor}. That org gets no new runners even though the controller is up — restart / check the org credentials.";
        }
      ];
    }
    {
      name = "garm-fleet-provider";
      comment = [ "# ── Provider (CreateInstance) health ──" ];
      rules = [
        {
          name = "GarmProviderCreateFailures";
          expr = "increase(garm_runner_errors_total{operation=\"CreateInstance\"}[15m]) >= ${s providerCreateFailCount}";
          for = providerCreateFailFor;
          severity = "warning";
          summary = "GARM provider failing to create runners ({{ $labels.provider }})";
          description = "Provider {{ $labels.provider }} has had at least ${s providerCreateFailCount} CreateInstance failures in the last 15m. The backend (incus/libvirt/tart/EC2) is likely broken — check the provider host.";
        }
        {
          name = "GarmProviderHighErrorRatio";
          # Plain division is safe here: every error is also a counted
          # operation (operations_total >= errors_total per operation/provider),
          # so the denominator is never 0 while the numerator is > 0, and a
          # no-traffic provider yields 0/0 = NaN which never trips `> x`. (Do NOT
          # reintroduce clamp_min(rate, 1): rates are per-SECOND, so a floor of 1
          # makes the ratio meaningless below 1 failed op/s.)
          expr = ''
            rate(garm_runner_errors_total[15m])
              / rate(garm_runner_operations_total[15m])
              > ${providerErrorRatioCrit}'';
          for = providerErrorRatioFor;
          severity = "critical";
          summary = "GARM provider failing >${providerErrorRatioCrit} of operations ({{ $labels.provider }})";
          description = "Provider {{ $labels.provider }} is failing more than ${providerErrorRatioCrit} of its runner operations over 15m ({{ $value | humanizePercentage }}). The backend is broken (incus/libvirt/tart down, or AWS quota/subnet/AMI errors) — runners are not being provisioned.";
        }
      ];
    }
    {
      name = "garm-fleet-github";
      comment = [ "# ── GitHub API rate limits ──" ];
      rules = [
        {
          name = "GarmGithubRateLimitLow";
          expr = "garm_github_rate_limit_remaining < ${s rateLimitWarn}";
          for = rateLimitFor;
          severity = "warning";
          summary = "GitHub API rate limit low ({{ $labels.credential_name }})";
          description = "Credential {{ $labels.credential_name }} has {{ $value }} GitHub API requests remaining (< ${s rateLimitWarn}) for ${rateLimitFor}. Approaching a throttle that will stall runner provisioning.";
        }
        {
          name = "GarmGithubRateLimitCritical";
          expr = "garm_github_rate_limit_remaining < ${s rateLimitCrit}";
          for = rateLimitFor;
          severity = "critical";
          summary = "GitHub API rate limit critically low ({{ $labels.credential_name }})";
          description = "Credential {{ $labels.credential_name }} has only {{ $value }} GitHub API requests remaining (< ${s rateLimitCrit}). GARM is about to be throttled — runner provisioning will stall.";
        }
      ];
    }
    {
      name = "garm-fleet-capacity";
      comment = [
        "# ── Capacity / STARVATION (the priority page) ──"
        "# Recording rules derive per-(owner,class) saturation + queued demand"
        "# from the base metrics so the alert stays legible and promtool can"
        "# assert the whole chain from raw series. See rules.nix for the join."
      ];
      records = [
        {
          record = "garm:class_saturated";
          expr = if isPool then poolSaturatedExpr else scalesetSaturatedExpr;
        }
        {
          record = "garm:class_queued_jobs";
          expr = queuedJobsExpr;
        }
      ];
      rules = [
        {
          name = "GarmFleetStarvation";
          expr = starvationExpr;
          for = starvationFor;
          severity = "critical";
          summary = "Runner STARVATION: {{ $labels.garm_owner }}/{{ $labels.garm_class }} saturated with jobs queued";
          description = "{{ $value }} job(s) have been queued for ${starvationFor} for class {{ $labels.garm_class }} (owner {{ $labels.garm_owner }}) while that class is at its runner ceiling. Jobs are starving — raise max-runners, add a qualifying host, or check that the AWS burst spill is firing.";
        }
      ];
    }
  ]
  ++ optionals externalChecks [
    {
      name = "garm-fleet-external";
      comment = [
        "# ── EXTERNAL checks: things garm_* cannot see ──"
        "# Fed by the garm-fleet-external-checks exporter, NOT by GARM. If the"
        "# exporter is down these go inactive (a blind spot, not a false page) —"
        "# the generic up==0 scrape-target alert notices a dead exporter."
      ];
      rules = [
        {
          name = "GithubAppTokenMintFailing";
          expr = "github_app_installation_token_mint_ok == 0";
          for = appTokenMintFor;
          severity = "critical";
          summary = "GitHub App token minting is failing ({{ $labels.app }})";
          description = "The garm-fleet-external-checks exporter could not mint an installation token for App {{ $labels.app }} for ${appTokenMintFor}. The App private key/JWT is rejected (rotated, revoked, clock skew, or the installation was removed) — GARM cannot register or reap runners for that org. Rotate/repair the App credential.";
        }
      ]
      ++ optionals webhookChecks [
        {
          name = "GithubWebhookDeliveryFailing";
          expr = "github_webhook_last_delivery_ok == 0";
          for = webhookDeliveryFor;
          severity = "critical";
          summary = "GitHub webhook deliveries are failing ({{ $labels.org }})";
          description = "GitHub reports the most recent webhook delivery to the controller endpoint for {{ $labels.org }} (hook {{ $labels.hook_id }}) as non-2xx for ${webhookDeliveryFor}. Job events are not reaching GARM — check the Cloudflare Tunnel / public endpoint and the org webhook config.";
        }
        {
          name = "GithubWebhookEndpointProbeDown";
          expr = "probe_success{job=~\"${webhookProbeJobRegex}\"} == 0";
          for = webhookProbeFor;
          severity = "critical";
          summary = "GARM public webhook endpoint probe is failing ({{ $labels.instance }})";
          description = "The blackbox probe of the public webhook endpoint {{ $labels.instance }} has failed for ${webhookProbeFor} (tunnel down, cert expired, or endpoint unreachable). GitHub cannot deliver workflow_job events.";
        }
      ];
    }
  ]
  ++ optionals webhookChecks [
    {
      name = "garm-fleet-webhook";
      comment = [
        "# ── GARM-side webhook HMAC (POST-PHASE-C) ──"
        "# garm_webhook_received only exists in pool mode. valid=false is an HMAC"
        "# or parse failure: a secret mismatch, a bad relay, or a spoof attempt."
      ];
      rules = [
        {
          name = "GarmWebhookHmacFailures";
          expr = "increase(garm_webhook_received{valid=\"false\"}[10m]) >= 1";
          for = webhookHmacFor;
          severity = "warning";
          summary = "GARM is rejecting webhook deliveries (HMAC/parse)";
          description = "GARM has recorded webhook deliveries with valid=\\\"false\\\" (reason {{ $labels.reason }}) for ${webhookHmacFor}. The per-entity webhook secret likely does not match GitHub, or a relay is corrupting the payload — new jobs from the affected org will not scale runners.";
        }
      ];
    }
  ];
in
''
# GENERATED by nixos-modules/modules/garm-fleet-alerts/rules.nix — do not edit
# the deployed copy; change the library and re-render. mode=${mode}, job=${garmJob}.
groups:
${concatMapStringsSep "\n" mkGroup groups}
''
