# Weather Workflow MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a runnable weather preparation example whose successful tasks survive failures and manual restarts through a reusable synchronous checkpoint library.

**Architecture:** An abstract sequential Workflow evaluates orchestration against an ordered JSON task history. Internal schema and storage modules validate identity, hold an invocation-wide advisory lock, and commit complete snapshots with file and directory synchronization. Weather remains application code, with injectable HTTP, clock, and writer operations and a thin command-line script.

**Tech Stack:** Haskell, exact Nix-owned GHC 9.10.3, Stack, Cabal, aeson, filelock, unix, http-client, http-client-tls, time. Linux and trusted local filesystems only.

**Spec:** docs/superpowers/specs/2026-09-14-weather-workflow-mvp-design.md

## Global Constraints

- `duraflow-core/` remains the package directory, `duraflow` remains the Cabal package name, and `Duraflow` remains the public module.
- Application code may live anywhere. The core must never import, discover, or register weather workflows.
- Retain Nix toolchain ownership and exact GHC 9.10.3 matching. Do not silently upgrade GHC or allow Stack to install another compiler.
- `Workflow` is an abstract sequential monad with `Functor`, `Applicative`, and `Monad` instances. It exposes no general `MonadIO` instance or catch-and-continue facility in this MVP.
- The caller supplies an existing state directory. Core resolves it to an absolute canonical directory before deriving filenames. It does not create directory trees.
- Acquire a nonblocking exclusive lock for the entire `runWorkflow` invocation using the Haskell `filelock` package and `System.FileLock`, not a subprocess running `flock`.
- The lock file must not be deleted or replaced during ordinary operation.
- Every snapshot transition writes a unique same-directory temporary file, synchronizes and closes it, atomically replaces the snapshot, and synchronizes its directory.
- An existing valid visible snapshot must itself pass a file and directory synchronization barrier under the lock before any cached result is reused or any new action starts.
- A storage failure is fatal to the invocation. Asynchronous cancellation is rethrown, not converted into an ordinary failure or swallowed for retry.
- Saved task failure text is truncated to at most 2048 characters.
- An action can affect an external system and the process can die before its success is saved. That action may run again on the next invocation.
- Weather uses the workflow name `weatherPreparation` and an explicit version `1` constant, with exactly `fetchForecast`, `prepareAdvice`, and `writeChecklist` tasks.
- Make one application HTTP request with redirects disabled and no application retry loop. Apply a 30 second total elapsed-time deadline covering connection establishment, response headers, full body consumption, and validation.
- Stable UTF-8 checklist text uses LF line endings and one trailing newline.
- All automated acceptance tests run without credentials or live network access. A live Open-Meteo smoke run is optional and separately requested, not a prerequisite for CI.
- Preserve unrelated staged files, PDFs, Python bytecode, and pending ignore-file changes in the original checkout. Use conventional commits and `gh` for GitHub operations. Do not merge the PR.

## Workspace and execution order

The implementation branch is `feat/weather-workflow-mvp`, in the sibling worktree `/home/pirackr/Working/grinder/duraflow-weather-mvp`, based on latest fetched `origin/main` at `3c8871a`. The approved spec is copied by cherry-picking its isolated documentation commit, without bringing over the original checkout index.

Execute Tasks 1 through 5 sequentially. Each has a fresh implementer, recorded RED and GREEN evidence where code changes, and an independent spec and quality review. Record progress in this plan and the plan-scoped SDD ledger. Never implement in the original dirty checkout.

## File and responsibility map

