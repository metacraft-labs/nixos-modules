#!/usr/bin/env bash

root_dir="$(git rev-parse --show-toplevel)"
result_dir="$root_dir/.result"

save_gh_ci_matrix() {

  echo "$1"

  echo "gen_matrix=$1" >> "${GITHUB_OUTPUT:-${result_dir}/gh-output.env}"

}

hasShards="$(@nixBin@ eval .#legacyPackages.x86_64-linux.checks.shardCount && echo "true" || echo "false")";
if [ "$hasShards" = "false" ]; then
  echo "No shards found, exiting"
  save_gh_ci_matrix '{"include":[{prefix: "", postfix: "", "digit": -1}]}'
  exit 0
fi

numShards=$(( $(@nixBin@ eval .#legacyPackages.x86_64-linux.checks.shardCount) - 1))

shards=$(for i in $(seq 0 $numShards); do echo '{"prefix" : "legacyPackages", "postfix" : "checks.shards.'"$i"'", "digit": '"$i"' }'; done | paste -sd, -)

gen_matrix='{"include":'["$shards"]'}'


save_gh_ci_matrix "$(echo "$gen_matrix" | @jqBin@ -c .)"
