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
./package.sh               # 打发布包（通用二进制 dmg + zip）
./package.sh --zip-only     # 只要 zip（dmg 走 hdiutil，慢一点）
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

# 抓收起过程中某一时刻的一帧。一次只抓一帧、改 _AT 多跑几次——
# 同步渲染整棵树要几十毫秒，在一次 0.22s 动画里连抓多帧会把主线程占满，
# 动画被自己卡住，量到的就不是动画了
NOTCHTASKS_COLLAPSEPROBE=/tmp/cp NOTCHTASKS_COLLAPSEPROBE_AT=0.10 \
  ./dist/NotchTasks.app/Contents/MacOS/NotchTasks
```

无 GUI 自检（CI 用的就是这些）：

```bash
./build/NotchTasks --dump                    # 打印当前读到的任务
./build/NotchTasks --preview /tmp/np --demo  # 离屏渲染各状态 PNG（--demo = 合成数据）
./build/NotchTasks --animframes /tmp/an      # 逐帧渲染生长动画
./build/NotchTasks --hittest 150 90 6        # 面板内坐标 → 命中的行/底栏按钮
./build/NotchTasks --states                  # 状态映射表（逻辑状态 → 展示状态 + 配色）
./build/NotchTasks --claude                  # Claude 注册表自检（原始内容 / 解析 / 进程存活）
./build/NotchTasks --sound                   # 提示音响度自检（原版 ↔ 自带放大 的 dBFS 对比）
```

## 代码结构

```
Sources/
  main.swift        入口，--dump / --preview / --animframes / --hittest / --states
  Models.swift      TaskItem / TaskKind / TaskState / AlertLevel
  Database.swift    只读 SQLite（快照复制后查询）
  ClaudeStore.swift 终端 Claude Code CLI 会话（只读 ~/.claude/sessions）
  TaskStore.swift   轮询、查询、状态跃迁检测
  NotchUI.swift     UIState / MorphPath / 形状 / 把手 / 面板
  App.swift         窗口控制器、几何与锚点、悬停与点击、通知、菜单栏
  Preview.swift     离屏渲染：静态预览 + 逐帧动画
tools/
  make-icon.swift    App 图标生成（改完重跑，产出 Resources/AppIcon.icns + docs/logo.png）
  make-strip.swift   多图横向拼接，生成 docs/ 里的对比图
scripts/
  smoke-test.sh       冒烟测试
  make-screenshots.sh 重新生成 docs/ 下全部界面图（用合成数据）
  make-dmg.sh         .app → dmg（放一个指向 /Applications 的软链）
  release-notes.sh    从 CHANGELOG.md 抽某版本的段落，当 Release 正文
