#!/bin/bash
# Stop hook: remind about review when code files are changed

INPUT=$(cat)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')

# Prevent infinite loop
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --git-dir > /dev/null 2>&1 || exit 0

CHANGES=$(git diff --name-only 2>/dev/null | grep -E '\.(go|ts|tsx|js|jsx|py|dart|swift|kt|rs)$' | wc -l | tr -d ' ')

if [ "$CHANGES" -gt 0 ]; then
  echo "{\"systemMessage\":\"Session summary: code files changed: $CHANGES. Consider running code-reviewer subagent before committing.\"}"
fi

exit 0
