#!/usr/bin/env sh
#export LD_DEBUG=all
export LD_LIBRARY_PATH=$(nix eval --raw nixpkgs#curl.out.outPath)/lib:$LD_LIBRARY_PATH
dub test -- -e 'coda|fetchJson'
