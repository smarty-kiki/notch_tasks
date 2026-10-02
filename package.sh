#!/usr/bin/env bash
#
# 打出可发布的产物
#
#   ./package.sh               通用二进制 → dist/NotchTasks-<版本>-macos-universal.dmg + .zip
#   ./package.sh --zip-only    只出 zip
#   ./package.sh --host-only   只编本机架构
#
# 两种产物都给，各带一个 .sha256：
#
#   .dmg  挂载后把图标拖进「应用程序」——推荐普通用户下这个
#   .zip  解压即用，也方便被 Homebrew cask 之类的工具消费
#
# dist/ 不进版本库（见 .gitignore）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

BUILD_ARGS=(--clean --universal)
MAKE_DMG=1
for arg in "$@"; do
  case "$arg" in
    --host-only) BUILD_ARGS=(--clean) ;;
    --debug)     BUILD_ARGS+=(--debug) ;;
    --zip-only)  MAKE_DMG=0 ;;
    -h|--help)   sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（试试 --help）" >&2; exit 2 ;;
  esac
done

"$ROOT/build.sh" "${BUILD_ARGS[@]}"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/dist/NotchTasks.app"
BIN="$APP/Contents/MacOS/NotchTasks"
ARCHS="$(lipo -archs "$BIN")"

case "$ARCHS" in
  *"arm64"*"x86_64"*|*"x86_64"*"arm64"*) TAG="universal" ;;
  *) TAG="$(echo "$ARCHS" | tr ' ' '-')" ;;
esac

NAME="NotchTasks-${VERSION}-macos-${TAG}"
ZIP="$ROOT/dist/${NAME}.zip"
DMG="$ROOT/dist/${NAME}.dmg"

# 校验文件写成 `shasum` 的原生格式（哈希 + 文件名），这样下载后能直接用
#   shasum -a 256 -c <文件>.sha256
# 只在文件所在目录跑，所以里面记的是文件名而不是绝对路径
checksum() {
  ( cd "$ROOT/dist" && shasum -a 256 "$(basename "$1")" > "$(basename "$1").sha256" )
}

echo
echo "==> 打包 $NAME"
rm -f "$ZIP" "${ZIP}.sha256" "$DMG" "${DMG}.sha256"

# zip：用 ditto 而不是 zip —— 能保住 .app 里的权限位和扩展属性，签名不会被打坏
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
checksum "$ZIP"

echo
echo "==> 生成 dmg"
if [ "$MAKE_DMG" = "1" ]; then
  "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" "任务坞"
  checksum "$DMG"
else
  echo "    （--zip-only，跳过）"
fi

echo
echo "==> 完成"
echo "    版本   $VERSION"
echo "    架构   $ARCHS"
for f in "$ROOT/dist/${NAME}"*; do
  printf '    %-56s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
