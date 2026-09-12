# Duraflow: Haskell engine + Python client PoC

A deliberately small local runtime. Haskell owns JSON checkpoints, locking,
and subprocess supervision. Workflow programs are ordinary Python files:
adding one requires no Haskell rebuild. Other languages can implement the
same JSON-lines protocol.

**PoC only:** manual enqueue/retry, one serial worker, no scheduler or automatic
retry policy, and no new automated tests. The scaffold's empty test entrypoint
is unchanged.

## Build and run

```sh
nix develop                 # or nix-shell; .envrc also uses this flake
stack build

# This ONLY queues work; it does not run Python or pi.
stack exec -- duraflow enqueue weather-sf examples/weather-input.json -- python3 -m examples.weather

# Separately execute queued runs, then exit.
stack exec -- duraflow worker --once
stack exec -- duraflow show weather-sf
```

Use `worker` without `--once` to poll every second. `--once` drains the current
queue. The worker stays separate from your interactive pi session. `show`
prints the persisted run, including its final `result` and completed `steps`.
Worker exit success means the queue was processed; check run status for
individual workflow failures.

Run IDs accept ASCII letters, digits, `_`, and `-`. Enqueuing an existing ID
fails instead of overwriting it. Set `DURAFLOW_HOME` to change the state directory
(default `.duraflow/`, gitignored); its parent directory must already exist.
Use the same home for enqueue, worker, retry, and show.

## Two-step weather example

`examples/weather.py` contains the workflow:

```python
forecast = ctx.step("fetch-forecast", lambda: fetch_forecast(ctx.inputs, target))
return ctx.step("suggest-items", lambda: ask_ornith(forecast))
```

1. Scripted Open-Meteo lookup for tomorrow in San Francisco, in Fahrenheit.
   The date is derived from the **persisted enqueue timestamp** in
   `America/Los_Angeles`, or an explicit `date` input. Recovery cannot move it.
2. An actual headless pi call using **lemonade / Ornith-1.5-35B-A3B-GGUF**.
   Tools, extensions, skills, context discovery, and sessions are disabled.
   The adapter validates the terminal pi response and saves text/model/usage.

`pi` must be on PATH and have that model/provider configured; its existing
configuration supplies endpoint/auth. Pi is not installed by this Nix shell.
Live weather needs internet access. To remove that dependency while still
calling the **real model**, use the explicitly synthetic fixture:

```sh
stack exec -- duraflow enqueue weather-fixture examples/weather-fixture.json -- python3 -m examples.weather
stack exec -- duraflow worker --once
stack exec -- duraflow show weather-fixture
```

No notifications or purchases. The report remains in the run JSON. Re-running
the worker does not rerun completed jobs; use a fresh ID for a fresh model call.

## Failure and recovery

```sh
stack exec -- duraflow show weather-sf
# Fix the underlying service/input-environment problem, then:
stack exec -- duraflow retry weather-sf
stack exec -- duraflow worker --once
```

`retry` accepts only failed runs. Inputs and completed results are retained.
The restarted Python program receives cached values for completed steps;
unfinished steps execute again. Attempt counters are recorded before execution.
A worker interrupted while running leaves a recoverable `running` document.

Scripts and dependencies must remain unchanged while runs are unfinished.
Bad input requires a **new run**, not editing an existing run document.

## Minimal language-independent protocol (v1)

The worker launches the saved command in its saved working directory. Its
stdin/stdout are dedicated UTF-8 JSONL pipes; each frame ends with a literal LF.
Diagnostics go to stderr. Python's `run(workflow)` redirects ordinary `print`
calls, but subprocess stdout must still be captured or redirected explicitly.

Engine sends the initial `hello` containing `run_id`, `inputs`, and `created_at`.
Every frame contains `"v": 1`.

```text
Client: {"v":1,"type":"begin_step","name":"forecast"}
Engine: {"v":1,"type":"saved","result":...}
    OR: {"v":1,"type":"execute","attempt":1}

Client: {"v":1,"type":"complete_step","name":"forecast","result":...}
Engine: {"v":1,"type":"committed","result":...}
```

The client waits for `committed` before advancing. It is sent only after
persistence. Return its JSON-normalized result, so fresh execution and replay
have the same representation. Values may be any JSON value, including null. No nested or parallel
steps; names must be nonempty and unique within an invocation.

On failure, send `{"v":1,"type":"fail_step","name":"forecast","error":"..."}`
and exit. On success, send `{"v":1,"type":"finish","result":...}` and exit.
These two terminal messages have no reply. A run is completed only after
`finish` **and** a zero process exit. Protocol errors, EOF without finish,
nonzero exit, or timeout fail the run.

## Storage and scope

- One JSON document per run. Publish: same-directory temp file, fsync file,
  atomic rename, fsync directory. Corrupt records fail loudly.
- `store.lock` protects brief metadata updates, never script execution.
  `worker.lock` protects the worker's lifetime. Stable lock files are not deleted.
- Whole workflow timeout: 180 seconds; pi timeout: 150 seconds. Handled shutdown
  and errors kill the workflow process group and reap the direct child.
- **SIGKILL/power loss bypasses cleanup.** Detached subprocesses can also escape
  the group. Before recovery, ensure old children are gone; real deployment
  requires a supervisor with cgroup cleanup. Flock alone doesn't prevent orphan
  effects overlapping recovery.
- Interrupted callbacks may repeat: external effects are **not exactly-once**.
  Effects outside `ctx.step` are not checkpointed. Use trusted, idempotent scripts.
- No sandbox, output-size cap, code/dependency pinning, schedule engine, retry
  backoff, migration, or distributed worker support. These are intentionally
  deferred rather than hidden behind a larger abstraction.

## Development files

- `src/Duraflow.hs`: queue/worker CLI and protocol interpreter.
- `src/Duraflow/Store.hs`: run schema, locks, atomic JSON publication.
- `clients/python/duraflow.py`: synchronous Python client.
- `examples/weather.py`: ordinary Python workflow, launch with `-m` from repo root.
- `flake.nix`, `shell.nix`, `nix/dev-shell.nix`: shared pinned dev tools, including Python.
- `stack.yaml`, `stack.yaml.lock`: LTS 24.15, matching Nix's GHC 9.10.3.

No project license has been chosen (`license: NONE`). No commits are made by
running the examples.
