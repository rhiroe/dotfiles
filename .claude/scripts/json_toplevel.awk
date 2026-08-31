#!/usr/bin/awk -f
# 2スペースインデントで整形されたJSONオブジェクトのトップレベルキーだけを
# 操作する軽量ツール。jqに依存できない(インストール先の環境が不明な)
# install.sh/uninstall.shから使う。
#
# 制約: ネストしたキー同士の再帰マージはしない(トップレベルキー単位で
# 値をまるごと置き換える)。2スペースインデント以外の整形やミニファイされた
# JSONには対応しない(呼び出し側で事前にフォーマットを検証すること)。
#
# Usage:
#   awk -v MODE=merge -f json_toplevel.awk TARGET SOURCE
#     TARGETにSOURCEのトップレベルキーをマージ(衝突時はSOURCEが勝つ)して標準出力へ
#   awk -v MODE=del -v KEY=name -f json_toplevel.awk TARGET
#     TARGETからトップレベルキーKEYを削除して標準出力へ

function strip_strings(s,    out, i, c, in_str, esc) {
  out = ""
  in_str = 0
  esc = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (in_str) {
      if (esc) { esc = 0 }
      else if (c == "\\") { esc = 1 }
      else if (c == "\"") { in_str = 0 }
      continue
    }
    if (c == "\"") { in_str = 1; continue }
    out = out c
  }
  return out
}

function brace_delta(line,    s, i, c, d) {
  s = strip_strings(line)
  d = 0
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "{" || c == "[") d++
    else if (c == "}" || c == "]") d--
  }
  return d
}

function rstrip_comma(s) {
  sub(/,[ \t]*$/, "", s)
  return s
}

function parse_toplevel(file, order, val,    line, depth, cur, buf, n, key, rest) {
  n = 0
  depth = 0
  cur = ""
  buf = ""
  while ((getline line < file) > 0) {
    if (depth == 0) {
      if (match(line, /^  "[^"]+" *:/)) {
        key = line
        sub(/^  "/, "", key)
        sub(/" *:.*/, "", key)
        rest = line
        sub(/^  "[^"]+" *: */, "", rest)
        depth += brace_delta(rest)
        cur = key
        buf = line
        if (depth <= 0) {
          n++
          order[n] = cur
          val[cur] = buf
          depth = 0
          cur = ""; buf = ""
        }
      }
      continue
    }
    buf = buf "\n" line
    depth += brace_delta(line)
    if (depth <= 0) {
      n++
      order[n] = cur
      val[cur] = buf
      depth = 0
      cur = ""; buf = ""
    }
  }
  close(file)
  return n
}

function emit(order, val, n,    i, out) {
  print "{"
  for (i = 1; i <= n; i++) {
    out = rstrip_comma(val[order[i]])
    if (i < n) out = out ","
    print out
  }
  print "}"
}

BEGIN {
  if (MODE == "merge") {
    tn = parse_toplevel(ARGV[1], torder, tval)
    sn = parse_toplevel(ARGV[2], sorder, sval)
    for (i = 1; i <= sn; i++) {
      k = sorder[i]
      if (!(k in tval)) {
        tn++
        torder[tn] = k
      }
      tval[k] = sval[k]
    }
    emit(torder, tval, tn)
  } else if (MODE == "del") {
    tn = parse_toplevel(ARGV[1], torder, tval)
    on = 0
    for (i = 1; i <= tn; i++) {
      k = torder[i]
      if (k == KEY) continue
      on++
      oorder[on] = k
      oval[k] = tval[k]
    }
    emit(oorder, oval, on)
  } else {
    print "MODE must be 'merge' or 'del'" > "/dev/stderr"
    exit 1
  }
  exit 0
}
