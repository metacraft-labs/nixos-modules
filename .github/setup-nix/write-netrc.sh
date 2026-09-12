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
set -euo pipefail

token="${SETUP_NIX_GITHUB_TOKEN:-}"

if [[ -z "$token" ]]; then
  echo "netrc: no github token supplied; git+https fetches of private repos will fail"
  exit 0
fi

if [[ "$token" == *$'\n'* || "$token" == *$'\r'* ]]; then
  echo "netrc: refusing a github token containing a line break" >&2
  exit 1
fi

netrc_home="${SETUP_NIX_NETRC_HOME:-${HOME:?HOME is not set}}"

umask 077
temporary_file=""

cleanup_temporary_files() {
  cleanup_status=$?
  trap - EXIT
  if [[ -n "$temporary_file" ]]; then
    if [[ -e "$temporary_file" || -L "$temporary_file" ]]; then
      rm -f -- "$temporary_file" || cleanup_status=1
    fi
  fi
  exit "$cleanup_status"
}

trap cleanup_temporary_files EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$netrc_home/.config/nix"

write_netrc() {
  netrc="$1"
  netrc_directory="${netrc%/*}"

  # Replacing a symlink would sever an intentionally managed credential file,
  # while following it would make the atomic rename target a different path.
  # Persistent runners must surface that configuration instead of guessing.
  if [[ -L "$netrc" ]]; then
    echo "netrc: refusing to replace symlink: $netrc" >&2
    return 1
  fi
  if [[ -e "$netrc" && ! -f "$netrc" ]]; then
    echo "netrc: refusing to replace non-regular file: $netrc" >&2
    return 1
  fi

  temporary_file="$(mktemp "$netrc_directory/.write-netrc.XXXXXX")"

  # mktemp already obeys the restrictive umask. Keep an explicit chmod both as
  # defence in depth and as a fail-closed check before credential bytes exist.
  chmod 0600 "$temporary_file"

  if [[ -e "$netrc" ]]; then
    # A netrc machine entry starts at `machine HOST` and continues until the
    # next machine/default/macdef entry. This removes every github.com record,
    # whether its fields share the machine line or use conventional following
    # lines, while emitting unrelated records without reconstructing them.
    awk '
      {
        original = $0
        parsed = $0
        sub(/^[[:space:]]+/, "", parsed)
        sub(/\r$/, "", parsed)

        # A macdef body is opaque until its terminating blank line. In
        # particular, a body line beginning with "machine github.com" is data,
        # not a credential record boundary.
        if (in_macdef) {
          print original
          if (parsed == "") in_macdef = 0
          next
        }

        split(parsed, fields, /[[:space:]]+/)
        keyword = tolower(fields[1])

        if (keyword == "machine") {
          host = tolower(fields[2])
          dropping_github = (host == "github.com")
          if (!dropping_github) {
            print original
          }
          next
        }

        if (keyword == "macdef") {
          dropping_github = 0
          in_macdef = 1
          print original
          next
        }

        if (keyword == "default") {
          dropping_github = 0
        }

        # Comments and visual separators are not credential fields. Preserve
        # them byte-for-byte even when they sit between a removed GitHub record
        # and the next machine/default record.
        if (parsed == "" || substr(parsed, 1, 1) == "#") {
          print original
          next
        }

        if (!dropping_github) {
          print original
        }
      }
    ' "$netrc" > "$temporary_file"
  fi

  {
    # `login` is ignored by GitHub for PAT-over-https; x-access-token is the
    # documented placeholder.
    printf 'machine github.com\n'
    printf '  login x-access-token\n'
    printf '  password %s\n' "$token"
  } >> "$temporary_file"

  chmod 0600 "$temporary_file"
  mv -f -- "$temporary_file" "$netrc"
  # The published pathname no longer exists. Stop tracking it so EXIT cannot
  # remove an unrelated file that is later created at the old random name.
  temporary_file=""
}

# Each file has its own atomic publication boundary. A failure while publishing
# the second file returns nonzero; rerunning safely converges both files because
# write_netrc removes every prior GitHub stanza before installing the new one.
write_netrc "$netrc_home/.netrc"
write_netrc "$netrc_home/.config/nix/netrc"

echo "netrc: github.com credential written for git+https flake inputs"
