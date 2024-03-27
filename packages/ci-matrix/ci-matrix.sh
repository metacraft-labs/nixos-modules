#!/usr/bin/env bash

set -euo pipefail

flake_attr_pre="${1:-checks}"
flake_attr_post="${2:-}"

ci-matrix-d "$flake_attr_pre" "$flake_attr_post"

echo "Complete!"
