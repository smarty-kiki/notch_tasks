import AppKit
import SwiftUI

let _ = NSApplication.shared

// 离屏渲染预览：NotchTasks --preview <输出目录>
if let idx = CommandLine.arguments.firstIndex(of: "--preview") {
    let out = CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1]
        : "/tmp/notchtasks-preview"
    MainActor.assumeIsolated { PreviewRunner.run(outDir: out) }
    exit(0)
}

// 逐帧渲染生长动画：NotchTasks --animframes <输出目录>
if let idx = CommandLine.arguments.firstIndex(of: "--animframes") {
    let out = CommandLine.arguments.count > idx + 1
        ? CommandLine.arguments[idx + 1]
        : "/tmp/notchtasks-anim"
    MainActor.assumeIsolated { PreviewRunner.animFrames(outDir: out) }
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
