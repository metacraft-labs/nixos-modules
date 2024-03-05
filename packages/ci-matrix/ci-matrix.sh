#!/usr/bin/env bash

set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"

source "@nixEvalJobsSh@"

eval_packages_to_json() {
  flake_attr_pre="${1:-checks}"
  flake_attr_post="${2:-}"

  cachix_url="https://${CACHIX_CACHE}.cachix.org"

  nix_eval_for_all_systems "$flake_attr_pre" "$flake_attr_post" \
    | @jqBin@ -sr '{
      "x86_64-linux": "ubuntu-latest",
      "x86_64-darwin": "macos-14",
      "aarch64-darwin": "macos-14"
    } as $system_to_gh_platform
    |
    map({
      package: .attr,
      attrPath: "'"${flake_attr_pre}".'\(.system)'"${flake_attr_post:+.${flake_attr_post}}"'.\(.attr)",
      allowedToFail: false,
      isCached,
      system,
      out: .outputs.out,
      cache_url: .outputs.out
        | "'"$cachix_url"'/\(match("^\/nix\/store\/([^-]+)-").captures[0].string).narinfo",
      os: $system_to_gh_platform[.system]
    })
      | sort_by(.package | ascii_downcase)
  '
}

source "@printTableSh@"

printTableForCacheStatus "$(eval_packages_to_json "$@")"
echo "Complete!"
