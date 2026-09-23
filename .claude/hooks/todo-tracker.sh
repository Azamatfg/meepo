#!/bin/bash
# PostToolUse hook: detect TODO/FIXME/HACK added in edits

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
NEW_STRING=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // empty')

# Skip non-code files
if [[ ! "$FILE_PATH" =~ \.(go|ts|tsx|js|jsx|py|dart|swift|kt|rs)$ ]]; then
  exit 0
fi

# Check if new content contains TODO/FIXME/HACK
TODOS=$(echo "$NEW_STRING" | grep -inE '(TODO|FIXME|HACK|XXX):?' | head -5)

if [ -n "$TODOS" ]; then
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":\"Note: TODO/FIXME detected in $FILE_PATH — make sure these are intentional and tracked:\\n$TODOS\"}}"
fi

exit 0
