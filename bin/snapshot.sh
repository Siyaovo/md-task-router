#!/usr/bin/env bash
#
# snapshot.sh "<message>"
# Commits a local git snapshot of WORKSPACE_ROOT if anything changed.
# No-op when WORKSPACE_ROOT is not a git repo or SNAPSHOTS=0. Never pushes.
#
# Called by run-task-check.sh before and after every run, so each automated
# run shows up as its own commit. To undo one file:
#   git -C "$WORKSPACE_ROOT" checkout <commit> -- path/to/file.md
#
: "${WORKSPACE_ROOT:?WORKSPACE_ROOT env var must be set}"
[ "${SNAPSHOTS:-1}" = "0" ] && exit 0
cd "$WORKSPACE_ROOT" || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git add -A -- . ':(exclude).task-router' >/dev/null 2>&1 || exit 0
git diff --cached --quiet && exit 0
git -c user.name="md-task-router" -c user.email="md-task-router@localhost" \
  commit -q --no-verify -m "${1:-snapshot} · $(date '+%Y-%m-%d %H:%M')" >/dev/null 2>&1
exit 0
