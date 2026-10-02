#!/usr/bin/env bash
#
# 打出可发布的压缩包
#
#   ./package.sh               通用二进制 → dist/NotchTasks-<版本>-macos-universal.zip
#   ./package.sh --host-only   只编本机架构
#
# 产物同时生成 .sha256 校验文件。dist/ 不进版本库（见 .gitignore）。
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

BUILD_ARGS=(--clean --universal)
for arg in "$@"; do
  case "$arg" in
    --host-only) BUILD_ARGS=(--clean) ;;
    --debug)     BUILD_ARGS+=(--debug) ;;
    -h|--help)   sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（试试 --help）" >&2; exit 2 ;;
  esac
done

"$ROOT/build.sh" "${BUILD_ARGS[@]}"

VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BIN="$ROOT/dist/NotchTasks.app/Contents/MacOS/NotchTasks"
ARCHS="$(lipo -archs "$BIN")"

case "$ARCHS" in
  *"arm64"*"x86_64"*|*"x86_64"*"arm64"*) TAG="universal" ;;
  *) TAG="$(echo "$ARCHS" | tr ' ' '-')" ;;
esac

NAME="NotchTasks-${VERSION}-macos-${TAG}"
ZIP="$ROOT/dist/${NAME}.zip"

echo
echo "==> 打包 $NAME.zip"
rm -f "$ZIP" "${ZIP}.sha256"
# 用 ditto 而不是 zip：能保住 .app 里的权限位和扩展属性，签名不会被打坏
ditto -c -k --sequesterRsrc --keepParent "$ROOT/dist/NotchTasks.app" "$ZIP"

shasum -a 256 "$ZIP" | awk '{print $1}' > "${ZIP}.sha256"

echo
echo "==> 完成"
echo "    产物   $ZIP  ($(du -h "$ZIP" | cut -f1))"
echo "    校验   ${ZIP}.sha256"
echo "    条目   $(unzip -l "$ZIP" | tail -1 | awk '{print $2}') 个"
echo "    架构   $ARCHS"
