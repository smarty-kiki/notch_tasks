# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.2] - 2026-10-03

收起过程不再是「整块面板消失」，改成被形状从左边逐步裁掉；移开鼠标后的等待从 0.8 秒缩到 0.5 秒。

### 修复

- **收起时面板不再「整个消失」**：`collapse()` 一进门就把 `expanded` 翻成 false，
  内容层瞬间从面板换成把手，屏幕上是「一块满尺寸的黑色空面板僵在那儿 0.22 秒，
  然后啪地收掉」。现在只动画 `progress`，面板留在原地被形状从左边逐步裁掉，
  收完再换内容、缩窗口。实测抓帧：光晕左端 29→41→71→145→193→336→396pt 单调右移
  （形状确实在连续收缩），面板文字像素 6929→2064→734→164→27 被逐步裁掉；
  收到一半把鼠标移回来会反向播回去，不会卡在半路
- **收起等待 0.8s → 0.5s**，感知上约 0.7s 收干净

### 工程

- 新增 `NOTCHTASKS_COLLAPSEPROBE` / `NOTCHTASKS_COLLAPSEPROBE_AT`：
  在真实窗口里抓收起过程中某一时刻的一帧，用来核对「面板是不是被逐步裁掉」。
  刻意做成一次只抓一帧——同步渲染整棵视图树要几十毫秒，
  在一次 0.22s 的动画里连抓多帧会把主线程占满，量到的就只剩阻塞
- 清掉两处早前补丁重复插入的调用（`installClickMonitor()` 被装了两次，
  靠 250ms 去重才没暴露；`NOTCHTASKS_ANIMPROBE` 挂钩也重复了一份）

## [1.0.1] - 2026-10-03

列表里的 CLI 任务改用 Claude 自己起的会话标题，和 iTerm2 标签页对得上。

### 新增

- **CLI 任务行改用 Claude 自己起的会话标题**：以前显示的是注册表里的派生名
  （`kiki-2d` 这种），跟 iTerm2 标签页上看到的对不上。现在读会话记录
  `projects/<cwd>/<sessionId>.jsonl` 里的 `{"type":"ai-title","aiTitle":"…"}`——
  这正是 Claude 写进终端标签的那个标题。只读文件尾部 256 KB 并按 mtime + size 缓存，
  不必反复解析几十 MB 的记录；会话刚开始还没标题时退回派生名

### 文档

- 说明 `~/.claude/sessions/` 会被 Claude Code **按日清理**（`~/.claude/.last-cleanup`），
  清理后那一刻目录为空、列表里没有 CLI 会话，属于数据源的正常行为

## [1.0.0] - 2026-10-02

首个版本：屏幕右边缘的一枚把手，鼠标扫过去向左展开，把 **WorkBuddy** 与
**终端里的 Claude Code CLI** 的任务状态收在一处。

### 新增

- **屏幕右边缘的把手**：空闲时是一枚 32×68 的黑色胶囊，紧贴屏幕右边缘、距顶 104pt。
  悬停向左展开成 420×自适应高度的面板，移开约 1 秒后收起
  （0.8s 等待 + 0.22s 收缩动画，倒计时从离开那一刻起算）
- **WorkBuddy 监控**：只读 `~/.workbuddy/workbuddy.db` 的 `sessions` 与 `automation_runs`，
  并从 `~/.workbuddy/tasks/<sessionId>/*.json` 取当前 `in_progress` 子任务，
  显示成「正在：…」
- **Claude Code CLI 监控**：只读 `~/.claude/sessions/<pid>.json`（文件名就是 PID），
  用 `status` 区分在跑 / 空闲 / 等你确认；存活判断结合 `kill(pid,0)` 与 `proc_pidpath`，
  排除 PID 被系统复用造成的幽灵会话
- **统一的状态语义**：两个数据源的字段含义并不一致，统一映射到
  待确认（橙）/ 执行中（蓝）/ 空闲（明亮绿）/ 已完成（灰蓝）/ 失败（红）五档，按颜色区分，
  排序也按这套顺序。`done` 是同一个状态，只按时间分两个视觉档位——
  **结束 10 分钟内显示成明亮的「空闲」**，再久沉成灰蓝的「已完成」，
  让视线焦点落在刚有动静的东西上
- **列表区分来源**：每行右侧带固定宽度的来源标签，`WorkBuddy`（蓝）/ `Claude CLI`（绿），
  多行之间标签、标题、状态列全部对齐
- **点击跳转**：点 WorkBuddy 的任务切回 WorkBuddy，点 CLI 的任务切到 iTerm2
- **提醒形态**：把手亮起脉冲描边 + 两层同色光晕 + 角标，配合呼吸动画；
  另有声音（完成 Glass / 待确认 Ping / 失败 Basso）与系统通知
