@.claude/CLAUDE_IMPORT.md

# install.sh / uninstall.sh / .claude/scripts/ の依存
- インストール先の環境が不明なため、jq・python3・perl・rubyなど非標準ツールに依存しない
- bash組み込み機能、POSIX awk、sed、grep、coreutils(find/sort/date等)の範囲内で実装する
- JSON操作が必要な場合は .claude/scripts/json_toplevel.awk を使う(2スペースインデント整形済みJSONのトップレベルキー限定のmerge/del。ネストしたキーの再帰マージや任意フォーマットには非対応)
