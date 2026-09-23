#!/bin/bash
# SessionStart hook: inject git context at session start

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')

# Only on fresh start or after compaction
if [[ "$SOURCE" != "startup" && "$SOURCE" != "compact" ]]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --git-dir > /dev/null 2>&1 || exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
UNCOMMITTED=$(git diff --stat 2>/dev/null | tail -1)
RECENT_COMMITS=$(git log --oneline -5 2>/dev/null)

echo "Session context:
Branch: $BRANCH
Uncommitted: ${UNCOMMITTED:-none}
Recent commits: $RECENT_COMMITS"
exit 0