| File | Responsibility |
| --- | --- |
| `stack.yaml`, `stack.yaml.lock` | Pinned dependency closure and exact system compiler configuration |
| `duraflow-core/duraflow.cabal` | Library and independent internal test components, no weather dependency |
| `duraflow-core/src/Duraflow.hs` | Small public re-export facade |
| `duraflow-core/src/Duraflow/Internal/Types.hs` | IDs, configuration, public error categories, validation |
| `duraflow-core/src/Duraflow/Internal/Snapshot.hs` | Strict schema version 1 encoding, decoding, history validation |
| `duraflow-core/src/Duraflow/Internal/Storage.hs` | Permanent lock, entry checks, private temporary files, durable replacement and recovery barrier |
| `duraflow-core/src/Duraflow/Internal/Runtime.hs` | Abstract Workflow monad, replay cursor, task execution, completion |
| `duraflow-core/test/Main.hs`, `TestSupport.hs` | Offline test dispatcher and isolated directories/assertions |
| `duraflow-core/test/SnapshotTests.hs`, `StorageTests.hs` | Strict schema and injectable filesystem protocol tests |
| `duraflow-core/test/RuntimeTests.hs`, `ProcessTests.hs` | Replay, failure, cancellation, lock contention and kill/restart tests |
| `workflows/Weather.hs` | Public application facade and three-task orchestration |
| `workflows/Weather/Types.hs`, `Forecast.hs`, `Advice.hs`, `Output.hs`, `Cli.hs` | Focused application types, HTTP validation, pure rendering, durable writer, argument/path handling |
| `workflows/Weather/Cli/Internal.hs` | Testable application error boundary preserving all asynchronous cancellations |
| `workflows/WeatherWorkflow.example.hs` | Runnable thin Main script, stderr failures and stdout success path |
| `workflows/test/Main.hs`, `TestSupport.hs`, `ForecastTests.hs`, `AdviceTests.hs`, `IntegrationTests.hs`, `CliTests.hs` | Separate offline application tests |
| `workflows/test/fixtures/forecast.json`, `checklist.txt` | Valid provider response and exact rendering golden fixture |
| `scripts/test-weather.sh`, `scripts/test-weather-cli.sh` | Project-aware offline test and relocated-script verification commands |
| `.github/workflows/ci.yml` | Build and run both suites without live forecast requests |
| `README.md`, `duraflow-core/README.md`, `workflows/README.md` | Implemented guarantees, caveats, commands, recovery and version discipline |

Internal modules stay Cabal `other-modules`, not exposed library API. The core tests may compile internal source through `hs-source-dirs: test, src`; enumerate those modules rather than publishing test seams. Small application submodules keep the required `Weather` facade understandable without adding an application Cabal package.

### Task 1: Pin and verify the dependency closure

**Files:** Modify `stack.yaml`, create `stack.yaml.lock`, modify `duraflow-core/duraflow.cabal` and `nix/dev-shell.nix` if native library discovery requires it.

**Interfaces:** Produces a verified exact-GHC project build and package environment for all later tasks. Core consumes only `base`, `aeson`, `bytestring`, `text`, `directory`, `filepath`, `filelock`, `unix`; weather additionally consumes `http-client`, `http-client-tls`, `time`. Test-only dependencies may include `process` for handshake helpers; do not introduce a weather dependency into the core library.

- [x] Step 1. Record baseline compiler and empty suite behavior.

```sh
nix develop --no-write-lock-file --command ghc --numeric-version
nix develop --no-write-lock-file --command stack test
```

Expected compiler is exactly `9.10.3`; current placeholder suite passes. Select `lts-24.59`, whose snapshot SHA256 is `0f728e30e843d7f00460ad56858b995a3b227fca683659c7df9f2fc3988a3ce1` and size is `732465` bytes. Preserve all existing `system-ghc`, `install-ghc`, `compiler-check`, and `nix.enable` settings.

- [x] Step 2. Set `resolver: lts-24.59`, pinning that content hash in generated `stack.yaml.lock`. Add the core dependency family to the library and internal test suite with compatible bounds selected from that snapshot. All required packages are in this snapshot, so no extra dependencies are necessary. Do not change `flake.lock`. If native zlib discovery fails, add pinned Nix zlib to the shared development shell and export `EXTRA_INCLUDE_DIRS` and `EXTRA_LIB_DIRS` or a verified equivalent consumed by Stack, rather than introducing host-system search paths.

```yaml
system-ghc: true
install-ghc: false
compiler-check: match-exact
notify-if-nix-on-path: false
nix:
  enable: false
```

- [x] Step 3. Validate dependency resolution before writing runtime code. Build the local core and the application packages, then load all required modules in a temporary smoke script.

```sh
nix develop --no-write-lock-file --command stack build --test --no-run-tests
nix develop --no-write-lock-file --command stack build http-client http-client-tls
nix develop --no-write-lock-file --command stack runghc --package duraflow --package aeson --package filelock --package unix --package http-client --package http-client-tls --package time -- /tmp/duraflow-dependency-smoke.hs
```

