#!/usr/bin/env bash

set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"

# shellcheck source=./nix-eval-jobs.sh
source "$root_dir/scripts/nix-eval-jobs.sh"

eval_packages_to_json() {
  flake_attr_pre="${1:-checks}"
  flake_attr_post="${2:-}"

  cachix_url="https://${CACHIX_CACHE}.cachix.org"

  nix_json=$(nix_eval_for_all_systems "$flake_attr_pre" "$flake_attr_post" \
    | jq -sr '{
      "x86_64-linux": "ubuntu-latest",
      "x86_64-darwin": "macos-14",
      "aarch64-darwin": "macos-14"
    } as $system_to_gh_platform
    |
    map({
      package: .attr,
      attrPath: "'"${flake_attr_pre}".'\(.system).\(.attr)",
      allowedToFail: false,
      isCached,
      system,
      out: .outputs.out,
      cache_url: .outputs.out
        | "'"$cachix_url"'/\(match("^\/nix\/store\/([^-]+)-").captures[0].string).narinfo",
      os: $system_to_gh_platform[.system]
    })
      | sort_by(.package | ascii_downcase)
  ')

  mapfile -t nix_array < <(echo "$nix_json" | jq -c '.[]')
  for nix in "${nix_array[@]}"; do
    isCached=$(  echo "$nix" | jq -cr '.isCached')
    cache_url=$( echo "$nix" | jq -cr '.cache_url')
    if [ "$isCached" = "false" ]; then
      isAvailable=$( [ $(curl --silent -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" -I "$cache_url"\
        | grep -E "^HTTP" \
        | awk -F " " '{print $2}') == 200 ] \
        && echo "true" || echo "false")
      nix=$(echo "$nix" | jq -c ".isCached = $isAvailable")
    fi
    echo $nix
  done
}

save_gh_ci_matrix() {
  packages_to_build=$(echo "$packages" | jq -sc '. | map(select(.isCached | not))')
  matrix='{"include":'"$packages_to_build"'}'
  res_path=''
  if [ "${IS_INITIAL:-true}" = "true" ]; then
    res_path='matrix-pre.json'
  else
    res_path='matrix-post.json'
  fi
  echo "$matrix" > "$res_path"
  echo "matrix=$matrix" >> "${GITHUB_OUTPUT:-${result_dir}/gh-output.env}"
}

save_cachix_deploy_spec() {
  echo "$packages"  | jq -sr '
    {
      agents: map({
        key: .package, value: .out
      }) | from_entries
    }' \
    > .result/cachix-deploy-spec.json
}

convert_nix_eval_to_table_summary_json() {
  is_initial="${IS_INITIAL:-true}"
  echo "$packages" \
  | jq -s '
    def getStatus(pkg; key):
      if (pkg | has(key))
      then if pkg[key].isCached
        then "[✅ cached](\(pkg[key].cache_url))"
        else if "'$is_initial'" == "true"
          then "⏳ building..."
          else "❌ build failed" end
      end else "🚫 not supported" end;

    group_by(.package)
    | map(
      . | INDEX(.system) as $pkg
      | .[0].package as $name
      | {
        package: $name,
        "x86_64-linux": getStatus($pkg; "x86_64-linux"),
        "x86_64-darwin": getStatus($pkg; "x86_64-darwin"),
        "aarch64-darwin": getStatus($pkg; "aarch64-darwin"),
      }
    )
    | sort_by(.package)'
}

printTableForCacheStatus() {
  packages="$(eval_packages_to_json "$@")"
  save_gh_ci_matrix
  save_cachix_deploy_spec

  {
    echo "Thanks for your Pull Request!"
    echo
    echo "Below you will find a summary of the cachix status of each package, for each supported platform."
    echo
    # shellcheck disable=SC2016
    echo '| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |'
    echo '| ------- | -------------- | --------------- | ---------------- |'
    convert_nix_eval_to_table_summary_json | jq -r '
      .[] | "| `\(.package)` | \(.["x86_64-linux"]) | \(.["x86_64-darwin"]) | \(.["aarch64-darwin"]) |"
    '
    echo
  } > comment.md
}

printTableForCacheStatus "$@"

