#!/bin/bash
# PreToolUse hook for Bash: validate git commit message format

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Only check git commit commands
if ! echo "$COMMAND" | grep -q 'git commit'; then
  exit 0
fi

# Check if message contains a conventional prefix
PREFIXES="feat|fix|chore|refactor|docs|test|style|perf|ci|build|revert"

if echo "$COMMAND" | grep -qE "($PREFIXES)[:(]|($PREFIXES): "; then
  # Good format
  exit 0
fi

# If it's a git commit -m but no conventional prefix found
if echo "$COMMAND" | grep -q 'commit.*-m'; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"Reminder: commit messages should follow conventional format — feat/fix/chore/refactor prefix. Example: feat: add user login\"}}"
fi

exit 0