The smoke script imports `Duraflow`, `Data.Aeson`, `System.FileLock`, `System.Posix.Unistd`, `Network.HTTP.Client`, `Network.HTTP.Client.TLS`, and `Data.Time`, with `main = putStrLn "dependency closure loaded"`. The expected output is exactly that line. Store exact successful commands and selected versions in the task report. Verify commands without manual native include/library flags after adjusting the Nix shell, so CI and user commands use the same working environment.

- [x] Step 4. Commit only dependency configuration and the finalized plan dependency details.

```sh
git add stack.yaml stack.yaml.lock nix/dev-shell.nix duraflow-core/duraflow.cabal docs/superpowers/plans/2026-09-14-weather-workflow-mvp.md
git commit -m "build: pin weather workflow dependency closure"
```

### Task 2: Implement strict snapshot storage and permanent execution locks

**Files:** Create `Duraflow/Internal/Types.hs`, `Snapshot.hs`, `Storage.hs` under `duraflow-core/src/`; create `TestSupport.hs`, `SnapshotTests.hs`, `StorageTests.hs` under `duraflow-core/test/`; modify `duraflow-core/test/Main.hs` and `duraflow-core/duraflow.cabal`.

**Interfaces:** Define these common types. ID constructors are available to callers; validate at the runtime/store boundary, never silently trim values.

```haskell
newtype ExecutionId = ExecutionId Text deriving (Eq, Show)
newtype TaskId = TaskId Text deriving (Eq, Show)
data RunConfig = RunConfig
  { stateDirectory :: FilePath
  , executionId :: ExecutionId
  , workflowName :: Text
  , workflowVersion :: Text
  } deriving (Eq, Show)
data DuraflowError
  = InvalidConfiguration Text
  | ExecutionBusy ExecutionId
  | ExecutionMismatch ExecutionId Text
  | InvalidState ExecutionId Text
  | ReplayMismatch ExecutionId Int (Maybe TaskId) Text
  | StorageFailure ExecutionId Text
  | TaskFailure ExecutionId Int TaskId Text
  deriving (Eq, Show)
data TaskStatus = Running | Success Value | Failed Text deriving (Eq, Show)
data TaskRecord = TaskRecord
  { recordTaskId :: TaskId, recordInput :: Value, recordStatus :: TaskStatus
  } deriving (Eq, Show)
data Snapshot = Snapshot
  { snapshotExecutionId :: ExecutionId
  , snapshotWorkflowName :: Text
  , snapshotWorkflowVersion :: Text
  , snapshotWorkflowInput :: Value
  , snapshotCompleted :: Bool
  , snapshotTasks :: [TaskRecord]
  } deriving (Eq, Show)
```

Make `DuraflowError` an `Exception`. Provide `validateRunConfig :: RunConfig -> Either Text ()`, `validateTaskId :: TaskId -> Either Text ()`, `encodeSnapshot :: Snapshot -> ByteString`, `decodeSnapshot :: ByteString -> Either Text Snapshot`. ByteString here is strict. `encodeSnapshot` writes `schemaVersion = 1`; it is not a mutable public configuration value.

Storage exports an internal `Store` and these operations:

```haskell
withExecutionStore :: StorageOps -> RunConfig -> (Store -> IO a) -> IO a
readSnapshot :: Store -> IO (Maybe Snapshot)
commitSnapshot :: Store -> Snapshot -> IO ()
recoverSnapshot :: Store -> IO ()
storeRunConfig :: Store -> RunConfig
productionStorageOps :: StorageOps
```

`storeRunConfig` contains the canonical state directory. `readSnapshot` validates the entry and strict schema, but does not repair it. `recoverSnapshot` synchronizes the existing canonical file and then its directory. `StorageOps` is an internal injectable record of write, file synchronization, replacement, and directory synchronization operations; no global mutable fault switches and no test seam in the public facade. Each operation keeps its own path/handle parameters so tests can wrap real operations and fail a chosen transition.

- [x] Step 1. Write schema and path-validation tests before the implementation. Build fixtures with Aeson values, not brittle encoded-object key order. The tests must assert actual rejection or decoded equality.

```haskell
let sid = ExecutionId "example-1"
    state = Snapshot sid "workflow" "1" (object ["n" .= (1 :: Int)]) False []
assertEqual "round trip" (Right state) (decodeSnapshot (encodeSnapshot state))
assertLeft "unsupported schema" (decodeSnapshot "{\"schemaVersion\":2}")
assertLeft "path execution id" (validateRunConfig (RunConfig dir (ExecutionId "../escape") "w" "1"))
```

