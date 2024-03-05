#!/usr/bin/env bash

set -euo pipefail

root_dir="$(git rev-parse --show-toplevel)"

result_dir="$root_dir/.result"
gc_roots_dir="$result_dir/gc-roots"

create_result_dirs() {
  mkdir -p "$result_dir" "$gc_roots_dir"
}

create_result_dirs

save_gh_ci_matrix() {
  packages_to_build=$(echo "$packages" | @jqBin@ -c '. | map(select(.isCached | not))')
  if [ -z "$packages_to_build" ]; then
    packages_to_build='[]'
  fi
  matrix='{"include":'"$packages_to_build"'}'
  res_path=''
  if [ "${IS_INITIAL:-true}" = "true" ]; then
    res_path='matrix-pre.json'
  else
    res_path='matrix-post.json'
  fi
  echo "$matrix" > "$res_path"
  # echo "matrix=$matrix" >> "${GITHUB_OUTPUT:-${result_dir}/gh-output.env}"
}

save_cachix_deploy_spec() {
  echo "$packages"  | @jqBin@ '
    {
      agents: map({
        key: .package, value: .out
      }) | from_entries
    }' \
    > "${result_dir}/cachix-deploy-spec.json"
}

convert_nix_eval_to_table_summary_json() {
  is_initial="${IS_INITIAL:-true}"
  echo "$packages" \
  | @jqBin@ '
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
  packages="$1"

  if [ -z ${PRECALC_MATRIX} ]; then
    save_gh_ci_matrix
  else
    true
  fi
  save_cachix_deploy_spec
  table_summary_json="$(convert_nix_eval_to_table_summary_json)"
  {
    echo "Thanks for your Pull Request!"
    echo
    echo "Below you will find a summary of the cachix status of each package, for each supported platform."
    echo
    # shellcheck disable=SC2016
    echo '| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |'
    echo '| ------- | -------------- | --------------- | ---------------- |'
    echo "$table_summary_json" | @jqBin@ '
      .[] | "| `\(.package)` | \(.["x86_64-linux"]) | \(.["x86_64-darwin"]) | \(.["aarch64-darwin"]) |"
    '
    echo
  } > comment.md
}

PRECALC_MATRIX="${PRECALC_MATRIX:-}"

if [ -z ${PRECALC_MATRIX} ]; then
  true
else
  packages=""
  mapfile -t nix_array < <(echo "${PRECALC_MATRIX}"  | @jqBin@ -cr '.include' | @jqBin@ -c '.[]')
  for nix in "${nix_array[@]}"; do
    isCached=$(  echo "$nix" | @jqBin@ -cr '.isCached')
    cache_url=$( echo "$nix" | @jqBin@ -cr '.cache_url')
    if [ "$isCached" = "false" ]; then
      isAvailable=$( [ $(curl --silent -H "Authorization: Bearer $CACHIX_AUTH_TOKEN" -I "$cache_url"\
        | grep -E "^HTTP" \
        | awk -F " " '{print $2}') == 200 ] \
        && echo "true" || echo "false")
      nix=$(echo "$nix" | @jqBin@ -c ".isCached = $isAvailable")
    fi
    packages="$packages$nix"
  done
  packages=$(echo "$packages" | @jqBin@ -sc '.')
  printTableForCacheStatus "$packages"
fi
