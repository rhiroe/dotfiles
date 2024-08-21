#!/usr/bin/env bash
# PreToolUse hook: セッションの推定コスト(USD)が CLAUDE_COST_BUDGET_USD の倍数を
# 超えるたびに、ツール呼び出しを一度だけ deny してユーザーに知らせる。
# 目的は「1セッションが暴走して大量にトークン/コストを溶かす」ケースの早期検知。
# 非対話(Auto Mode/VSCode拡張等)では "ask" が自動的に deny 扱いになった上で
# ユーザーへの通知が出ないため、明示的に "deny" を返す。
#
# 単価はモデルごとに大きく異なる(例: Opusはoutputトークン単価がHaikuの数十倍)ため、
# トークン数の単純合算ではなく概算コストで閾値判定する。
#
# 注意:
# - 単価表はおおまかな概算(モデル名の部分一致、キャッシュ書き込みは5分TTL想定で1.25倍、
#   読み込みは0.1倍として計算)。未知のモデルはSonnet相当の単価にフォールバックする。
#   正確な請求額と一致することは意図していない。
# - Agent/Task ツールで起動したサブエージェントのトークン消費はメインの
#   transcript には記録されないため、この集計には含まれない。
set -euo pipefail

THRESHOLD_USD="${CLAUDE_COST_BUDGET_USD:-3}"
STATE_DIR="$HOME/.claude/hooks/state"
mkdir -p "$STATE_DIR"

INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# 古い状態ファイルを掃除(2日以上前のもの)
find "$STATE_DIR" -type f -mtime +2 -delete 2>/dev/null || true

# 概算単価表(USD / 1Mトークン)。モデルIDの部分一致で判定する。日付サフィックス付き
# モデルIDにもマッチするよう、モデル世代を表す部分文字列をキーにしている。
PRICING_JSON='[
  {"match":"fable-5",  "in":10,"out":50},
  {"match":"mythos-5", "in":10,"out":50},
  {"match":"opus-5",   "in":5, "out":25},
  {"match":"opus-4-8", "in":5, "out":25},
  {"match":"opus-4-7", "in":5, "out":25},
  {"match":"opus-4-6", "in":5, "out":25},
  {"match":"opus",     "in":5, "out":25},
  {"match":"sonnet-5", "in":3, "out":15},
  {"match":"sonnet",   "in":3, "out":15},
  {"match":"haiku",    "in":1, "out":5}
]'

RESULT=$(jq -s \
  --argjson pricing "$PRICING_JSON" \
  --argjson threshold "$THRESHOLD_USD" '
  def pricefor(model):
    ([$pricing[] | select(.match as $sub | model | contains($sub))][0] // {match:"default","in":3,"out":15});
  ( [ .[]
      | select(.type == "assistant")
      | .message
      | (.model // "unknown") as $m
      | .usage as $u
      | (pricefor($m)) as $p
      | ((($u.input_tokens // 0) * $p.in)
        + (($u.output_tokens // 0) * $p.out)
        + (($u.cache_creation_input_tokens // 0) * ($p.in * 1.25))
        + (($u.cache_read_input_tokens // 0) * ($p.in * 0.1))
        ) / 1000000
    ] | add // 0
  ) as $total
  | { total: (($total * 100 | round) / 100), level: ($total / $threshold | floor) }
' "$TRANSCRIPT_PATH")

TOTAL=$(echo "$RESULT" | jq -r '.total')
LEVEL=$(echo "$RESULT" | jq -r '.level')

if [ "$LEVEL" -lt 1 ]; then
  exit 0
fi

STATE_FILE="$STATE_DIR/${SESSION_ID}.level"
LAST_LEVEL=0
if [ -f "$STATE_FILE" ]; then
  LAST_LEVEL=$(cat "$STATE_FILE")
fi

if [ "$LEVEL" -gt "$LAST_LEVEL" ]; then
  echo "$LEVEL" > "$STATE_FILE"
  jq -n \
    --arg reason "このセッションの推定コストが \$${THRESHOLD_USD} の倍数(現在: 約\$${TOTAL}、${LEVEL}倍)に達したため、このツール呼び出しをブロックしました。セッションのクリアを検討してください。" \
    '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $reason
      }
    }'
fi

exit 0