`assertEqual`, `assertLeft`, and `withTestDirectory` belong in `TestSupport`; failed assertions throw with the case name and expected/actual values only for synthetic test fixtures. Cover empty and 129-character IDs, non-ASCII IDs, valid punctuation after an initial ASCII alphanumeric, blank workflow name/version/task IDs, exact untrimmed values, every missing/unexpected field, field type errors, all statuses, extra status-specific fields, error text over 2048 characters, duplicate IDs, unfinished-middle histories, and completed unfinished histories. Application JSON values remain opaque.

- [x] Step 2. Run `nix develop --no-write-lock-file --command stack test`; record the initial missing API or failing assertion. Implement the types and schema parser with exact key-set checks for snapshot and status-dependent records. Aeson structural Value equality is the compatibility relation. Reject invalid saved metadata and histories, rather than trusting internal constructors.

```haskell
-- The record schema is deliberately status dependent.
-- Running: taskId,input,status
-- Success: taskId,input,status,output
-- Failed:  taskId,input,status,error
-- Snapshot: schemaVersion,executionId,workflowName,workflowVersion,
--           workflowInput,completed,tasks
```

- [x] Step 3. Add failing storage tests using real temporary directories and wrapped `StorageOps`. Record an event list and inject failures at write, file sync, replace, directory sync, and recovery file/directory barriers. Assert the old complete snapshot remains before replacement and the new complete snapshot is visible after a post-replacement failure. Never infer that a reported failure means replacement did not happen. Assert leftover temporary files are ignored.

```haskell
withExecutionStore productionStorageOps cfg $ \store -> do
  commitSnapshot store state
  assertEqual "canonical snapshot" (Just state) =<< readSnapshot store
  recoverSnapshot store
```

Tests must also check owner-only mode bits for new lock, snapshot, and the temporary file while the write callback sees it; reject symlink, directory, and FIFO snapshot/lock entries without opening or blocking on them. Check a directory symlink resolves to the same store. The permanent lock inode must remain unchanged across two invocations and never be unlinked during cleanup.

- [x] Step 4. Implement the storage protocol. Validate config, canonicalize an existing directory, derive only the validated filename components, reject unsafe entries with POSIX `lstat`, and provision the permanent lock privately before `tryLockFile Exclusive`. Use a nonblocking lock for the callback lifetime and `bracket`/`mask` for ownership cleanup. New files use mode 0600 without changing process-global umask. Use unique same-directory temporary files, force all encoded bytes before beginning their write, synchronize through a file descriptor, close, rename, then synchronize the directory. Cleanup removes only this operation's temporary file. Do not delete the lock and do not roll back after rename. Re-throw asynchronous exceptions; classify synchronous filesystem errors as `StorageFailure` without dumping state.

- [x] Step 5. Run all core tests and confirm no compiler warnings. Commit the storage deliverable.

```sh
nix develop --no-write-lock-file --command stack test
git add duraflow-core
git commit -m "feat: add strict durable execution snapshot storage"
```

### Task 3: Implement sequential task replay, failure and cancellation semantics

**Files:** Create `duraflow-core/src/Duraflow/Internal/Runtime.hs`, `duraflow-core/test/RuntimeTests.hs`, `duraflow-core/test/ProcessTests.hs`; modify `duraflow-core/src/Duraflow.hs`, `duraflow-core/test/Main.hs`, `TestSupport.hs`, and Cabal module lists.

**Consumes:** Task 2 types, `withExecutionStore`, snapshot read/commit/recovery operations and injectable `StorageOps`.

**Produces:** The exact public signatures below and an internal `runWorkflowWith :: ToJSON input => StorageOps -> RunConfig -> input -> (input -> Workflow output) -> IO output` for fault tests. `Duraflow` exports only `ExecutionId(..)`, `TaskId(..)`, `RunConfig(..)`, `DuraflowError(..)`, abstract `Workflow`, `runWorkflow`, and `task`.

```haskell
runWorkflow :: ToJSON input => RunConfig -> input -> (input -> Workflow output) -> IO output
task :: (ToJSON input, ToJSON output, FromJSON output)
     => TaskId -> input -> (input -> IO output) -> Workflow output
```

- [x] Step 1. Add failing real-runtime tests with IORef action counters and actual persisted snapshots. Start with success, failure in task two, and replay.

