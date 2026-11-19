#!/usr/bin/env bash
#
# status.sh
# One-shot status report of the task router's current state.
#

set -euo pipefail

# Pick up WORKSPACE_ROOT / LABEL_PREFIX saved by install.sh, so this works in any terminal.
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.rendered/env.sh"
[ -f "$_ENV_FILE" ] && . "$_ENV_FILE"

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT env var must be set (directory containing task-board.md)}"

LABEL_PREFIX="${LABEL_PREFIX:-io.github.local.md-task-router}"
STATE_DIR="${STATE_DIR:-$WORKSPACE_ROOT/.task-router/state}"
LOCK_DIR="$STATE_DIR/task-check.lock"
EVENTS_LOG="$STATE_DIR/events.jsonl"

echo "═══════════════════════════════════════════════"
echo "  Markdown Task Router · status report"
echo "═══════════════════════════════════════════════"
echo ""

# --- launchd services ---
echo "▸ launchd agents"
for label in "${LABEL_PREFIX}.runner" "${LABEL_PREFIX}.watcher"; do
  if launchctl list | grep -q "$label"; then
    PID=$(launchctl list | awk -v l="$label" '$3==l {print $1}')
    LAST_EXIT=$(launchctl list | awk -v l="$label" '$3==l {print $2}')
    if [ "$PID" != "-" ]; then
      echo "  ✓ $label  (PID=$PID, running)"
    else
      echo "  ○ $label  (last_exit=$LAST_EXIT, not running)"
    fi
  else
    echo "  ✗ $label  (not loaded)"
  fi
done
echo ""

# --- Lock state ---
echo "▸ Task-check lock"
if [ -d "$LOCK_DIR" ]; then
  LOCK_AGE=$(($(date +%s) - $(stat -f %m "$LOCK_DIR")))
  echo "  🔒 task running (lock age ${LOCK_AGE}s)"
else
  echo "  🔓 no task in flight"
fi
echo ""

# --- Recent events ---
echo "▸ Last 10 events"
if [ -f "$EVENTS_LOG" ]; then
  tail -10 "$EVENTS_LOG" | while read -r line; do
    ts=$(echo "$line" | /usr/bin/python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('ts',''))")
    ev=$(echo "$line" | /usr/bin/python3 -c "import sys,json;print(json.loads(sys.stdin.read()).get('event',''))")
    tr=$(echo "$line" | /usr/bin/python3 -c "
import sys, json
d = json.loads(sys.stdin.read())
print(d.get('trigger', d.get('component', '-')))
" 2>/dev/null || echo "-")
    printf "  %s  %-25s  %s\n" "$ts" "$ev" "$tr"
  done
else
  echo "  (no events yet)"
fi
echo ""

# --- Event counts today ---
echo "▸ Today's event counts"
if [ -f "$EVENTS_LOG" ]; then
  TODAY=$(date -u +%Y-%m-%d)
  grep "\"ts\":\"$TODAY" "$EVENTS_LOG" 2>/dev/null | \
    /usr/bin/python3 -c "
import sys, json
from collections import Counter
c = Counter()
for line in sys.stdin:
    try:
        c[json.loads(line)['event']] += 1
    except: pass
for ev, n in c.most_common():
    print(f'  {n:4d}  {ev}')
" || echo "  (no events today)"
else
  echo "  (no events yet)"
fi
echo ""

# --- Task board snapshot ---
echo "▸ task-board.md snapshot"
BOARD="$WORKSPACE_ROOT/task-board.md"
if [ -f "$BOARD" ]; then
  for pattern_name in "ready" "blocked:human" "blocked:task" "blocked:external" "running:" "done" "cancelled" "failed"; do
    # grep -c returns 1 on no match; `; true` keeps `set -e` from killing us.
    N=$(grep -cE "^- \*\*Status\*\*:[[:space:]]*${pattern_name}" "$BOARD" 2>/dev/null ; true)
    printf "  %-20s %3d\n" "$pattern_name" "$N"
  done
else
  echo "  ($BOARD not found)"
fi
echo ""
echo "═══════════════════════════════════════════════"
