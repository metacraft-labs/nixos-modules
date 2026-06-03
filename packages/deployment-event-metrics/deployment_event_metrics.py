#!/usr/bin/env python3
"""Prometheus exporter for Metacraft deployment JSONL and Attic nginx logs."""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import http.server
import json
import os
import pathlib
import socketserver
import sys
import tempfile
import threading
from collections import Counter
from dataclasses import dataclass
from typing import Iterable


DEFAULT_EVENT_DIR = "/var/log/mcl/deployments"
DEFAULT_PORT = 9161


@dataclass(frozen=True)
class Metric:
    name: str
    labels: tuple[tuple[str, str], ...]
    value: float


def parse_timestamp(value: str | None) -> float | None:
    if not value:
        return None
    try:
        normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
        return dt.datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return None


def prom_escape_label(value: object) -> str:
    text = "" if value is None else str(value)
    return text.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def prom_sample(name: str, labels: dict[str, object], value: float | int) -> str:
    label_text = ",".join(
        f'{key}="{prom_escape_label(labels[key])}"' for key in sorted(labels)
    )
    return f"{name}{{{label_text}}} {value:g}" if label_text else f"{name} {value:g}"


def metric_key(name: str, labels: dict[str, object]) -> tuple[str, tuple[tuple[str, str], ...]]:
    return name, tuple(sorted((key, "" if value is None else str(value)) for key, value in labels.items()))


def event_log_paths(event_logs: list[str], event_dirs: list[str]) -> list[pathlib.Path]:
    paths = [pathlib.Path(path) for path in event_logs]
    for directory in event_dirs:
        paths.extend(pathlib.Path(p) for p in glob.glob(os.path.join(directory, "*.jsonl")))
    return sorted(set(paths))


def load_events(event_logs: list[str], event_dirs: list[str]) -> tuple[list[dict], Counter]:
    events: list[dict] = []
    parse_errors: Counter = Counter()
    for path in event_log_paths(event_logs, event_dirs):
        try:
            if not path.exists():
                continue
            with path.open() as handle:
                for line_no, line in enumerate(handle, start=1):
                    if not line.strip():
                        continue
                    try:
                        event = json.loads(line)
                    except json.JSONDecodeError:
                        parse_errors[str(path)] += 1
                        continue
                    if isinstance(event, dict):
                        events.append(event)
                    else:
                        parse_errors[str(path)] += 1
        except OSError:
            parse_errors[str(path)] += 1
    return events, parse_errors


def event_labels(event: dict) -> dict[str, object]:
    target = event.get("target") if isinstance(event.get("target"), dict) else {}
    backend = event.get("backend") if isinstance(event.get("backend"), dict) else {}
    command = event.get("command") if isinstance(event.get("command"), dict) else {}
    return {
        "target": target.get("name", "unknown"),
        "phase": event.get("phase", "unknown"),
        "status": command.get("status", "unknown"),
        "controller": backend.get("controller", "unknown"),
        "transport": target.get("transport", "unknown"),
        "cache": backend.get("cache", "unknown"),
    }


def event_finished_at(event: dict) -> float | None:
    timestamps = event.get("timestamps") if isinstance(event.get("timestamps"), dict) else {}
    return parse_timestamp(timestamps.get("finishedAt"))


def event_started_at(event: dict) -> float | None:
    timestamps = event.get("timestamps") if isinstance(event.get("timestamps"), dict) else {}
    return parse_timestamp(timestamps.get("startedAt"))


def closure_summary(event: dict) -> dict:
    store_paths = event.get("storePaths") if isinstance(event.get("storePaths"), dict) else {}
    closure = store_paths.get("closure")
    return closure if isinstance(closure, dict) else {}


