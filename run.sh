#!/bin/bash
# 构建并启动「任务坞」
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
pkill -f NotchTasks 2>/dev/null || true
sleep 0.6
"$ROOT/build.sh"
open "$ROOT/dist/NotchTasks.app"
echo "已启动，看屏幕顶部中央的刘海。退出：菜单栏图标 → 退出任务坞"