```haskell
let flow () = do
      a <- task (TaskId "one") () (\() -> modifyIORef' calls (+1) >> pure (7 :: Int))
      task (TaskId "two") a (\n -> pure (n + 1))
first <- runWorkflow cfg () flow
second <- runWorkflow cfg () flow
assertEqual "workflow result" (8, 8) (first, second)
assertEqual "successful action skipped" 1 =<< readIORef calls
```

Use a second case where task two fails once, and task three appends a marker. Assert task three never runs on the first invocation; rerun invokes task two exactly once, preserves task one's saved output, and completes. Run the focused tests and record RED evidence.

- [x] Step 2. Implement Workflow as a private environment-passing IO computation with an invocation-local cursor and snapshot reference. Its Functor, Applicative and Monad instances sequence through the same environment; do not export its constructor or general IO lifting. Encode and fully force workflow input before initializing or comparing metadata. Under the lock, validate metadata and structural JSON input, synchronize a valid existing snapshot, or commit a new empty identity snapshot. Evaluate orchestration afresh each invocation.

For a task, validate and force its input before actions. Detect duplicates within the invocation separately from the history cursor. Match saved ID/input before using a record. Decode a successful output without executing the action; an incompatible decode is `ReplayMismatch`. For a retry or append, commit `Running` before restoring interruption for the action. Force the entire encoded output in the action-exception boundary. Commit an ordinary failure as `Failed` then throw `TaskFailure`; preserve the original failure context if this commit instead fails with `StorageFailure`. Keep the success commit outside the action catch so storage errors never become task failures. Update in-memory state only after committed transitions. An outer exception skips completion validation. On normal return require all old records consumed; commit completion unless already completed. Completed histories reject appended tasks.

- [x] Step 3. Add negative replay tests, then implement only missing behavior. Assert no action counter increments for metadata mismatch, structural-input mismatch, changed IDs/order/inputs, invalid task ID, duplicate invocation ID, corrupt/unknown schema, invalid history, undecodable success, and appended task after completion. Assert a normal shortened orchestration fails but an orchestration exception is not replaced by a missing-old-task error. Test zero tasks, application output without a ToJSON instance, and a workflow input object whose key ordering changes. Exceptions outside tasks propagate intact. Encoding exceptions become task failure only when encoding a task output, before success is committed.

- [x] Step 4. Add process and injection tests before tightening interruption behavior. Child modes in the same test executable use POSIX pipes or flushed line-oriented stdin/stdout handshakes. Never use a guessed sleep to decide a child holds a lock or committed Running. The parent waits for an explicit action-start message, then launches a contender or kills the child and waits for termination. Bound each wait so a regression fails instead of hanging CI.

Test same-ID busy with no action, independent different IDs, killed Running resume, completed earlier tasks skipped, cancellation and lock release, and no partial canonical JSON. Inject every commit phase around Running, Success and failure recording. Assert no action starts after a failed Running commit, no dependent action starts after a failed Success commit, and recovery barrier failure prevents cached reuse and new actions. Inject a failed success commit after an effect, rerun, and assert the effect count reaches two. Assert an external asynchronous exception is never saved as Failed.

- [x] Step 5. Run the complete core suite once before committing. The test executable prints named case results and exits nonzero on any failure.

```sh
nix develop --no-write-lock-file --command stack test
git add duraflow-core
git commit -m "feat: implement checkpointed workflow replay and manual retry"
```

### Task 4: Implement weather contracts, pure advice and the durable checklist writer

**Files:** Create `workflows/Weather.hs`, `Weather/Types.hs`, `Weather/Forecast.hs`, `Weather/Advice.hs`, `Weather/Output.hs`, application `test/Main.hs`, `TestSupport.hs`, `ForecastTests.hs`, `AdviceTests.hs`, and fixtures `forecast.json`, `checklist.txt`.

**Consumes:** Public Duraflow API from Task 3. No imports of core internal modules in application code.

**Produces:** Define and export through `Weather` the following application types and functions. JSON instances save the complete values and support replay round trips. `Day`, `UTCTime` use `time`; coordinates and metrics are Double, all validated before a forecast is returned.

