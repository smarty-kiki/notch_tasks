<p align="center">
  <img src="docs/logo.png" width="140" alt="任务坞">
</p>

<h1 align="center">任务坞 · NotchTasks</h1>

<p align="center">
  屏幕右边缘的一枚把手，悬停展开，把 <b>WorkBuddy</b> 和<b>终端里的 Claude Code CLI</b> 的任务状态收在一处。
</p>

<p align="center">
  <a href="https://github.com/OWNER/notch_tasks/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/OWNER/notch_tasks/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/OWNER/notch_tasks/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/OWNER/notch_tasks?display_name=tag&sort=semver"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Universal" src="https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-blue">
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-green"></a>
</p>

> 仓库名是 `notch_tasks`，产物和应用名是 `NotchTasks` /「任务坞」。

鼠标停到屏幕右边缘靠上的把手，面板向左展开；有任务**完成**或**待确认**时，
把手会亮起脉冲描边 + 光晕 + 角标，并可选地响一声、发一条系统通知。

| | |
|---|---|
| ![收起](docs/preview/01-收起.png) | ![展开](docs/preview/02-展开.png) |
| 空闲 | 展开 |

## 安装

**下载现成的**：到 [Releases](https://github.com/OWNER/notch_tasks/releases/latest) 下载
`NotchTasks-<版本>-macos-universal.zip`，解压把 `NotchTasks.app` 拖进「应用程序」。

首次打开会被 Gatekeeper 拦（产物是 ad-hoc 签名，没有 Developer ID），
**右键点图标 →「打开」**，或：

```bash
xattr -dr com.apple.quarantine /Applications/NotchTasks.app
```

**自己编**：

```bash
git clone https://github.com/OWNER/notch_tasks.git
cd notch_tasks
./run.sh
```

## 它监控什么

| 来源 | 数据 | 怎么读的 |
|---|---|---|
| WorkBuddy | `~/.workbuddy/workbuddy.db` 的会话与自动化运行 | 每轮复制到临时目录再查，**从不打开原库** |
| Claude Code CLI | `~/.claude/sessions/<pid>.json` 的会话与 `status` | 只读，不写 |

两个数据源都不存在时也不会崩，面板只是显示空状态。

| 状态 | 形态 |
|---|---|
| 收起 | **32×68** 黑色胶囊，紧贴屏幕右边缘，距顶 104pt |
| 展开 | **420×自适应高度**，形状右上角不动、向左下展开，左/上/下圆角 26 |

**右侧贴屏幕，交界处用反角（凹角）**：形状的右边缘直接贴住屏幕，
在与上、下边交界处用一段凹曲线向上 / 向下翘起融进屏幕边缘——
看上去是从屏幕边缘「长出来」的，而不是被一刀切断（直角贴边会有被切掉的感觉）。

形状外圈留了 **44pt 留白**（左 / 上 / 下，右侧贴屏幕不留），用途有三：

1. 反角向上/下翘起的空间（反角半径 14 ≤ 44）
2. **告警光晕的完整衰减空间**。`.shadow(radius: 18)` 的可视范围约 38pt，
   留白小于它就会在窗口边界被硬切——表现成光晕最外圈有一道不自然的断口。
   实测：留白 20pt 时窗口边界处光强还比背景高 0.12；44pt 时降到 0.000
3. 描边自身的光晕（radius 7）

留白大了会白白吞掉点击，所以**空闲且收起时把窗口设成不接收鼠标事件**
（`panel.ignoresMouseEvents`，见 `updateMouseEventPolicy()`）：
- 空闲 + 收起 → 不吃事件，留白区域点得到下面的东西
- 有告警、或已展开 → 接收事件（要不点不到任务行）

悬停感应区单独用 `shapeFrame(expanded:)`（形状本身的矩形）算，
不跟着留白一起变大，否则留白一加，鼠标离得老远就会展开。

预览图见 `docs/preview/`，离屏逐帧对比见 `docs/生长动画-右侧吸附.png`，
**真实窗口里抓的展开帧**见 `docs/live/`。

> 展开态圆角用 26 而不是按比例的小值：把手 32 宽配 16 圆角就是胶囊，视觉上很圆；
> 同样的小圆角放到 420 宽的面板上几乎看不出圆，会显得像直角。

## 列表里的来源区分

每一行右侧都有一个**来源标签**，固定宽度所以各行对齐：

| 来源 | 标签 | 颜色 | 点击后 |
|---|---|---|---|
| WorkBuddy（对话 / 自动化） | `WorkBuddy` | 蓝 | 切回 WorkBuddy |
| 终端 Claude Code CLI | `Claude CLI` | 绿 | 切到 iTerm2 |

状态由左侧圆点 + 右侧文字表示，**按颜色区分**，不用去猜词义：

| 状态 | 颜色 | 什么时候 |
|---|---|---|
| 执行中 | 蓝 | 正在干活 |
| **待确认** | 橙 | 等你确认 / 授权 / 有未读结果 |
| 空闲 | 明亮绿 | 没事干：会话活着但停着，或任务刚结束不久 |
| 已完成 | 灰蓝 | 早就结束了 |
| 失败 | 红 | 失败 / 中断 |

和来源是两个独立的维度，互不干扰：来源看右侧标签，状态看圆点 + 颜色。

## 提醒形态

| 状态 | 把手表现 |
|---|---|
| 常态 | 黑色胶囊 + 蓝点（有任务在跑）+ 灰色握把 |
| 待确认 | 橙色 2.5pt 描边 + 两层光晕，**22×22 橙色角标**（白描边 + 自发光） |
| 刚完成 | 绿色同上 |

**描边走不闭合路径**（`MorphPath(closed: false)`）：
从右上反角贴屏幕的一端起笔 → 顶边 → 左 → 底边 → 右下反角贴屏幕的一端收笔。
也就是说**只排除贴着屏幕的那段直边**：

- 反角要描 —— 光晕顺着凹曲线收进屏幕边缘，是「从边缘长出来」的收口
- 右直边不描 —— 一条黄线贴着屏幕边缘闪，纯属劣质

角标的光晕半径压到 3 / 6，同样是为了不让它溢到贴屏那条边。

**没有告警时不加任何投影**：形状外圈只会画画告警色的光晕，
黑色投影会让面板外围浮出一圈灰，在浅色壁纸上很明显。

角标会随呼吸动画在 1.0 / 0.88 之间缩放，描边与光晕亮度同步脉冲。
另有声音（Glass / Ping / Basso）和系统通知。

## 展开 / 收起动画

把手和面板是同一个形状在变形，**锚点写在路径计算里**，不依赖 SwiftUI 的布局对齐或隐式 frame 插值：

- `MorphPath`（`Shape`）用 `progress`（0→1）线性插值宽高、圆角与反角半径，
  形状的右边缘恒定贴住容器右侧（也就是屏幕右边缘）
- **形状必须拿到「容器尺寸」的 rect，这有两个坑**（都踩过）：
  1. 直接让它 `.fill()` 的话，`ZStack` 会按**形状路径的包围盒**收缩，
     `path(in:)` 收到的 rect 变成形状自己的尺寸，`rect.maxX - w` 退化成左侧留白
     → 用 `GeometryReader` 拿真实容器尺寸 + 每个形状显式 `.frame(width:height:)`
  2. 如果 `ui.expanded` 的翻转变更进了 `withAnimation` 事务，SwiftUI 会把**容器尺寸**
     也一起插值（52×108 → 440×314），rect 于是逐帧变化，坑 1 会以另一种形式复现
     → `ui.expanded` 必须在动画事务**之外**翻转，只让 `progress` 进动画
- 同一个 `MorphPath` 同时用于**背景填充、内容裁剪、告警描边**，三者几何必然一致，
  动画中内容不会溢出还在变小的背景（描边用 `closed: false` 的不闭合版本）
- 展开时**先把窗口撑到目标尺寸**再播动画，避免生长过程被窗口边界裁掉；
  收起时等收缩动画播完再缩窗口
- 形状右上角在容器内、以及容器的右上角在屏幕上，两段映射在两个状态下都是**同一个点**，
  所以不存在「参考系跳变导致从窗口左上角长出来」的问题

逐帧验证（`--animframes`）的形状包围盒，右边缘全程不动（440 = 画布右边缘 = 屏幕边缘）：

| progress | x 范围 | y 范围 |
|---|---|---|
| 0.0 | 408…**440** | 14…94 |
| 0.4 | 252…**440** | 12…218 |
| 0.8 | 98…**440** | 10…342 |
| 1.0 | 20…**440** | 10…404 |

（画布 440×412，右边缘 440 即屏幕边缘。y 从 14 渐变到 10 是反角半径随形状放大的结果。）

## 数据来源（**全程只读**）

| 来源 | 内容 |
|---|---|
| `~/.workbuddy/workbuddy.db` → `sessions` | 会话任务：标题、状态、工作目录、最后活动时间、未读 |
| `~/.workbuddy/workbuddy.db` → `automation_runs` | 自动化运行，`read_at IS NULL` = 待确认 |
| `~/.workbuddy/tasks/<sessionId>/*.json` | 当前 `in_progress` 子任务，作为「正在：xxx」 |
| `~/.claude/sessions/<pid>.json` | 终端里 Claude Code CLI 的会话与执行状态 |

**零写入保证**：程序从不打开原库。每轮把 `workbuddy.db` / `-wal` / `-shm`
复制到系统临时目录 `notchtasks-snapshot/`，只在副本上查询，并加 `PRAGMA query_only=ON`。
副本会做一次 `SELECT count(*)` 校验，撕裂即丢弃重读。

### 终端 Claude Code CLI

`~/.claude/sessions/<pid>.json`（文件名就是 PID）里带了现成的状态字段：

```json
{"pid":44187,"sessionId":"…","cwd":"…/crewup_api","name":"crewup-api-ef",
 "status":"busy","updatedAt":1790944083343}
```

- `status` 已知三种取值：
  - `busy` = 正在执行
  - `idle` = 空闲，停在提示符等你输入
  - **`waiting` = 停在等你确认 / 授权**，此时会多一个 `waitingFor` 字段
    （例如 `"permission prompt"`），映射成橙黄色的「待确认」并触发把手告警
- 未知取值一律按「运行中」处理，原始英文只写进 `NOTCHTASKS_DEBUG` 日志，不显示在界面上
- 存活判断：`kill(pid, 0)` **加上** `proc_pidpath` 校验可执行文件里含 `claude`，
  排除 PID 被系统复用后出现的幽灵会话
- 标题用 Claude 自己给会话起的 `name`（同时是它的终端标题），便于和 iTerm2 标签页对上
- 时间取「`updatedAt` 字段」与「文件 mtime」里更晚的那个

## 状态映射

WorkBuddy 和 Claude Code CLI 各自把自家取值映射到**同一套**状态上，
同一个词在哪边都是同一件事：

| 展示 | 含义 | 配色 | 来源 |
|---|---|---|---|
| 执行中 | 正在干活 | 蓝 `#298FFF` | WorkBuddy `status = 'working'` / CLI `status = 'busy'` |
| **待确认** | 等你确认 / 授权 / 有未读结果 | 橙 `#FF9E0A` | WorkBuddy `status = 'pending'`、`unread != 0`、自动化 `read_at IS NULL`、CLI `status = 'waiting'` |
| 空闲 | 没事干 | **明亮绿** `#33CC5C` | CLI `status = 'idle'`（进程还在、停在提示符）；**或任务刚结束**（见下） |
| 已完成 | 早就结束了 | **灰蓝** `#6B9EB8` | `status = 'completed'`，且结束已超过 10 分钟 |
| 失败 | 失败 / 中断 | 红 `#FF4A3D` | `status in ('error','terminated')` / 自动化 `result_success = 0` |
| 不显示 | — | — | `status = 'archived'` |

### 「刚完成」与「早就完成」

`done` 是**同一个逻辑状态**，只按时间分成两个视觉档位
（`TaskItem.recentDoneWindow`，默认 10 分钟）：

| 结束距今 | 显示 | 配色 |
|---|---|---|
| ≤ 10 分钟 | 空闲 | 明亮绿，还「热」 |
| > 10 分钟 | 已完成 | 灰蓝，安静下来了 |

这样视线焦点天然落在「刚有动静的东西」上，而几十小时前的旧任务不会一直抢眼。
排序也走展示状态，所以刚结束的（绿）排在早就结束的（灰）前面。

> CLI 的 `idle` 一直显示成绿色的「空闲」——进程还活着，随时可以接着用；
> 而 WorkBuddy 的任务结束了就是结束了，所以会随着时间从绿沉到灰。

> ⚠️ WorkBuddy 的 `pending` 很容易被误读成「排队中」，实际含义是**停在等你确认 / 选择**。
> 本 App 把它映射成橙黄的「待确认」并让它参与把手告警——
> 一个卡在等你回话的任务，正是最该提醒你的事。

> 「有未读结果」和「等待确认」都套 24 小时窗口，避免一个没人理会的旧状态让把手永久亮着。

时间窗：列表只显示 7 天内；更早的旧未读不再当作待确认，避免永久亮灯。

整套映射可以离线打出来核对（冒烟测试也在断言它）：

```bash
./build/NotchTasks --states
```

## 构建与运行

```bash
./run.sh                 # 构建 + 启动
./build.sh               # 只构建，产物在 dist/NotchTasks.app
./build.sh --universal   # 通用二进制（arm64 + x86_64）
./package.sh             # 打发布包 → dist/NotchTasks-<版本>-macos-universal.zip
make help                # 全部命令（build / run / test / preview / icons / clean）
```

无 GUI 自检：

```bash
./build/NotchTasks --dump                    # 打印当前读到的任务
./build/NotchTasks --preview /tmp/np         # 离屏渲染各状态界面 PNG（不需要屏幕录制权限）
./build/NotchTasks --animframes /tmp/an      # 逐帧渲染生长动画（progress 0→1），验证锚点
./build/NotchTasks --hittest 150 81 6        # 面板内坐标 → 命中的行/底栏按钮
./build/NotchTasks --states                  # 状态映射表（逻辑状态 → 展示状态 + 配色）
```

在真实窗口里抓展开动画的帧（离屏渲染验证不了窗口/容器在各时刻的实际状态）：

```bash
NOTCHTASKS_DEBUG=1 NOTCHTASKS_ANIMPROBE=/tmp/live \
  ./dist/NotchTasks.app/Contents/MacOS/NotchTasks
# 输出 /tmp/live/live-*.png，并打印每帧 path(in:) 收到的 rect
```

调试：

```bash
NOTCHTASKS_FORCE_ALERT=confirm|done|running|idle ./dist/NotchTasks.app/Contents/MacOS/NotchTasks
NOTCHTASKS_DEBUG=1 ./dist/NotchTasks.app/Contents/MacOS/NotchTasks   # 打印窗口/容器几何
```

## 操作

- **悬停**把手 → 展开；**移开约 1 秒后**收起（0.8s 等待 + 0.22s 收缩动画）。
  倒计时从离开那一刻起算，之后鼠标怎么动都不会推迟；中途回到面板上则撤销倒计时
- **点击任务行按来源跳转**（看行右侧的来源标签）：`WorkBuddy` → 切回 WorkBuddy；
  `Claude CLI` → 切到 iTerm2（只把 iTerm2 带到前台，不切具体标签页）
- 面板底部：打开 WorkBuddy / 立即刷新 / 声音开关 / 退出
- **菜单栏图标** 提供：显示条数、显示屏幕、系统通知开关、刷新、退出

## 点击为什么不用 SwiftUI 手势

本 app 是 accessory（无 Dock 图标）且**永远不会成为活跃 app**——前台始终是 WorkBuddy。
这种窗口里 SwiftUI 的 `Button` / `onTapGesture` 收不到点击，所以：

- 行点击和底栏按钮都由控制器自己命中：`UIState.hitTest(_:rowCount:)` 把面板窗口内的点
  （左上角原点）映射成 `row(i)` / `footer(i)` / `none`
- 两条投递路径并存并去重（250ms）：
  1. `FirstMouseHostingView.mouseDown`（点击直接落到我们窗口时）
  2. `NSEvent.addGlobalMonitorForEvents(.leftMouseDown)` + 屏幕坐标换算
     （点击被窗口系统交给前台 app 时）
- 底栏按钮因此改成**纯展示**（`FooterChip`），宽度固定写在 `UIState.footerLeftWidths`，
  保证渲染位置和命中区间严格一致，避免"看起来点到了但没中"

`--hittest` 可以离线验证这套映射。

## 已知边界

- 把手会占住右边缘靠上的一条 32×68 区域（约 y 104–172），紧贴屏幕边缘
- 窗口层级 26，高于菜单栏，会出现在所有 Space / 全屏应用之上
- 未做开机自启动；如需，可在「系统设置 → 通用 → 登录项」里手动添加 `dist/NotchTasks.app`
- 首次运行会申请通知权限；不授权也不影响把手本身的提醒

## 源码结构

```
Sources/
  main.swift       入口，--dump / --preview / --animframes 模式
  Models.swift     TaskItem / TaskState / AlertLevel
  Database.swift   只读 SQLite（快照复制）
  ClaudeStore.swift 终端 Claude Code CLI 会话（只读 ~/.claude/sessions）
  TaskStore.swift  轮询、查询、状态跃迁检测
  NotchUI.swift    UIState / MorphPath / SideShape / 把手 / 面板
  App.swift        窗口控制器、几何与锚点、悬停检测、通知、菜单栏
  Preview.swift    离屏渲染：静态预览 + 逐帧动画
tools/
  make-icon.swift  App 图标生成（可复现，产出 Resources/AppIcon.icns + docs/logo.png）
scripts/
  smoke-test.sh    冒烟测试，本地和 CI 共用
.github/workflows/
  ci.yml           构建 + 冒烟测试 + 通用二进制
  release.yml      推 v* 标签自动打包并创建 Release
```

## 参与贡献

欢迎提 issue 和 PR。动手前请先看 [CONTRIBUTING.md](CONTRIBUTING.md)——
里面记了三个容易踩的坑（生长动画的锚点、光晕留白与点击、为什么不能用 SwiftUI 手势），
以及本地怎么跑冒烟测试和界面预览。

## 许可

[MIT](LICENSE)
