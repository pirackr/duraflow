# Weather workflow and minimal checkpoint runtime

## Status and scope

This is a specification for written review, not an implementation plan or implemented behavior. The user approved the direction: a synchronous Haskell runtime, JSON state with file locking, saved successful task results, and manual retry by rerunning. The concrete API, storage schema, compatibility rules, and weather defaults below are proposals submitted together for approval.

The deliverable after implementation is one runnable weather example backed by a reusable `duraflow` library. It fetches a forecast, derives preparation advice through deterministic rules, and writes a checklist. Interrupting or failing the invocation must not require repeating tasks whose successful results were committed.

The existing `Duraflow` module and test entrypoint are placeholders. `workflows/WeatherWorkflow.example.hs` is currently only a sketch. This design builds on the completed core and workflow directory split; it does not revive the historical Python runner design.

## Approach and boundaries

Three approaches were considered:

1. Restart the entire workflow and repeat all actions. This is smallest, but refetches weather and repeats successful effects after every failure.
2. Restart orchestration and replay saved task results. This is the selected approach. It adds task history and compatibility checks without a resident service.
3. Add a supervisor, scheduler, and automatic retries. This increases operational and lifecycle complexity without serving the current example.

The MVP is a single synchronous sequence per execution. A failed task stops the invocation. The caller explicitly reruns the program to try again. There is no retry loop, backoff, scheduled wakeup, worker pool, daemon, scheduler, central registry, remote control API, parallel task combinator, or restoration of the Haskell stack.

`duraflow-core/` remains the package directory, `duraflow` remains the Cabal package name, and `Duraflow` remains the public module. Application code may live anywhere. The core must never import, discover, or register weather workflows. State location is supplied explicitly and is independent of source location.

The initial supported durability environment is Linux with a trusted local filesystem that implements advisory locking, atomic replacement within one directory, and file and directory synchronization. Network filesystems, hostile concurrent filesystem modification, distributed execution, and cross-platform durability are outside the MVP contract.

## Public API

The public surface is deliberately small. The following are intended signatures, not declarations added by this document:

```haskell
runWorkflow
  :: ToJSON input
  => RunConfig
  -> input
  -> (input -> Workflow output)
  -> IO output

task
  :: (ToJSON input, ToJSON output, FromJSON output)
  => TaskId
  -> input
  -> (input -> IO output)
  -> Workflow output
```

`RunConfig` contains an explicit state directory, execution ID, workflow name, and workflow version. Execution ID and task ID are distinct types. `Workflow` is an abstract sequential monad with `Functor`, `Applicative`, and `Monad` instances. It exposes no general `MonadIO` instance or catch-and-continue facility in this MVP. External effects belong inside task actions, not in orchestration.

The execution ID is an ASCII filename component, between 1 and 128 characters, starting with a letter or digit and followed only by letters, digits, periods, underscores, or hyphens. It is never interpreted as a path. Workflow names, versions, and task IDs must be nonblank text; they are compared exactly without silent trimming. Task IDs must be unique within an execution history and within an invocation. A repeated operation needs distinct stable task IDs.

The caller supplies an existing state directory. Core resolves it to an absolute canonical directory before deriving filenames. It does not create directory trees. Initialization errors are reported before running user actions. The directory and its ancestors must be provisioned durably by the caller when power-loss durability is required.

JSON instances define the serialization contract. Task outputs must round-trip through their JSON instances. Inputs must include all action parameters that affect compatibility; ambient settings must not silently change an action on resume. Orchestration must be deterministic for its input and saved task results. Changing task logic, JSON meaning, or orchestration requires an explicit workflow version change, even when task names stay the same. Core does not hash source code or infer semantic changes.

There is no stored final workflow result and no `ToJSON output` constraint on `runWorkflow`. On every invocation, orchestration runs from the beginning, successful tasks supply decoded saved values, and orchestration computes the returned value again.

## State format and execution identity