```

### docs/ 里的截图必须是合成数据

`docs/` 会被 README 引用、随仓库公开，所以**不能**把本机真实任务标题与路径渲染进去：

- 截图一律走 `./scripts/make-screenshots.sh`，它给预览加 `--demo`，
  数据来自 `TaskStore.demoItems()`——那批假任务是唯一允许出现在 docs/ 里的内容
- 新增示例行时，路径要用 `NSHomeDirectory() + "/Projects/…"` 这类中性值，
  别硬编码真实工程目录
- `NOTCHTASKS_ANIMPROBE` / `NOTCHTASKS_COLLAPSEPROBE` 在真实窗口里抓的帧含真实数据，
  只往 `/tmp` 放，不要提交
  （`docs/live/` 已在 .gitignore 里）

改完 UI 或配色，重跑 `make screenshots` 并把 `docs/` 的变化一起提交。

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

**路径一律走 `UserHome.path`，别直接用 `NSHomeDirectory()`。** 后者在 macOS 上走
getpwuid、**不认 `HOME` 环境变量**；而冒烟测试靠 `HOME=<临时目录>` 把数据源指开，
用错的话那份隔离是假的 —— 测试会去读真实数据，断言假通过。这个坑真踩过。

提交 PR 时请保持这个约束。

**两个 `status` 字段都容易被想当然，两个坑都踩过：**

- WorkBuddy `sessions.status` 实际取值只有
  `working` / `pending` / `completed` / `error` / `terminated` / `archived`，
  其中 **`pending` 是「等你确认 / 选择」，不是「排队中」**；`archived` 在 SQL 层已排除
- Claude Code `status` 取值是 `busy` / `idle` / `waiting`。
  **`waiting` 表示停在等你确认 / 授权**，此时会多一个 `waitingFor` 字段
  （如 `"permission prompt"`）——漏了它就会掉进兜底分支，把英文状态显示到界面上
- 两处容易误判的地方：
  - `~/.claude/sessions/` 会被 Claude Code **按日清理**，清完那一刻是空的，
    「列表里没有 CLI 会话」很可能只是没会话在跑，不是读不到
  - 列表标题要读**会话记录**里的 `ai-title`，不是注册表里的 `name`——
    后者是派生的（`kiki-2d` 这种），跟终端标签对不上
  - 注册表文件可能**被写坏**：Claude Code 重写时若内容变短又没截断，尾部会留下残片
    （形如 `{…完整对象…}51,"waitingFor":"permission prompt"}`）。整文件严格解析会因
    extra data 失败，于是进程明明活着、列表里却一条都没有。读的时候必须容错
    （括号配对、只取第一个完整对象），`--claude` 能区分「进程退了 / 被清理 / 文件写坏」

遇到没见过的取值：映射按「运行中」兜底，原始值写进 `NOTCHTASKS_DEBUG` 日志，别直接显示给用户。

**另一个坑：逻辑状态 ≠ 展示状态。**

`TaskItem.state` 是数据源给的逻辑状态，列表上画的是 `TaskItem.displayState`，两者有意分开：

- `needsConfirm` 为真 → 一律显示「待确认」。否则会出现标题栏写着「N 待确认」、
  列表里却看不出是哪一个
- `done` 按 `recentDoneWindow`（10 分钟）分档：窗口内显示成明亮的「空闲」绿，
  再久沉成灰蓝的「已完成」

改配色/排序请改 `displayState` 那条链路，别去改 `state`——
`state` 还牵扯告警级别和状态跃迁检测（`detectTransitions`）。

配色和映射可以用 `--states` 离线核对，`scripts/smoke-test.sh` 里也断言了同一张表。

## 提交信息

用 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/) 风格。
注意 release notes **不是**自动生成的——`release.yml` 取的是 `CHANGELOG.md` 里
对应版本的段落（见 `scripts/release-notes.sh`），所以提交信息按类型分好，
归纳 CHANGELOG 时省事：

```
feat: 把手支持显示 Claude Code CLI 会话
fix: 生长动画从左上角展开
docs: 补充留白与光晕的说明
chore: 升级 CI runner
```

## 提 PR

1. Fork 并开一个分支：`fix/xxx` 或 `feat/xxx`
2. 改完跑 `make test`，本地再跑一次 `./run.sh` 肉眼确认
3. 涉及界面改动的，跑 `make screenshots` 并把 `docs/` 的变化一并提交
   （它用合成数据渲染，不会把你的真实任务标题带进仓库）
4. 提 PR，描述里写清「改了什么 / 为什么 / 怎么验证的」

CI 会跑构建 + 冒烟测试 + 通用二进制编译，全绿才会合。

## 发版

维护者操作，标准流程是「改版本 → 提 PR → 合并 → 打标签」，标签推上去由
`release.yml` 自动打包并创建 Release：

```bash
# 1. 定版本：改 VERSION，把 CHANGELOG.md 里的 [Unreleased] 整理成 [x.y.z] - 日期
$EDITOR VERSION CHANGELOG.md
./scripts/release-notes.sh x.y.z        # 先看一眼 Release 正文长什么样

# 2. 走正常 PR 流程合进 main（CI 必须全绿）

