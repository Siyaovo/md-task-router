#!/usr/bin/env bash
#
# auto-on.sh
# Loads the watcher + runner launchd agents.
# Use when you want the system to pick up task-board changes automatically.
#
# Required to have already run bin/install.sh once before this.
#

set -euo pipefail

# Pick up WORKSPACE_ROOT / LABEL_PREFIX saved by install.sh, so this works in any terminal.
_ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.rendered/env.sh"
[ -f "$_ENV_FILE" ] && . "$_ENV_FILE"

LABEL_PREFIX="${LABEL_PREFIX:-io.github.local.md-task-router}"
LA_DIR="$HOME/Library/LaunchAgents"

echo "═══════════════════════════════════════════════"
echo "  Markdown Task Router · auto-on"
echo "═══════════════════════════════════════════════"

for label in "${LABEL_PREFIX}.watcher" "${LABEL_PREFIX}.runner"; do
  if launchctl list | grep -q "$label"; then
    echo "  ○ $label already running, skipping"
  else
    if [ -f "$LA_DIR/$label.plist" ]; then
      launchctl load "$LA_DIR/$label.plist" 2>&1
      sleep 1
      if launchctl list | grep -q "$label"; then
        PID=$(launchctl list | awk -v l="$label" '$3==l {print $1}')
        echo "  ✓ $label started (PID=$PID)"
      else
        echo "  ✗ $label failed to start"
      fi
    else
      echo "  ⚠️  $label.plist not found in $LA_DIR — run bin/install.sh first"
    fi
  fi
done

echo ""
echo "Notes:"
echo "  - The watcher triggers a run on every change to task-board.md."
echo "  - Avoid keeping an interactive session editing the same board;"
echo "    the quiescence gate helps, but belt-and-suspenders: run auto-off"
echo "    when you want full manual control."
echo "  - Turn off: bash bin/auto-off.sh"
echo "═══════════════════════════════════════════════"
