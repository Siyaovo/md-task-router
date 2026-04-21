#!/usr/bin/env bash
#
# watcher.sh
# Long-running process: watches task-board.md for changes and triggers
# run-task-check.sh when it changes.
#
# Managed by launchd (macOS); auto-restarts on crash.
#
# Design notes:
# - fswatch's -l flag debounces: many rapid saves → single trigger.
# - No concurrency control here. That lives in run-task-check.sh.
#

set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT env var must be set (directory containing task-board.md)}"

WATCH_FILE="$WORKSPACE_ROOT/task-board.md"
RUNNER_DIR="${TASK_ROUTER_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
RUNNER="$RUNNER_DIR/run-task-check.sh"
STATE_DIR="${STATE_DIR:-$WORKSPACE_ROOT/.task-router/state}"
EVENTS_LOG="$STATE_DIR/events.jsonl"

mkdir -p "$STATE_DIR"

log_watcher_event() {
  local event="$1"
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "{\"ts\":\"$ts\",\"event\":\"$event\",\"component\":\"watcher\"}" >> "$EVENTS_LOG"
}

log_watcher_event "watcher_started"

# fswatch flags:
#   -l 2.0       debounce 2 seconds (prevents multiple triggers from editor saves)
#   -o           output event count only (quieter)
#   --event ...  only care about actual content changes
fswatch \
  -l 2.0 \
  -o \
  --event Updated \
  --event Created \
  --event Renamed \
  "$WATCH_FILE" | while read -r _; do
    log_watcher_event "file_changed_triggered"
    "$RUNNER" "fswatch" || true
  done
