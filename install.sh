#!/bin/bash
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p ~/.claude/hooks
cp "$DOTFILES_DIR/.claude/hooks/check_token_budget.sh" ~/.claude/hooks/check_token_budget.sh
chmod +x ~/.claude/hooks/check_token_budget.sh

[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
MERGED=$(jq -s '.[0] * .[1]' ~/.claude/settings.json "$DOTFILES_DIR/.claude/hooks/settings.json")
echo "$MERGED" > ~/.claude/settings.json

cp "$DOTFILES_DIR/.claude/CLAUDE_IMPORT.md" ~/.claude/CLAUDE_IMPORT.md

IMPORT_LINE="@$HOME/.claude/CLAUDE_IMPORT.md"
touch ~/.claude/CLAUDE.md
sed -i '' '\#^@.*/\.claude/CLAUDE_IMPORT\.md$#d' ~/.claude/CLAUDE.md
grep -qxF "$IMPORT_LINE" ~/.claude/CLAUDE.md || echo "$IMPORT_LINE" >> ~/.claude/CLAUDE.md
