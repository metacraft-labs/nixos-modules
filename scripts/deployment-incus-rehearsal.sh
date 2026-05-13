#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="${1:-}"
mode="${2:-run}"

image="${MCL_ATTIC_INCUS_IMAGE:-images:nixos/25.11}"
prefix="${MCL_ATTIC_INCUS_PREFIX:-mcl-attic-cache-${USER:-user}}"
cache_container="${MCL_ATTIC_INCUS_SERVER:-${prefix}-server}"
client_container="${MCL_ATTIC_INCUS_CLIENT:-${prefix}-client}"
host_port="${MCL_ATTIC_INCUS_PORT:-38180}"
cache_name="${MCL_ATTIC_CACHE_NAME:-example-deploy-cache}"
runtime_probe_timeout="${MCL_ATTIC_INCUS_RUNTIME_PROBE_TIMEOUT:-10}"
nix_features=(--extra-experimental-features "nix-command flakes")
attic_server_pkg=""
attic_client_pkg=""
openssl_pkg=""
host_system=""

usage() {
  cat >&2 <<'USAGE'
usage: deployment-incus-rehearsal.sh attic-cache [--check-env|--check-runtime|--dry-run]

Scenarios:
  attic-cache   Rehearse an Attic cache plus client substitute flow.

Modes:
  --check-env       Verify local script dependencies only.
  --check-runtime   Verify an Incus or LXC daemon is reachable.
  --dry-run         Print the planned launch commands without creating containers.
  run               Launch the runtime rehearsal.
USAGE
}

die() {
  echo "deployment-incus-rehearsal: $*" >&2
  exit 1
}

