#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p ~/.claude/hooks
cp -r "$DOTFILES_DIR/.claude/hooks/." ~/.claude/hooks
find ~/.claude/hooks -type f -exec chmod +x {} +

[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json

# json_toplevel.awkは2スペースインデントの整形済みJSONしか扱えないため、
# 想定外フォーマット(ミニファイ済み等)なら壊さず中断する。
FIRST_LINE=$(grep -m1 -v '^[[:space:]]*$' ~/.claude/settings.json | tr -d ' \t\r\n')
LAST_LINE=$(grep -v '^[[:space:]]*$' ~/.claude/settings.json | tail -1 | tr -d ' \t\r\n')
if [ "$FIRST_LINE" != "{}" ] && { [ "$FIRST_LINE" != "{" ] || [ "$LAST_LINE" != "}" ]; }; then
  echo "~/.claude/settings.json が2スペースインデントの整形済みJSONではないため、自動マージを中断しました。手動でマージしてください。" >&2
  exit 1
fi

MERGED=$(awk -v MODE=merge -f "$DOTFILES_DIR/.claude/scripts/json_toplevel.awk" ~/.claude/settings.json "$DOTFILES_DIR/.claude/settings.json")
echo "$MERGED" > ~/.claude/settings.json

cp "$DOTFILES_DIR/.claude/CLAUDE_IMPORT.md" ~/.claude/CLAUDE_IMPORT.md

IMPORT_LINE="@$HOME/.claude/CLAUDE_IMPORT.md"
touch ~/.claude/CLAUDE.md
sed -i.bak '\#^@.*/\.claude/CLAUDE_IMPORT\.md$#d' ~/.claude/CLAUDE.md && rm -f ~/.claude/CLAUDE.md.bak
grep -qxF "$IMPORT_LINE" ~/.claude/CLAUDE.md || echo "$IMPORT_LINE" >> ~/.claude/CLAUDE.md

mkdir -p ~/.local/bin
cp "$DOTFILES_DIR/scripts/claude-report.sh" ~/.local/bin/claude-report
chmod +x ~/.local/bin/claude-report