```haskell
data WeatherRequest = WeatherRequest
  { requestedLatitude :: Double, requestedLongitude :: Double
  , forecastDate :: Day, outputPath :: FilePath
  } deriving (Eq, Show, Generic)
data ForecastUnits = ForecastUnits
  { timeUnit :: Text, temperatureUnit :: Text, precipitationUnit :: Text
  , windUnit :: Text, uvUnit :: Text
  } deriving (Eq, Show, Generic)
data Forecast = Forecast
  { forecastRequest :: WeatherRequest
  , forecastUnits :: ForecastUnits
  , providerLatitude :: Double, providerLongitude :: Double
  , minimumTemperature :: Double, maximumTemperature :: Double
  , rainProbability :: Double, maximumWindSpeed :: Double, maximumUvIndex :: Double
  , provider :: Text, requestUrl :: Text, retrievedAt :: UTCTime
  } deriving (Eq, Show, Generic)
data Checklist = Checklist
  { checklistForecast :: Forecast, checklistItems :: [Text]
  } deriving (Eq, Show, Generic)
data WeatherEffects = WeatherEffects
  { getForecast :: WeatherRequest -> IO Forecast
  , putChecklist :: (FilePath, Checklist) -> IO FilePath
  }
weatherWorkflowName, weatherWorkflowVersion :: Text
weatherPreparationWith :: WeatherEffects -> WeatherRequest -> Workflow FilePath
weatherPreparation :: WeatherRequest -> Workflow FilePath
fetchForecast :: WeatherRequest -> IO Forecast
prepareAdvice :: Forecast -> Checklist
renderChecklist :: Checklist -> Text
writeChecklist :: (FilePath, Checklist) -> IO FilePath
```

Save normalized units explicitly through `forecastUnits`; both temperature metrics use `temperatureUnit`. Public field names above must remain consistent across tests and CLI. The effects record changes the provider/writer implementations, not the workflow task inputs. `weatherPreparationWith` uses exactly the three specified task IDs; `prepareAdvice` is executed through `pure . prepareAdvice` in a task.

Internal forecast interfaces:

```haskell
forecastUrl :: WeatherRequest -> Text
parseForecast :: WeatherRequest -> Text -> UTCTime -> ByteString -> Either Text Forecast
fetchForecastWith :: Int -> (Text -> IO (Int, ByteString)) -> IO UTCTime -> WeatherRequest -> IO Forecast
```

ByteString is strict. The Int is the elapsed-time deadline in microseconds; production supplies `30000000`. The transport returns status and fully consumed bytes and production uses `http-client` plus `http-client-tls`, redirects disabled. `fetchForecastWith` encloses transport, complete parsing and forcing in `System.Timeout.timeout`; no broad catch may swallow external cancellation. Capture the retrieval timestamp only after successful response validation, then save it in the forecast. A temporary dummy timestamp used while validating pure structure must never escape. The injectable deadline makes timeout tests fast without changing the production limit.

- [x] Step 1. Write valid JSON and rendering fixtures and failing parsing tests. The valid response has UTC offset zero, explicit required units, at least two daily rows with the requested date second, and provider coordinates different from the request. Assert that the requested row, both coordinate pairs, URL, provider and supplied timestamp survive parsing and JSON round-trip.

```haskell
assertEqual "rain threshold" ["Bring rain protection."]
  (checklistItems (prepareAdvice (mildForecast { rainProbability = 50 })))
assertEqual "rain just below" ["No additional preparation was identified by these rules."]
  (checklistItems (prepareAdvice (mildForecast { rainProbability = 49.99 })))
```

`mildForecast` is a complete fixture Forecast with minimum 10, maximum 20, rain 0, wind 0 and UV 0. Test cold at 5 and 5.01, wind at 40 and 39.99, UV at 3 and 2.99, combinations, every rule in fixed order, and single fallback. Golden text includes requested/provider coordinates separately, all five metrics and units, date, Open-Meteo provider and saved UTC retrieval time; assert exact UTF-8 bytes, LF endings and one final newline.

- [x] Step 2. Run separate application tests before implementation to record RED. Implement application types and pure parser/advice/rendering. Request `https://api.open-meteo.com/v1/forecast` with supplied coordinates, equal ISO `start_date`/`end_date`, `timezone=UTC`, `temperature_unit=celsius`, `wind_speed_unit=kmh`, and the five daily metrics from the spec. Use URL encoding supplied by the HTTP library rather than locale-dependent formatting. Validate unit strings exactly (`iso8601`, `°C`, `%`, `km/h`, empty UV), zero UTC offset, finite bounded provider coordinates, all array lengths, explicit requested date, missing/null fields, finite values, ordered temperatures, bounded rain, and nonnegative wind/UV. Requested coordinates remain the request values even when provider grid coordinates differ.