def deployment_metrics(
    events: list[dict],
    parse_errors: Counter,
    expected_targets: list[str],
    now: float,
) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
    metrics: dict[tuple[str, tuple[tuple[str, str], ...]], Metric] = {}
    failure_counts: Counter = Counter()
    cache_upload_bytes: Counter = Counter()
    cache_restore_failures: Counter = Counter()
    last_seen: dict[str, float] = {}
    last_successful_complete: dict[str, float] = {}
    last_phase_success: dict[tuple[str, str], float] = {}
    latest_phase_state: dict[
        tuple[str, str, str], tuple[float, str, dict[str, object], float | None]
    ] = {}

    def set_metric(name: str, labels: dict[str, object], value: float | int) -> None:
        key = metric_key(name, labels)
        metrics[key] = Metric(key[0], key[1], float(value))

    for source, count in parse_errors.items():
        set_metric("mcl_deployment_event_parse_errors_total", {"source": source}, count)

    for event in events:
        labels = event_labels(event)
        target = str(labels["target"])
        phase = str(labels["phase"])
        status = str(labels["status"])
        started = event_started_at(event)
        finished = event_finished_at(event)
        observed = finished if finished is not None else started

        if observed is not None:
            last_seen[target] = max(last_seen.get(target, 0), observed)
            deployment_id = str(event.get("deploymentId", "unknown"))
            state_key = (deployment_id, target, phase)
            previous = latest_phase_state.get(state_key)
            if previous is None or observed >= previous[0]:
                latest_phase_state[state_key] = (observed, status, labels, started)

        if started is not None and finished is not None:
            set_metric(
                "mcl_deployment_phase_duration_seconds",
                labels,
                max(0, finished - started),
            )

        closure = closure_summary(event)
        if "count" in closure and closure["count"] is not None:
            count_labels = dict(labels)
            count_labels.pop("status", None)
            set_metric("mcl_deployment_closure_paths", count_labels, int(closure["count"]))
        if "totalBytes" in closure and closure["totalBytes"] is not None:
            bytes_labels = dict(labels)
            bytes_labels.pop("status", None)
            set_metric("mcl_deployment_closure_bytes", bytes_labels, int(closure["totalBytes"]))

        if status == "failed":
            error = event.get("error") if isinstance(event.get("error"), dict) else {}
            error_code = error.get("code", "unknown")
            failure_counts[
                (
                    labels["target"],
                    labels["phase"],
                    labels["controller"],
                    labels["transport"],
                    labels["cache"],
                    error_code,
                )
            ] += 1
            if phase == "agent-restore":
                cache_restore_failures[
                    (
                        labels["target"],
                        labels["controller"],
                        labels["transport"],
                        labels["cache"],
                        error_code,
                    )
                ] += 1

        if phase == "cache-push":
            total_bytes = closure.get("totalBytes")
            if total_bytes is not None:
                cache_upload_bytes[
                    (
                        labels["target"],
                        labels["controller"],
                        labels["cache"],
                        status,
                    )
                ] += int(total_bytes)

        if status == "succeeded" and finished is not None:
            last_phase_success[(target, phase)] = max(
                last_phase_success.get((target, phase), 0), finished
            )
            if phase == "complete":
                last_successful_complete[target] = max(
                    last_successful_complete.get(target, 0), finished
                )

    for _state_key, (_observed, status, labels, started) in latest_phase_state.items():
        if status in {"pending", "running"} and started is not None:
            set_metric(
                "mcl_deployment_in_progress_age_seconds",
                labels,
                max(0, now - started),
            )

    for key, count in failure_counts.items():
        target, phase, controller, transport, cache, error_code = key
        set_metric(
            "mcl_deployment_phase_failures_total",
            {
                "target": target,
                "phase": phase,
                "controller": controller,
                "transport": transport,
                "cache": cache,
                "error_code": error_code,
            },
            count,
        )

    for key, count in cache_restore_failures.items():
        target, controller, transport, cache, error_code = key
        set_metric(
            "mcl_deployment_cache_restore_failures_total",
            {
                "target": target,
                "controller": controller,
                "transport": transport,
                "cache": cache,
                "error_code": error_code,
            },
            count,
        )

    for key, total_bytes in cache_upload_bytes.items():
        target, backend, cache, status = key
        set_metric(
            "mcl_deployment_cache_upload_bytes_total",
            {
                "target": target,
                "backend": backend,
                "cache": cache,
                "status": status,
            },
            total_bytes,
        )

    for target, timestamp in last_successful_complete.items():
        set_metric(
            "mcl_deployment_last_successful_timestamp_seconds",
            {"target": target},
            timestamp,
        )

    for (target, phase), timestamp in last_phase_success.items():
        set_metric(
            "mcl_deployment_last_phase_success_timestamp_seconds",
            {"target": target, "phase": phase},
            timestamp,
        )

    all_expected = sorted(set(expected_targets))
    for target in all_expected:
        set_metric("mcl_deployment_target_expected", {"target": target}, 1)
        set_metric("mcl_deployment_target_seen", {"target": target}, 1 if target in last_seen else 0)
    for target, timestamp in last_seen.items():
        set_metric("mcl_deployment_target_last_seen_timestamp_seconds", {"target": target}, timestamp)

    return metrics


