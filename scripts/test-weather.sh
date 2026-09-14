#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repository_root"

exec stack runghc \
  --package duraflow \
  --package aeson \
  --package http-client \
  --package http-client-tls \
  --package process \
  --package time \
  --package unix \
  -- -iworkflows -iworkflows/test workflows/test/Main.hs
