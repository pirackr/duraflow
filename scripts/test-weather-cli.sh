#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
stack_yaml="$repository_root/stack.yaml"
example="$repository_root/workflows/WeatherWorkflow.hs"
weather_modules="-i$repository_root/workflows"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT HUP INT TERM

state="$temporary/state"
outside="$temporary/outside"
mkdir "$state" "$outside"

# Exercise this wrapper itself against the controller's failure mode. The guard
# prevents the probe invocation from recursively starting another probe.
if [[ ${DURAFLOW_CLI_FAILURE_PROBE:-0} != 1 ]]; then
  failure_stub="$temporary/failure-stub"
  mkdir "$failure_stub"
  cat >"$failure_stub/stack" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' 'simulated compiler failure before Main loads' >&2
exit 1
EOF
  chmod +x "$failure_stub/stack"
  if PATH="$failure_stub:$PATH" DURAFLOW_CLI_FAILURE_PROBE=1 bash "$0" \
      >"$temporary/failure-probe.stdout" 2>"$temporary/failure-probe.stderr"; then
    echo "CLI checks accepted a compiler failure before Main loaded" >&2
    exit 1
  fi
fi

run_invalid() {
  local label=$1
  local execution=$2
  local expected_diagnostic=$3
  shift 3
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
      -- --ghc-arg="$weather_modules" --ghc-arg=-main-is --ghc-arg=WeatherWorkflow.main "$example" "$@"
  ) >"$stdout_file" 2>"$stderr_file"; then
    echo "$label unexpectedly succeeded" >&2
    exit 1
  fi
  if [[ -s "$stdout_file" ]]; then
    echo "$label wrote to stdout" >&2
    exit 1
  fi
  if ! grep -Fqx -- "user error ($expected_diagnostic)" "$stderr_file"; then
    echo "$label did not emit its expected application diagnostic: $expected_diagnostic" >&2
    cat "$stderr_file" >&2
    exit 1
  fi
  if [[ -e "$state/$execution.json" ]]; then
    echo "$label created an execution snapshot" >&2
    exit 1
  fi
}

run_invalid "missing arguments" missing \
  "expected six arguments: STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE"
run_invalid "invalid latitude" bad-latitude \
  "latitude is outside its geographic range" \
  "$state" bad-latitude 91 -122.3321 2026-09-15 "$outside/report.txt"
run_invalid "invalid date" bad-date \
  "forecast date must be a valid YYYY-MM-DD calendar date" \
  "$state" bad-date 47.6062 -122.3321 2026-02-29 "$outside/report.txt"
run_invalid "output inside state" inside-state \
  "output file must be outside the state directory" \
  "$state" inside-state 47.6062 -122.3321 2026-09-15 "$state/report.txt"

ln -s "$state" "$temporary/state-alias"
run_invalid "state directory alias" state-alias \
  "output file must be outside the state directory" \
  "$temporary/state-alias" state-alias 47.6062 -122.3321 2026-09-15 "$state/alias-report.txt"

printf 'untouched\n' >"$outside/target.txt"
ln -s "$outside/target.txt" "$outside/linked.txt"
run_invalid "symlink output" symlink-output \
  "output entry is not a regular file" \
  "$state" symlink-output 47.6062 -122.3321 2026-09-15 "$outside/linked.txt"

ln -s "$outside/missing-target.txt" "$outside/dangling.txt"
run_invalid "dangling symlink output" dangling-output \
  "output entry is not a regular file" \
  "$state" dangling-output 47.6062 -122.3321 2026-09-15 "$outside/dangling.txt"

mkdir "$outside/directory-output"
run_invalid "nonregular output" nonregular-output \
  "output entry is not a regular file" \
  "$state" nonregular-output 47.6062 -122.3321 2026-09-15 "$outside/directory-output"
run_invalid "absent output parent" absent-parent \
  "output parent directory does not exist or is not a directory" \
  "$state" absent-parent 47.6062 -122.3321 2026-09-15 "$temporary/missing/report.txt"

printf 'Standalone CLI validation passed.\n'
