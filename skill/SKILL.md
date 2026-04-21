---
name: task-check
description: |
  Reads the workspace's task-board.md, heals any deadlocked running tasks,
  resolves dependency blockers, executes all Claude-assigned `ready` tasks
  in parallel (with retry + dead-letter on failure), and writes a report.
  Pairs with an `/loop` schedule or a launchd watcher for full automation.

  Trigger phrases: `/task-check`, "check tasks", "any tasks for me".
---

# task-check — parallel + self-healing + fault-tolerant

You are the task-board executor. Workflow:

> read board → clean deadlocks → execute `ready` tasks in parallel →
> handle failures → write report.

---

## Step 0 · Self-healing scan

Before doing anything else, **check for deadlocked tasks**:

1. Read the task-board.
2. Find every task whose `Status:` matches `running:{agent-id}:{iso8601-ts}`.
3. For each such task, compute `now - ts`:
   - **> 30 minutes** → treat as deadlocked (the process died without updating state).
     - Reset `Status` to `ready`.
     - Append to `Notes`: `[{current-ts}] lock_stale_removed: previous running since {ts} by {agent-id} exceeded 30min`.
     - Emit event: `{"event":"lock_stale_removed","task_id":"...","previous_agent":"...","age_minutes":N}`.
4. If a task has been reset multiple times (its `Notes` contain more than one `lock_stale_removed` entry) and is still running > 60 minutes → escalate to `failed:repeated_deadlock` and write a dead-letter entry.

---

## Step 1 · Read and parse the board

Read `${WORKSPACE_ROOT}/task-board.md`.

For each `## [TASK-XXX]` heading, parse:

- `Who:` · `Status:` · `Priority:` · `Notes:`
- `retries: N` (if present in Notes)

**Canonical `Status` grammar**:

```
ready
blocked:human:{what-is-pending}
blocked:task:TASK-XXX
blocked:external:{what}
running:{agent-id}:{iso8601-ts}
done
cancelled:{reason}
failed:{reason}
```

The `blocked:human:*` form means a human teammate is the blocker; a common
convention is to make `{what-is-pending}` a short verb phrase like
`blocked:human:reply-to-client` or `blocked:human:review-draft`.

---

## Step 2 · Resolve dependencies

For every task whose status is `blocked:task:TASK-XXX`:

- If TASK-XXX is now `done` → promote current task to `ready`. Emit event `dependency_resolved`.
- If TASK-XXX is `failed` or `cancelled` → escalate current task to `blocked:human:dependency-broken`. Emit event + surface in the report.

---

## Step 3 · Filter and batch

From the parsed pool, select tasks where:
- `Who` includes Claude
- `Status` is `ready`

Sort by `Priority` (P0 > P1 > P2 > P3), then by TASK-ID ascending.

**Dependency-aware batching**:
- Tasks with ordering dependencies (one's `Measure` or `Notes` references another's deliverable) go into different batches.
- Independent tasks go into the same batch and run in parallel.

**Concurrency cap**: at most **3 subagents per batch**.

If the pool is empty, skip to Step 6.

---

## Step 4 · Batch execution

For each batch:

1. **Atomically update Status** — a single `Edit` pass that flips every task in the batch from `ready` to `running:{agent-id}:{ts}`. Each task gets a unique agent-id (e.g. `sub-TASK-007-abc123`).
   - **The main Claude is the only writer of task-board.md.** Subagents only produce results and return them; they never edit the board themselves.

2. **Launch subagents in parallel** via the `Agent` tool (all tool calls in one message → real parallelism).
   - Pass each subagent: task ID, `Measure`, input context, and an explicit output path for any deliverables.
   - Subagents **only** execute their task and return structured results (success/failure + output path + short summary).

3. **Wait for the batch to finish** (Agent parallel calls block until every subagent returns).

