#!/usr/bin/env bash
# PreToolUse hook: セッションの消費トークン数が CLAUDE_TOKEN_BUDGET の倍数を
# 超えるたびに、ユーザーにポップアップ通知する。
# 目的は「1セッションが暴走して大量にトークンを溶かす」ケースの早期検知。
# 対話モードのときだけ ask でセッションを中断して確認を求め、それ以外は通知のみで
# 処理を継続する("ask" は応答者がいない非対話モードでは自動的に deny 扱いになり、
# ユーザーが気づけないため)。
#
# 閾値はトークン数そのもの(全モデル・全トークン種別を単純合算した値)で判定する。
# デフォルトの20万トークンは、Opusのinput/output単価の平均($5/1Mと$25/1Mの平均=
# $15/1M)で$3相当となるトークン数として設定している(3 / 15 * 1,000,000 = 200,000)。
# モデルごとの実際の単価差は考慮しないため、実際の請求額とは一致しない。
#
# 注意:
# - Agent/Task ツールで起動したサブエージェントのトークン消費はメインの
#   transcript には記録されないため、この集計には含まれない。
set -euo pipefail

THRESHOLD_TOKENS="${CLAUDE_TOKEN_BUDGET:-200000}"
STATE_DIR="$HOME/.claude/hooks/state"
mkdir -p "$STATE_DIR"

notify_user() {
  local title="$1"
  local msg="$2"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$msg" >/dev/null 2>&1 || true
    return 0
  fi
  echo "$(date +"%Y-%m-%dT%H:%M:%S%z") NOTIFY title=${title} message=${msg}" >> "$STATE_DIR/notify.log" 2>/dev/null || true
}

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

find "$STATE_DIR" -type f -mtime +2 -delete 2>/dev/null || true

RESULT=$(jq -s \
  --argjson threshold "$THRESHOLD_TOKENS" '
  ( [ .[]
      | select(.type == "assistant")
      | .message.usage as $u
      | (($u.input_tokens // 0)
        + ($u.output_tokens // 0)
        + ($u.cache_creation_input_tokens // 0)
        + ($u.cache_read_input_tokens // 0))
    ] | add // 0
  ) as $total
  | { total: $total, level: ($total / $threshold | floor) }
' "$TRANSCRIPT_PATH")

TOTAL=$(echo "$RESULT" | jq -r '.total')
LEVEL=$(echo "$RESULT" | jq -r '.level')

if [ "$LEVEL" -lt 1 ]; then
  exit 0
fi

# セッションごとに直近で通知したレベルを記録し、レベルが進んだときだけ通知する。
STATE_FILE="$STATE_DIR/${SESSION_ID}.level"
LAST_NOTIFIED_LEVEL=0
if [ -f "$STATE_FILE" ]; then
  LAST_NOTIFIED_LEVEL=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
  case "$LAST_NOTIFIED_LEVEL" in ''|*[!0-9]*) LAST_NOTIFIED_LEVEL=0 ;; esac
fi

if [ "$LEVEL" -le "$LAST_NOTIFIED_LEVEL" ]; then
  exit 0
fi
echo "$LEVEL" > "$STATE_FILE"

# default/plan/acceptEdits は対話モード、auto/dontAsk/bypassPermissions は応答者がいない非対話モード。
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // "default"')
case "$PERMISSION_MODE" in
  auto|dontAsk|bypassPermissions) IS_INTERACTIVE="false" ;;
  *) IS_INTERACTIVE="true" ;;
esac

SH_REASON="このセッションの消費トークン数が ${THRESHOLD_TOKENS} トークン(Opus換算で約\$3相当)の倍数(現在: ${TOTAL}トークン、${LEVEL}倍)に達しました。セッションのクリアを推奨します。"
notify_user "CLAUDE: トークン消費警告" "$SH_REASON"

if [ "$IS_INTERACTIVE" = "true" ]; then
  jq -n \
    --arg reason "$SH_REASON" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: $reason
      }
    }'
fi

exit 0