Each execution owns two permanent names within the state directory:

```text
<execution-id>.json
<execution-id>.lock
```

The lock file must not be deleted or replaced during ordinary operation. Temporary snapshot files are separate names in the same directory. An interrupted temporary write is never treated as a newer checkpoint. The runtime reads only the canonical JSON snapshot, not a temporary file selected by timestamp.

Schema version 1 has this shape:

```json
{
  "schemaVersion": 1,
  "executionId": "weather-example-001",
  "workflowName": "weatherPreparation",
  "workflowVersion": "1",
  "workflowInput": {},
  "completed": false,
  "tasks": []
}
```

`workflowInput` is the encoded input value, not necessarily an object. Each task record contains `taskId`, `input`, and `status`. A `Success` record additionally contains `output`; a `Failed` record additionally contains a bounded diagnostic `error` string. A `Running` record contains neither. There is no attempt log, automatic retry schedule, or final result field.

History must consist of zero or more `Success` records followed by at most one `Running` or `Failed` record. No record may follow an unfinished task. A completed execution may contain only successful records. The loader rejects malformed JSON, unknown schema versions, missing or unexpected schema fields, invalid field types, duplicate task IDs, and invalid history shapes. JSON values inside application inputs and outputs remain application-defined.

An absent snapshot means a new execution. Initialize its metadata under the lock even if the workflow has no tasks. An existing snapshot must match execution ID, workflow name, workflow version, and workflow input before any task action runs. Compare decoded JSON values structurally, not serialized bytes or object key order.

A mismatch, corrupt snapshot, or undecodable saved task result is an error. Never silently reset, migrate, overwrite, or start a different workflow in that execution slot. The caller can repair data deliberately outside the runtime or choose a new execution ID.

## Locking and durable snapshot protocol

Acquire a nonblocking exclusive lock for the entire `runWorkflow` invocation using the Haskell `filelock` package and `System.FileLock`, not a subprocess running `flock`. Another invocation of the same execution reports `ExecutionBusy` without waiting or running actions. Different execution IDs have independent locks. Release the lock on normal completion and on exceptions; a terminated process releases its operating-system lock.

Reject symlink or nonregular snapshot and lock entries. Canonicalizing the state directory makes ordinary directory aliases share the same execution files. This is an accidental-misuse check, not a security guarantee against an adversary modifying the trusted directory. State is plaintext and includes inputs, results, and diagnostic messages; use a private directory and owner-only permissions for newly created state files.

Every snapshot transition uses this protocol while holding the lock:

1. Encode a complete snapshot into strict bytes and create a unique temporary file in the snapshot directory.
2. Write all bytes, synchronize the file, and close its handle.
3. Atomically replace the canonical snapshot with the temporary file.
4. Synchronize the containing directory before treating the transition as committed.

An existing valid visible snapshot must itself pass a file and directory synchronization barrier under the lock before any cached result is reused or any new action starts. This handles a prior process that replaced the snapshot but died before finishing directory synchronization.

A storage failure is fatal to the invocation. Do not continue to another action, silently fall back to memory, overwrite the snapshot with an older state, or reclassify a failed success-commit as an ordinary task failure. Replacement followed by a synchronization error can leave the new snapshot visible; the next invocation validates and synchronizes whichever complete snapshot is present.

Resource acquisition, release, and state transitions must be protected against asynchronous interruption using appropriate masking and cleanup. User actions remain interruptible. This does not require uninterruptible masking around arbitrary filesystem operations.

## Task execution and replay

`runWorkflow` maintains an in-memory cursor into the ordered history. On each `task` call:

