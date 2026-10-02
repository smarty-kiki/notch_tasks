import AppKit
import SwiftUI

let _ = NSApplication.shared

let cliArgs = CommandLine.arguments

/// 取 `--flag` 后面紧跟的值（下一个以 -- 开头就当作没给）
func argValue(after flag: String) -> String? {
    guard let i = cliArgs.firstIndex(of: flag), i + 1 < cliArgs.count else { return nil }
    let v = cliArgs[i + 1]
    return v.hasPrefix("--") ? nil : v
}

/// `--demo`：渲染时用合成任务替掉真实数据源。docs/ 的截图走这条，
/// 保证公开仓库里的图不含本机任务标题与路径。
let demoRendering = cliArgs.contains("--demo")

// 离屏渲染预览：NotchTasks --preview <输出目录> [--demo]
if cliArgs.contains("--preview") {
    let out = argValue(after: "--preview") ?? "/tmp/notchtasks-preview"
    MainActor.assumeIsolated { PreviewRunner.run(outDir: out, demo: demoRendering) }
    exit(0)
}

// 逐帧渲染生长动画：NotchTasks --animframes <输出目录> [--demo]
if cliArgs.contains("--animframes") {
    let out = argValue(after: "--animframes") ?? "/tmp/notchtasks-anim"
    MainActor.assumeIsolated { PreviewRunner.animFrames(outDir: out, demo: demoRendering) }
    exit(0)
}

// 命中映射自检：NotchTasks --hittest <面板内x> <面板内y> [行数]
if let idx = CommandLine.arguments.firstIndex(of: "--hittest") {
    let args = CommandLine.arguments
    let x = idx + 1 < args.count ? (Double(args[idx + 1]) ?? 0) : 0
    let y = idx + 2 < args.count ? (Double(args[idx + 2]) ?? 0) : 0
    let rows = idx + 3 < args.count ? (Int(args[idx + 3]) ?? 4) : 4
    let ui = UIState()
    ui.rows = rows
    let hit = ui.hitTest(CGPoint(x: x, y: y), rowCount: rows)
    let rowsTop = Int(ui.edgeMargin + ui.headerHeight)
    let footerTop = Int(ui.edgeMargin + ui.expandedHeight - ui.footerHeight)
    print("面板 \(Int(ui.expandedSize.width))×\(Int(ui.expandedSize.height))  行数=\(rows)")
    print("行区 y: \(rowsTop)…\(footerTop)  行高 \(Int(ui.rowHeight))")
    print("底栏 y: \(footerTop)…\(Int(ui.edgeMargin + ui.expandedHeight))")
    for z in ui.footerZones { print("  底栏按钮\(z.index) x: \(Int(z.range.lowerBound))…\(Int(z.range.upperBound))") }
    print("输入 (\(Int(x)), \(Int(y))) → \(hit)")
    exit(0)
}

// 状态映射自检：NotchTasks --states
// 把「逻辑状态 + 新鲜度」→「展示状态 + 配色」整张表打出来，供人工核对 / 冒烟测试断言。
// 时间相关的分档（刚完成 vs 早就完成）只有靠它才能离线验。
if CommandLine.arguments.contains("--states") {
    func hex(_ c: Color) -> String {
        guard let s = NSColor(c).usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }
    let now = Date()
    // (场景, 逻辑状态, 距今多久, 是否需要你确认)
    let cases: [(String, TaskState, TimeInterval, Bool)] = [
        ("WorkBuddy working",  .running,     30,          false),
        ("WorkBuddy pending",  .needConfirm, 30,          true),
        ("Claude CLI busy",    .running,     5,           false),
        ("Claude CLI waiting", .needConfirm, 5,           true),
        ("Claude CLI idle",    .idle,        5,           false),
        ("完成 10 秒",          .done,        10,          false),
        ("完成 9 分钟",         .done,        9 * 60,      false),
        ("完成 11 分钟",        .done,        11 * 60,     false),
        ("完成 3 小时",         .done,        3 * 3600,    false),
        ("完成但有未读",        .done,        3 * 3600,    true),
        ("失败",               .failed,      60,          false),
    ]
    print(String(format: "%-18@ %-10@ %-10@ %-8@ %@",
                 "场景" as NSString, "逻辑" as NSString, "展示" as NSString, "配色" as NSString, "排序" as NSString))
    for (name, state, age, confirm) in cases {
        var item = TaskItem(id: name, kind: .session, title: name, detail: nil, cwd: nil,
                            state: state, updatedAt: now.addingTimeInterval(-age))
        item.needsConfirm = confirm
        let shown = item.displayState
        print(String(format: "%-18@ %-10@ %-10@ %-8@ %d",
                     name as NSString, state.label as NSString,
                     shown.label as NSString, hex(shown.color) as NSString, shown.sortRank))
    }
    exit(0)
}