def classify_operation(method: str) -> str:
    upper = method.upper()
    if upper in {"GET", "HEAD"}:
        return "download"
    if upper in {"POST", "PUT", "PATCH"}:
        return "upload"
    return "other"


def load_nginx_entries(nginx_logs: list[str]) -> tuple[list[dict], Counter]:
    entries: list[dict] = []
    parse_errors: Counter = Counter()
    for path_text in nginx_logs:
        path = pathlib.Path(path_text)
        try:
            if not path.exists():
                continue
            with path.open() as handle:
                for line in handle:
                    if not line.strip():
                        continue
                    try:
                        entry = json.loads(line)
                    except json.JSONDecodeError:
                        parse_errors[path_text] += 1
                        continue
                    if isinstance(entry, dict):
                        entries.append(entry)
                    else:
                        parse_errors[path_text] += 1
        except OSError:
            parse_errors[path_text] += 1
    return entries, parse_errors


def nginx_metrics(nginx_logs: list[str]) -> dict[tuple[str, tuple[tuple[str, str], ...]], Metric]:
    metrics: dict[tuple[str, tuple[tuple[str, str], ...]], Metric] = {}
    entries, parse_errors = load_nginx_entries(nginx_logs)
    request_counts: Counter = Counter()
    byte_counts: Counter = Counter()
    object_failures: Counter = Counter()

    def set_metric(name: str, labels: dict[str, object], value: float | int) -> None:
        key = metric_key(name, labels)
        metrics[key] = Metric(key[0], key[1], float(value))

    for source, count in parse_errors.items():
        set_metric("mcl_attic_nginx_log_parse_errors_total", {"source": source}, count)

    for entry in entries:
        method = str(entry.get("method", "UNKNOWN"))
        status = str(entry.get("status", "000"))
        operation = classify_operation(method)
        request_counts[(operation, method, status)] += 1

        try:
            status_int = int(status)
        except ValueError:
            status_int = 0

        try:
            request_length = int(entry.get("request_length") or 0)
        except (TypeError, ValueError):
            request_length = 0
        try:
            body_bytes_sent = int(entry.get("body_bytes_sent") or 0)
        except (TypeError, ValueError):
            body_bytes_sent = 0

        if operation == "upload":
            byte_counts[(operation, "request", status)] += request_length
        elif operation == "download":
            byte_counts[(operation, "response", status)] += body_bytes_sent
        else:
            byte_counts[(operation, "response", status)] += body_bytes_sent

        if operation in {"upload", "download"} and status_int >= 400:
            object_failures[(operation, method, status)] += 1

    for key, count in request_counts.items():
        operation, method, status = key
        set_metric(
            "mcl_attic_nginx_requests_total",
            {"operation": operation, "method": method, "status": status},
            count,
        )

    for key, total_bytes in byte_counts.items():
        operation, direction, status = key
        set_metric(
            "mcl_attic_nginx_bytes_total",
            {"operation": operation, "direction": direction, "status": status},
            total_bytes,
        )

    for key, count in object_failures.items():
        operation, method, status = key
        set_metric(
            "mcl_attic_nginx_cache_object_failures_total",
            {"operation": operation, "method": method, "status": status},
            count,
        )

    return metrics


HELP_TEXT = {
    "mcl_deployment_phase_duration_seconds": "Duration of the latest observed deployment phase by target.",
    "mcl_deployment_phase_failures_total": "Count of failed deployment phase events observed in JSONL logs.",
    "mcl_deployment_closure_paths": "Latest observed deployment closure path count.",
    "mcl_deployment_closure_bytes": "Latest observed deployment closure byte size.",
    "mcl_deployment_cache_upload_bytes_total": "Total deployment cache upload bytes observed from cache-push events.",
    "mcl_deployment_cache_restore_failures_total": "Count of failed target cache restore events.",
    "mcl_deployment_last_successful_timestamp_seconds": "Unix timestamp for the latest completed successful deployment by target.",
    "mcl_deployment_last_phase_success_timestamp_seconds": "Unix timestamp for the latest successful deployment phase by target.",
    "mcl_deployment_in_progress_age_seconds": "Age of currently running or pending deployment phases.",
    "mcl_deployment_target_expected": "Expected deployment target inventory marker.",
    "mcl_deployment_target_seen": "Whether an expected deployment target has been observed in deployment events.",
    "mcl_deployment_target_last_seen_timestamp_seconds": "Unix timestamp for the latest deployment event observed by target.",
    "mcl_deployment_event_parse_errors_total": "Count of JSONL deployment event parse errors by source.",
    "mcl_attic_nginx_requests_total": "Count of Attic nginx requests by cache operation, method, and status.",
    "mcl_attic_nginx_bytes_total": "Attic nginx byte volume by cache operation, direction, and status.",
    "mcl_attic_nginx_cache_object_failures_total": "Count of failed Attic cache object requests.",
    "mcl_attic_nginx_log_parse_errors_total": "Count of Attic nginx access log parse errors by source.",
}


