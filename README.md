# Markdown Task Router

English · [中文](README.zh-CN.md)

A minimal, session-independent runtime that turns a single Markdown file
into an agent control plane.

> Edit `task-board.md`. A watcher notices. An LLM decision layer routes
> `ready` tasks to subagents, executes them in parallel, writes results
> back. Self-heals deadlocks. Retries failures. Writes a dead-letter
> entry on terminal failure.

All state lives in plain text in a git-tracked directory. No database.
No vendor.

---

## Why this shape

- **Markdown as the control plane.** Tasks are cards in a single file
  the user already edits. Git-tracked state; no canvas UI to re-enter
  state into.
- **Typed state machine, not free-text status.** A status token like
  `blocked:human:send-brief` or `running:agent-42:2026-04-21T10:15Z`
  is a small protocol the LLM reasons about rather than a label it
  pattern-matches. The decision layer can inspect dependency chains,
  timestamp validity, and deadlock conditions directly.
- **Single-writer concurrency.** The main Claude is the only process
  that writes to `task-board.md`. Subagents execute and return
  structured results. This removes an entire class of race conditions
  without requiring a distributed lock.
- **Quiescence gate.** Editor saves often fire 5–10 file-change events
  for a single logical save. The runner waits for 30 seconds of file
  idle before proceeding, so the automation doesn't race a human who
  is still mid-edit.
- **Session-independent execution.** Runs via `launchd` on macOS
  (`systemd` on Linux works the same way — see Portability below),
  independent of any open terminal, Claude Code session, or chat window.

---

## Architecture

```
Edit task-board.md
        ↓
fswatch (2-second debounce)
        ↓
run-task-check.sh
    ↓ acquire mkdir-based atomic lock
    ↓ wait for 30-second quiescence on task-board.md
    ↓ invoke `claude -p /task-check` (no session)
        ↓
Claude Code running the task-check skill
    ↓ clean deadlocked `running:*` entries > 30 min
    ↓ resolve `blocked:task:X` whose dep is now done
    ↓ batch `ready` tasks by dependency
    ↓ parallel-execute up to 3 subagents per batch
    ↓ on failure: retry up to 2 times; then dead-letter
    ↓ write results back to task-board.md (single writer)
    ↓ append structured events to events.jsonl
```

### The 5 layers

| Layer | Responsibility | Implementation |
|---|---|---|
| L5 — Control plane | Human + LLM share one view of state | `task-board.md` |
| L4 — Scheduler | Event-driven + time-based fallback | `fswatch` + `launchd` |
| L3 — Executor | Stateless, one-shot LLM invocation | `bash` + `claude -p --no-session-persistence` |
| L2 — Decision layer | State-machine routing, retry, dead-letter | `task-check` skill (LLM) |
| L1 — State & audit | Append-only event log + dead-letter queue | `events.jsonl` + `deadletter/` |

---

## Requirements

