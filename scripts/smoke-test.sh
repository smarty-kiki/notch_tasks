#!/usr/bin/env bash
#
# 冒烟测试（CI 和本地共用）
#
#   ./scripts/smoke-test.sh
#
# 不用起 GUI，也不需要你本机的 WorkBuddy / Claude 数据。检查：
#   1. 数据源全缺时也不崩
#   2. 点击命中映射正确
#   3. 各状态离屏渲染都能出图、且画布尺寸符合布局常量
#   4. 生长动画逐帧都能出图
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/NotchTasks"

if [ ! -x "$BIN" ]; then
  echo "找不到 $BIN，先跑 ./build.sh" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "   ✗ $*" >&2; exit 1; }
ok()   { echo "   ✓ $*"; }

# ---------------------------------------------------------------- 1
echo "== 1/4 数据源缺失时不崩"
HOME="$TMP/empty-home" "$BIN" --dump > "$TMP/dump.txt" || fail "--dump 退出码非 0"
grep -q "读取时间" "$TMP/dump.txt" || fail "--dump 输出不完整"
ok "--dump 正常输出"

# ---------------------------------------------------------------- 2
echo "== 2/4 点击命中映射"
# 面板内坐标（左上原点）：留白 44，行区从 44+35 开始，每行 49，底栏 43
assert_hit() {
  local got
  got="$("$BIN" --hittest "$1" "$2" "$3" | tail -1)"
  case "$got" in
    *"$4"*) ok "($1,$2) rows=$3 → $4" ;;
    *) fail "($1,$2) rows=$3 得到「$got」，期望 $4" ;;
  esac
}
assert_hit 150   90 6 "row(0)"
assert_hit 150  240 6 "row(3)"
assert_hit  70  390 6 "footer(0)"
assert_hit 390  390 6 "footer(3)"
assert_hit 300  390 6 "none"       # 底栏按钮之间的空隙
assert_hit  10  120 6 "none"       # 左侧留白内
assert_hit 150   10 6 "none"       # 顶部留白内

# ---------------------------------------------------------------- 3
echo "== 3/4 离屏渲染"
# 画布 = 窗口尺寸，由布局常量决定：
#   收起 = 把手 32×68 + 左右留白，展开 = 面板 420 宽 + 左侧留白 44
# 改 Sources/NotchUI.swift 里的常量时，同步改这里
W_COLLAPSED=76
H_COLLAPSED=156
W_EXPANDED=464

HOME="$TMP/empty-home" "$BIN" --preview "$TMP/preview" > /dev/null || fail "--preview 退出码非 0"

python3 - "$TMP/preview" "$W_COLLAPSED" "$H_COLLAPSED" "$W_EXPANDED" <<'PY' || exit 1
import struct, sys, pathlib
d, wc, hc, we = sys.argv[1], *(int(x) for x in sys.argv[2:5])

SCALE = 2   # Sources/Preview.swift 里 ImageRenderer.scale = 2，PNG 像素是点数的 2 倍

def size(p):
    b = pathlib.Path(p).read_bytes()
    assert b[:8] == b"\x89PNG\r\n\x1a\n", f"{p} 不是 PNG"
    w, h = struct.unpack(">II", b[16:24])
    return w // SCALE, h // SCALE

checks = {
    "01-收起.png":        (wc, hc),
    "03-待确认.png":      (wc, hc),
    "05-完成.png":        (wc, hc),
    "02-展开.png":        (we, None),
    "04-展开-待确认.png": (we, None),
    "06-展开中-0-0.35.png": (we, None),
    "06-展开中-1-0.70.png": (we, None),
}
for name, (ew, eh) in checks.items():
    p = pathlib.Path(d) / name
    if not p.exists():
        print(f"   ✗ 缺少 {name}"); sys.exit(1)
    w, h = size(p)
    if w != ew or (eh is not None and h != eh):
        print(f"   ✗ {name} 尺寸 {w}×{h}pt，期望 {ew}×{eh}pt"); sys.exit(1)
    print(f"   ✓ {name} {w}×{h}pt")
PY

# ---------------------------------------------------------------- 4
echo "== 4/4 生长动画逐帧"
HOME="$TMP/empty-home" "$BIN" --animframes "$TMP/anim" > /dev/null || fail "--animframes 退出码非 0"
count="$(find "$TMP/anim" -name '*.png' | wc -l | tr -d ' ')"
[ "$count" -ge 6 ] || fail "只生成了 $count 帧"
ok "生成 $count 帧"

echo
echo "全部通过 ✓"
