#!/usr/bin/env bash

PATH="$(nix build --print-out-paths 'nixpkgs#jq^bin')/bin:$PATH"
export PATH

ls */matrix-pre.json
# TODO: Fix this
matrix="$(cat */matrix-pre.json | jq -cr '.include[]' | jq '[ select (.cacheUrl != "" and .cacheUrl != null) ]' | jq -s 'add' | jq -c  '. | {include: .}')"

if [[ "$matrix" == '' ]] || [[ "$matrix" == '{}' ]] || [[ "$matrix" == '{"include":null}' ]] || [[ "$matrix" == '{"include":[]}' ]]; then
  matrix='{"include":[],"empty":"true"}'
fi

echo "---"
echo "Matrix:"
echo "$matrix" | jq
echo "---"
echo
echo

fullMatrix="$(cat */matrix-pre.json | jq -cr '.include' | jq -s 'add' | jq -c '. | {include: .}')"

echo "---"
echo "Full Matrix:"
echo "$fullMatrix" | jq
echo "---"

echo "matrix=$matrix" >> $GITHUB_OUTPUT
echo "fullMatrix=$fullMatrix" >> $GITHUB_OUTPUT
