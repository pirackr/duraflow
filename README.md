# Duraflow

Duraflow is a small synchronous Haskell workflow runtime. It durably records
successful task results in JSON, then replays those results when the caller
reruns the same execution. This repository also contains a runnable weather
preparation workflow.

There is no daemon, scheduler, automatic retry, or restart subcommand. A failed
run stops; rerun the same command manually to resume. A new execution ID starts
a fresh history and, for weather, fetches a fresh forecast.

## Development

Nix owns the exact GHC 9.10.3 toolchain and Stack is configured not to install a
compiler:

```sh
nix develop --no-write-lock-file
stack build --test --no-run-tests http-client http-client-tls duraflow
stack test
bash scripts/test-weather.sh
bash scripts/test-weather-cli.sh
```

All automated tests are offline. They use injected HTTP fixtures and never call
the live forecast service.

## Weather example

The command has exactly six positional arguments and no defaults:

```text
STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE
```

Provision private, existing state and output directories first. The output must
be outside the state directory. For example:

```sh
mkdir -m 700 -p "$HOME/.local/state/duraflow-weather" "$HOME/weather-reports"
nix develop --no-write-lock-file --command \
  stack runghc --package duraflow --package aeson --package http-client \
  --package http-client-tls --package time -- \
  -iworkflows workflows/WeatherWorkflow.example.hs \
  "$HOME/.local/state/duraflow-weather" weather-home-001 \
  47.6062 -122.3321 2026-09-15 "$HOME/weather-reports/preparation.txt"
```

**For a fresh execution, the example date must be a date currently served by
Open-Meteo. Replace `2026-09-15` as needed.** This is a user-invoked live example,
not an automated test. Success prints only the normalized absolute output path;
errors are written to standard error with a nonzero status.

Execution IDs are filename components: 1–128 ASCII characters, beginning with a
letter or digit and continuing with letters, digits, `.`, `_`, or `-`. State and
output-parent directories must already exist. The CLI canonicalizes both,
rejects output equal to or inside state (including aliases), and rejects
symlink or nonregular output entries.

## Replay and durability contract

Each execution uses `<execution-id>.json` and a permanent
`<execution-id>.lock` in the caller-provided state directory. State contains
plaintext workflow inputs, task outputs, and bounded failure diagnostics; it can
include sensitive coordinates and forecast data. Keep the directory private.
The JSON schema and application JSON instances are compatibility contracts.
Changing orchestration, task behavior, or JSON meaning requires changing the
workflow version rather than silently reusing old state.

Rerunning the same execution replays committed successful tasks. The weather
workflow therefore preserves the original forecast and retrieval timestamp.
Use a fresh ID for a fresh request. A committed checklist write is skipped even
if the output artifact was later deleted, so replay does not recreate missing
artifacts.

Durable checkpoints do not make external effects exactly once. An output can be
replaced and the process can fail before its success checkpoint, causing the
complete replacement to repeat on resume. The writer is safe to repeat and does
not append, but separate executions targeting one path are not locked together;
the last replacement wins. Prefer separate output paths. There are no automatic
retries.

The supported durability environment is Linux on a trusted local filesystem
with advisory locks, atomic same-directory replacement, and file/directory
synchronization. Network filesystems, hostile concurrent changes, and other
platforms are outside the contract. Test failures, injected storage faults, and
SIGKILL process tests exercise protocol behavior; they do not certify hardware
power-loss behavior.

See [`duraflow-core/README.md`](duraflow-core/README.md) for the public runtime
API and [`workflows/README.md`](workflows/README.md) for weather behavior and
application commands. The core never imports or discovers workflows.
