#!/usr/bin/env bash

set -euo pipefail

FLAKE_INPUT=${FLAKE_INPUT:-""}

running_in_github_actions() {
  set -x
  [ -n "${CI:-}" ] && \
  [ -n "${GITHUB_REPOSITORY:-}" ] && \
  [ -n "${GITHUB_RUN_ID:-}" ] && \
  [ -n "${GITHUB_TOKEN:-}" ] && \
  curl --silent --fail \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" > /dev/null 2>&1
}

if running_in_github_actions; then
  echo "Running in GitHub Actions."
  git config --list --show-origin
fi

current_commit="$(git rev-parse HEAD)"

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0="$RUNNER_TEMP/empty-git-hooks"

nix flake update $FLAKE_INPUT --accept-flake-config --commit-lock-file
commit_after_update="$(git rev-parse HEAD)"

if [[ "$commit_after_update" = "$current_commit" ]]; then
  if [[ "$FLAKE_INPUT" = "" ]]; then
    echo "All flake inputs are up to date."
  else
    echo "$FLAKE_INPUT input is up to date."
  fi
  exit 0
fi

msg_file=./commit_msg_body.txt
{
  echo '```'
  git log -1 '--pretty=format:%b' | sed '1,2d'
  echo '```'
} > $msg_file

if [[ "$FLAKE_INPUT" = "" ]]; then
  git commit --amend -F - <<EOF
  chore(flake.lock): Update all Flake inputs ($(date -I))

  $(cat $msg_file)
EOF
else
  git commit --amend -F - <<EOF
  chore(flake.lock): Update \`$FLAKE_INPUT\` Flake input ($(date -I))

  $(cat $msg_file)
EOF
fi

if [ -z "${CI+x}" ]; then
  rm -v $msg_file
fi
