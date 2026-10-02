#!/usr/bin/env bash
#
# 构建「任务坞」.app
#
#   ./build.sh                 构建到 dist/NotchTasks.app（本机架构）
#   ./build.sh --universal     同时编 arm64 + x86_64 并 lipo 成通用二进制
#   ./build.sh --debug         不优化、带调试符号
#   ./build.sh --clean         先删掉 build/ 和 dist/NotchTasks.app
#
# 版本号读仓库根的 VERSION 文件；release 工作流会用 tag 覆盖它。
# 可用环境变量覆盖：VERSION / BUILD_NUMBER / TARGET_ARCH
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="NotchTasks"
BUNDLE_ID="com.smarty.notchtasks"      # 改这个会让偏好设置和通知授权重置
MIN_MACOS="14.0"

BUILD="$ROOT/build"
DIST="$ROOT/dist"
BUNDLE="$DIST/$APP_NAME.app"

UNIVERSAL=0
DEBUG=0
CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --debug)     DEBUG=1 ;;
    --clean)     CLEAN=1 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$arg（试试 --help）" >&2; exit 2 ;;
  esac
done

# ---------- 版本 ----------
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

# ---------- 清理 ----------
if [ "$CLEAN" = "1" ]; then
  echo "==> 清理"
  rm -rf "$BUILD"
  # 某些环境下删 .app 会被拦，拦不住就原样覆盖
  rm -rf "$BUNDLE" 2>/dev/null || echo "   (无法删除旧 bundle，将原样覆盖)"
fi

mkdir -p "$BUILD" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

SDK="$(xcrun --show-sdk-path)"
HOST_ARCH="$(uname -m)"

COMMON_FLAGS=(
  -sdk "$SDK"
  -framework AppKit
  -framework SwiftUI
  -framework UserNotifications
  -lsqlite3
  -Xfrontend -disable-sandbox      # 关掉编译器自带的 sandbox，避免中间产物写入被拦
)
if [ "$DEBUG" = "1" ]; then
  OPT_FLAGS=(-Onone -g)
else
  OPT_FLAGS=(-O -whole-module-optimization)
fi

compile_arch() {          # $1 = arch，$2 = 输出路径
  echo "      - $1"
  swiftc "${OPT_FLAGS[@]}" -target "$1-apple-macos${MIN_MACOS}" \
    "${COMMON_FLAGS[@]}" "$ROOT"/Sources/*.swift -o "$2"
}

echo "==> 编译  版本 $VERSION (build $BUILD_NUMBER)"
if [ "$UNIVERSAL" = "1" ]; then
  echo "   target: universal (arm64 + x86_64)"
  compile_arch arm64  "$BUILD/$APP_NAME-arm64"
  compile_arch x86_64 "$BUILD/$APP_NAME-x86_64"
  lipo -create -output "$BUILD/$APP_NAME" \
       "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
  rm -f "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64"
else
  ARCH="${TARGET_ARCH:-$HOST_ARCH}"
  echo "   target: $ARCH"
  compile_arch "$ARCH" "$BUILD/$APP_NAME"
fi

echo "==> 组装 bundle"
cp -f "$BUILD/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp -f "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp -f "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "   ⚠️  缺少 Resources/AppIcon.icns（跑 swift tools/make-icon.swift 生成）"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                        -c "Set :CFBundleVersion $BUILD_NUMBER" \
                        "$BUNDLE/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> ad-hoc 签名"
if codesign --force --sign - --timestamp=none "$BUNDLE" 2>/dev/null; then
  echo "   已签名（ad-hoc；不是 Developer ID，首次打开需右键→打开）"
else
  echo "   签名失败，本地仍可运行"
fi

SIZE="$(du -sh "$BUNDLE" | cut -f1)"
echo
echo "==> 完成"
echo "    产物   $BUNDLE  ($SIZE)"
echo "    版本   $VERSION ($BUILD_NUMBER)"
echo "    架构   $(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || echo "$HOST_ARCH")"