runtime_unavailable() {
  echo "deployment-incus-rehearsal: pending-runtime: $*" >&2
  exit 69
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

runtime_cmd() {
  if command -v incus >/dev/null 2>&1; then
    echo incus
    return 0
  fi
  if command -v lxc >/dev/null 2>&1; then
    echo lxc
    return 0
  fi
  return 1
}

check_port() {
  [[ "$host_port" =~ ^[0-9]+$ ]] || die "MCL_ATTIC_INCUS_PORT is not numeric: $host_port"
  (( host_port > 0 && host_port < 65536 )) || die "MCL_ATTIC_INCUS_PORT is outside TCP range: $host_port"
}

check_env() {
  require_command bash
  require_command curl
  require_command mktemp
  require_command nix
  require_command sed
  require_command timeout
  check_port
  bash -n "$repo_root/scripts/deployment-incus-rehearsal.sh"

  if runtime_cmd >/dev/null; then
    echo "deployment-incus-rehearsal: container client: $(runtime_cmd)"
  else
    echo "deployment-incus-rehearsal: container client: pending-runtime (install incus or lxc for runtime launch)"
  fi

  echo "deployment-incus-rehearsal: local environment is complete"
}

check_runtime() {
  cli="$(runtime_cmd)" || runtime_unavailable "Incus/LXC CLI not found; install incus or lxc and initialize a daemon"
  if ! timeout "$runtime_probe_timeout" "$cli" info >/dev/null 2>&1; then
    runtime_unavailable "$cli CLI is present, but no reachable Incus/LXD daemon is available"
  fi
  echo "deployment-incus-rehearsal: runtime is available via $cli"
}

dry_run() {
  check_env
  local client
  client="$(runtime_cmd || echo incus)"
  cat <<EOF
attic-cache rehearsal plan:
  1. Launch ${client}:${image} containers ${cache_container} and ${client_container}.
  2. Start atticd in ${cache_container} on port 8080 and proxy it to 127.0.0.1:${host_port}.
  3. Create public Attic cache ${cache_name} with a deterministic test token.
  4. Build a small host fixture closure.
  5. Run mcl cache push-closure with --backend attic, --substituter, and --require-substitute.
  6. Restore the fixture from Attic inside ${client_container} using nix copy.
  7. Remove containers unless MCL_ATTIC_INCUS_KEEP=1 is set.
EOF
}

container_exec() {
  "$cli" exec "$1" -- /run/current-system/sw/bin/bash -lc "$2"
}

build_tool() {
  nix "${nix_features[@]}" build --no-link --print-out-paths "$1" | head -n1
}

prepare_tools() {
  host_system="$(nix "${nix_features[@]}" eval --raw --impure --expr builtins.currentSystem)"
  attic_server_pkg="$(build_tool nixpkgs#attic-server)"
  attic_client_pkg="$(build_tool nixpkgs#attic-client)"
  openssl_pkg="$(build_tool nixpkgs#openssl)"
}

import_closure() {
  local container="$1"
  local archive="$2"
  shift 2

  nix-store --export $(nix-store -qR "$@") > "$archive"
  "$cli" file push "$archive" "${container}/tmp/mcl-attic-tools.nar"
  container_exec "$container" "nix-store --import < /tmp/mcl-attic-tools.nar >/dev/null"
}

cleanup() {
  if [[ "${MCL_ATTIC_INCUS_KEEP:-}" == "1" ]]; then
    echo "deployment-incus-rehearsal: keeping containers $cache_container and $client_container"
    return
  fi
  if [[ -n "${cli:-}" ]]; then
    "$cli" stop "$cache_container" --force >/dev/null 2>&1 || true
    "$cli" stop "$client_container" --force >/dev/null 2>&1 || true
    "$cli" delete "$cache_container" >/dev/null 2>&1 || true
    "$cli" delete "$client_container" >/dev/null 2>&1 || true
  fi
}

wait_host_http() {
  local url="$1"
  local attempt
  for attempt in $(seq 1 90); do
    if curl -sS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "Attic did not become reachable at $url"
}

start_atticd() {
  container_exec "$cache_container" "mkdir -p /var/lib/mcl-attic/{storage,config}"
  container_exec "$cache_container" \
    "'${openssl_pkg}/bin/openssl' genrsa -traditional 4096 | base64 -w0 > /var/lib/mcl-attic/token-secret"
  container_exec "$cache_container" \
    "printf 'ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=%s\n' \"\$(cat /var/lib/mcl-attic/token-secret)\" > /var/lib/mcl-attic/environment"
  container_exec "$cache_container" "cat > /var/lib/mcl-attic/server.toml <<EOF
listen = \"0.0.0.0:8080\"
api-endpoint = \"http://127.0.0.1:${host_port}/\"
allowed-hosts = [\"${cache_container}:8080\", \"127.0.0.1:8080\", \"127.0.0.1:${host_port}\", \"localhost:${host_port}\"]

[database]
url = \"sqlite:///var/lib/mcl-attic/server.db?mode=rwc\"

[storage]
type = \"local\"
path = \"/var/lib/mcl-attic/storage\"

[chunking]
nar-size-threshold = 65536
min-size = 16384
avg-size = 65536
max-size = 262144
EOF"
  container_exec "$cache_container" \
    "set -a; . /var/lib/mcl-attic/environment; set +a; nohup '${attic_server_pkg}/bin/atticd' -f /var/lib/mcl-attic/server.toml >/var/lib/mcl-attic/atticd.log 2>&1 &"
}

make_token() {
  container_exec "$cache_container" \
    "set -a; . /var/lib/mcl-attic/environment; set +a; '${attic_server_pkg}/bin/atticadm' -f /var/lib/mcl-attic/server.toml make-token --sub incus-rehearsal --validity 1y --create-cache '*' --pull '*' --push '*' --delete '*' --configure-cache '*' --configure-cache-retention '*'"
}

run_attic_cache() {
  check_env
  check_runtime
  prepare_tools

  trap cleanup EXIT
  cleanup

  echo "deployment-incus-rehearsal: launching containers: $cache_container $client_container"
  "$cli" launch "$image" "$cache_container"
  "$cli" launch "$image" "$client_container"

  "$cli" config device add "$cache_container" attic-http proxy \
    "listen=tcp:127.0.0.1:${host_port}" "connect=tcp:127.0.0.1:8080"
  "$cli" config device add "$client_container" attic-client-http proxy \
    "listen=tcp:127.0.0.1:8080" "connect=tcp:127.0.0.1:${host_port}" "bind=container"

  container_exec "$cache_container" "nix --version >/dev/null"
  container_exec "$client_container" "nix --version >/dev/null"
  tool_archive="$(mktemp)"
  import_closure "$cache_container" "$tool_archive" "$attic_server_pkg" "$openssl_pkg"

  start_atticd
  wait_host_http "http://127.0.0.1:${host_port}/"

  local token fixture fixture_expr public_key event_log
  token="$(make_token | tail -n1)"

  export XDG_CONFIG_HOME
  XDG_CONFIG_HOME="$(mktemp -d)"
  fixture_expr='derivation { name = "mcl-attic-incus-fixture"; system = "'"$host_system"'"; builder = "/bin/sh"; args = [ "-c" "echo incus-attic-fixture > $out" ]; }'
  fixture="$(nix "${nix_features[@]}" build --no-link --print-out-paths --expr "$fixture_expr")"
  event_log="$(mktemp)"

  "${attic_client_pkg}/bin/attic" login --set-default incus "http://127.0.0.1:${host_port}" "$token"
  "${attic_client_pkg}/bin/attic" cache create --public "$cache_name"
  public_key="$("${attic_client_pkg}/bin/attic" cache info "$cache_name" 2>&1 | sed -n 's/.*Public Key: //p')"
  [[ -n "$public_key" ]] || die "failed to discover Attic public key"

  nix "${nix_features[@]}" run "$repo_root#mcl" -- cache push-closure \
    --backend attic \
    --cache "$cache_name" \
    --target "$client_container" \
    --system "$host_system" \
    --kind incus \
    --transport local-incus \
    --substituter "http://127.0.0.1:${host_port}/${cache_name}" \
    --trusted-public-key "$public_key" \
    --require-substitute \
    --event-log "$event_log" \
    "$fixture"

  container_exec "$client_container" \
    "nix --extra-experimental-features 'nix-command flakes' copy --from http://127.0.0.1:8080/${cache_name} --to file:///tmp/mcl-attic-restore-store --option trusted-public-keys '$public_key' '$fixture'"

  grep -q '"controller":"attic"' "$event_log" || die "event log does not contain Attic backend event"
  grep -q '"successful-substitute"' "$event_log" || die "event log does not contain successful substitute probe"

  echo "deployment-incus-rehearsal: runtime rehearsal passed"
}

if [[ "$scenario" != "attic-cache" ]]; then
  usage
  exit 64
fi

case "$mode" in
  --check-env)
    check_env
    ;;
  --check-runtime)
    check_runtime
    ;;
  --dry-run)
    dry_run
    ;;
  run)
    run_attic_cache
    ;;
  *)
    usage
    exit 64
    ;;
esac
