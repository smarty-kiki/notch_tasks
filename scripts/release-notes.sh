#!/usr/bin/env bash
#
# 从 CHANGELOG.md 里抽出某个版本的段落，用来当 GitHub Release 的正文
#
#   ./scripts/release-notes.sh 1.0.0
#   ./scripts/release-notes.sh            # 不给就用 VERSION 里的
#
# 输出到 stdout；找不到该版本时退出码为 1（调用方可以退回 --generate-notes）。
# 之所以不用 `gh release create --generate-notes`：那玩意只列 PR 和提交者，
# 按 Conventional Commits 写的东西在 CHANGELOG 里分类整理过，更适合给人看。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"

V="${1:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
[ -n "$V" ] || { echo "没给版本号，且 VERSION 是空的" >&2; exit 1; }
[ -f "$CHANGELOG" ] || { echo "找不到 $CHANGELOG" >&2; exit 1; }

NOTES="$(awk -v v="$V" '
  BEGIN            { hdr = "## [" v "]" }
  index($0, hdr) == 1 { found = 1; next }
  found && substr($0, 1, 3) == "## " { exit }
  found            { print }
' "$CHANGELOG")"

# 去掉首尾空行（中间的保留，别把段落挤没了）
NOTES="$(printf '%s\n' "$NOTES" | awk '
  { lines[NR] = $0; if (NF) { if (!first) first = NR; last = NR } }
  END { for (i = first; i <= last; i++) print lines[i] }
')"

if [ -z "$NOTES" ]; then
  echo "CHANGELOG.md 里没有 [$V] 这一段" >&2
  exit 1
fi

printf '%s\n' "$NOTES"
