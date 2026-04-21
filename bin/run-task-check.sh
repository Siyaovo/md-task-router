#!/usr/bin/env bash
#
# run-task-check.sh
# Single-shot invocation of Claude Code running the /task-check skill, then exits.
# Called both by fswatch (event-driven) and launchd (hourly fallback).
#
# Design notes:
# - mkdir-based atomic lock prevents concurrent execution.
# - bash-native timeout (macOS has no `timeout` command by default).
# - All events written to events.jsonl for observability.
#

set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT env var must be set (directory containing task-board.md)}"

STATE_DIR="${STATE_DIR:-$WORKSPACE_ROOT/.task-router/state}"
LOCK_DIR="$STATE_DIR/task-check.lock"
EVENTS_LOG="$STATE_DIR/events.jsonl"
RUN_LOG="$STATE_DIR/run-$(date +%Y%m%d).log"
TIMEOUT_SECS="${TASK_CHECK_TIMEOUT:-1800}"

TRIGGER_SOURCE="${1:-manual}"

mkdir -p "$STATE_DIR"

log_event() {
  local event="$1"
  local extra="${2:-}"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [ -n "$extra" ]; then
    echo "{\"ts\":\"$ts\",\"event\":\"$event\",\"trigger\":\"$TRIGGER_SOURCE\",$extra}" >> "$EVENTS_LOG"
  else
    echo "{\"ts\":\"$ts\",\"event\":\"$event\",\"trigger\":\"$TRIGGER_SOURCE\"}" >> "$EVENTS_LOG"
  fi
}

# --- Atomic lock: prevent concurrent execution ---
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_AGE=$(($(date +%s) - $(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)))
  if [ "$LOCK_AGE" -gt "$TIMEOUT_SECS" ]; then
    log_event "lock_stale_removed" "\"age_secs\":$LOCK_AGE"
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR"
  else
    log_event "skipped_locked" "\"lock_age_secs\":$LOCK_AGE"
    exit 0
  fi
fi

# Release lock on exit.
cleanup() { rm -rf "$LOCK_DIR"; }
trap cleanup EXIT

# --- Quiescence gate ---
# If task-board is still being edited (file modified within the last 30 seconds),
# wait until it's been "quiet" for the full window before running.
# This prevents the automated checker from racing an interactive session that
# might also be writing to the same file.
BOARD="$WORKSPACE_ROOT/task-board.md"
QUIESCENCE_SECS="${QUIESCENCE_SECS:-30}"
MAX_WAIT_SECS="${MAX_WAIT_SECS:-300}"
WAIT_START=$(date +%s)

while true; do
  ELAPSED=$(($(date +%s) - WAIT_START))
  if [ "$ELAPSED" -gt "$MAX_WAIT_SECS" ]; then
    log_event "quiescence_timeout" "\"max_wait_secs\":$MAX_WAIT_SECS"
    exit 0  # Give up this round; next watcher event retries.
  fi

  LAST_EDIT=$(stat -f %m "$BOARD" 2>/dev/null || echo 0)
  IDLE=$(($(date +%s) - LAST_EDIT))

  if [ "$IDLE" -ge "$QUIESCENCE_SECS" ]; then
    # Board has been quiet long enough. Proceed.
    if [ "$ELAPSED" -gt 0 ]; then
      log_event "quiescence_reached" "\"waited_secs\":$ELAPSED,\"final_idle_secs\":$IDLE"
    fi
    break
  fi

  # Still being edited; check again in 5 seconds.
  sleep 5
done

log_event "started"

cd "$WORKSPACE_ROOT"

# --- Invoke Claude Code running the /task-check skill ---
# bash-native timeout: background the process + kill-timer.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === run-task-check start (trigger=$TRIGGER_SOURCE) ===" >> "$RUN_LOG"

claude \
  --permission-mode bypassPermissions \
  --no-session-persistence \
  -p "/task-check" >> "$RUN_LOG" 2>&1 &
CLAUDE_PID=$!

# Kill-timer: if the process outlives TIMEOUT_SECS, kill it.
(
  sleep "$TIMEOUT_SECS"
  if kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill -9 "$CLAUDE_PID" 2>/dev/null || true
  fi
) &
TIMER_PID=$!

# Wait for claude to finish.
EXIT_CODE=0
wait "$CLAUDE_PID" 2>/dev/null || EXIT_CODE=$?

# Clean up the timer.
kill -9 "$TIMER_PID" 2>/dev/null || true
wait "$TIMER_PID" 2>/dev/null || true

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === run-task-check end (exit=$EXIT_CODE) ===" >> "$RUN_LOG"

# Classify the result by exit code.
if [ "$EXIT_CODE" -eq 0 ]; then
  log_event "completed" "\"exit_code\":0"
elif [ "$EXIT_CODE" -eq 137 ] || [ "$EXIT_CODE" -eq 143 ]; then
  # 137 = SIGKILL, 143 = SIGTERM — both indicate our timeout killed it.
  log_event "timeout" "\"timeout_secs\":$TIMEOUT_SECS"
else
  log_event "failed" "\"exit_code\":$EXIT_CODE"
fi

exit "$EXIT_CODE"
