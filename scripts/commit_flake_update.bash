#!/usr/bin/env bash

set -euo pipefail

FLAKE_INPUT=${FLAKE_INPUT:-""}

if ! git config --get user.name >/dev/null 2>&1 || \
  [ "$(git config --get user.name)" = "" ] ||
  ! git config --get user.email >/dev/null 2>&1 || \
  [ "$(git config --get user.email)" = "" ]; then
  echo "git config user.{name,email} is not set - configuring"
  set -x
  git config --local user.email "out@space.com"
  git config --local user.name "beep boop"
fi

current_commit="$(git rev-parse HEAD)"
export PRE_COMMIT_ALLOW_NO_CONFIG=1

git config --list --show-origin

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
