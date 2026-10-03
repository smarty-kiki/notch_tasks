#!/usr/bin/env bash
#
# 冒烟测试（CI 和本地共用）
#
#   ./scripts/smoke-test.sh
#
# 不用起 GUI，也不需要你本机的 WorkBuddy / Claude 数据。检查：
#   1. 数据源全缺时也不崩
#   2. Claude 注册表被写坏（尾部残渣）时仍能解析出会话
#   3. 状态映射（展示状态 + 配色）符合预期
#   4. 点击命中映射正确
#   5. 各状态离屏渲染都能出图、且画布尺寸符合布局常量
#   6. 生长动画逐帧都能出图
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
echo "== 1/6 数据源缺失时不崩"
HOME="$TMP/empty-home" "$BIN" --dump > "$TMP/dump.txt" || fail "--dump 退出码非 0"
grep -q "读取时间" "$TMP/dump.txt" || fail "--dump 输出不完整"
ok "--dump 正常输出"

# ---------------------------------------------------------------- 2
echo "== 2/6 Claude 数据源：注册表写坏 / 注册表漏记"
# Claude Code 重写 sessions/<pid>.json 时存在「内容变短但不截断」的竞态：
# 旧内容更长时，文件尾部会留下上一次写下的残片，例如
#     {...完整的对象...}51,"waitingFor":"permission prompt"}
# 严格 JSON 解析遇到这种 extra data 会直接报错。曾经用 `try?` 一包，
# 整条会话就被静默丢掉了 —— 现象是进程活得好好的、sessions/ 里也有文件，
# 列表里却一个 CLI 会话都没有。这条用例就是钉住那个修复。
FAKE_HOME="$TMP/fake-home"
mkdir -p "$FAKE_HOME/.claude/sessions"
cat > "$FAKE_HOME/.claude/sessions/12345.json" <<'JSON'
{"pid":12345,"sessionId":"00000000-0000-0000-0000-000000000000","cwd":"/tmp/demo","name":"demo-1","status":"waiting","updatedAt":1790962853751,"statusUpdatedAt":1790962853751}51,"waitingFor":"permission prompt"}
JSON

CLI_OUT="$(HOME="$FAKE_HOME" "$BIN" --claude)"
printf '%s\n' "$CLI_OUT" | grep -q "严格解析: 失败" \
  || fail "带残渣的文件竟被严格解析通过了，这条用例已失效"
printf '%s\n' "$CLI_OUT" | grep -q "取值: pid=12345 name=demo-1 status=waiting" \
  || fail "带尾部残渣的注册表没能解析出字段"
ok "带尾部残渣 → 仍解析出 pid=12345 / waiting"

# 干净文件也必须照常通过（别为了容错把正常路径弄坏）
cat > "$FAKE_HOME/.claude/sessions/22222.json" <<'JSON'
{"pid":22222,"sessionId":"11111111-1111-1111-1111-111111111111","cwd":"/tmp/demo2","name":"demo-2","status":"busy","updatedAt":1790962853751}
JSON
printf '%s\n' "$(HOME="$FAKE_HOME" "$BIN" --claude)" | grep -q "取值: pid=22222 name=demo-2 status=busy" \
  || fail "干净的注册表解析失败"
ok "干净注册表照常解析"

# 注册表**漏记**的会话也要能发现：被程序 spawn 出来的 claude（比如数字员工平台起的）
# 照样写会话记录、照样在干活，却不写 sessions/<pid>.json。只看注册表会整条漏掉，
# 所以会话发现是「注册表 ∪ 最近在动的记录」。这里用假的记录文件钉住这条逻辑。
PROJ="$FAKE_HOME/.claude/projects/-tmp-demo"
mkdir -p "$PROJ"

cat > "$PROJ/9e9e9e9e-1111-2222-3333-444455556666.jsonl" <<'JSONL'
{"type":"mode","sessionId":"9e9e9e9e-1111-2222-3333-444455556666"}
{"type":"ai-title","aiTitle":"示例：正在跑工具的会话"}
{"type":"assistant","cwd":"/tmp/demo","message":{"role":"assistant","content":[{"type":"tool_use"}],"stop_reason":"tool_use"}}
JSONL

cat > "$PROJ/8d8d8d8d-1111-2222-3333-444455556666.jsonl" <<'JSONL'
{"type":"ai-title","aiTitle":"示例：已经答完的会话"}
{"type":"assistant","cwd":"/tmp/demo2","message":{"role":"assistant","content":[{"type":"text"}],"stop_reason":"end_turn"}}
JSONL

OUT2="$(HOME="$FAKE_HOME" "$BIN" --claude)"
printf '%s\n' "$OUT2" | grep -q "只有会话记录在动的（最近 15 分钟）: 2 条" \
  || fail "注册表漏记的会话没被发现"
printf '%s\n' "$OUT2" | grep -q "推断 status=busy" || fail "没从 stop_reason=tool_use 推断出 busy"
printf '%s\n' "$OUT2" | grep -q "推断 status=idle" || fail "没从 stop_reason=end_turn 推断出 idle"
printf '%s\n' "$OUT2" | grep -q "示例：正在跑工具的会话" || fail "没读到记录里的 aiTitle"
printf '%s\n' "$OUT2" | grep -q "cwd=/tmp/demo" || fail "没读到记录里的 cwd"
ok "注册表漏记的会话从记录补回（aiTitle / cwd / busy-idle 都对）"

# ---------------------------------------------------------------- 3
echo "== 3/6 状态映射（WorkBuddy 与 Claude CLI 统一到同一套）"
# 「展示状态 + 配色」是列表上唯一可见的东西，锁死它，
# 免得以后改映射时把「刚完成」和「早就完成」又混回去
STATES="$("$BIN" --states)"
assert_state() {  # 场景前缀 期望展示 期望配色
  local line
  line="$(printf '%s\n' "$STATES" | awk -v k="$1" 'index($0, k) == 1')"
  [ -n "$line" ] || fail "缺少场景「$1」"
  case "$line" in
    *"$2"*"$3"*) ok "$1 → $2 $3" ;;
    *) fail "$1 得到「$line」，期望 $2 / $3" ;;
  esac
}
assert_state "WorkBuddy working"  "执行中" "#298FFF"
assert_state "WorkBuddy pending"  "待确认" "#FF9E0A"
assert_state "Claude CLI busy"    "执行中" "#298FFF"
assert_state "Claude CLI waiting" "待确认" "#FF9E0A"
assert_state "Claude CLI idle"    "空闲"   "#33CC5C"
assert_state "完成 10 秒"          "空闲"   "#33CC5C"   # 刚完成 → 明亮绿
assert_state "完成 9 分钟"         "空闲"   "#33CC5C"   # 还在窗口内
assert_state "完成 11 分钟"        "已完成" "#6B9EB8"   # 沉成灰蓝
assert_state "完成但有未读"        "待确认" "#FF9E0A"

# ---------------------------------------------------------------- 3
echo "== 4/6 点击命中映射"
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
echo "== 5/6 离屏渲染"
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
echo "== 6/6 生长动画逐帧"
HOME="$TMP/empty-home" "$BIN" --animframes "$TMP/anim" > /dev/null || fail "--animframes 退出码非 0"
count="$(find "$TMP/anim" -name '*.png' | wc -l | tr -d ' ')"
[ "$count" -ge 6 ] || fail "只生成了 $count 帧"
ok "生成 $count 帧"

echo
echo "全部通过 ✓"
