#!/bin/bash
# PreToolUse hook for Bash: block dangerous commands

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

# Block destructive git commands
if echo "$COMMAND" | grep -qE 'git (push --force|reset --hard|clean -fd)'; then
  echo "BLOCKED: destructive git command — ask user first" >&2
  exit 2
fi

# Block rm -rf on project root or home dir
if echo "$COMMAND" | grep -qE 'rm -rf\s+(\/Users\/Azamat\/[^/ ]+\s*$|\/Users\/Azamat\s*$|~\s*$|\/)'; then
  echo "BLOCKED: rm -rf on critical directory" >&2
  exit 2
fi

# Block dropping database
if echo "$COMMAND" | grep -qiE 'DROP\s+(DATABASE|TABLE)'; then
  echo "BLOCKED: DROP DATABASE/TABLE — ask user first" >&2
  exit 2
fi

exit 0
