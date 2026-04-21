#!/usr/bin/env bash
#
# install.sh
# Installs the launchd agents into ~/Library/LaunchAgents and loads them.
# Idempotent: safe to re-run — unloads existing versions before reinstalling.
#
# Required:
#   WORKSPACE_ROOT   Directory containing task-board.md (e.g. /Users/you/notes)
#
# Optional:
#   LABEL_PREFIX     Reverse-DNS prefix for the launchd labels.
#                    Default: io.github.local.md-task-router
#                    Example: io.github.yourname.md-task-router
#

set -euo pipefail

: "${WORKSPACE_ROOT:?WORKSPACE_ROOT env var must be set before running install.sh}"

if [ ! -f "$WORKSPACE_ROOT/task-board.md" ]; then
  echo "✗ $WORKSPACE_ROOT/task-board.md not found."
  echo "  Copy sample/task-board.md there, or point WORKSPACE_ROOT elsewhere."
  exit 1
fi

LABEL_PREFIX="${LABEL_PREFIX:-io.github.local.md-task-router}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/config"
LA_DIR="$HOME/Library/LaunchAgents"
RENDERED_DIR="$REPO_ROOT/.rendered"

mkdir -p "$LA_DIR" "$RENDERED_DIR"

LABELS=("${LABEL_PREFIX}.runner" "${LABEL_PREFIX}.watcher")

# Source template filenames (fixed) → rendered filenames (reflect LABEL_PREFIX).
declare -a TEMPLATES=(
  "com.local.md-task-router.runner.plist.template"
  "com.local.md-task-router.watcher.plist.template"
)

echo "═══════════════════════════════════════════════"
echo "  Markdown Task Router · install launchd agents"
echo "═══════════════════════════════════════════════"
echo ""
echo "  WORKSPACE_ROOT = $WORKSPACE_ROOT"
echo "  REPO_ROOT      = $REPO_ROOT"
echo "  LABEL_PREFIX   = $LABEL_PREFIX"
echo ""

# 1. Render plist templates with real paths + LABEL_PREFIX.
echo "▸ Rendering plist templates"
for i in "${!LABELS[@]}"; do
  label="${LABELS[$i]}"
  template="${TEMPLATES[$i]}"
  sed \
    -e "s|__WORKSPACE_ROOT__|$WORKSPACE_ROOT|g" \
    -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__LABEL_PREFIX__|$LABEL_PREFIX|g" \
    "$CONFIG_DIR/$template" > "$RENDERED_DIR/$label.plist"
  echo "  ✓ $label.plist"
done

# 2. Unload existing versions (idempotent).
for label in "${LABELS[@]}"; do
  if launchctl list | grep -q "$label"; then
    echo "▸ Unloading existing $label ..."
    launchctl unload "$LA_DIR/$label.plist" 2>/dev/null || true
  fi
done

# 3. Copy rendered plists into LaunchAgents.
echo ""
echo "▸ Copying rendered plists to $LA_DIR"
for label in "${LABELS[@]}"; do
  cp "$RENDERED_DIR/$label.plist" "$LA_DIR/$label.plist"
  echo "  ✓ $label.plist"
done

# 4. Load services.
echo ""
echo "▸ Loading services"
for label in "${LABELS[@]}"; do
  launchctl load "$LA_DIR/$label.plist"
  echo "  ✓ $label loaded"
done

# 5. Verify.
echo ""
echo "▸ Verifying"
sleep 1
for label in "${LABELS[@]}"; do
  if launchctl list | grep -q "$label"; then
    PID=$(launchctl list | awk -v l="$label" '$3==l {print $1}')
    echo "  ✓ $label  (PID=$PID)"
  else
    echo "  ✗ $label  not running — check $WORKSPACE_ROOT/.task-router/state/"
  fi
done

echo ""
echo "═══════════════════════════════════════════════"
echo "  Install complete. Verify with:"
echo ""
echo "    bash bin/status.sh"
echo ""
echo "  Trigger a test run (any edit to task-board.md will fire):"
echo "    touch \"$WORKSPACE_ROOT/task-board.md\""
echo "═══════════════════════════════════════════════"
