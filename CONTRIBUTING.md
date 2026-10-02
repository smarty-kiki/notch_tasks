# 参与开发

感谢愿意搭把手。这个项目很小，改动前先看一下下面几条「坑」能省很多时间——
它们都是踩过才总结出来的，代码里也留了注释。

## 环境

- macOS 14+（Sonoma）
- Xcode 或 Command Line Tools（提供 `swiftc` / `xcrun`）
- 不需要 CocoaPods / SPM 依赖，整个项目就是 8 个 `.swift` 文件直接 `swiftc` 编译

```bash
swift --version        # 确认工具链在
```

## 构建 / 运行 / 测试

```bash
./build.sh                 # 编译到 dist/NotchTasks.app
./run.sh                   # 编译并启动
make test                  # 冒烟测试（不需要 GUI，也不需要本机数据）
./package.sh               # 打发布包（通用二进制 zip）
make help                  # 看全部命令
```

调试开关：

```bash
# 强制提醒级别，方便调样式
NOTCHTASKS_FORCE_ALERT=confirm|done|running|idle \
  ./dist/NotchTasks.app/Contents/MacOS/NotchTasks

# 打印窗口几何、点击命中、鼠标事件策略
NOTCHTASKS_DEBUG=1 ./dist/NotchTasks.app/Contents/MacOS/NotchTasks

# 在真实窗口里抓展开动画的帧（离屏渲染验证不了这个）
NOTCHTASKS_DEBUG=1 NOTCHTASKS_ANIMPROBE=/tmp/live \
  ./dist/NotchTasks.app/Contents/MacOS/NotchTasks
```

无 GUI 自检（CI 用的就是这些）：

```bash
./build/NotchTasks --dump                    # 打印当前读到的任务
./build/NotchTasks --preview /tmp/np         # 离屏渲染各状态 PNG
./build/NotchTasks --animframes /tmp/an      # 逐帧渲染生长动画
./build/NotchTasks --hittest 150 90 6        # 面板内坐标 → 命中的行/底栏按钮
```

## 代码结构

```
Sources/
  main.swift        入口，--dump / --preview / --animframes / --hittest
  Models.swift      TaskItem / TaskKind / TaskState / AlertLevel
  Database.swift    只读 SQLite（快照复制后查询）
  ClaudeStore.swift 终端 Claude Code CLI 会话（只读 ~/.claude/sessions）
  TaskStore.swift   轮询、查询、状态跃迁检测
  NotchUI.swift     UIState / MorphPath / 形状 / 把手 / 面板
  App.swift         窗口控制器、几何与锚点、悬停与点击、通知、菜单栏
  Preview.swift     离屏渲染：静态预览 + 逐帧动画
tools/make-icon.swift   App 图标生成（改完重跑，产出 Resources/AppIcon.icns）
```

## 改 UI 前必读的三个坑

**1. 生长动画的锚点靠 `path(in:)` 里的数学，不能靠布局**

`MorphPath` 用 `progress`（0→1）线性插值宽高，形状右上角钉在容器内的固定位置。
两个必要的做法：

- 形状必须拿到「容器尺寸」的 `rect`。直接 `.fill()` 的话 `ZStack` 会按形状路径的包围盒收缩，
  `path(in:)` 收到的 rect 变成形状自己的尺寸，形状就跑到左上角去了 → 用 `GeometryReader`
  拿真实容器尺寸 + 每个形状显式 `.frame(width:height:)`
- `ui.expanded` 必须在 `withAnimation` **事务之外**翻转。放进事务里的话 SwiftUI 会把容器尺寸
  也一起插值，rect 逐帧变化，上面那个问题会换个形式复现

**2. 光晕需要留白，留白会吞点击**

告警光晕是 `.shadow(radius: 18)`，可视范围约 38pt。外圈留白（`UIState.edgeMargin`）小于它，
光晕就会在窗口边界被硬切出一道不自然的断口。留白大了又会变成一块吞掉点击的死区，
所以「空闲 + 收起」时把窗口设成 `ignoresMouseEvents = true`（`updateMouseEventPolicy()`）。

**3. 点击不能用 SwiftUI 手势**

本 app 是 accessory 且永远不是活跃 app（前台始终是别的应用），这种窗口里
SwiftUI 的 `Button` / `onTapGesture` 收不到点击。所以行点击和底栏按钮都由控制器自己命中：
`UIState.hitTest(_:rowCount:)` 把面板内坐标映射成 `row(i)` / `footer(i)` / `none`，
投递路径有两条（窗口 `mouseDown` + 全局鼠标监听）并去重。

底栏按钮因此是**纯展示**的（`FooterChip`），宽度固定写在 `UIState.footerLeftWidths`，
保证「画在哪」和「命中哪」严格一致。改底栏布局时两边要一起改。

## 数据源一律只读

- WorkBuddy：`~/.workbuddy/workbuddy.db` —— **从不打开原库**，每轮复制到临时目录再查，并加 `PRAGMA query_only=ON`
- Claude Code：`~/.claude/sessions/*.json` —— 只读，不写

提交 PR 时请保持这个约束。

## 提交信息

用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 风格，
release notes 会自动按类型归类：

```
feat: 把手支持显示 Claude Code CLI 会话
fix: 生长动画从左上角展开
docs: 补充留白与光晕的说明
chore: 升级 CI runner
```

## 提 PR

1. Fork 并开一个分支：`fix/xxx` 或 `feat/xxx`
2. 改完跑 `make test`，本地再跑一次 `./run.sh` 肉眼确认
3. 涉及界面改动的，跑 `make preview` 并把 `docs/preview/` 的变化一并提交
4. 提 PR，描述里写清「改了什么 / 为什么 / 怎么验证的」

CI 会跑构建 + 冒烟测试 + 通用二进制编译，全绿才会合。

## 发版

维护者操作：

```bash
# 1. 更新 VERSION 和 CHANGELOG.md，提交
# 2. 打标签并推上去，Release 工作流会自动打包并创建 Release
git tag v1.0.0
git push origin v1.0.0
```

也可以在 Actions 页面手动触发 `Release` 工作流，填版本号即可。

Release 产物是 `NotchTasks-<版本>-macos-universal.zip` 加一个 `.sha256`。
注意是 **ad-hoc 签名**，不是 Developer ID，用户首次打开需要右键 →「打开」。