- **macOS** with Homebrew (Linux instructions below)
- **`fswatch`** — `brew install fswatch`
- **Claude Code or Codex**, either one:
  - [Claude Code](https://docs.claude.com/en/docs/claude-code), logged in once with `claude` (Claude Pro or Max)
  - Codex: `npm install -g @openai/codex` (or `brew install codex`), then `codex login`
- A workspace folder for `task-board.md` and whatever Claude produces (ideally a git repo, so runs can be undone)

---

## Install

```bash
# 1. Clone this repo.
git clone https://github.com/Siyaovo/md-task-router.git ~/code/md-task-router
cd ~/code/md-task-router

# 2. Install fswatch.
brew install fswatch

# 3. Point WORKSPACE_ROOT at the folder that contains your task-board.md.
export WORKSPACE_ROOT=~/notes
mkdir -p "$WORKSPACE_ROOT"
#    No board yet? Copy the sample (skip this if you already have one).
cp sample/task-board.md "$WORKSPACE_ROOT/"

# 4. (Optional) Set your own reverse-DNS label prefix for the launchd
#    agents. Default is io.github.local.md-task-router; override with
#    something like io.github.yourusername.md-task-router if you prefer.
export LABEL_PREFIX=io.github.yourusername.md-task-router

# 5. Install the `task-check` skill into Claude Code.
mkdir -p ~/.claude/skills/task-check
cp skill/SKILL.md ~/.claude/skills/task-check/SKILL.md

# 6. Give headless runs a long-lived login (one time).
#    A normal `claude` login expires and cannot be refreshed without you,
#    so background runs would start failing after a few weeks.
claude setup-token          # confirm in the browser; it prints a token
security add-generic-password -U -a "$USER" -s claude-headless-token -w
#                           # paste the token at the prompt (not echoed)

# 7. Render and load the launchd agents.
bash bin/install.sh
```

The token lives only in your Keychain. `run-task-check.sh` reads it on every
run; you never put it in a file or an environment variable.

**Using Codex instead of Claude Code:** skip steps 5 and 6 and run
`export AGENT_CLI=codex` before `bash bin/install.sh`. The runner feeds
`skill/SKILL.md` straight to `codex exec`, and Codex uses the account from
`codex login`. If `AGENT_CLI` is unset, install.sh picks Claude Code when it is
installed, otherwise Codex. Cards still say `Who: Claude`; it just means "the
agent".

`install.sh` finds where the agent CLI and `fswatch` live and remembers
`WORKSPACE_ROOT`, so the `bin/` commands work from any new terminal without
exporting it again.

If the workspace is a git repo, add `.task-router/` to its `.gitignore` so run
logs stay out of your own commits.

### First run

1. Add a test card under "To do" in `$WORKSPACE_ROOT/task-board.md`:

   ```markdown
   ## [TASK-100] Smoke test
   - **Who**: Claude
   - **Est**: —
   - **Type**: simple
   - **Priority**: P1 · #test · @output
   - **Status**: ready
   - **Measure**: hello.md contains the line "task router works"
   ```

2. Save, then wait about a minute (30 seconds of quiet, plus Claude's work).
3. Run `bash bin/status.sh`. If it worked, `hello.md` exists, the card is
   `done`, and the last line of `events.jsonl` is `completed`.
4. Nothing happened? Check `$WORKSPACE_ROOT/.task-router/state/launchd-runner.log`,
   then "Events and debugging" below.

---

## Usage

```bash
# See what's running + last events + task-board counts.
bash bin/status.sh

# Temporarily pause automation (e.g. during an interactive editing session).
bash bin/auto-off.sh

# Resume.
bash bin/auto-on.sh

# Manually trigger a one-shot run (handy for testing a new skill change).
bash bin/run-task-check.sh manual

# Fully uninstall the launchd agents.
bash bin/uninstall.sh

# Run the smoke test (verifies fswatch + watcher + runner, without calling Claude).
bash bin/smoke-test.sh
```

### Writing a task

Add a card to `task-board.md`:

```markdown
## [TASK-042] Summarise yesterday's meeting notes

- **Who**: Claude
- **Type**: simple
- **Priority**: P1 · #notes · @output
- **Status**: ready
- **Measure**: 3-bullet summary at the top of notes/2026-04-21-meeting.md
```

Only cards whose `Who` includes Claude and whose `Status` is `ready` are run
automatically; cards for humans are skipped.

Save. The watcher picks it up. Once the file has been idle for 30
seconds, the runner kicks off. Claude reads the board, finds your
`ready` task, delegates to a subagent, writes the result, and flips the
card to `done`.

See [`sample/task-board.md`](sample/task-board.md) for a full template
with the status grammar and an example of each state.

---

## Events and debugging

Every transition is logged as a JSON line in
`$WORKSPACE_ROOT/.task-router/state/events.jsonl`.

```bash
tail -f "$WORKSPACE_ROOT/.task-router/state/events.jsonl"
```

Example of what you'll see during one end-to-end run:

```json
{"ts":"2026-04-21T10:15:00Z","event":"file_changed_triggered","component":"watcher"}
{"ts":"2026-04-21T10:15:30Z","event":"quiescence_reached","trigger":"fswatch","waited_secs":30,"final_idle_secs":30}
{"ts":"2026-04-21T10:15:30Z","event":"started","trigger":"fswatch"}
{"ts":"2026-04-21T10:15:30Z","event":"task_check_start","version":"v3"}
{"ts":"2026-04-21T10:15:35Z","event":"batch_started","batch_size":1,"task_ids":["TASK-042"]}
{"ts":"2026-04-21T10:15:58Z","event":"task_completed","task_id":"TASK-042","duration_sec":23}
{"ts":"2026-04-21T10:15:58Z","event":"task_check_run","ready":0,"executed":1,"succeeded":1,"retried":0,"deadlettered":0}
{"ts":"2026-04-21T10:15:58Z","event":"completed","trigger":"fswatch","exit_code":0}
```

If something goes wrong, check `$WORKSPACE_ROOT/.task-router/state/launchd-watcher.log`
and `launchd-runner.log` — they contain stdout/stderr from the launchd-managed
processes.

### Expired credentials

Headless runs authenticate with the long-lived token from install step 6
(Keychain service `claude-headless-token`, override with
`TOKEN_KEYCHAIN_SERVICE`). If `CLAUDE_CODE_OAUTH_TOKEN` is already set in the
environment, that wins.

A run whose `claude` invocation dies on expired credentials is logged as
`auth_failed` rather than the generic `failed`, and raises a desktop
notification:

```json
{"ts":"2026-09-15T05:48:23Z","event":"auth_failed","trigger":"launchd-hourly","exit_code":1}
```

This case is worth separating because retrying cannot fix it — a human has
to renew the login (`claude setup-token`, see install step 6). Folded into `failed`, an expired login looks
exactly like a transient error, and a scheduled runner will keep firing
hourly against it indefinitely. In my own deployment it did so for six
weeks before I noticed.

After an auth failure the runner backs off: it notifies once, then skips runs
for 6 hours (`AUTH_BACKOFF_SECS`) and logs `skipped_auth_backoff` instead of
failing every hour. Once you have fixed the token, resume immediately with:

```bash
rm -f "$WORKSPACE_ROOT/.task-router/state/auth_failed.marker"
bash bin/run-task-check.sh manual
```

### Snapshots and undo

If `WORKSPACE_ROOT` is a git repository, the runner commits a local snapshot
right before and right after every run (`bin/snapshot.sh`; nothing is pushed).
Each automated run therefore shows up as its own commit:

```bash
git -C "$WORKSPACE_ROOT" log --oneline | head          # recent runs
git -C "$WORKSPACE_ROOT" show --stat <commit>          # what one run changed
git -C "$WORKSPACE_ROOT" checkout <commit> -- task-board.md   # undo one file
```

Not a git repo? Run `git init` in it once to get this. Set `SNAPSHOTS=0` to
turn it off.

### Permissions

The runner starts the agent with full permissions (Claude Code:
`--permission-mode bypassPermissions`; Codex:
`--dangerously-bypass-approvals-and-sandbox`), so unattended runs can use any
tool without asking. Point `WORKSPACE_ROOT` at a
folder you are comfortable letting an agent edit, keep it under git so the
snapshots above can undo a bad run, and use `bin/auto-off.sh` while you are
working in the folder yourself.

### Keeping the board short

The `task-check` skill also tidies the board after each run: cards keep at
most 3 lines of notes (long material goes into linked files), finished cards
move to the Done section, and when Done exceeds 20 cards it is archived to
`archive/task-board-archive-YYYY-MM-DD.md`. Task IDs are never reused. See
`sample/task-board.md` for the card format, including the `Est` field for the
time a human needs to spend.

---

## Design decisions

Each decision below names the alternative I rejected and the specific
reason. These are the kinds of trade-offs that tend to drive the
actual behaviour of an LLM-driven system.

| Decision | Rejected alternative | Reason |
|---|---|---|
| Markdown as control plane | Notion / Airtable / Postgres | Keeps task state in plain text the user already edits, which is git-versioned by default. The downside (no schema enforcement) is recovered by the typed-state-machine layer. |
| Typed state protocol | Free-text status ("in progress", "waiting") | A protocol lets the LLM reason about dependency chains, deadlock conditions, and timestamp validity instead of pattern-matching strings. In practice, this is the single biggest lever on system behaviour. |
| Single-writer protocol | Distributed locking (`flock`, CRDT, append-log) | Markdown isn't transactional. Restricting writes to one process eliminates an entire class of race-condition bugs without runtime cost. Parallelism is preserved in subagent execution. |
| 30-second quiescence gate | 2-second debounce | A user mid-edit can trigger the watcher 5–10 times during a single logical save. Without quiescence, the executor races the user. 30 seconds aligns automation with a human's natural pause rhythm. |
| No RAG, no fine-tuning | Retrieval-augmented decision layer | The full task-board fits in the context window (typically 1–3K tokens). The decision layer needs *all* active tasks to reason about dependencies — partial retrieval would miss them. |

---

## Portability (Linux)

Only three pieces are macOS-specific. Each has a direct Linux equivalent:

| Piece | macOS | Linux equivalent |
|---|---|---|
| File-change watcher | `fswatch` (via Homebrew) | `inotifywait` (from `inotify-tools`) |
| Service manager | `launchd` with `plist` files | `systemd` with `.service` unit files |
| Shell scripts (`bin/*.sh`) | bash 3.2+ | bash 4+ (swap `stat -f %m` → `stat -c %Y`) |

A Linux port is a ~2 hour task: replace the plist templates with
`systemd` unit files, swap the watcher's `fswatch` invocation for
`inotifywait -m -e modify,create,move`, and update the `stat`
calls in `run-task-check.sh` and `status.sh` to use `-c %Y`.
Everything else — the state machine, the skill, the quiescence
gate, the dead-letter queue — is unchanged.

---

## When not to use this

- **Team workflows with a non-technical operator.** Coze, Dify, and
  n8n are designed for shared, UI-first state and will serve you
  better.
- **When you need a shared web UI.** This project leaves presentation
  to your editor or terminal on purpose.
- **High task volume (> 500 active tasks).** Markdown parsing becomes
  the bottleneck at that scale. The usual next step is to add a
  SQLite index alongside, keeping Markdown as the human-readable UI.

---

## License

MIT. See `LICENSE`.
