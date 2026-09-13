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

filter_existing_netrc() {
  # This helper runs before setup-nix has established a Nix toolchain. Keep the
  # parser in Bash so a deliberately minimal runner PATH is sufficient. The
  # implementation is line-oriented because a macdef body is opaque until its
  # terminating blank line; interpreting tokens inside one could mistake macro
  # data for a credential record.
  local line=""
  local line_has_newline=0
  local parsed_line=""
  local keyword=""
  local host=""
  local in_macdef=0
  local dropping_github=0
  local emitted_bytes=0
  local emitted_newline=1
  # Bash 3.2 treats literal capture parentheses on the right-hand side of
  # `=~` as shell syntax. Passing the expressions through variables keeps them
  # regular-expression data while still populating BASH_REMATCH.
  local keyword_pattern='^[[:space:]]*([^[:space:]]+)'
  local machine_host_pattern='^[[:space:]]*[^[:space:]]+[[:space:]]+([^[:space:]]+)'

  while :; do
    line=""
    if IFS= read -r line; then
      line_has_newline=1
    elif [[ -n "$line" ]]; then
      line_has_newline=0
    else
      break
    fi

    # read removes only LF. Retain a CR for byte-identical output, but exclude
    # it from token and blank-line recognition for CRLF-formatted files.
    parsed_line="${line%$'\r'}"

    if [[ "$in_macdef" -eq 1 ]]; then
      if [[ "$line_has_newline" -eq 1 ]]; then
        printf '%s\n' "$line"
        emitted_newline=1
      else
        printf '%s' "$line"
        emitted_newline=0
      fi
      emitted_bytes=1

      if [[ "$parsed_line" =~ ^[[:space:]]*$ ]]; then
        in_macdef=0
      fi
    else
      keyword=""
      host=""
      if [[ "$parsed_line" =~ $keyword_pattern ]]; then
        keyword="${BASH_REMATCH[1]}"
      fi

      # Spell out ASCII case folding instead of using ${value,,}, which was
      # added after the Bash 3.2 still shipped by macOS.
      case "$keyword" in
        [Mm][Aa][Cc][Hh][Ii][Nn][Ee])
          if [[ "$parsed_line" =~ $machine_host_pattern ]]; then
            host="${BASH_REMATCH[1]}"
          fi
          dropping_github=0
          case "$host" in
            [Gg][Ii][Tt][Hh][Uu][Bb].[Cc][Oo][Mm]) dropping_github=1 ;;
          esac
          ;;
        [Mm][Aa][Cc][Dd][Ee][Ff])
          dropping_github=0
          in_macdef=1
          ;;
        [Dd][Ee][Ff][Aa][Uu][Ll][Tt])
          dropping_github=0
          ;;
      esac

      # Comments and visual separators are not credential fields. Preserve
      # them even while removing the surrounding GitHub credential record.
      if [[ "$dropping_github" -eq 0 || -z "$keyword" || "$keyword" == \#* ]]; then
        if [[ "$line_has_newline" -eq 1 ]]; then
          printf '%s\n' "$line"
          emitted_newline=1
        else
          printf '%s' "$line"
          emitted_newline=0
        fi
        emitted_bytes=1
      fi
    fi

    if [[ "$line_has_newline" -eq 0 ]]; then
      break
    fi
  done

  # A machine stanza appended after an unterminated macdef would still be part
  # of the macro body, so git would never see the credential. Refuse to
  # publish a replacement instead of reporting success with a malformed file.
  if [[ "$in_macdef" -eq 1 ]]; then
    echo "netrc: refusing to append after an unterminated macdef" >&2
    return 65
  fi

  # A final unrelated field without LF is preserved verbatim by the loop. Add
  # only the structural separator required to keep the new machine record from
  # becoming part of that field.
  if [[ "$emitted_bytes" -eq 1 && "$emitted_newline" -eq 0 ]]; then
    printf '\n'
  fi
}

validate_netrc_target() {
  local netrc="$1"

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
}

write_netrc() {
  netrc="$1"
  netrc_directory="${netrc%/*}"

  # Validate again immediately before reading. The up-front validation below
  # prevents a known-invalid second destination from partially rotating the
  # first; this second check narrows the remaining check/use window.
  validate_netrc_target "$netrc"

  temporary_file="$(mktemp "$netrc_directory/.write-netrc.XXXXXX")"

  # mktemp already obeys the restrictive umask. Keep an explicit chmod both as
  # defence in depth and as a fail-closed check before credential bytes exist.
  chmod 0600 "$temporary_file"

  if [[ -e "$netrc" ]]; then
    # A netrc machine entry starts at `machine HOST` and continues until the
    # next machine/default/macdef entry. This removes every github.com record,
    # whether its fields share the machine line or use conventional following
    # lines, while emitting unrelated records without reconstructing them.
    filter_existing_netrc < "$netrc" > "$temporary_file"
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
user_netrc="$netrc_home/.netrc"
nix_netrc="$netrc_home/.config/nix/netrc"
validate_netrc_target "$user_netrc"
validate_netrc_target "$nix_netrc"
write_netrc "$user_netrc"
write_netrc "$nix_netrc"

echo "netrc: github.com credential written for git+https flake inputs"