// 提示音响度自检：NotchTasks --sound [音效名] [--play]
//
// 音量这种事不该靠耳朵猜：这里把「系统原版」和「app 自带的放大版」各量一遍，
// 给出峰值与 RMS（dBFS）以及响度差。加 --play 顺带真放一遍。
if cliArgs.contains("--sound") {
    let names = argValue(after: "--sound").map { [$0] } ?? ["Glass", "Ping", "Basso"]
    print("对比    : 系统原版 /System/Library/Sounds  ↔  app 自带 Resources/Sounds")
    print("由来    : tools/make-sounds.swift 统一放大 +9.6 dB（线性 ×3.0，无损）")
    print(String(repeating: "-", count: 78))
    for n in names {
        print("\(n):")
        print(SoundPlayer.measure(n))
    }
    if cliArgs.contains("--play") {
        print(String(repeating: "-", count: 78))
        print("依次播放（听一下实际效果）：")
        for n in names {
            print("  ▶︎ \(n)")
            SoundPlayer.shared.play(n)
            Thread.sleep(forTimeInterval: 1.3)
        }
    }
    exit(0)
}

// Claude 会话自检：NotchTasks --claude
//
// 「列表里没有 CLI 会话」有三种完全不同的原因：进程真的退了、注册表被 Claude
// 按日清理了、或者文件被写坏导致解析失败。只看界面分不出来，这个命令把
// 原始文件、解析结果、进程存活判断一并打出来。
if cliArgs.contains("--claude") {
    let fm = FileManager.default
    let dir = ClaudeStore.sessionsDir
    let stamp = (UserHome.path as NSString).appendingPathComponent(".claude/.last-cleanup")

    print("会话目录: \(dir)")
    if let t = try? String(contentsOfFile: stamp, encoding: .utf8) {
        print("按日清理: \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        print("按日清理: (无记录)")
    }

    let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".json") }.sorted()
    print("文件数  : \(files.count)")
    print(String(repeating: "-", count: 78))

    for f in files {
        let path = (dir as NSString).appendingPathComponent(f)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mt = (attrs?[.modificationDate] as? Date).map { "\($0)" } ?? "-"
        print("── \(f)  \(size) 字节  mtime=\(mt)")

        guard let data = fm.contents(atPath: path) else { print("   读取失败"); continue }
        print("   原始: \(String(data: data, encoding: .utf8) ?? "(非 UTF-8)")")

        // 严格解析失败 = 文件里有 extra data（尾部残渣）或被截断，
        // 这正是「会话明明活着却不显示」的原因
        let strict = (try? JSONSerialization.jsonObject(with: data)) != nil
        print("   严格解析: \(strict ? "通过（文件干净）" : "失败 → 有尾部残渣或被截断，改用括号配对取第一个对象")")

        guard let obj = ClaudeStore.firstJSONObject(in: data) else {
            print("   结果: 一个完整对象都没取到 → 这条会被跳过")
            continue
        }
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? -1
        print("   取值: pid=\(pid)"
              + " name=\(obj["name"] as? String ?? "-")"
              + " status=\(obj["status"] as? String ?? "-")"
              + " waitingFor=\(obj["waitingFor"] as? String ?? "-")")
    }

    print(String(repeating: "-", count: 78))
    let all = ClaudeStore.scan()
    let live = all.filter { $0.alive && $0.isClaude }
    print("scan() 读到 \(all.count) 条；其中「进程活着且是 claude」\(live.count) 条")
    for s in all {
        print("  pid=\(s.pid) 存活=\(s.alive ? "是" : "否") 是claude=\(s.isClaude ? "是" : "否")"
              + " status=\(s.status) 标题=\(s.displayTitle)")
    }
    exit(0)
}

