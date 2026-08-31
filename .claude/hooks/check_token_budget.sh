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
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

find "$STATE_DIR" -type f -mtime +2 -delete 2>/dev/null || true

# transcriptは肥大化し続けるため、毎回全体を読み直すと呼び出しのたびに遅くなる。
# 前回読み終えたバイト位置(オフセット)と、そこまでの累計トークン数だけを
# state に保存し、以降は差分(新規に追記された分)だけを jq に渡して加算する。
OFFSET_FILE="$STATE_DIR/${SESSION_ID}.offset"
PREV_OFFSET=0
PREV_TOTAL=0
if [ -f "$OFFSET_FILE" ]; then
  IFS=' ' read -r PREV_OFFSET PREV_TOTAL < "$OFFSET_FILE" 2>/dev/null || true
  case "$PREV_OFFSET" in ''|*[!0-9]*) PREV_OFFSET=0 ;; esac
  case "$PREV_TOTAL" in ''|*[!0-9]*) PREV_TOTAL=0 ;; esac
fi

FILE_SIZE=$(stat -c%s "$TRANSCRIPT_PATH" 2>/dev/null || stat -f%z "$TRANSCRIPT_PATH" 2>/dev/null || echo 0)

# transcriptがローテーション/切り詰めされていた場合は最初から数え直す。
if [ "$PREV_OFFSET" -gt "$FILE_SIZE" ]; then
  PREV_OFFSET=0
  PREV_TOTAL=0
fi

NEW_OFFSET="$PREV_OFFSET"
TOTAL="$PREV_TOTAL"

if [ "$FILE_SIZE" -gt "$PREV_OFFSET" ]; then
  TMP_CHUNK="$STATE_DIR/.tmp_chunk_${SESSION_ID}"
  trap 'rm -f "$TMP_CHUNK" "${TMP_CHUNK}.complete" 2>/dev/null || true' EXIT
  tail -c "+$((PREV_OFFSET + 1))" "$TRANSCRIPT_PATH" > "$TMP_CHUNK"
  CHUNK_SIZE=$(stat -c%s "$TMP_CHUNK" 2>/dev/null || stat -f%z "$TMP_CHUNK" 2>/dev/null || echo 0)

  if [ "$CHUNK_SIZE" -gt 0 ]; then
    COMPLETE_FILE=""
    CONSUMED_BYTES=0
    LAST_CHAR=$(tail -c1 "$TMP_CHUNK")
    if [ -z "$LAST_CHAR" ]; then
      # 末尾が改行 = 追記分はすべて完全な行
      CONSUMED_BYTES="$CHUNK_SIZE"
      COMPLETE_FILE="$TMP_CHUNK"
    else
      # 末尾行がまだ書き込み中の可能性があるため、最後の改行までだけを使う
      LAST_NL_BYTE=$(grep -abo $'\n' "$TMP_CHUNK" | tail -1 | cut -d: -f1)
      if [ -n "$LAST_NL_BYTE" ]; then
        CONSUMED_BYTES=$((LAST_NL_BYTE + 1))
        head -c "$CONSUMED_BYTES" "$TMP_CHUNK" > "${TMP_CHUNK}.complete"
        COMPLETE_FILE="${TMP_CHUNK}.complete"
      fi
    fi

    if [ -n "$COMPLETE_FILE" ] && [ "$CONSUMED_BYTES" -gt 0 ]; then
      DELTA=$(jq -s '
        [ .[]
          | select(.type == "assistant")
          | .message.usage as $u
          | (($u.input_tokens // 0)
            + ($u.output_tokens // 0)
            + ($u.cache_creation_input_tokens // 0)
            + ($u.cache_read_input_tokens // 0))
        ] | add // 0
      ' "$COMPLETE_FILE")
      NEW_OFFSET=$((PREV_OFFSET + CONSUMED_BYTES))
      TOTAL=$((PREV_TOTAL + DELTA))
    fi
  fi

  rm -f "$TMP_CHUNK" "${TMP_CHUNK}.complete" 2>/dev/null || true
  trap - EXIT
fi

echo "$NEW_OFFSET $TOTAL" > "$OFFSET_FILE"

LEVEL=$((TOTAL / THRESHOLD_TOKENS))

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

# Claude Codeにはセッション名/タイトルが存在しないため、cwdのプロジェクト名と
# session_idの先頭8文字で、どのセッションかを見分けられるようにする。
SESSION_LABEL="${SESSION_ID:0:8}"
if [ -n "$CWD" ]; then
  SESSION_LABEL="$(basename "$CWD") [${SESSION_LABEL}]"
fi

SH_REASON="[${SESSION_LABEL}] このセッションの消費トークン数が ${THRESHOLD_TOKENS} トークン(Opus換算で約\$3相当)の倍数(現在: ${TOTAL}トークン、${LEVEL}倍)に達しました。セッションのクリアを推奨します。"
notify_user "CLAUDE: トークン消費警告 (${SESSION_LABEL})" "$SH_REASON"

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
