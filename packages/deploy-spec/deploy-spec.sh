#!/usr/bin/env bash
@cachixBin@ deploy activate "$(git rev-parse --show-toplevel)"/cachix-deploy-spec.json --async