1. Validate its ID and encoded input before starting an action.
2. If a record exists at the cursor, require its task ID and input to match. For `Success`, decode and return its stored output without invoking the action. A decode failure stops replay; it must not trigger a fresh action.
3. For a matching `Running` or `Failed` record, replace that record with a durably committed `Running` record before retrying its action. There is one attempt in this invocation, not an automatic loop.
4. If the cursor is beyond existing history, append and commit `Running` before starting the new action. A previously completed execution rejects any appended task.
5. Run the action. Convert its returned value to fully encoded JSON before considering it successful. An ordinary action exception or output-encoding exception produces a committed `Failed` record and then a `TaskFailure` exception. A successful action produces a committed `Success` record before its result is returned to orchestration.

Asynchronous cancellation is rethrown, not converted into an ordinary failure or swallowed for retry. The last committed snapshot remains authoritative; commonly it will show the interrupted task as `Running`. If saving an ordinary failure also fails, report `StorageFailure` with the original action failure as diagnostic context.

An exception outside a task propagates and leaves the committed history intact. Only on normal workflow return does the runtime require that all old records have been consumed, then commit `completed = true`. Never replace an existing task or orchestration failure with a misleading missing-old-task error during unwinding. A successfully replayed completed execution need not rewrite its already completed snapshot.

The completion marker rejects appending tasks after an execution has completed. An active execution with only successful records may legitimately need another task, for example after a crash between two tasks. The runtime cannot distinguish that case from changed code which reused the same version. Explicit version discipline remains mandatory.

Useful public error categories are `InvalidConfiguration`, `ExecutionBusy`, `ExecutionMismatch`, `InvalidState`, `ReplayMismatch`, `StorageFailure`, and `TaskFailure`. They should identify the execution and, where applicable, task and position. Diagnostics must not automatically print entire inputs, outputs, or state files. Saved task failure text is truncated to at most 2048 characters and may still contain sensitive application information.

### Durability does not imply exactly-once effects

An action can affect an external system and the process can die before its success is saved. That action may run again on the next invocation. Core cannot atomically commit arbitrary external effects with its JSON snapshot. Actions must be idempotent or tolerate duplicate attempts.

Conversely, a successful checkpoint does not guarantee that an external artifact still exists later. A committed checklist write is skipped on replay even if someone subsequently deletes the checklist. The MVP does not inspect or repair external artifacts behind saved task results; use a new execution to regenerate them.

## Weather application

Promote `workflows/WeatherWorkflow.example.hs` into a runnable `Main` script and add a sibling `workflows/Weather.hs` application module. Keep the existing example filename to avoid another structural rename. `Weather` owns application types, orchestration, HTTP handling, pure advice rules, and checklist rendering. The thin script parses arguments, normalizes inputs, constructs `RunConfig`, invokes the workflow, and reports success or failure.

The command takes explicit state directory, execution ID, latitude, longitude, forecast date, and output file arguments. There are no hidden Seattle, current-date, state-directory, or output defaults. The workflow name is `weatherPreparation` and the application owns an explicit version `1` constant. Latitude and longitude must be finite and within geographic bounds. The forecast date must be a valid ISO calendar date. Resolve the output parent to an existing canonical directory and store the resulting absolute output path as part of the workflow input.

The output must be outside the canonical state directory and must not be a symlink or nonregular existing entry. This prevents accidental replacement of execution state or its lock file. A nonexistent output file is valid. Output parents are provisioned by the caller. All relevant request choices, including date, coordinates, and output path, participate in execution compatibility.

The workflow consists of exactly these three tasks:

1. `fetchForecast` takes the normalized weather request and fetches its forecast.
2. `prepareAdvice` takes the saved forecast and returns a checklist using pure rules.
3. `writeChecklist` takes the absolute output path and checklist, atomically replaces the file, and returns that path.

### Forecast contract

Use the public Open-Meteo forecast endpoint at `https://api.open-meteo.com/v1/forecast`. Request a single date with equal `start_date` and `end_date`, the supplied coordinates, `timezone=UTC`, Celsius temperatures, and wind speed in kilometres per hour. Request these daily fields:

