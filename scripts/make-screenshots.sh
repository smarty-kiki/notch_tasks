#!/usr/bin/env bash
#
# 重新生成 docs/ 下的全部界面图
#
#   ./scripts/make-screenshots.sh
#
# 全程走 --demo：渲染用的是 Sources/TaskStore.swift 里的合成任务，
# 不读本机的 WorkBuddy 库、也不扫 ~/.claude。所以产物不含任何个人数据，
# 可以直接进公开仓库——README 里的截图就是它出的。
#
# 改完 UI 或配色，重跑这个脚本，图就和代码一致了。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/NotchTasks"

if [ ! -x "$BIN" ]; then
  echo "== 没有 build/NotchTasks，先构建"
  "$ROOT/build.sh" > /dev/null
fi

PREVIEW="$ROOT/docs/preview"
mkdir -p "$PREVIEW"
rm -f "$PREVIEW"/*.png

echo "== 1/3 各状态静态图"
"$BIN" --preview "$PREVIEW" --demo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo
echo "== 2/3 收起把手的三种形态"
swift "$ROOT/tools/make-strip.swift" "$ROOT/docs/把手三种形态.png" 1.0 \
  "常态 · 收起=$PREVIEW/01-收起.png" \
  "有待确认=$PREVIEW/03-待确认.png" \
  "刚有完成=$PREVIEW/05-完成.png"

echo
echo "== 3/3 生长动画逐帧"
"$BIN" --animframes "$TMP/anim" --demo > /dev/null
swift "$ROOT/tools/make-strip.swift" "$ROOT/docs/生长动画.png" 0.62 \
  "progress 0.0=$TMP/anim/帧-00-progress-0.0.png" \
  "progress 0.4=$TMP/anim/帧-02-progress-0.4.png" \
  "progress 0.8=$TMP/anim/帧-04-progress-0.8.png" \
  "progress 1.0=$TMP/anim/帧-05-progress-1.0.png"

echo
echo "完成："
ls -1 "$ROOT/docs"/*.png "$PREVIEW"/*.png | sed "s|$ROOT/||; s|^|  |"
