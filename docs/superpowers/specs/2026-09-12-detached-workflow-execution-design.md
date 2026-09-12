# Detached Workflow Execution Design

**Date:** 2026-09-12  
**Status:** Proposed  
**Scope:** A small, local, Temporal-style durable workflow runtime

## Summary

Duraflow should represent an open workflow as durable data, not as a permanently attached process. A workflow process runs only long enough to make progress. When it reaches an unresolved activity, timer, or signal, the engine persists what it is waiting for, asks the process to exit, and releases the worker slot.

When the awaited event arrives, Duraflow queues another workflow task. Any available worker can launch the workflow again. The workflow replays from the beginning, completed operations return their recorded values, and execution continues after the resolved wait.

```text
launch workflow
      |
      v
replay recorded operations
      |
      v
make progress until blocked
      |
      +-- completed ----------------------> persist result
      |
      +-- unresolved activity/timer/signal
                    |
                    v
              persist wait + exit
                    |
              no attached worker
                    |
              completion/wake event
                    |
                    v
              enqueue workflow task
```

This design applies Temporal's core execution idea without attempting to reproduce Temporal's distributed platform, operational tooling, or full API.

## Goals

- Release workflow worker slots while workflows wait for unknown-duration events.
- Resume a workflow on any compatible worker rather than the worker that started it.
- Preserve ordinary sequential-looking workflow code through restart and replay.
- Separate deterministic workflow orchestration from nondeterministic external work.
- Make activities, timers, signals, retries, and wakeups durable and race-safe.
- Bound workflow and activity concurrency independently.

## Non-goals

- Distributed consensus or multi-region replication.
- Exactly-once external side effects.
- Arbitrary serialization of Python closures, stacks, threads, or interpreter state.
- Compatibility with Temporal SDKs or its wire protocol.
- A graphical workflow editor or operations UI.
- Running untrusted workflow code in a security sandbox.

## Core model

Duraflow has five distinct responsibilities:

1. **Workflow task worker** launches and replays workflow code until it completes or suspends.
2. **Activity worker** performs external or nondeterministic work independently.
3. **Scheduler/reconciler** creates scheduled runs and resolves expired timers, deadlines, and leases.
4. **Durable store** owns run history, task queues, activity results, and wait state.
5. **Client SDK** turns sequential workflow calls into protocol commands.

```text
                    +----------------------+
cron/systemd ------>| scheduler/reconciler |
                    +----------+-----------+
                               |
                               v
+----------------+     +-------+--------+     +----------------+
| workflow worker|<--->| durable store  |<--->| activity worker|
+-------+--------+     +-------+--------+     +----------------+
        |                      ^
        v                      |
+----------------+             |
| workflow client|-------------+
| subprocess     |
+----------------+
```

The scheduler never runs workflow code. Workflow workers never perform long external operations. Activity workers never decide workflow control flow.

## Durable history

Each run has an append-only, sequence-numbered history. The exact storage implementation may initially be an atomically published file, but its behavior must match a transactional log.

Example history:

```json
[
  {"seq":1,"type":"workflow_started","inputs":{"order_id":42}},
  {"seq":2,"type":"activity_scheduled","id":"load-order","activity":"load_order","args":{"order_id":42}},
  {"seq":3,"type":"activity_completed","id":"load-order","result":{"status":"pending"}},
  {"seq":4,"type":"timer_started","id":"poll-delay","fire_at":"2026-09-12T12:05:00Z"},
  {"seq":5,"type":"timer_fired","id":"poll-delay"}
]
```

A history append and any related state transition must be committed atomically. A client acknowledgment is sent only after that commit.

## Restart and replay

The engine does not serialize the Python stack. It relaunches the workflow from line one and answers commands using history.

Example workflow:

```python
def order_workflow(ctx):
    order = ctx.activity(
        "load-order",
        activity="load_order",
        args={"order_id": ctx.inputs["order_id"]},
    )

    ctx.sleep("poll-delay", seconds=300)

    return ctx.activity(
        "check-order",
        activity="check_order",
        args={"order_id": order["id"]},
    )
```

On the first launch, `load-order` is scheduled and the workflow suspends. After the activity completes, another launch replays `load-order`, receives its stored result, reaches `poll-delay`, records the timer, and suspends again. After the timer fires, a third launch replays both resolved operations and schedules `check-order`.

```text
Launch 1: load-order -> unresolved -> suspend
Launch 2: load-order -> saved; poll-delay -> unresolved -> suspend
Launch 3: load-order -> saved; poll-delay -> fired; check-order -> unresolved
Launch 4: replay all resolved operations -> finish
```

## Replay determinism

During replay, the client must issue the same durable commands in the same order with the same stable IDs and equivalent arguments. The engine compares each command with the next history event. A mismatch fails the workflow with a nondeterminism error and performs no new external work.

