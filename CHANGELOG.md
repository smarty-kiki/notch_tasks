# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [1.0.0] - 2026-10-02

首个版本。

### 新增

- **屏幕右边缘常驻把手**：空闲时是一枚黑色胶囊，紧贴屏幕右边缘、距顶 104pt；
  鼠标悬停向左展开面板，移开约 1 秒后收起（0.8s 等待 + 0.22s 收缩动画）
- **WorkBuddy 任务监控**：读取 `~/.workbuddy/workbuddy.db` 的会话与自动化运行，
  展示执行中 / 待确认 / 已完成 / 失败，并在状态跃迁时提醒
- **等待确认的状态修正**：两处 `status` 的语义都曾被映射错
  - WorkBuddy `session.status = 'pending'` 不是「排队中」，而是**停在等你确认 / 选择**
  - Claude Code CLI `status = 'waiting'`（伴随 `waitingFor`，如 `"permission prompt"`）
    之前落到了兜底分支，界面上直接显示了英文 `waiting`
  两者现在都映射成橙黄色的「待确认」并触发把手告警
- **终端 Claude Code CLI 监控**：读取 `~/.claude/sessions/<pid>.json`，
  用 `status` 字段区分执行中（`busy`）与空闲（`idle`）；
  存活判断结合 `kill(pid,0)` 与 `proc_pidpath`，避免 PID 复用造成的幽灵会话
- **列表区分来源**：每一行右侧带来源标签，`WorkBuddy`（蓝）/ `Claude CLI`（绿）
- **点击跳转**：WorkBuddy 任务切回 WorkBuddy，CLI 任务切到 iTerm2
- **提醒形态**：把手脉冲描边 + 同色光晕 + 角标，另有声音（Glass / Ping / Basso）与系统通知
- **菜单栏图标**：显示条数、显示屏幕、系统通知开关、刷新、退出

### 设计要点

- 面板用 **反角（凹角）** 融进屏幕右边缘，而不是直角切断；
  告警描边只画上 / 左 / 下三条边，贴屏幕的那条不描
- 展开动画的锚点写在 `MorphPath.path(in:)` 的路径计算里，
  形状始终从右上角向左下生长，不依赖 SwiftUI 的隐式 frame 插值

### 说明

- App 图标由 `tools/make-icon.swift` 生成，可复现
- 构建产物是 ad-hoc 签名，首次打开需要右键 →「打开」
- 全部数据源**只读**：WorkBuddy 库每轮快照复制后查询，不写原库
