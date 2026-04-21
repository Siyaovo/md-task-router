#!/usr/bin/env bash
#
# smoke-test.sh
# Minimal end-to-end sanity check. Runs in a throwaway temp directory,
# never touches real state. Exit 0 = all critical pieces work.
#
# What it verifies:
#   - fswatch is installed and detects a file change within the window.
#   - watcher.sh launches and emits the expected events to events.jsonl.
#   - run-task-check.sh's atomic lock works (second concurrent call is skipped).
#   - Quiescence gate fires (we wait for it rather than passing fake data).
#
# Intentionally does NOT invoke Claude Code — that requires network + an
# API key. If you want a full integration test, run run-task-check.sh
# manually against a real WORKSPACE_ROOT.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_WORKSPACE="$(mktemp -d -t md-task-router-smoke-XXXXXX)"
TMP_STATE="$TMP_WORKSPACE/.task-router/state"
EVENTS_LOG="$TMP_STATE/events.jsonl"

cleanup() {
  # Best-effort cleanup; don't fail the test on cleanup error.
  pkill -f "$TMP_WORKSPACE/task-board.md" 2>/dev/null || true
  rm -rf "$TMP_WORKSPACE"
}
trap cleanup EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; exit 1; }

echo "═══════════════════════════════════════════════"
echo "  md-task-router · smoke test"
echo "  workspace: $TMP_WORKSPACE"
echo "═══════════════════════════════════════════════"
echo ""

# --- Preflight ---
echo "▸ Preflight"
command -v fswatch >/dev/null 2>&1 || fail "fswatch not installed — brew install fswatch"
pass "fswatch present"

mkdir -p "$TMP_STATE"
cp "$REPO_ROOT/sample/task-board.md" "$TMP_WORKSPACE/task-board.md"
pass "sample task-board.md copied"

export WORKSPACE_ROOT="$TMP_WORKSPACE"
export STATE_DIR="$TMP_STATE"
export TASK_ROUTER_BIN="$REPO_ROOT/bin"
# Short quiescence so the test finishes quickly.
export QUIESCENCE_SECS=2
export MAX_WAIT_SECS=15
# We won't actually invoke Claude Code; override the runner's claude
# command with a no-op by using a fake PATH entry first.
FAKE_BIN="$TMP_WORKSPACE/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
# Fake `claude` shim for smoke test — exits 0 immediately.
exit 0
EOF
chmod +x "$FAKE_BIN/claude"
export PATH="$FAKE_BIN:$PATH"
pass "fake claude shim in place"

# --- Test 1: run-task-check happy path ---
echo ""
echo "▸ Test 1 — run-task-check completes end-to-end"
"$REPO_ROOT/bin/run-task-check.sh" smoke-test >/dev/null 2>&1
grep -q '"event":"started"' "$EVENTS_LOG" || fail "no 'started' event logged"
grep -q '"event":"completed"' "$EVENTS_LOG" || fail "no 'completed' event logged"
pass "started → completed events present"

# --- Test 2: atomic lock blocks concurrent runs ---
echo ""
echo "▸ Test 2 — atomic lock prevents concurrent execution"
# Start a runner in background that will sit in quiescence wait;
# while it's waiting, a second invocation should see the lock and skip.
touch "$TMP_WORKSPACE/task-board.md"
"$REPO_ROOT/bin/run-task-check.sh" smoke-bg >/dev/null 2>&1 &
BG_PID=$!
sleep 1   # give it time to take the lock
"$REPO_ROOT/bin/run-task-check.sh" smoke-second >/dev/null 2>&1 || true
wait "$BG_PID" 2>/dev/null || true
grep -q '"event":"skipped_locked"' "$EVENTS_LOG" || fail "concurrent run was not skipped"
pass "concurrent run correctly skipped"

# --- Test 3: watcher emits file_changed_triggered ---
echo ""
echo "▸ Test 3 — watcher detects file change"
# Start watcher in background, wait for it to initialise, then trigger an
# edit and check the event appears.
WATCHER_LOG="$TMP_WORKSPACE/watcher.out"
"$REPO_ROOT/bin/watcher.sh" > "$WATCHER_LOG" 2>&1 &
WATCHER_PID=$!
# fswatch can take 2-4 seconds to arm its kqueue handle on macOS.
sleep 4
# Modify content to guarantee fswatch sees an Updated event (pure touch
# of an already-touched file sometimes doesn't fire on macOS).
echo "# smoke-test edit $(date +%s)" >> "$TMP_WORKSPACE/task-board.md"
# Debounce is 2s, so give up to 15s for the event to appear.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  grep -q '"event":"file_changed_triggered"' "$EVENTS_LOG" && break
  sleep 1
done
kill "$WATCHER_PID" 2>/dev/null || true
# Also kill any fswatch child processes.
pkill -P "$WATCHER_PID" 2>/dev/null || true
wait "$WATCHER_PID" 2>/dev/null || true
if ! grep -q '"event":"file_changed_triggered"' "$EVENTS_LOG"; then
  echo "  --- watcher log ---"
  sed 's/^/    /' "$WATCHER_LOG" || true
  echo "  --- events.jsonl ---"
  sed 's/^/    /' "$EVENTS_LOG" || true
  fail "watcher did not emit file_changed_triggered within 15s"
fi
pass "watcher event emitted"

# --- Done ---
echo ""
echo "═══════════════════════════════════════════════"
echo "  ✓ all smoke tests passed"
echo "═══════════════════════════════════════════════"