Unsafe example:

```python
# Different branches could be selected during replay.
if random.random() > 0.5:
    ctx.activity("branch-a", "send_a", {})
else:
    ctx.activity("branch-b", "send_b", {})
```

Safe example:

```python
choose_a = ctx.side_effect("choose-branch", lambda: random.random() > 0.5)

if choose_a:
    ctx.activity("branch-a", "send_a", {})
else:
    ctx.activity("branch-b", "send_b", {})
```

`ctx.side_effect` executes once, records its JSON result, and returns that result on replay. Equivalent durable APIs must exist for workflow time, generated IDs, and other nondeterministic values.

External effects outside activities or recorded side effects are unsupported because replay could repeat them.

## Activities

An activity is named, separately executable work with JSON inputs and output. It replaces an in-process callback for operations that may be slow or nondeterministic.

```python
report = ctx.activity(
    "generate-report",
    activity="generate_report",
    args={"account_id": "acct-17"},
    timeout="10m",
    retry={"maximum_attempts": 3},
)
```

The workflow client sends:

```json
{"v":1,"type":"request_activity","id":"generate-report","activity":"generate_report","args":{"account_id":"acct-17"},"timeout_seconds":600}
```

If no result exists, the engine atomically appends `activity_scheduled`, creates an activity task, records that the workflow is waiting for it, and replies:

```json
{"v":1,"type":"suspend","reason":"activity","wait_id":"generate-report"}
```

The workflow process exits successfully. An activity worker later claims and runs the task:

```text
activity pending -> running -> completed
                            \-> failed
                            \-> timed_out
```

Completion atomically records the outcome and enqueues a workflow task. On replay, the same activity request returns:

```json
{"v":1,"type":"resolved","result":{"report_url":"file:///reports/acct-17.json"}}
```

A Python closure such as `ctx.step("x", lambda: work())` cannot be detached because its executable state is not safely serializable. It may remain as a short local operation, but long-running work must use registered activities.

## Timers

A durable timer records a deadline and suspends the workflow. No Python process sleeps.

```python
ctx.sleep("retry-delay", seconds=300)
```

First encounter:

```text
append timer_started(fire_at=12:05)
set run waiting_timer
exit workflow process
release workflow slot
```

At or after 12:05, the reconciler atomically appends `timer_fired` and queues a workflow task. Replay then lets `ctx.sleep` return immediately.

The fire time is calculated once and stored. Replay must not calculate a new deadline from the current wall clock.

## Signals

Signals deliver external data to an open workflow. Signals are buffered durably even if the workflow has not reached its wait yet.

```python
approval = ctx.wait_signal("manager-approval")

if approval["approved"]:
    return ctx.activity("purchase", "purchase_item", approval)
return {"status": "rejected"}
```

An operator or API sends:

```bash
duraflow signal RUN_ID manager-approval '{"approved":true,"limit":500}'
```

The command appends a `signal_received` event. If the run is currently waiting for that signal, it also queues a workflow task. If the signal arrives early, replay consumes the buffered event when `ctx.wait_signal` is reached.

Signals with the same name are ordered by event sequence. The initial API consumes one signal per `wait_signal` call.

## Suspension protocol

Suspension is a successful workflow-task outcome, not a workflow failure.

```python
class SuspendWorkflow(Exception):
    pass


def run(workflow):
    ctx = Context()
    try:
        result = workflow(ctx)
    except SuspendWorkflow:
        ctx.send("suspended")
        return
    ctx.send("finish", result=result)
```

Engine/client exchange:

```text
Client: request_activity
Engine: persist schedule + wait state
Engine: suspend
Client: suspended
Client process exits 0
Engine: run remains waiting_activity
```

`finish` means the entire workflow completed. `suspended` means the current workflow task completed but the run remains open.

## Scheduler and wakeups

An external timer invokes a stateless command regularly:

```cron
* * * * * duraflow tick
```

A tick performs only bounded durable state transitions:

```text
1. Create due scheduled workflow runs.
2. Fire expired durable timers.
3. Mark expired activity attempts timed out.
4. Recover expired worker leases.
5. Queue workflow tasks affected by those events.
6. Exit without running workflow code.
```

Activity completion and signals wake workflows directly; they do not wait for the next tick. Tick is required only for time-based conditions and recovery.

Example unknown-duration wait:

```text
10:00 workflow schedules ask-model activity and exits
10:00 activity worker begins model request
10:03 model responds
10:03 activity completion queues workflow immediately
10:03 workflow worker replays and continues
```

The workflow does not need to predict that the activity will take three minutes.

## Concurrent ticks

Correctness must not depend on ticks avoiding overlap. Every scheduled occurrence has a deterministic identity:

```text
weather-report:2026-09-12T15:10:00Z
```