- **菜单栏图标**：显示·收起面板、立即刷新、声音提醒、系统通知、显示已完成、
  显示条数（4 / 6 / 8）、显示屏幕（多屏）、打开 WorkBuddy、退出

### 设计要点

- **反角贴边**：形状右边缘直接贴住屏幕，在与上下边交界处用一段凹曲线（反角）
  融进屏幕边缘，看上去是从边缘「长出来」的，而不是被一刀切断
- **形状外圈留 44pt 留白**：既是反角翘起的空间，也是告警光晕的完整衰减空间——
  `.shadow(radius: 18)` 的可视范围约 38pt，留白不足会在窗口边界切出一道不自然的断口
- **留白不吞点击**：空闲且收起时把窗口设成不接收鼠标事件，留白区域能点到底下的东西；
  悬停感应区单独按形状自身的矩形算，不跟着留白一起变大
- **展开动画的锚点写在路径计算里**：`MorphPath.path(in:)` 用 `progress` 线性插值宽高、
  圆角与反角半径，右边缘恒定贴住容器右侧。同一个形状同时用于背景填充、内容裁剪、
  告警描边，三者几何必然一致；展开时先把窗口撑到目标尺寸再播动画
- **告警描边走不闭合路径**：只排除贴着屏幕的那段直边——反角要描（光晕顺着凹曲线
  收进屏幕边缘），右直边不描（一条黄线贴着屏幕边缘闪很劣质）
- **没有告警时不加任何投影**：黑色投影会让面板外围浮出一层灰，在浅色壁纸上很明显

### 安全与隐私

- **全程只读**，程序从不打开原库：每轮把 `workbuddy.db` / `-wal` / `-shm` 复制到
  系统临时目录 `notchtasks-snapshot/`，只在副本上查询，并加 `PRAGMA query_only = ON`；
  副本会做一次 `SELECT count(*)` 校验，读到撕裂数据即丢弃重读
- 只读状态字段（标题、状态、工作目录、时间），**不读会话正文、不读代码**
- 不需要任何系统权限；唯一会弹的是通知权限，不授权也不影响把手本身的提醒
- 不写任何文件到用户目录；没有 LaunchAgent，不自启动

### 工程

- 8 个 `.swift` 文件直接 `swiftc` 编译，**零第三方依赖**；产物是 `dist/NotchTasks.app`
- `build.sh` 支持 `--universal`（arm64 + x86_64）、`--debug`、`--clean`，
  版本号从 `VERSION` 注入 Info.plist，构建号取 git 提交数
- `package.sh` 出两种产物，各带一个 `.sha256`：`.dmg`（挂载后拖进「应用程序」，
  推荐普通用户下载）与 `.zip`（解压即用）。dmg 由 `scripts/make-dmg.sh` 用 `hdiutil`
  生成，里面放好指向 `/Applications` 的软链；打包一律用 `ditto` 而不是 `zip` 命令，
  否则 `.app` 里的权限位与扩展属性会丢、签名会坏
- `scripts/smoke-test.sh` 冒烟测试：数据源全缺时不崩、状态映射与配色、点击命中映射、
  各状态离屏渲染的画布尺寸、生长动画逐帧，本地与 CI 共用同一份
- App 图标由 `tools/make-icon.swift` 生成（可复现，10 个尺寸齐全）；
  `docs/` 下的截图由 `scripts/make-screenshots.sh` 用**合成数据**渲染，
  产物不含任何本机任务标题与路径
- GitHub Actions：`ci.yml` 跑构建 + 冒烟 + 通用二进制 + 脚本语法；
  `release.yml` 推 `v*` 标签即打包发布，release notes 取自本文件的对应段落
- 无 GUI 自检命令：`--dump` / `--states` / `--hittest` / `--preview` / `--animframes`
- **许可是 MIT**，`LICENSE` 会随产物一起分发：`build.sh` 把它拷进
  `.app/Contents/Resources/`。MIT 要求所有副本或实质性部分都带上版权声明与许可文本，
  放进 bundle 之后，转发 dmg / zip 的人不会再中途把作者弄丢

### 说明

- 产物是 **ad-hoc 签名**，没有 Apple Developer ID。首次打开会被 Gatekeeper 拦下，
  右键 →「打开」一次即可
- 把手会占住屏幕右边缘靠上约 32×68 的一小块（约 y 104–172）
- 窗口层级 26，高于菜单栏，会出现在所有 Space 与全屏应用之上
- 列表只显示 7 天内的任务；「等你确认」与「有未读结果」都套 24 小时窗口，
  避免一个没人理会的旧状态让把手永久亮着

[Unreleased]: https://github.com/smarty-kiki/notch_tasks/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/smarty-kiki/notch_tasks/releases/tag/v1.0.2
[1.0.1]: https://github.com/smarty-kiki/notch_tasks/releases/tag/v1.0.1
[1.0.0]: https://github.com/smarty-kiki/notch_tasks/releases/tag/v1.0.0
