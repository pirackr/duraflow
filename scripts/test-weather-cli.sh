#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
stack_yaml="$repository_root/stack.yaml"
example="$repository_root/workflows/WeatherWorkflow.example.hs"
weather_modules="-i$repository_root/workflows"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

state="$temporary/state"
outside="$temporary/outside"
mkdir "$state" "$outside"

run_invalid() {
  local label=$1
  local execution=$2
  shift 2
  local stdout_file="$temporary/$execution.stdout"
  local stderr_file="$temporary/$execution.stderr"

  if (
    cd "$temporary"
    stack --stack-yaml "$stack_yaml" runghc \
      --package duraflow \
      --package aeson \
      --package http-client \
      --package http-client-tls \
      --package time \
      -- "$weather_modules" "$example" "$@"
  ) >"$stdout_file" 2>"$stderr_file"; then
    echo "$label unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ -s "$stdout_file" ]]; then
    echo "$label wrote to stdout" >&2
    exit 1
  fi
  if [[ ! -s "$stderr_file" ]]; then
    echo "$label did not write a diagnostic to stderr" >&2
    exit 1
  fi
  if [[ -e "$state/$execution.json" ]]; then
    echo "$label created an execution snapshot" >&2
    exit 1
  fi
}

run_invalid "missing arguments" missing
run_invalid "invalid latitude" bad-latitude \
  "$state" bad-latitude 91 -122.3321 2026-09-15 "$outside/report.txt"
run_invalid "invalid date" bad-date \
  "$state" bad-date 47.6062 -122.3321 2026-02-29 "$outside/report.txt"
run_invalid "output inside state" inside-state \
  "$state" inside-state 47.6062 -122.3321 2026-09-15 "$state/report.txt"

ln -s "$state" "$temporary/state-alias"
run_invalid "state directory alias" state-alias \
  "$temporary/state-alias" state-alias 47.6062 -122.3321 2026-09-15 "$state/alias-report.txt"

printf 'untouched\n' >"$outside/target.txt"
ln -s "$outside/target.txt" "$outside/linked.txt"
run_invalid "symlink output" symlink-output \
  "$state" symlink-output 47.6062 -122.3321 2026-09-15 "$outside/linked.txt"

ln -s "$outside/missing-target.txt" "$outside/dangling.txt"
run_invalid "dangling symlink output" dangling-output \
  "$state" dangling-output 47.6062 -122.3321 2026-09-15 "$outside/dangling.txt"

mkdir "$outside/directory-output"
run_invalid "nonregular output" nonregular-output \
  "$state" nonregular-output 47.6062 -122.3321 2026-09-15 "$outside/directory-output"
run_invalid "absent output parent" absent-parent \
  "$state" absent-parent 47.6062 -122.3321 2026-09-15 "$temporary/missing/report.txt"

printf 'Standalone CLI validation passed.\n'
