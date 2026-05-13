{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      docs = ../docs/deployment;
      workflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
    in
    {
      checks = {
        deployment-event-schema-examples = pkgs.runCommand "deployment-event-schema-examples" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import json
          import re
          from pathlib import Path

          docs = Path("${docs}")
          schema = json.loads((docs / "event-schema.json").read_text())
          examples = docs / "examples" / "events-success.jsonl"
          desired_state_schema = json.loads((docs / "desired-state-schema.json").read_text())
          desired_state_example_path = docs / "examples" / "desired-state-success.json"

          expected_desired_state_required = [
              "schemaVersion",
              "deploymentId",
              "target",
              "gitRevision",
              "sequence",
              "manifestSignature",
              "desiredSystemPath",
              "cacheRequirements",
              "healthChecks",
              "rollbackPolicy",
              "currentState",
              "supersededState",
              "retryTimestamps",
          ]
          actual_desired_state_required = desired_state_schema["required"]
          if actual_desired_state_required != expected_desired_state_required:
              raise SystemExit(
                  "desired-state required fields drifted: "
                  f"{actual_desired_state_required!r}"
              )

          expected_phases = [
              "evaluate",
              "build",
              "closure-prefill",
              "cache-push",
              "activate-requested",
              "agent-restore",
              "switch",
              "healthcheck",
              "rollback",
              "complete",
          ]
          actual_phases = schema["properties"]["phase"]["enum"]
          if actual_phases != expected_phases:
              raise SystemExit(f"phase enum drifted: {actual_phases!r}")

          def type_name(value):
              if value is None:
                  return "null"
              if isinstance(value, bool):
                  return "boolean"
              if isinstance(value, int) and not isinstance(value, bool):
                  return "integer"
              if isinstance(value, str):
                  return "string"
              if isinstance(value, list):
                  return "array"
              if isinstance(value, dict):
                  return "object"
              return type(value).__name__

          def validate(schema, value, path):
              allowed = schema.get("type")
              if allowed is not None:
                  allowed_types = allowed if isinstance(allowed, list) else [allowed]
                  actual = type_name(value)
                  if actual not in allowed_types:
                      raise AssertionError(f"{path}: expected {allowed_types}, got {actual}")
                  if actual == "null":
                      return

              if "enum" in schema and value not in schema["enum"]:
                  raise AssertionError(f"{path}: {value!r} not in enum {schema['enum']!r}")

              if "minLength" in schema and len(value) < schema["minLength"]:
                  raise AssertionError(f"{path}: shorter than minLength {schema['minLength']}")
              if "minimum" in schema and value < schema["minimum"]:
                  raise AssertionError(f"{path}: less than minimum {schema['minimum']}")
              if "pattern" in schema and not re.search(schema["pattern"], value):
                  raise AssertionError(f"{path}: {value!r} does not match {schema['pattern']!r}")

              if type_name(value) == "object":
                  required = schema.get("required", [])
                  for key in required:
                      if key not in value:
                          raise AssertionError(f"{path}: missing required key {key!r}")
                  props = schema.get("properties", {})
                  if schema.get("additionalProperties") is False:
                      extra = sorted(set(value) - set(props))
                      if extra:
                          raise AssertionError(f"{path}: unexpected keys {extra!r}")
                  for key, nested in props.items():
                      if key in value:
                          validate(nested, value[key], f"{path}.{key}")

              if type_name(value) == "array" and "items" in schema:
                  for index, item in enumerate(value):
                      validate(schema["items"], item, f"{path}[{index}]")

          seen = []
          for line_no, line in enumerate(examples.read_text().splitlines(), 1):
              if not line.strip():
                  continue
              event = json.loads(line)
              validate(schema, event, f"events-success.jsonl:{line_no}")
              seen.append(event["phase"])

          required_success_phases = [
              phase for phase in expected_phases if phase != "rollback"
          ]
          missing = [phase for phase in required_success_phases if phase not in seen]
          if missing:
              raise SystemExit(f"success example missing phases: {missing!r}")
          if "rollback" in seen:
              raise SystemExit("success example must not include rollback phase")

          desired_state_example = json.loads(desired_state_example_path.read_text())
          validate(
              desired_state_schema,
              desired_state_example,
              "examples/desired-state-success.json",
          )
          PY
          touch "$out"
        '';

        deployment-current-flow-inventory = pkgs.runCommand "deployment-current-flow-inventory" { } ''
          ${pkgs.python3}/bin/python3 <<'PY'
          import json
          import re
          from pathlib import Path

          docs = Path("${docs}")
          workflow = Path("${workflow}")
          inventory = json.loads((docs / "current-flow-inventory.json").read_text())
          text = workflow.read_text()

          required_files = [
              docs / "event-schema.json",
              docs / "desired-state-schema.json",
              docs / "examples" / "events-success.jsonl",
              docs / "examples" / "desired-state-success.json",
              docs / "current-cachix-flow.md",
              docs / "cache-and-deploy-risk-register.md",
          ]
          for path in required_files:
              if not path.is_file():
                  raise SystemExit(f"required M0 key source file is missing: {path.relative_to(docs.parent)}")

          workflow_name = re.compile(
              r"^name:\s*['\"]?" + re.escape(inventory["workflowName"]) + r"['\"]?\s*$",
              re.MULTILINE,
          )
          if not workflow_name.search(text):
              raise SystemExit(f"workflow name {inventory['workflowName']!r} not found")

          for job in inventory["jobs"]:
              if not re.search(r"^  " + re.escape(job) + r":\s*$", text, re.MULTILINE):
                  raise SystemExit(f"documented job not found in workflow: {job}")

          for step in inventory["criticalSteps"]:
              quoted = re.escape(step)
              if not re.search(r"^\s+- name:\s*['\"]?" + quoted + r"['\"]?\s*$", text, re.MULTILINE):
                  raise SystemExit(f"documented step not found in workflow: {step}")

          for command in inventory["criticalCommands"]:
              if command not in text:
                  raise SystemExit(f"documented command fragment not found in workflow: {command}")

          deploy = inventory["deployPath"]
          for value in [deploy["entryJob"], deploy["deployStep"], deploy["deployCondition"], deploy["mclCommand"]]:
              if value not in text:
                  raise SystemExit(f"deploy path value not found in workflow: {value}")

          monitoring = inventory["monitoringPath"]
          required_monitoring_sources = {
              "metacraft-labs/infra/services/monitoring/cachix-deploy-metrics/default.nix",
              "modules/cachix-deploy-metrics/default.nix",
              "packages/cachix-deploy-metrics/default.nix",
              "packages/cachix-deploy-metrics/main.d",
          }
          documented_sources = set(monitoring["sourceFiles"])
          missing_sources = sorted(required_monitoring_sources - documented_sources)
          if missing_sources:
              raise SystemExit(f"monitoring inventory is missing sources: {missing_sources!r}")

          flow_doc = (docs / "current-cachix-flow.md").read_text()
          required_monitoring_terms = [
              "services.cachix-deploy-metrics",
              "auth-token-path",
              "workspace",
              "agent-names",
              "Prometheus exporter",
              "Cachix Deploy API",
              "event stream",
          ]
          for term in required_monitoring_terms:
              if term not in flow_doc:
                  raise SystemExit(f"current Cachix flow doc is missing monitoring term: {term}")
          for source in required_monitoring_sources:
              if source not in flow_doc:
                  raise SystemExit(f"current Cachix flow doc is missing monitoring source: {source}")
          PY
          touch "$out"
        '';

        deployment-general-private-split = pkgs.runCommand "deployment-general-private-split" { } ''
          cd ${docs}

          forbidden='solunska|gpu-server|cache\.metacraft-labs\.com|metacraft-private-infrastructure'
          generic_files=$(find . -type f \
            ! -path './private-inventory.md' \
            \( -name '*.md' -o -name '*.json' -o -name '*.jsonl' \))

          if grep -Eni "$forbidden" $generic_files; then
            echo "generic deployment docs contain private infrastructure details" >&2
            exit 1
          fi

          private=private-inventory.md
          for term in \
            solunska \
            gpu-server \
            cache.metacraft-labs.com \
            metacraft-private-infrastructure \
            /etc/cachix-agent.token \
            cachix-deploy-metrics/auth-token
          do
            if ! grep -Fq "$term" "$private"; then
              echo "private inventory is missing concrete detail: $term" >&2
              exit 1
            fi
          done

          touch "$out"
        '';
      };
    };
}
