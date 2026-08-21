#!/bin/bash
set -euo pipefail

rm -f ~/.claude/hooks/check_token_budget.sh
rmdir ~/.claude/hooks 2>/dev/null || true

if [ -f ~/.claude/settings.json ]; then
  MERGED=$(jq 'del(.hooks)' ~/.claude/settings.json)
  echo "$MERGED" > ~/.claude/settings.json
fi

rm -f ~/.claude/CLAUDE_IMPORT.md

IMPORT_LINE="@$HOME/.claude/CLAUDE_IMPORT.md"
if [ -f ~/CLAUDE.md ]; then
  grep -qxF "$IMPORT_LINE" ~/CLAUDE.md && grep -vxF "$IMPORT_LINE" ~/CLAUDE.md > ~/CLAUDE.md.tmp && mv ~/CLAUDE.md.tmp ~/CLAUDE.md || true
fi