4. **Process results serially** in the main thread:
   - Success → set Status to `done`. Append deliverable path to Notes.
   - Failure → see Step 5.

---

## Step 5 · Failure handling, retry, dead-letter

For each failed task:

1. Parse `retries: N` from Notes (default 0 if missing).
2. If `retries < 2`:
   - Set Status back to `ready`.
   - Append to Notes: `retries: {N+1}`, `last_failure: {reason}`.
   - Emit `task_retry_scheduled`.
3. If `retries >= 2`:
   - Set Status to `failed:exhausted_retries`.
   - Write a dead-letter JSON file:
     ```
     ${WORKSPACE_ROOT}/.task-router/state/deadletter/{TASK-XXX}-{YYYYMMDD-HHMMSS}.json
     ```
     with content:
     ```json
     {
       "task_id": "TASK-XXX",
       "title": "...",
       "priority": "...",
       "final_status": "failed:exhausted_retries",
       "retry_history": [...],
       "last_failure_reason": "...",
       "last_agent_output": "...",
       "moved_at": "iso8601-ts"
     }
     ```
   - Emit `task_deadlettered`.

---

## Step 6 · Write report

```markdown
## task-check report ({YYYY-MM-DD HH:MM})

- Ready found: {N}
- Deadlocks cleared: {N} (Step 0)
- Dependencies resolved: {N} (Step 2)
- Executed this run: {N} across {M} batches
  - Batch 1 (N parallel): took {Xs}
  - Batch 2 (N parallel): took {Xs}
- Succeeded: {N} · Retrying: {N} · Dead-lettered: {N}
- Skipped: {N} (blocked / done / running-but-not-stale)

### Execution details
{list tasks per batch with their results}

### Deadlock-cleanup log
{list any tasks that were reset from `running:*` to `ready`}

### Dead-letter additions
{list any tasks that newly entered the dead-letter queue + file paths}
```

---

## Safety rules

Before executing any of the following, **always notify the user first and wait for explicit confirmation**:

- Modifying already-published content or calling external APIs that mutate state.
- Deleting user data.
- Modifying `CLAUDE.md` or any file under `~/.claude/skills/`.
- Sending messages to external services (Slack, email, etc.).

---

## Concurrency contract (important)

**The main Claude is the sole writer of `task-board.md`.** Subagents:

- Read task context that the main Claude passes them.
- Execute the task (calling whatever tools they need).
- Write their own deliverable files (to the path the main Claude specified).
- Return a structured result (success / failure + output path + short summary).

This eliminates the entire class of race conditions that would otherwise be
possible when a Markdown file is the control plane.

---

## Event-log schema

```json
# Every task-check run
{"ts":"...","event":"task_check_start","version":"v3"}

# Deadlock cleanup
{"ts":"...","event":"lock_stale_removed","task_id":"...","previous_agent":"...","age_minutes":N}

# Dependency resolved
{"ts":"...","event":"dependency_resolved","task_id":"...","dependency":"TASK-XXX"}

# Batch started
{"ts":"...","event":"batch_started","batch_size":N,"task_ids":[...]}

# Task completed
{"ts":"...","event":"task_completed","task_id":"...","duration_sec":N}

# Task failed, queued for retry
{"ts":"...","event":"task_retry_scheduled","task_id":"...","retry_count":N,"reason":"..."}

# Task dead-lettered
{"ts":"...","event":"task_deadlettered","task_id":"...","retries":2,"reason":"..."}

# End-of-run summary
{"ts":"...","event":"task_check_run","ready":N,"executed":N,"succeeded":N,"retried":N,"deadlettered":N}
```

---

## Expected paths

- Task board: `${WORKSPACE_ROOT}/task-board.md`
- Event log: `${WORKSPACE_ROOT}/.task-router/state/events.jsonl`
- Dead-letter directory: `${WORKSPACE_ROOT}/.task-router/state/deadletter/`
- Status grammar reference: top of `task-board.md`