- `temperature_2m_min`
- `temperature_2m_max`
- `precipitation_probability_max`
- `wind_speed_10m_max`
- `uv_index_max`

No geocoding, authentication, model inference, or separate weather service is needed. A fresh task can fetch only dates served by the forecast endpoint. Do not reject a saved forecast merely because its date has become historical; replay does not make a new HTTP request.

Make one application HTTP request with redirects disabled and no application retry loop. Apply a 30 second total elapsed-time deadline covering connection establishment, response headers, full body consumption, and validation. Expiry becomes an ordinary task failure without swallowing external cancellation. This is not merely an inactivity timeout.

HTTP errors, malformed JSON, missing or null required metrics, unexpected units, an absent requested date, or inconsistent daily array lengths fail the task. Required daily unit strings are `iso8601` for time, `°C` for both temperatures, `%` for precipitation probability, `km/h` for wind, and the empty string for UV. Require a zero UTC offset. Validate finite returned coordinates within geographic bounds, finite metrics, minimum temperature not greater than maximum, precipitation probability between 0 and 100, and nonnegative wind and UV values. Select and validate the requested date explicitly rather than assuming the first row is correct.

`Forecast` retains the requested coordinates and date, the API response latitude and longitude, normalized units and metrics, provider identity, request URL, and UTC retrieval timestamp. Provider coordinates identify the forecast grid location and need not equal the requested coordinates. The retrieval timestamp is captured after receiving and validating the response and is part of the saved task output.

Replay deliberately reuses that forecast and timestamp. A fresh forecast requires a new execution ID. This is preparation guidance based on a dated prediction, not a current warning or guarantee of safe conditions.

### Deterministic checklist rules

Evaluate rules in this fixed order, including each applicable item once:

1. Rain probability at least 50 percent: bring rain protection.
2. Minimum temperature at most 5 degrees Celsius: bring warm layers.
3. Maximum wind speed at least 40 kilometres per hour: secure loose outdoor items and prepare for wind.
4. Maximum UV index at least 3: use sun protection.

If no rule applies, include a single item saying no additional preparation was identified by these rules. Include all requested metrics, units, forecast date, provider, and retrieval timestamp in the checklist header. Show both requested and provider latitude and longitude, labeled separately, rather than inventing a city name. Advice and rendering must not read the current clock, make network requests, or depend on process locale. Use stable UTF-8 text with LF line endings and one trailing newline.

Write through a unique temporary file in the destination directory, synchronize it, atomically replace the target, and synchronize its parent before returning. Retrying replaces the complete checklist rather than appending duplicate content. The core checkpoint and output-file replacement are two separate commits; the output write must be safe to repeat in the gap between them. Different executions targeting the same output are not mutually locked; the last replacement wins. Callers should normally use separate output paths.

CLI errors go to standard error with a nonzero exit status. Success prints the absolute output path. No automatic retry or restart command is added; rerunning the same invocation resumes it.

## Build and application isolation

Core needs JSON serialization, filesystem operations, advisory locks, and POSIX synchronization. The expected dependency families are `aeson`, `bytestring`, `text`, `directory`, `filepath`, `filelock`, and `unix`, in addition to `base`. Keep persistence and replay responsibilities in focused internal modules rather than exposing the storage representation as public API.

Weather HTTP, TLS, time handling, request parsing, and business rules stay outside the core package. Use `http-client` and `http-client-tls` for HTTP and `time` for date and timestamp handling. Weather may depend on core, not the reverse. Application tests live under `workflows/test/` and import the application module without moving it into the library test suite. Network and clock operations should be replaceable in application tests; production uses the real operations.

Retain Nix toolchain ownership and exact GHC 9.10.3 matching. The current compiler-only Stack resolver does not provide the new dependency closure. The implementation plan must specify compatible pinned dependencies, either through a matching snapshot or explicit extra dependencies, and validate resolution before runtime development. Do not silently upgrade GHC or allow Stack to install another compiler.

