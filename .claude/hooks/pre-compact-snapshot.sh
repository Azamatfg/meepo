#!/bin/bash
# PreCompact hook: snapshot git state before context compaction
# Writes to $PROJECT_DIR/.claude/session-env/last-precompact.md (overwrite)
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
OUT="$PROJECT_DIR/.claude/session-env/last-precompact.md"
mkdir -p "$(dirname "$OUT")"

{
  echo "# Pre-compact snapshot — $(date '+%Y-%m-%d %H:%M:%S')"
  echo
  echo "## Branch"
  git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo "(no branch)"
  echo
  echo "## Uncommitted"
  git -C "$PROJECT_DIR" status --short 2>/dev/null | head -40 || echo "(clean)"
  echo
  echo "## Last 5 commits"
  git -C "$PROJECT_DIR" log -5 --oneline 2>/dev/null || echo "(no log)"
} > "$OUT" 2>/dev/null || true

exit 0
