# Weather workflow example

`WeatherWorkflow.hs` is the named runnable `WeatherWorkflow` module. It contains
all weather application types, CLI handling, Open-Meteo client behavior,
deterministic advice, checklist rendering, and three-task orchestration. This
directory is application code rather than a Cabal package, and the core does
not know it exists.

## Command

There are exactly six positional arguments and no defaults:

```text
STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE
```

- `STATE_DIR`: existing, private execution-state directory
- `EXECUTION_ID`: valid Duraflow execution filename component
- `LATITUDE`: finite value from -90 through 90
- `LONGITUDE`: finite value from -180 through 180
- `YYYY-MM-DD`: valid canonical ISO calendar date
- `OUTPUT_FILE`: checklist path whose parent already exists

The output is normalized to an absolute path and must be outside the canonical
state directory. Existing symlink and nonregular output entries are rejected,
including dangling symlinks. Directory aliases do not bypass the state/output
separation check.

Example:

```sh
mkdir -m 700 -p "$HOME/.local/state/duraflow-weather" "$HOME/weather-reports"
nix develop --no-write-lock-file --command \
  stack runghc --package duraflow --package aeson --package http-client \
  --package http-client-tls --package time -- \
  --ghc-arg=-iworkflows --ghc-arg=-main-is --ghc-arg=WeatherWorkflow.main workflows/WeatherWorkflow.hs \
  "$HOME/.local/state/duraflow-weather" weather-home-001 \
  47.6062 -122.3321 2026-09-15 "$HOME/weather-reports/preparation.txt"
```

**A fresh fetch requires a date currently served by Open-Meteo; replace the
illustrative `2026-09-15` date before running.** The live command is for the user
and is never run by automated tests. Success emits only the absolute output
path. Failures emit a standard-error diagnostic and exit nonzero.

## Workflow behavior

The workflow version is explicitly `1` and runs these stable tasks in order:

1. `fetchForecast`
2. `prepareAdvice`
3. `writeChecklist`

The forecast request includes coordinates, date, and absolute output path so all
choices participate in compatibility. Forecast output retains requested and
provider coordinates, metrics and normalized units, Open-Meteo provenance,
request URL, and retrieval timestamp. Advice is deterministic and ordered:
rain protection at 50%, warm layers at 5 °C minimum, wind preparation at 40
km/h, and sun protection at UV 3. If none applies, one no-additional-preparation
item is emitted. Checklist text is stable UTF-8 with LF endings and one trailing
newline.

No task is automatically retried. Rerun the same invocation to resume. Saved
successful tasks replay without HTTP or clock access, preserving the original
forecast and retrieval timestamp. Use a new execution ID for a fresh forecast.
Changing task behavior, orchestration, or JSON meaning requires changing the
workflow version because JSON instances and versioned state are compatibility
contracts.

The output writer atomically replaces a complete file rather than appending.
An effect can finish before its success checkpoint, so replacement may repeat;
Duraflow provides at-least-once effects in that gap, not exactly once. Once the
write is committed, replay skips it even if somebody deletes the artifact; a
missing output remains missing. Different executions do not share an output
lock, so use separate paths; if paths are shared, last replacement wins.

## Privacy and limitations

State files are plaintext and contain request choices, saved forecasts, and
possibly failure diagnostics. Provision state and output-parent directories
before invocation, keep state private, and use owner-controlled permissions.
The durability contract is limited to Linux on a trusted local filesystem with
advisory locking, atomic same-directory replacement, and file/directory sync.
Network filesystems and hostile concurrent changes are unsupported. SIGKILL,
failure-injection, and test failures do not certify hardware power-loss
behavior.

## Offline tests

From any working directory, the single current wrapper locates the repository
itself:

```sh
nix develop --no-write-lock-file --command bash scripts/test-weather.sh
```

It runs the consolidated `workflows/test/Main.hs` suite: fixture, rule, writer,
replay, repeated-effect, and CLI unit tests, plus subprocess checks that launch
the example from an unrelated temporary directory with absolute Stack, source,
and module paths. The suite uses no credentials and sends no forecast request.