Provide and verify project-aware `stack runghc` commands for the example and its offline tests, with the local core package and required application packages available. Test loading and argument validation without networking as part of verification. No standalone `stack script` distribution, published core package, or new application Cabal package is required. Standalone scripts ignore project Stack configuration and remain a separate packaging concern.

Update the root, core, and workflow READMEs to describe the implemented contract accurately when implementation occurs. CI must run core tests and the separate offline weather tests. It must not fetch a live forecast.

## Acceptance criteria

### Core

- A three-task workflow completes, commits outputs and completion, and returns its result. Rerunning it returns the same decoded task results without rerunning actions.
- An ordinary failure in task two stops task three. Rerunning replays task one and makes one new attempt at task two, then continues only if it succeeds.
- A process killed after committing `Running` can resume. Previously successful actions stay skipped; the interrupted action can repeat. Use explicit process handshakes rather than timing guesses.
- A second process targeting an execution with a held lock receives busy promptly and runs no action. Different execution IDs can progress independently.
- Metadata and structural input mismatches, changed task order or IDs, duplicate IDs, corrupt JSON, unsupported schemas, invalid histories, incompatible saved outputs, and missing old tasks on normal return fail without silently refetching or resetting history.
- A completed run rejects extra appended tasks. A zero-task workflow still persists identity and completion and rejects incompatible reuse.
- Filesystem fault injection checks write, file synchronization, replacement, directory synchronization, and recovery barriers. No action begins before its `Running` commit; no dependent task starts after a failed success-commit.
- Cancellation releases the lock, does not become an ordinary saved failure, and never leaves partial canonical JSON. Ordinary workflow failures are not masked by end-of-replay validation.
- Newly created snapshots, temporary snapshots, and lock files have owner-only permissions. Symlink and nonregular snapshot or lock entries are rejected before any user action.
- A repeated effect is demonstrable when an action finishes but its success is not committed. Tests and documentation must not claim exactly-once effects.

### Weather

- Offline fixtures test forecast parsing, units, date selection, malformed and incomplete responses, invalid metric values, HTTP failures, and timeouts.
- Pure tests cover every rule at its threshold and immediately outside it, combinations, fixed order, and the no-extra-preparation case. Rendering fixtures include separately labeled requested and provider coordinates, all metrics, and saved provenance.
- An offline three-task integration test fails the checklist write after the first two task checkpoints. A later invocation succeeds without another HTTP call, reuses the original retrieval timestamp, and writes one checklist.
- Repeating a write whose external effect completed before checkpointing replaces the same complete content without duplication. A committed write is skipped on replay, including when its artifact is later absent.
- Script argument and path validation works from an arbitrary source location when dependencies and module search paths are supplied. Reject output paths within state, symlink or nonregular output entries, and missing parent directories. The core requires no knowledge of `workflows/`.
- All automated acceptance tests run without credentials or live network access. A live Open-Meteo smoke run is optional and separately requested, not a prerequisite for CI.

Process-kill tests and injected filesystem failures establish protocol behavior. They do not empirically certify a storage device against power loss; the durability claim relies on the stated filesystem and synchronization contract.

## Delivery and next gate

This document is the only new project artifact in the specification change. Preserve unrelated staged files, PDFs, Python bytecode, and the pending root ignore-file changes. Keep the specification commit separate from the earlier structural pull request, use conventional commits, and use `gh` for any later GitHub operation.

After self-review, submit this written specification for user approval. Only then invoke the writing-plans skill to create the implementation plan. This request does not authorize executing that plan or adding runtime code.

## References

- [Core and workflow workspace split](2026-09-14-core-workflows-split-design.md).
- [Open-Meteo forecast API](https://open-meteo.com/en/docs).
- [Stack runghc](https://docs.haskellstack.org/en/stable/commands/runghc_command/).
- [Stack script](https://docs.haskellstack.org/en/stable/commands/script_command/).
