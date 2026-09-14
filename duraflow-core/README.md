# Duraflow core

`duraflow-core/` is the reusable `duraflow` Cabal library. Its public `Duraflow`
module exports:

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

It also exports `ExecutionId`, `TaskId`, `RunConfig`, `DuraflowError`, and the
abstract sequential `Workflow` type. The core has no weather dependency and
does not scan, register, or discover application workflows.

## Execution and replay

A caller supplies an existing state directory, execution ID, workflow name,
workflow version, and JSON-serializable workflow input. The directory is
canonicalized and each execution owns `<execution-id>.json` and a permanent
`<execution-id>.lock`. Execution IDs are 1–128-character ASCII filename
components, starting alphanumeric and continuing with alphanumerics, `.`, `_`,
or `-`. Names, versions, and task IDs must be nonblank and are compared exactly.

On a fresh run, each task is checkpointed `Running`, then `Success` or `Failed`.
A synchronous failure stops the invocation; there is no automatic retry. Rerun
with the same configuration and input to replay saved successes and retry the
unfinished task once. Completed executions replay without running actions.
A new execution ID creates a fresh history.

The schema-versioned JSON snapshot stores workflow identity and input, task
IDs/inputs/statuses, successful outputs, bounded failure diagnostics, and a
completion marker. JSON instances define compatibility. Existing state must
match workflow name, explicit version, input, task order, IDs, and task inputs;
corrupt, incompatible, or undecodable state is rejected rather than reset.
Change the workflow version whenever orchestration, task semantics, or JSON
meaning changes.

State is plaintext and may contain sensitive inputs, outputs, and errors.
Provision durable parent directories yourself and use a private directory.
New runtime files are owner-only, but the runtime does not change permissions on
caller-created directories.

## Durability boundaries

The implementation uses nonblocking advisory file locks, synchronized complete
JSON snapshots, atomic same-directory replacement, and directory
synchronization. Its supported environment is Linux on a trusted local
filesystem with those semantics. Network filesystems, hostile concurrent
filesystem changes, distributed execution, and other operating systems are
outside the contract.

Checkpointing does not make arbitrary external effects exactly once. An action
can complete externally and fail before its success is saved, so it may repeat
after restart. Actions should be idempotent or tolerate duplicates. Conversely,
a committed task is skipped even if its external artifact is later missing.
The runtime neither inspects nor repairs that artifact.

Process SIGKILL tests and injected storage failures check the protocol but do
not certify a physical device against power loss.

## Build and test

From the repository root:

```sh
nix develop --no-write-lock-file --command stack build --test --no-run-tests duraflow
nix develop --no-write-lock-file --command stack test
```

Nix owns exact GHC 9.10.3; Stack uses the local package and does not install a
compiler. There is no executable, scheduler, daemon, worker pool, or automatic
retry service in the core package.
