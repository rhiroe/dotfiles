#!/usr/bin/env bash
# ~/.claude/projects/**/*.jsonl のtranscriptから、セッションのトークン使用量を集計する。
# 金額には変換しない(単価は変更されうる不確実な情報のため、usageに記録された
# トークン数そのものだけを正として扱う)。jq/python3に依存せず、
# POSIX awk + GNU coreutils(date, find, sort)のみで完結させる。
#
# Usage:
#   session_cost.sh                     # カレントディレクトリの最新セッションの詳細
#   session_cost.sh <session_id>        # セッションIDを指定して詳細表示
#   session_cost.sh <transcript.jsonl>  # transcriptパスを直接指定して詳細表示
#   session_cost.sh --report [--days N] [--project SUBSTR]
#                                        # 全セッション横断でトークン量/品質代理指標を一覧表示
#
# 品質を直接示すラベルはtranscriptに存在しないため、以下を代理指標として使う:
#   - bash_error_rate: Bashツールがエラー/非ゼロ終了で終わった割合
#   - edit_revert_rate: Edit/Write結果のうち、ユーザーが手動修正した(userModified=true)割合
# どちらも低いほど「一発で狙った結果に到達できた」ことを示す代理になるが、
# タスク自体の難易度や価値は反映しない。絶対値ではなく同一ユーザー内での相対比較・
# 時系列トレンド用途に限定して使うこと。stderrの中身は正規表現 "stderr":"[^"]*" で
# 抜くため、エスケープされたダブルクォートを含む場合は途中で切れて誤判定しうる。
set -euo pipefail

PROJECTS_DIR="$HOME/.claude/projects"

# --- 共通: usage/toolUseResultのようなネストしたJSONオブジェクトを波括弧の対応を
# 数えて切り出すためのawk関数群。JSONパーサではなく、transcriptが1レコード1行の
# JSONLである前提の軽量な正規表現ベースの抽出。
AWK_COMMON='
function extract_num(str, key,    re, val) {
  re = "\"" key "\":[0-9.]+"
  if (match(str, re)) {
    val = substr(str, RSTART, RLENGTH)
    sub("\"" key "\":", "", val)
    return val + 0
  }
  return 0
}
function extract_str(str, key,    re, val) {
  re = "\"" key "\":\"[^\"]*\""
  if (match(str, re)) {
    val = substr(str, RSTART, RLENGTH)
    sub("^\"" key "\":\"", "", val)
    sub("\"$", "", val)
    return val
  }
  return ""
}
function extract_blob(line, key,    start, rest, depth, i, c) {
  start = index(line, "\"" key "\":{")
  if (start == 0) return ""
  rest = substr(line, start)
  depth = 0
  for (i = 1; i <= length(rest); i++) {
    c = substr(rest, i, 1)
    if (c == "{") depth++
    else if (c == "}") {
      depth--
      if (depth == 0) return substr(rest, 1, i)
    }
  }
  return ""
}
function cache_write_tokens(usage,    cc_flat, w5, w1) {
  cc_flat = extract_num(usage, "cache_creation_input_tokens")
  w5 = extract_num(usage, "ephemeral_5m_input_tokens")
  w1 = extract_num(usage, "ephemeral_1h_input_tokens")
  if (w5 == 0 && w1 == 0) return cc_flat
  return w5 + w1
}
'

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

resolve_transcript() {
  local arg="${1:-}"

  if [ -n "$arg" ] && [ -f "$arg" ]; then
    echo "$arg"
    return 0
  fi

  local project_dir
  project_dir="$PROJECTS_DIR/$(pwd | tr '/.' '-')"

  if [ -n "$arg" ]; then
    local match
    match=$(find "$project_dir" -maxdepth 1 -name "${arg}*.jsonl" 2>/dev/null | head -1)
    if [ -z "$match" ]; then
      echo "セッションが見つかりません: $arg" >&2
      exit 1
    fi
    echo "$match"
    return 0
  fi

  if [ ! -d "$project_dir" ]; then
    echo "このディレクトリのセッション履歴が見つかりません: $project_dir" >&2
    exit 1
  fi

  find "$project_dir" -maxdepth 1 -name "*.jsonl" -printf '%T@ %p\n' 2>/dev/null \
    | sort -rn | head -1 | cut -d' ' -f2-
}

