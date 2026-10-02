#!/bin/bash
# 构建并启动「任务坞」
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
pkill -f NotchTasks 2>/dev/null || true
sleep 0.6
"$ROOT/build.sh"
open "$ROOT/dist/NotchTasks.app"
echo "已启动。鼠标扫过屏幕右边缘靠上的把手即可展开"
