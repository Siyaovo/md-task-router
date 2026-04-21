#!/usr/bin/env bash
#
# uninstall.sh
# Unloads and removes the launchd agents.
# State directory ($WORKSPACE_ROOT/.task-router/state) is preserved —
# delete it manually if desired.
#

set -euo pipefail

LABEL_PREFIX="${LABEL_PREFIX:-io.github.local.md-task-router}"
LA_DIR="$HOME/Library/LaunchAgents"
LABELS=("${LABEL_PREFIX}.watcher" "${LABEL_PREFIX}.runner")

echo "═══════════════════════════════════════════════"
echo "  Markdown Task Router · uninstall launchd agents"
echo "═══════════════════════════════════════════════"
echo ""

for label in "${LABELS[@]}"; do
  PLIST="$LA_DIR/$label.plist"
  if [ -f "$PLIST" ]; then
    echo "▸ Unloading $label ..."
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "  ✓ removed"
  else
    echo "  ○ $label not installed; skipping"
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Uninstall complete. State directory preserved."
echo "═══════════════════════════════════════════════"