Two ticks may calculate the same occurrence, but atomic create-if-absent semantics permit only one run.

```text
Tick A: create occurrence X -> created
Tick B: create occurrence X -> already exists, skip
```

Overlap-policy checks and run creation occur under the same per-workflow scheduler lock or database transaction. A global tick lock may be used initially for simplicity, but deterministic identities and atomic creation remain required for crash recovery and future concurrency.

## Worker model and concurrency

A worker is a process managing bounded pools; it is not synonymous with one operating-system thread.

```text
Duraflow worker process
├── workflow task slots: 100
│   ├── short launch/replay/suspend task
│   └── no slot retained while waiting
└── activity slots: 20
    ├── HTTP request
    ├── model invocation
    └── subprocess
```

Example with 10,000 open workflows:

```text
9,980 waiting on timers/signals/activities -> zero workflow slots
   20 ready workflow tasks                -> up to 20 active slots
```

Workflow and activity limits are separate because workflow tasks should be short while activities may be slow or resource-heavy. Workers pull tasks only when their relevant pool has capacity.

## Claiming, leases, and recovery

Task claiming must be atomic. A claimed task records an owner and renewable lease:

```json
{
  "status":"running",
  "worker_id":"worker-7",
  "lease_until":"2026-09-12T12:01:00Z"
}
```

If a worker crashes, the reconciler waits for the lease to expire before returning the task to pending. Before retrying subprocess work, the runtime must ensure the previous process group is gone. Production isolation may require cgroups or containers; a file lock cannot terminate an orphan process.

Late results include the activity ID and attempt number. A result from an expired attempt cannot overwrite a newer accepted attempt.

## Timeouts, retries, and cancellation

Activities support independent timeouts and retry policies:

```python
result = ctx.activity(
    "fetch-data",
    "fetch_data",
    {"url": url},
    timeout="30s",
    retry={
        "maximum_attempts": 4,
        "initial_backoff": "1s",
        "maximum_backoff": "30s",
    },
)
```

Timeout processing records a durable outcome before retrying:

```text
attempt 1 running
-> activity_timed_out
-> retry_timer_started
-> retry_timer_fired
-> attempt 2 pending
```

A retry is another durable state transition, not a sleeping worker thread. After exhaustion, replay raises a typed `ActivityFailure` in workflow code.

Workflow cancellation records `cancel_requested`, cancels pending tasks, asks active workers to terminate their work, and queues the workflow so it can observe cancellation. Force termination may skip workflow cleanup and is a separate administrative operation.

## Race-safety invariants

The implementation must preserve these invariants:

1. Each history event has a unique, monotonically increasing sequence number.
2. History append and the corresponding run/task state update commit atomically.
3. An acknowledgment is never sent before durable commit.
4. Each schedule occurrence is created at most once.
5. Each workflow waits on a stable event or task ID.
6. Activity results are accepted only for the current attempt.
7. Signals are persisted before any wake-up notification.
8. Queue notification is only an optimization; persisted pending state is the source of truth.
9. Replay mismatch performs no new activity or side effect.
10. Worker lease expiration permits recovery but does not imply the old external process is dead.

## Storage direction

The first implementation may use local files and OS locks, provided it offers:

- append-or-rewrite under an exclusive per-run lock;
- write temporary file, fsync, atomic rename, and fsync directory;
- atomic create-if-absent for task and schedule identities;
- explicit schema and event versions;
- recovery scans for pending work and expired leases.

A database implementation may later replace the store behind the same transaction-oriented interface. The workflow/client protocol must not depend on file paths or storage format.

## Suggested delivery phases

1. **Replay foundation:** versioned history, deterministic command matching, workflow-task queue.
2. **Durable timers:** suspend, process exit, tick wake-up, relaunch, and replay.
3. **Signals:** buffered delivery and direct wake-up.
4. **Named activities:** separate activity registry, queue, worker pool, and result wake-up.
5. **Reliability:** leases, timeouts, retries, cancellation, and stale-result rejection.
6. **Scale:** multiple worker processes and a transactional database-backed store if required.

Timers come before activities because they prove the central detach/relaunch/replay mechanism without introducing a second execution registry and worker pool.

## Success criteria

The design is successful when the following scenario works without retaining an attached workflow process:

```python
def workflow(ctx):
    forecast = ctx.activity("forecast", "fetch_forecast", ctx.inputs)
    ctx.sleep("cooldown", seconds=300)
    approval = ctx.wait_signal("approval")
    return ctx.activity(
        "publish",
        "publish_report",
        {"forecast": forecast, "approval": approval},
    )
```

During each unresolved operation, the workflow process exits and its slot is released. Activity completions, timer firing, and signal delivery each make the run pending. Any compatible worker can relaunch it, replay produces the same durable command sequence, completed results are reused, and the final result is committed exactly once to Duraflow's store.
