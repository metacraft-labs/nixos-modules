#!/usr/bin/env bash
# Write the github.com credential where GIT will look for it.
#
# WHY THIS EXISTS, because the obvious reading of the problem is wrong.
#
# `access-tokens` in nix.conf is consumed by Nix's own GitHub/GitLab API
# fetchers — that is, by `github:owner/repo` and `gitlab:` flake refs. A flake
# input written as
#
#   { type = "git"; url = "https://github.com/org/private-repo"; }
#
# is fetched by Nix SHELLING OUT TO git. git never sees `access-tokens`, has no
# credential helper in a CI checkout, and so prompts, cannot, and dies with
#
#   fatal: could not read Username for 'https://github.com'
#
# Observed on metacraft-labs/infra: its `ci` matrix went red on `live` as soon
# as a flake.lock bump pulled in `reprobuild`, which declares
# codetracer-native-recorder in exactly that form. It presents as a token-scope
# problem and is not one — widening the PAT changes nothing, because the token
# never reaches git.
#
# actions/checkout does not cover it either: it installs a gitdir-scoped
# `includeIf` credential config for THE WORKSPACE REPO only, so fetching any
# other private repo is unauthenticated.
#
# git honours ~/.netrc for https (it sets CURLOPT_NETRC to CURL_NETRC_OPTIONAL
# by default), so the credential goes there. Nix's own netrc lives at
# $HOME/.config/nix/netrc and git does NOT read that path, which is why both
# files are written rather than one.
#
# Usage: write-netrc.sh            (reads SETUP_NIX_GITHUB_TOKEN from the env)
#        SETUP_NIX_NETRC_HOME=DIR  (test seam; defaults to $HOME)
set -uo pipefail

home="${SETUP_NIX_NETRC_HOME:-$HOME}"
token="${SETUP_NIX_GITHUB_TOKEN:-}"

mkdir -p "$home/.config/nix"

if [[ -z "$token" ]]; then
  echo "netrc: no github token supplied; git+https fetches of private repos will fail"
  exit 0
fi

for netrc in "$home/.netrc" "$home/.config/nix/netrc"; do
  umask 077
  [[ -e "$netrc" ]] || : > "$netrc"
  # Idempotent: this action can run more than once in a job, and appending a
  # second stanza for the same machine would leave git using whichever it read
  # first — a confusing, order-dependent failure if the tokens ever differ.
  if ! grep -qE '^[[:space:]]*machine[[:space:]]+github\.com[[:space:]]*$' "$netrc" 2>/dev/null; then
    {
      # `login` is ignored by GitHub for PAT-over-https; x-access-token is the
      # documented placeholder.
      printf 'machine github.com\n'
      printf '  login x-access-token\n'
      printf '  password %s\n' "$token"
    } >> "$netrc"
  fi
  chmod 0600 "$netrc"
done

echo "netrc: github.com credential written for git+https flake inputs"
