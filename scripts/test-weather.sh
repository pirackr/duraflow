#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repository_root"

stack runghc \
  --package duraflow \
  --package aeson \
  --package http-client \
  --package http-client-tls \
  --package time \
  -- -iworkflows -iworkflows/test workflows/test/Main.hs