# 3. 合并后打标签并推送
make tag            # 按 VERSION 打 vX.Y.Z 注解标签，不推送
git push origin vX.Y.Z
```

推完标签，Actions 里的 `Release` 工作流会：

1. 从标签解析版本号，写回 `VERSION`
2. `./package.sh` 构建通用二进制，出 `.dmg` 与 `.zip`，各带一个 `.sha256`
3. 跑一遍冒烟测试
4. 确认四个产物齐全，并挂载 dmg 确认里面真的躺着 `NotchTasks.app`
5. 用 `CHANGELOG.md` 里该版本的段落作为 Release 正文，把产物全部挂上去

也可以在 Actions 页面手动触发 `Release`，填版本号即可（不需要先有标签）。

### 首次发布：把仓库推上 GitHub

> 本仓库已经用 `smarty-kiki` 走完这一步，地址是 https://github.com/smarty-kiki/notch_tasks 。下面是留档，从别处 fork 出独立项目时同样适用。

先把占位的仓库地址换成真实用户名（README 的徽章与下载链接、CHANGELOG 的版本对比链接、
issue 模板里的 Discussions 链接都用了 `OWNER`）：

```bash
sed -i '' 's|OWNER/notch_tasks|<你的用户名>/notch_tasks|g' \
  README.md CHANGELOG.md .github/ISSUE_TEMPLATE/config.yml
git commit -am "docs: 填上仓库地址"
```

**装了 `gh`**（推荐）：

```bash
gh repo create notch_tasks --public --source=. --remote=origin --push
```

**没装 `gh`**：在网页上新建空仓库，然后接上远端再推：

```bash
git remote add origin git@github.com:<你的用户名>/notch_tasks.git
git push -u origin main
```

推完记得去仓库设置里把 **About → Topics** 和描述填一下，issue / PR 模板会自动生效。

### 发布前自查

- [ ] `make test` 全绿
- [ ] `make screenshots` 后 `docs/` 没有意外变化（也不该出现真实任务标题）
- [ ] `VERSION` 与 `CHANGELOG.md` 的版本号一致，日期是今天
- [ ] `CHANGELOG.md` 里没有残留的 `[Unreleased]` 条目
- [ ] LICENSE 的版权人写的是你自己想要的名字
- [ ] README / CHANGELOG / issue 模板里的 `OWNER` 都换成了真实用户名

### 发布产物

```
NotchTasks-<版本>-macos-universal.dmg          挂载后拖进「应用程序」，推荐下载这个
NotchTasks-<版本>-macos-universal.dmg.sha256
NotchTasks-<版本>-macos-universal.zip          解压即用
NotchTasks-<版本>-macos-universal.zip.sha256
```

dmg 里除了 `.app`，还放了一个指向 `/Applications` 的软链——用户挂载后
把图标拖到软链上就装好了。之前踩过的坑：打包一旦用 `zip` 命令而不是 `ditto`，
`.app` 里的权限位与扩展属性会丢，签名随之失效。

注意是 **ad-hoc 签名**，不是 Developer ID，用户首次打开需要右键 →「打开」。
要正经签名得配 Apple Developer 证书并在工作流里加 `codesign` + `notarytool`，
目前还没做。

## 许可

本项目以 [MIT](LICENSE) 发布，版权归 `LICENSE` 里那位署名者所有。

- **进来的**：你提的 PR 一经合并，即视为同意以 MIT 协议授权（inbound = outbound），
  不额外签 CLA。PR 模板里有这一条勾选
- **出去的**：MIT 要求所有副本或实质性部分都带上版权声明与许可文本，
  所以别删 `LICENSE`；`build.sh` 会把它一并放进
  `.app/Contents/Resources/`，产物转发到哪，声明就跟到哪
- **引用别人代码**：引入任何第三方代码前先开 issue 说一声，并在
  `THIRD-PARTY-NOTICES.md` 里记上来源与许可——本项目目前零依赖，希望保持这样