- [x] Step 3. Add failure tests for malformed JSON, absent date, mismatched array lengths, each wrong/missing unit, nonzero UTC offset, invalid coordinates, missing/null metric, negative wind/UV, rain outside 0 through 100, inverted temperatures and invalid numeric values. Add fake-transport tests for non-2xx status, redirects reported as failure, a deadline during response acquisition and validation, and external cancellation propagation. Assert the clock is not called before response validation and the saved timestamp comes from the injected clock. Implement the production transport with no retries and redirects set to zero.

- [x] Step 4. Add writer tests using real output files. Two writes must produce identical complete content, not appended content; a failure must not expose partial target bytes. Reject symlink/nonregular targets again at writing time. Write strict UTF-8 bytes through a private unique same-directory temporary file, synchronize, close, rename and synchronize the parent. Cleanup temporary files under masking and keep actions interruptible. The writer is independent of core storage because it serves an application artifact, not an execution snapshot.

- [x] Step 5. Wire the three-task flow and run offline application tests using project-aware module/package flags. Do not move application tests into core Cabal.

```sh
nix develop --no-write-lock-file --command stack runghc --package duraflow --package aeson --package http-client --package http-client-tls --package time -- -iworkflows -iworkflows/test workflows/test/Main.hs
git add workflows
git commit -m "feat: add offline-tested weather preparation workflow"
```

### Task 5: Deliver the CLI, replay integration coverage, documentation and CI

**Files:** Create `workflows/Weather/Cli.hs`, `workflows/test/IntegrationTests.hs`, `CliTests.hs`, `scripts/test-weather.sh`, `scripts/test-weather-cli.sh`; modify application `test/Main.hs`, `workflows/WeatherWorkflow.example.hs`, the three READMEs, and `.github/workflows/ci.yml`.

**Consumes:** Public core and Weather APIs from Tasks 3 and 4. Re-export `parseArguments`, `normalizeInvocation`, and `runCli` from `Weather.Cli` for offline tests. The script imports only `runCli` and defines `main = runCli`.

```haskell
parseArguments :: [String] -> Either Text (FilePath, ExecutionId, WeatherRequest)
normalizeInvocation :: (FilePath, ExecutionId, WeatherRequest) -> IO (RunConfig, WeatherRequest)
runCli :: IO ()
```

The six positional arguments are `STATE_DIR EXECUTION_ID LATITUDE LONGITUDE YYYY-MM-DD OUTPUT_FILE`. There are no defaults. `parseArguments` must reject missing/extra arguments, nonfinite/out-of-range coordinates, and noncanonical or invalid ISO calendar dates. `normalizeInvocation` requires existing directories, canonicalizes state and output parent, constructs the absolute output path, rejects output equal to or inside state using path-component comparisons, and rejects symlink/nonregular output entries, including dangling symlinks. It preserves all request choices in the workflow input. Validate configuration before the first action. No new run/restart subcommand is introduced.

- [x] Step 1. Add failing CLI/path tests and offline integration tests. Integration injects one saved forecast and a writer that initially fails. Assert the first two records are Success and the third Failed, then rerun with a successful real writer. Assert one fetch total, original timestamp, identical deterministic checklist, and completed state. Delete the committed output and rerun; assert no fetch or write occurs and the absent artifact stays absent. Demonstrate repeatable output replacement in the external-effect/checkpoint gap using an initial writer which completes `writeChecklist` then throws before returning to core.

- [x] Step 2. Run the focused offline tests and record RED. Implement CLI parsing and normalization. Use `readMaybe` plus explicit finite/geographic checks; require exact `formatTime defaultTimeLocale "%F" parsedDay == input` after parsing. Normalize output parent before joining the basename; validate `lstat` on the final entry. Compare canonical path components rather than string prefix, so a state sibling such as `state-other` remains legal. Catch ordinary top-level errors into stderr and `exitFailure`, but rethrow external cancellation. Success prints only the absolute returned path.

