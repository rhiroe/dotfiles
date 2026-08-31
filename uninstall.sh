#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f ~/.claude/settings.json ]; then
  # json_toplevel.awkは2スペースインデントの整形済みJSONしか扱えないため、
  # 想定外フォーマット(ミニファイ済み等)なら壊さず中断する。
  FIRST_LINE=$(grep -m1 -v '^[[:space:]]*$' ~/.claude/settings.json | tr -d ' \t\r\n')
  LAST_LINE=$(grep -v '^[[:space:]]*$' ~/.claude/settings.json | tail -1 | tr -d ' \t\r\n')
  if [ "$FIRST_LINE" != "{}" ] && { [ "$FIRST_LINE" != "{" ] || [ "$LAST_LINE" != "}" ]; }; then
    echo "~/.claude/settings.json が2スペースインデントの整形済みJSONではないため、hooks削除を中断しました。手動で削除してください。" >&2
    exit 1
  fi
  MERGED=$(awk -v MODE=del -v KEY=hooks -f "$DOTFILES_DIR/.claude/scripts/json_toplevel.awk" ~/.claude/settings.json)
  echo "$MERGED" > ~/.claude/settings.json
fi

rm -f ~/.claude/CLAUDE_IMPORT.md
rm -f ~/.local/bin/claude-report

IMPORT_LINE="@$HOME/.claude/CLAUDE_IMPORT.md"
if [ -f ~/CLAUDE.md ]; then
  grep -qxF "$IMPORT_LINE" ~/CLAUDE.md && grep -vxF "$IMPORT_LINE" ~/CLAUDE.md > ~/CLAUDE.md.tmp && mv ~/CLAUDE.md.tmp ~/CLAUDE.md || true
fi
