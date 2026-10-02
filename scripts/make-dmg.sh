#!/usr/bin/env bash
#
# 把 .app 打成 dmg
#
#   ./scripts/make-dmg.sh <app路径> <输出.dmg> [卷名]
#
# 做两件事：
#   1. 把 .app 拷进一个临时目录，再放一个指向 /Applications 的软链——
#      挂载后用户直接把图标拖到软链上就装好了，这是 macOS 上最顺手的装法
#   2. hdiutil -srcfolder 生成压缩磁盘映像（UDZO）
#
# 用 ditto 拷贝而不是 cp -R：保住扩展属性与签名，不然挂载后打开会被 Gatekeeper 拦。
#
set -euo pipefail

APP="${1:-}"
OUT="${2:-}"
VOL="${3:-NotchTasks}"

if [ -z "$APP" ] || [ -z "$OUT" ]; then
  echo "用法：make-dmg.sh <app路径> <输出.dmg> [卷名]" >&2
  exit 2
fi
[ -d "$APP" ] || { echo "找不到 $APP" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$OUT" > /dev/null

echo "    $OUT  ($(du -h "$OUT" | cut -f1))"