def render_metrics(
    event_logs: list[str],
    event_dirs: list[str],
    nginx_logs: list[str],
    expected_targets: list[str],
    now: float | None = None,
) -> str:
    now = dt.datetime.now(dt.timezone.utc).timestamp() if now is None else now
    events, parse_errors = load_events(event_logs, event_dirs)
    merged = deployment_metrics(events, parse_errors, expected_targets, now)
    merged.update(nginx_metrics(nginx_logs))

    lines: list[str] = []
    emitted_help: set[str] = set()
    for key in sorted(merged):
        metric = merged[key]
        if metric.name not in emitted_help:
            help_text = HELP_TEXT.get(metric.name, metric.name)
            lines.append(f"# HELP {metric.name} {help_text}")
            lines.append(f"# TYPE {metric.name} gauge" if not metric.name.endswith("_total") else f"# TYPE {metric.name} counter")
            emitted_help.add(metric.name)
        labels = {label: value for label, value in metric.labels}
        lines.append(prom_sample(metric.name, labels, metric.value))
    return "\n".join(lines) + ("\n" if lines else "")


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    event_logs: list[str] = []
    event_dirs: list[str] = []
    nginx_logs: list[str] = []
    expected_targets: list[str] = []

    def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics(
            self.event_logs,
            self.event_dirs,
            self.nginx_logs,
            self.expected_targets,
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def serve(args: argparse.Namespace) -> None:
    MetricsHandler.event_logs = args.event_log
    MetricsHandler.event_dirs = args.event_dir
    MetricsHandler.nginx_logs = args.nginx_log
    MetricsHandler.expected_targets = args.expected_target

    servers = []
    for bind_address in args.bind_addresses:
        server = ThreadingHTTPServer((bind_address, args.port), MetricsHandler)
        servers.append(server)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

    try:
        threading.Event().wait()
    finally:
        for server in servers:
            server.shutdown()


def self_test() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        event_dir = root / "events"
        event_dir.mkdir()
        event_log = event_dir / "deploy.jsonl"
        event_log.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "cache-push",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "cachix-agent",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "attic",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {
                                "system": "/nix/store/root-system",
                                "closure": {
                                    "count": 2,
                                    "totalBytes": 1234,
                                    "rootHashes": ["root"],
                                },
                            },
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:00Z",
                                "finishedAt": "2026-05-13T09:00:05Z",
                            },
                            "command": {
                                "name": "attic push",
                                "argv": ["attic", "push"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-2",
                            "correlationId": "corr-2",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-02",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z"
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "running",
                                "exitCode": None,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-3",
                            "correlationId": "corr-3",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-03",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z"
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "running",
                                "exitCode": None,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-3",
                            "correlationId": "corr-3",
                            "phase": "switch",
                            "target": {
                                "name": "app-server-03",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:10Z",
                                "finishedAt": "2026-05-13T09:00:15Z",
                            },
                            "command": {
                                "name": "switch",
                                "argv": ["switch"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "agent-restore",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "cachix-agent",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "cachix-deploy",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:05Z",
                                "finishedAt": "2026-05-13T09:00:08Z",
                            },
                            "command": {
                                "name": "restore",
                                "argv": ["restore"],
                                "status": "failed",
                                "exitCode": 1,
                            },
                            "error": {
                                "code": "cache_restore_failed",
                                "message": "restore failed",
                                "retryable": True,
                            },
                        }
                    ),
                    json.dumps(
                        {
                            "schemaVersion": 1,
                            "deploymentId": "dep-1",
                            "correlationId": "corr-1",
                            "phase": "complete",
                            "target": {
                                "name": "app-server-01",
                                "system": "x86_64-linux",
                                "kind": "server",
                                "transport": "direct-ssh",
                            },
                            "backend": {
                                "cache": "cache",
                                "controller": "direct-ssh",
                                "substituters": ["https://cache.example/cache"],
                            },
                            "storePaths": {"system": "/nix/store/root-system"},
                            "timestamps": {
                                "startedAt": "2026-05-13T09:00:08Z",
                                "finishedAt": "2026-05-13T09:00:09Z",
                            },
                            "command": {
                                "name": "complete",
                                "argv": ["complete"],
                                "status": "succeeded",
                                "exitCode": 0,
                            },
                        }
                    ),
                ]
            )
            + "\n"
        )

        nginx_log = root / "attic.access.jsonl"
        nginx_log.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:00+00:00",
                            "method": "PUT",
                            "uri": "/cache/nar/abc",
                            "status": "200",
                            "request_length": "4096",
                            "body_bytes_sent": "12",
                        }
                    ),
                    json.dumps(
                        {
                            "time": "2026-05-13T09:00:01+00:00",
                            "method": "GET",
                            "uri": "/cache/nar/missing",
                            "status": "404",
                            "request_length": "200",
                            "body_bytes_sent": "64",
                        }
                    ),
                ]
            )
            + "\n"
        )

        output = render_metrics(
            [],
            [str(event_dir)],
            [str(nginx_log)],
            [
                "app-server-01",
                "app-server-02",
                "app-server-03",
                "app-server-04",
            ],
            now=parse_timestamp("2026-05-13T09:01:00Z"),
        )
        required = [
            'mcl_deployment_phase_duration_seconds{cache="cache",controller="attic",phase="cache-push",status="succeeded",target="app-server-01",transport="cachix-agent"} 5',
            'mcl_deployment_cache_upload_bytes_total{backend="attic",cache="cache",status="succeeded",target="app-server-01"} 1234',
            'mcl_deployment_cache_restore_failures_total{cache="cache",controller="cachix-deploy",error_code="cache_restore_failed",target="app-server-01",transport="cachix-agent"} 1',
            'mcl_deployment_target_seen{target="app-server-02"} 1',
            'mcl_deployment_target_seen{target="app-server-04"} 0',
            'mcl_deployment_in_progress_age_seconds{cache="cache",controller="direct-ssh",phase="switch",status="running",target="app-server-02",transport="direct-ssh"} 50',
            'mcl_attic_nginx_requests_total{method="PUT",operation="upload",status="200"} 1',
            'mcl_attic_nginx_cache_object_failures_total{method="GET",operation="download",status="404"} 1',
        ]
        missing = [line for line in required if line not in output]
        if missing:
            raise AssertionError("missing metrics:\n" + "\n".join(missing) + "\n\n" + output)
        if 'mcl_deployment_in_progress_age_seconds{cache="cache",controller="direct-ssh",phase="switch",status="running",target="app-server-03",transport="direct-ssh"}' in output:
            raise AssertionError("stale in-progress metric was not cleared:\n" + output)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event-log", action="append", default=[], help="Deployment JSONL file to read")
    parser.add_argument(
        "--event-dir",
        action="append",
        default=[],
        help=f"Directory containing deployment *.jsonl files (default: {DEFAULT_EVENT_DIR})",
    )
    parser.add_argument("--nginx-log", action="append", default=[], help="Attic nginx JSONL access log to read")
    parser.add_argument("--expected-target", action="append", default=[], help="Target expected to emit deployment events")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--bind-addresses", default="127.0.0.1")
    parser.add_argument("--once", action="store_true", help="Print one metrics snapshot and exit")
    parser.add_argument("--self-test", action="store_true", help="Run deterministic parser/rendering self-test")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.bind_addresses = [part.strip() for part in args.bind_addresses.split(",") if part.strip()]
    if not args.bind_addresses:
        args.bind_addresses = ["127.0.0.1"]

    if args.self_test:
        self_test()
        print("deployment-event-metrics: self-test passed")
        return 0

    if not args.event_dir and not args.event_log:
        args.event_dir = [DEFAULT_EVENT_DIR]

    if args.once:
        sys.stdout.write(
            render_metrics(args.event_log, args.event_dir, args.nginx_log, args.expected_target)
        )
        return 0

    serve(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
