#!/bin/bash
# PreToolUse hook: block editing .env files and secrets

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

BLOCKED_PATTERNS=(".env" "secrets" "credentials" ".jks" "keystore")

for pattern in "${BLOCKED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "BLOCKED: $FILE_PATH contains '$pattern' — sensitive file" >&2
    exit 2
  fi
done

exit 0
