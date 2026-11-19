#!/usr/bin/env bash
#
# auto-off.sh
# Unloads the watcher + runner launchd agents without removing the plist files.
# Use when you want to fully control when task-check runs (e.g. during a
# long interactive editing session).
#

set -euo pipefail

# Pick up WORKSPACE_ROOT / LABEL_PREFIX saved by install.sh, so this works in any terminal.
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.rendered/env.sh"
[ -f "$_ENV_FILE" ] && . "$_ENV_FILE"

LABEL_PREFIX="${LABEL_PREFIX:-io.github.local.md-task-router}"
LA_DIR="$HOME/Library/LaunchAgents"

echo "═══════════════════════════════════════════════"
echo "  Markdown Task Router · auto-off"
echo "═══════════════════════════════════════════════"

for label in "${LABEL_PREFIX}.watcher" "${LABEL_PREFIX}.runner"; do
  if launchctl list | grep -q "$label"; then
    launchctl unload "$LA_DIR/$label.plist" 2>&1
    sleep 1
    if launchctl list | grep -q "$label"; then
      echo "  ✗ $label failed to unload"
    else
      echo "  ✓ $label unloaded"
    fi
  else
    echo "  ○ $label wasn't running"
  fi
done

echo ""
echo "Notes:"
echo "  - task-board.md edits no longer trigger a task-check run."
echo "  - You can still trigger manually: bash bin/run-task-check.sh manual"
echo "  - Turn back on: bash bin/auto-on.sh"
echo "═══════════════════════════════════════════════"