run_single() {
  local transcript_path
  transcript_path=$(resolve_transcript "${1:-}")

  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo "transcriptが見つかりません" >&2
    exit 1
  fi

  local session_id title
  session_id=$(basename "$transcript_path" .jsonl)
  title=$(awk "$AWK_COMMON"'
  index($0, "\"type\":\"ai-title\"") > 0 {
    t = extract_str($0, "aiTitle")
    if (t != "") title = t
  }
  END { print title }
  ' "$transcript_path")

  awk -v prefix="$session_id $title" "$AWK_COMMON"'
  index($0, "\"type\":\"assistant\"") == 0 { next }
  {
    model = ""
    if (match($0, /"model":"[^"]*"/)) {
      model = substr($0, RSTART, RLENGTH)
      sub(/^"model":"/, "", model)
      sub(/"$/, "", model)
    }
    if (model == "") next

    usage = extract_blob($0, "usage")
    if (usage == "") next

    in_tok  = extract_num(usage, "input_tokens")
    out_tok = extract_num(usage, "output_tokens")
    cw_tok  = cache_write_tokens(usage)
    cr_tok  = extract_num(usage, "cache_read_input_tokens")

    turns[model]++
    sum_in[model]  += in_tok
    sum_out[model] += out_tok
    sum_cw[model]  += cw_tok
    sum_cr[model]  += cr_tok
    total_in += in_tok; total_out += out_tok; total_cw += cw_tok; total_cr += cr_tok
    seen = 1
  }
  END {
    if (!seen) { print prefix " assistantターンが見つかりませんでした。"; exit 0 }
    for (m in turns) {
      printf "%s %s: %dturns  input=%d output=%d cache_write=%d cache_read=%d  total=%d\n", \
        prefix, m, turns[m], sum_in[m], sum_out[m], sum_cw[m], sum_cr[m], \
        sum_in[m]+sum_out[m]+sum_cw[m]+sum_cr[m]
    }
  }
  ' "$transcript_path"
}

run_report() {
  local days=30
  local project_filter=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --project) project_filter="$2"; shift 2 ;;
      *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
  done

  local files=()
  local d f pname
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    pname=$(basename "$d")
    if [ -n "$project_filter" ] && [[ "$pname" != *"$project_filter"* ]]; then
      continue
    fi
    while IFS= read -r f; do
      files+=("$f")
    done < <(find "$d" -maxdepth 1 -name "*.jsonl")
  done

  if [ ${#files[@]} -eq 0 ]; then
    echo "該当するセッションが見つかりませんでした。"
    return 0
  fi

  local cutoff
  cutoff=$(date -u -d "-${days} days" +"%Y-%m-%dT%H:%M:%S")

  local tsv
  tsv=$(awk -v cutoff="$cutoff" "$AWK_COMMON"'
  {
    ts = ""
    if (match($0, /"timestamp":"[^"]*"/)) {
      ts = substr($0, RSTART, RLENGTH)
      sub(/^"timestamp":"/, "", ts)
      sub(/"$/, "", ts)
    }
    if (ts != "" && ts < cutoff) next

    sid = ""
    if (match($0, /"sessionId":"[^"]*"/)) {
      sid = substr($0, RSTART, RLENGTH)
      sub(/^"sessionId":"/, "", sid)
      sub(/"$/, "", sid)
    }
    if (sid == "") next

    n = split(FILENAME, parts, "/")
    project[sid] = parts[n-1]

    if (ts != "") {
      if (first_ts[sid] == "" || ts < first_ts[sid]) first_ts[sid] = ts
      if (last_ts[sid] == "" || ts > last_ts[sid]) last_ts[sid] = ts
    }

    if (index($0, "\"type\":\"assistant\"") > 0) {
      usage = extract_blob($0, "usage")
      if (usage != "") {
        turns[sid]++
        in_tok[sid] += extract_num(usage, "input_tokens")
        out_tok[sid] += extract_num(usage, "output_tokens")
        cw_tok[sid] += cache_write_tokens(usage)
        cr_tok[sid] += extract_num(usage, "cache_read_input_tokens")
      }
    } else if (index($0, "\"type\":\"user\"") > 0 && index($0, "\"toolUseResult\":{") > 0) {
      tr = extract_blob($0, "toolUseResult")
      if (index(tr, "\"stdout\"") > 0 || index(tr, "\"stderr\"") > 0) {
        bash_total[sid]++
        stderr_val = extract_str(tr, "stderr")
        if (index(tr, "\"interrupted\":true") > 0 || length(stderr_val) > 0) bash_error[sid]++
      } else if (index(tr, "\"structuredPatch\"") > 0) {
        edit_total[sid]++
        if (index(tr, "\"userModified\":true") > 0) edit_reverted[sid]++
      }
    }
  }
  END {
    for (sid in turns) {
      total = in_tok[sid]+out_tok[sid]+cw_tok[sid]+cr_tok[sid]
      printf "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n", \
        sid, project[sid], turns[sid]+0, in_tok[sid]+0, out_tok[sid]+0, cw_tok[sid]+0, cr_tok[sid]+0, total, \
        bash_total[sid]+0, bash_error[sid]+0, edit_total[sid]+0, edit_reverted[sid]+0, \
        first_ts[sid], last_ts[sid]
    }
  }
  ' "${files[@]}")

  if [ -z "$tsv" ]; then
    echo "該当するセッションが見つかりませんでした。"
    return 0
  fi

  local header
  header=$(printf '%-10s%-24s%6s%10s%10s%12s%11s%10s%9s%9s%7s' \
    "session" "project" "turns" "input" "output" "cache_write" "cache_read" "total" "bash_err" "edit_rev" "min")
  echo "$header"
  printf '%s\n' "$header" | awk '{ for (i=0;i<length($0);i++) printf "-"; print "" }'

  local sid project_name turns in_tok out_tok cw_tok cr_tok total bash_total bash_error edit_total edit_reverted first_ts last_ts
  while IFS=$'\t' read -r sid project_name turns in_tok out_tok cw_tok cr_tok total bash_total bash_error edit_total edit_reverted first_ts last_ts; do
    local bash_error_rate edit_revert_rate duration_min duration_s
    bash_error_rate=$(awk -v a="$bash_error" -v b="$bash_total" 'BEGIN { printf "%.6f", (b>0)? a/b : 0 }')
    edit_revert_rate=$(awk -v a="$edit_reverted" -v b="$edit_total" 'BEGIN { printf "%.6f", (b>0)? a/b : 0 }')
    duration_min="n/a"
    if [ -n "$first_ts" ] && [ -n "$last_ts" ]; then
      duration_s=$(( $(date -d "$last_ts" +%s 2>/dev/null || echo 0) - $(date -d "$first_ts" +%s 2>/dev/null || echo 0) ))
      duration_min=$(awk -v s="$duration_s" 'BEGIN { printf "%.0f", s/60 }')
    fi
    printf '%s\t%-10s%-24s%6d%10d%10d%12d%11d%10d%8.0f%%%8.0f%%%7s\n' \
      "$total" "${sid:0:8}" "${project_name:0:23}" "$turns" "$in_tok" "$out_tok" "$cw_tok" "$cr_tok" "$total" \
      "$(awk -v r="$bash_error_rate" 'BEGIN{print r*100}')" \
      "$(awk -v r="$edit_revert_rate" 'BEGIN{print r*100}')" \
      "$duration_min"
  done <<< "$tsv" | sort -t$'\t' -k1,1 -rn | cut -f2-
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "${1:-}" = "--report" ]; then
  shift
  run_report "$@"
else
  run_single "${1:-}"
fi
