# Task Board

> Single source of truth for tasks in this workspace.
> Humans edit it by eye. The task-router reads it on a schedule (or on
> every save via fswatch) and runs any `ready` task that's assigned to
> Claude.

---

## Task-card grammar

**Simple** (single executor):

```markdown
## [TASK-XXX] {what}

- **Who**: Claude | Me | {other human}
- **When**: {deadline or ASAP}
- **Type**: simple
- **Priority**: P0 | P1 | P2 | P3 · #{domain} · @{kind}
- **Status**: {status code, see grammar below}
- **Measure**: {how do we know this is done?}
- **Notes**: {optional}
```

**Complex** (decomposed after Claude picks it up):

```markdown
## [TASK-XXX] {what}

- **Who**: Claude
- **When**: {deadline}
- **Type**: complex
- **Priority**: P0 | P1 | P2 | P3 · #{domain} · @{kind}
- **Status**: {status code}
- **Measure**: {completion criterion for the whole thing}
- **Notes**: {optional}

### Subtasks
- [ ] TASK-XXX-A: {description} (Claude · {status})
- [ ] TASK-XXX-B: {description} (Me · {status})
```

### Status grammar

| Code | Meaning | Example |
|------|---------|---------|
| `ready` | Eligible for the next `/task-check` pass | `Status: ready` |
| `blocked:human:{what}` | Waiting on a human to do something | `Status: blocked:human:reply-to-client` |
| `blocked:task:TASK-XXX` | Waiting on another task to finish | `Status: blocked:task:TASK-010` |
| `blocked:external:{what}` | Waiting on an external signal | `Status: blocked:external:api-credentials` |
| `running:{agent-id}:{iso-ts}` | In flight (timestamp used for deadlock detection) | `Status: running:sub-a9:2026-04-21T10:15Z` |
| `done` | Finished | `Status: done` |
| `cancelled:{reason}` | Dropped | `Status: cancelled:scope-changed` |
| `failed:{reason}` | Failed | `Status: failed:timeout` |

**Execution rules**:
- Only `ready` tasks are executed by `/task-check`.
- `blocked:*` tasks are skipped without re-evaluation (no token waste).
- `running:*` tasks older than 30 minutes are auto-reset to `ready` (deadlock recovery).
- On start, tasks transition `ready` → `running:*`; on success, `running:*` → `done`.

---

## To do

<!-- New task cards go here -->

## [TASK-001] Summarise yesterday's meeting notes

- **Who**: Claude
- **When**: today
- **Type**: simple
- **Priority**: P1 · #notes · @output
- **Status**: ready
- **Measure**: 3-bullet summary at the top of `notes/2026-04-20-meeting.md`, with action items extracted as a numbered list.

## [TASK-002] Draft blog post outline: "why I use Markdown as a control plane"

- **Who**: Claude
- **When**: this week
- **Type**: simple
- **Priority**: P2 · #writing · @output
- **Status**: blocked:human:pick-thesis-angle
- **Measure**: a 7-section outline in `drafts/markdown-control-plane.md`, each section with a one-sentence promise.

## [TASK-003] Run a weekly review

- **Who**: Claude
- **When**: every Sunday 20:00
- **Type**: simple
- **Priority**: P1 · #ops · @review
- **Status**: blocked:task:TASK-001
- **Measure**: written review file at `reviews/2026-W17.md` answering the standard 5 questions.

---

## Done

## [TASK-000] Smoke-test the task router

- **Who**: Claude
- **Type**: simple
- **Priority**: P0 · @setup
- **Status**: done
- **Measure**: `/task-check` runs end-to-end without errors; `events.jsonl` has `task_check_run` entry.