- [x] Step 3. Create runnable test wrappers. They determine repository root from their own path, `cd` there, and invoke the exact verified Stack package command. The CLI shell tests build no network requests: run missing arguments and invalid requests from a temporary unrelated source directory with absolute `--stack-yaml`, script and `-i` paths. Assert nonzero exit, stderr diagnostics, empty stdout and no new execution snapshot. Cover outputs inside state, state directory aliases, symlink/nonregular output entries and absent parent directories. All helper processes have cleanup traps.

```sh
nix develop --no-write-lock-file --command bash scripts/test-weather.sh
nix develop --no-write-lock-file --command bash scripts/test-weather-cli.sh
```

- [x] Step 4. Replace scaffold descriptions in all three READMEs with implemented API and command examples. Document private caller-provisioned directories, filename rules, JSON compatibility, workflow-version discipline, replay versus fresh IDs, plaintext/sensitive state, Linux trusted-filesystem limitations, no automatic retries, at-least-once effects, saved timestamps, missing artifacts skipped on replay, separate output paths and last-writer-wins behavior. Include all explicit CLI arguments and a clear warning that the example date must be served by Open-Meteo for a fresh fetch. Keep the live command a user-invoked example, not a test. Document that test failures and SIGKILL tests do not certify hardware power-loss behavior.

- [x] Step 5. Update CI to build core and required application packages, run `stack test`, then both separate offline scripts through Nix. Retain pinned actions, cache and exact toolchain ownership. Remove obsolete placeholder-suite comments. Do not introduce credentials or a live weather call.

```yaml
- name: Build all components and application dependencies
  run: nix develop --no-write-lock-file --command stack build --test --no-run-tests http-client http-client-tls duraflow
- name: Run core tests
  run: nix develop --no-write-lock-file --command stack test
- name: Run offline weather tests
  run: nix develop --no-write-lock-file --command bash scripts/test-weather.sh
- name: Verify standalone source location and CLI validation
  run: nix develop --no-write-lock-file --command bash scripts/test-weather-cli.sh
```

- [x] Step 6. Execute those exact CI commands locally, run `git diff --check`, self-review the public API and all spec acceptance bullets, and commit. Then perform a broad independent branch review, fix its findings with regression tests, rerun affected suites and one final complete verification.

```sh
git diff --check
git add workflows scripts README.md duraflow-core/README.md .github/workflows/ci.yml
git commit -m "feat: ship weather CLI with replay integration tests and CI"
```

## Final review and PR handoff

Verify the original checkout index and pending files remain untouched. Record test results and any limitations in the PR body. Push only `feat/weather-workflow-mvp` using GitHub CLI authentication, then create a PR with `gh pr create --base main --head feat/weather-workflow-mvp`; never push directly to main or merge. Include the spec and plan links, dependency pin, core and weather checks, durability limitations, and a statement that no live forecast smoke test was run. The user requested execution and a PR, so do not pause for another execution-choice prompt.

## Execution and verification record

All five implementation tasks completed in the isolated feature worktree based on `origin/main` at `3c8871a`. Each task passed independent specification and quality review. Whole-branch review and the final scoped fix review approved the implementation through `a9b8944`, with no outstanding Critical, Important, or deferred findings.

Review-driven regressions cover lazy cached decode failures, broad asynchronous CLI cancellation, lock arbitration before workflow-input encoding, interruptible serialization with lock release, and CLI test rejection of compiler/startup failures. Internal core modules remain hidden from consumers.

Final controller verification reran every CI-equivalent command above successfully. Counts were measured from the actual successful test output: **41 core test groups**, **16 offline weather test groups**, and **9 standalone invalid CLI scenarios**, plus the wrapper's compiler-failure regression. The fix worker's earlier count of 42 core groups double-counted an extended existing case; 41 is the verified total.

Both the application test entrypoint and runnable example also passed `ghc -Wall -Werror -fno-code` using the pinned environment and explicit application packages. `git diff --check` passed. Stack's informational Aeson package-revision warning does not represent a GHC source warning or an unpinned dependency.

The original checkout's staged files and pending `.gitignore` change were preserved. The accidentally committed scratch report was removed from the final tracked diff. The feature worktree remains available for PR feedback.

No live Open-Meteo smoke test was run. Tests exercise Linux local-filesystem operations, injected failures, process termination, and replay; they do not certify physical power-loss behavior. External effects remain at-least-once, and replay of a committed checklist write intentionally does not recreate an externally removed artifact.
