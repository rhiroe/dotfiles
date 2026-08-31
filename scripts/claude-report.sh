#!/usr/bin/env bash
# ~/.claude/projects/**/*.jsonl のtranscriptから、セッションのトークン使用量を集計する。
# 金額には変換しない(単価は変更されうる不確実な情報のため、usageに記録された
# トークン数そのものだけを正として扱う)。jq/python3に依存せず、
# POSIX awk + GNU coreutils(date, find, sort)のみで完結させる。
#
# Usage:
#   claude-report [--days N] [--project SUBSTR]
#                                        # 全セッション横断でトークン量/品質代理指標を一覧表示
#   claude-report --detail <session_id>
#                                        # そのセッションのみ詳細表示(期間制限なし)
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
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
}

print_session_detail() {
  local transcript_path="$1"
  local session_id project_name
  session_id=$(basename "$transcript_path" .jsonl)
  project_name=$(basename "$(dirname "$transcript_path")")

  awk -v session_id="$session_id" -v project_name="$project_name" "$AWK_COMMON"'
  function count_tool_uses(line,    rest, re, m) {
    rest = line
    re = "\"type\":\"tool_use\",\"id\":\"[^\"]*\",\"name\":\"[A-Za-z_]*\""
    while (match(rest, re)) {
      m = substr(rest, RSTART, RLENGTH)
      sub(/^.*"name":"/, "", m)
      sub(/"$/, "", m)
      tool_counts[m]++
      tool_total++
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  {
    if (cwd == "") { cwd = extract_str($0, "cwd") }
    if (branch == "") { branch = extract_str($0, "gitBranch") }
    ts = extract_str($0, "timestamp")
    if (ts != "") {
      if (first_ts == "" || ts < first_ts) first_ts = ts
      if (ts > last_ts) last_ts = ts
    }
    if (index($0, "\"type\":\"ai-title\"") > 0) {
      t = extract_str($0, "aiTitle")
      if (t != "") title = t
    }
    if (index($0, "\"type\":\"assistant\"") > 0) {
      model = ""
      if (match($0, /"model":"[^"]*"/)) {
        model = substr($0, RSTART, RLENGTH)
        sub(/^"model":"/, "", model)
        sub(/"$/, "", model)
      }
      if (model != "") {
        usage = extract_blob($0, "usage")
        if (usage != "") {
          turns[model]++
          sum_in[model]  += extract_num(usage, "input_tokens")
          sum_out[model] += extract_num(usage, "output_tokens")
          sum_cw[model]  += cache_write_tokens(usage)
          sum_cr[model]  += extract_num(usage, "cache_read_input_tokens")
        }
      }
      count_tool_uses($0)
      if (index($0, "\"name\":\"Skill\"") > 0 && match($0, /"skill":"[^"]*"/)) {
        sname = substr($0, RSTART, RLENGTH)
        sub(/^"skill":"/, "", sname)
        sub(/"$/, "", sname)
        skill_total++
        skill_counts[sname]++
        if (last_human_kind == "command") skill_cmd[sname]++
        else skill_auto[sname]++
      }
    } else if (index($0, "\"type\":\"user\"") > 0) {
      if (index($0, "\"kind\":\"human\"") > 0) {
        human_turns++
        if (index($0, "<command-name>") > 0 || match($0, /"text":"\//)) {
          last_human_kind = "command"
        } else {
          last_human_kind = "prompt"
        }
      }
      n_err = gsub(/"is_error":true/, "&", $0)
      tool_error += n_err
      if (index($0, "\"toolUseResult\":{") > 0) {
        tr = extract_blob($0, "toolUseResult")
        if (index(tr, "\"stdout\"") > 0 || index(tr, "\"stderr\"") > 0) {
          bash_total++
          stderr_val = extract_str(tr, "stderr")
          if (index(tr, "\"interrupted\":true") > 0 || length(stderr_val) > 0) bash_error++
        } else if (index(tr, "\"structuredPatch\"") > 0) {
          edit_total++
          if (index(tr, "\"userModified\":true") > 0) edit_reverted++
          fp = extract_str(tr, "filePath")
          if (fp != "") file_edits[fp]++
        }
      }
    }
  }
  END {
    printf "session: %s\n", session_id
    if (title != "") printf "title:   %s\n", title
    printf "project: %s\n", project_name
    if (cwd != "")    printf "cwd:     %s\n", cwd
    if (branch != "") printf "branch:  %s\n", branch
    if (first_ts != "") {
      printf "期間:    %s 〜 %s", first_ts, last_ts
      dur_cmd1 = "date -d \"" first_ts "\" +%s 2>/dev/null"
      dur_cmd1 | getline t1
      close(dur_cmd1)
      dur_cmd2 = "date -d \"" last_ts "\" +%s 2>/dev/null"
      dur_cmd2 | getline t2
      close(dur_cmd2)
      dur_s = (t2 + 0) - (t1 + 0)
      if (dur_s > 0) printf "  (%dh%02dm)", int(dur_s/3600), int(dur_s/60)%60
      print ""
    }
    printf "human turns: %d件\n", human_turns+0
    print "---"
    for (m in turns) {
      printf "%s: %dturns  input=%d output=%d cache_write=%d cache_read=%d  total=%d\n", \
        m, turns[m], sum_in[m], sum_out[m], sum_cw[m], sum_cr[m], \
        sum_in[m]+sum_out[m]+sum_cw[m]+sum_cr[m]
    }
    print "---"
    printf "tool使用回数 (計%d件):\n", tool_total+0
    sortcmd = "sort -t\"\t\" -k1,1 -rn"
    for (t in tool_counts) printf "%d\t  %-30s %d件\n", tool_counts[t], t, tool_counts[t] | sortcmd
    close(sortcmd)
    print "---"
    bash_rate = (bash_total > 0) ? bash_error / bash_total * 100 : 0
    edit_rate = (edit_total > 0) ? edit_reverted / edit_total * 100 : 0
    tool_err_rate = (tool_total > 0) ? tool_error / tool_total * 100 : 0
    printf "bash: %d件中%d件エラー (%.0f%%)\n", bash_total+0, bash_error+0, bash_rate
    printf "edit: %d件中%d件手動修正 (%.0f%%)\n", edit_total+0, edit_reverted+0, edit_rate
    printf "tool全体: %d件中%d件エラー (%.0f%%)\n", tool_total+0, tool_error+0, tool_err_rate
    if (edit_total > 0) {
      print "---"
      print "編集ファイル:"
      for (f in file_edits) printf "%d\t  %-70s %d件\n", file_edits[f], f, file_edits[f] | sortcmd
      close(sortcmd)
    }
    if (skill_total > 0) {
      print "---"
      printf "Skill参照 (計%d件, command=ユーザーが/コマンドで指定 / auto=AIが判断して呼び出し):\n", skill_total+0
      for (s in skill_counts) printf "%d\t  %-20s %d件 (command:%d / auto:%d)\n", \
        skill_counts[s], s, skill_counts[s], skill_cmd[s]+0, skill_auto[s]+0 | sortcmd
      close(sortcmd)
    }
  }
  ' "$transcript_path" | awk -F'\t' '{ if (NF >= 2) { sub(/^[^\t]*\t/, ""); print } else print }'
}

run_report() {
  local days=30
  local project_filter=""
  local session_filter=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --days) days="$2"; shift 2 ;;
      --project) project_filter="$2"; shift 2 ;;
      --detail) session_filter="$2"; shift 2 ;;
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
    done < <(find "$d" -maxdepth 1 -name "${session_filter}*.jsonl")
  done

  if [ ${#files[@]} -eq 0 ]; then
    echo "該当するセッションが見つかりませんでした。"
    return 0
  fi

  if [ -n "$session_filter" ]; then
    local f
    for f in "${files[@]}"; do
      print_session_detail "$f"
      echo
    done
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

run_report "$@"