// Claude 会话自检：NotchTasks --claude
//
// 「列表里没有 CLI 会话」有三种完全不同的原因：进程真的退了、注册表被 Claude
// 按日清理了、或者文件被写坏导致解析失败。只看界面分不出来，这个命令把
// 原始文件、解析结果、进程存活判断一并打出来。
if cliArgs.contains("--claude") {
    let fm = FileManager.default
    let dir = ClaudeStore.sessionsDir
    let stamp = (UserHome.path as NSString).appendingPathComponent(".claude/.last-cleanup")

    print("会话目录: \(dir)")
    if let t = try? String(contentsOfFile: stamp, encoding: .utf8) {
        print("按日清理: \(t.trimmingCharacters(in: .whitespacesAndNewlines))")
    } else {
        print("按日清理: (无记录)")
    }

    let files = ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".json") }.sorted()
    print("文件数  : \(files.count)")
    print(String(repeating: "-", count: 78))

    for f in files {
        let path = (dir as NSString).appendingPathComponent(f)
        let attrs = try? fm.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mt = (attrs?[.modificationDate] as? Date).map { "\($0)" } ?? "-"
        print("── \(f)  \(size) 字节  mtime=\(mt)")

        guard let data = fm.contents(atPath: path) else { print("   读取失败"); continue }
        print("   原始: \(String(data: data, encoding: .utf8) ?? "(非 UTF-8)")")

        // 严格解析失败 = 文件里有 extra data（尾部残渣）或被截断，
        // 这正是「会话明明活着却不显示」的原因
        let strict = (try? JSONSerialization.jsonObject(with: data)) != nil
        print("   严格解析: \(strict ? "通过（文件干净）" : "失败 → 有尾部残渣或被截断，改用括号配对取第一个对象")")

        guard let obj = ClaudeStore.firstJSONObject(in: data) else {
            print("   结果: 一个完整对象都没取到 → 这条会被跳过")
            continue
        }
        let pid = (obj["pid"] as? NSNumber)?.int32Value ?? -1
        print("   取值: pid=\(pid)"
              + " name=\(obj["name"] as? String ?? "-")"
              + " status=\(obj["status"] as? String ?? "-")"
              + " waitingFor=\(obj["waitingFor"] as? String ?? "-")")
    }

    print(String(repeating: "-", count: 78))
    let all = ClaudeStore.scan()
    let live = all.filter { $0.alive && $0.isClaude }
    print("scan() 读到 \(all.count) 条；其中「进程活着且是 claude」\(live.count) 条")
    for s in all {
        print("  pid=\(s.pid) 存活=\(s.alive ? "是" : "否") 是claude=\(s.isClaude ? "是" : "否")"
              + " status=\(s.status) 标题=\(s.displayTitle)")
    }
    exit(0)
}

// 无 GUI 自检：NotchTasks --dump  打印当前读取到的任务后退出
if CommandLine.arguments.contains("--dump") {
    let store = TaskStore()
    store.maxRows = 20
    store.refresh()
    print("DB      : \(WorkBuddyDB.liveDBPath)")
    print("状态    : \(store.statusText)")
    print("提醒级别: \(store.alertLevel)  角标: \(store.alertCount)")
    print("读取时间: \(store.lastRefresh.map { "\($0)" } ?? "-")")
    print(String(repeating: "-", count: 78))
    for (i, t) in store.tasks.enumerated() {
        let flag = t.needsConfirm ? "❗️" : (t.state.isActive ? "▶︎" : " ")
        print(String(format: "%2d %@ [%-5@] %@", i + 1, flag, t.displayState.label as NSString, t.title))
        var sub: [String] = []
        if let d = t.detail { sub.append(d) }
        if let c = t.cwd { sub.append(c) }
        sub.append(t.relativeTime)
        print("      \(sub.joined(separator: " · "))")
    }
    exit(0)
}

// 入口：无 Dock 图标的后台常驻应用
let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
