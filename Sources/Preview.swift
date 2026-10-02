import SwiftUI
import AppKit

/// 离屏渲染自检：不需要屏幕录制权限，直接把界面渲染成 PNG。
/// 用法：NotchTasks --preview /tmp/notchtasks-preview
enum PreviewRunner {

    @MainActor
    static func run(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prefs = Preferences()

        // ---- 正常状态（有任务在跑） ----
        let store = TaskStore()
        store.maxRows = 6
        store.demoClaude = true          // 预览里固定塞两条 CLI 行，便于看版式
        store.refresh()

        let ui = UIState()

        func sync() {
            ui.rows = max(2, min(store.tasks.count, store.maxRows))
        }

        // 预览画布 = 真实窗口尺寸：收起时是「把手 + 光晕留白」，展开时是「面板 + 留白」。
        // 动画中间帧的窗口已经撑到展开尺寸，所以统一用 expandedSize。
        func canvas() -> CGSize { ui.expanded ? ui.expandedSize : ui.collapsedSize }
        func animCanvas() -> CGSize { ui.expandedSize }

        setenv("NOTCHTASKS_FORCE_ALERT", "idle", 1)     // 空闲帧固定成 idle，别掺进真实告警
        store.refresh(); sync()                         // 必须再刷一次，env 才被 applyDebugOverride 读到
        ui.expanded = false
        ui.progress = 0
        sync()
        render(name: "01-收起.png", size: canvas(),
               store: store, ui: ui, prefs: prefs, outDir: outDir)

        ui.expanded = true
        ui.progress = 1
        render(name: "02-展开.png", size: canvas(),
               store: store, ui: ui, prefs: prefs, outDir: outDir)

        // ---- 强制「待确认」告警 ----
        setenv("NOTCHTASKS_FORCE_ALERT", "confirm", 1)
        store.refresh(); sync()
        ui.expanded = false
        ui.progress = 0
        render(name: "03-待确认.png", size: canvas(),
               store: store, ui: ui, prefs: prefs, outDir: outDir)
        ui.expanded = true
        ui.progress = 1
        render(name: "04-展开-待确认.png", size: canvas(),
               store: store, ui: ui, prefs: prefs, outDir: outDir)

        // ---- 强制「刚完成」告警 ----
        setenv("NOTCHTASKS_FORCE_ALERT", "done", 1)
        store.refresh(); sync()
        ui.expanded = false
        ui.progress = 0
        render(name: "05-完成.png", size: canvas(),
               store: store, ui: ui, prefs: prefs, outDir: outDir)

        // ---- 生长动画关键帧（回到 idle）----
        setenv("NOTCHTASKS_FORCE_ALERT", "idle", 1)
        store.refresh(); sync()
        for (i, p) in [CGFloat(0.35), 0.7].enumerated() {
            ui.expanded = p > 0.01
            ui.progress = p
            render(name: String(format: "06-展开中-%d-%.2f.png", i, Double(p)), size: animCanvas(),
                   store: store, ui: ui, prefs: prefs, outDir: outDir)
        }

        print("已输出到 \(outDir)")
    }

    /// 逐帧渲染生长动画：progress 是显式插值的，所以可以离屏精确复现中间帧，
    /// 用来验证形状确实是从把手那一点长出来的（右上角坐标全程不变）
    @MainActor
    static func animFrames(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prefs = Preferences()
        let store = TaskStore()
        store.maxRows = 6
        store.refresh()

        let ui = UIState()
        ui.rows = max(2, min(store.tasks.count, store.maxRows))

        let steps: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
        for (i, p) in steps.enumerated() {
            ui.progress = p
            ui.expanded = p > 0.01
            let name = String(format: "帧-%02d-progress-%.1f.png", i, Double(p))
            render(name: name, size: ui.expandedSize,
                   store: store, ui: ui, prefs: prefs, outDir: outDir)
        }
        print("已输出到 \(outDir)")
    }

    @MainActor
    private static func render(name: String, size: CGSize,
                               store: TaskStore, ui: UIState, prefs: Preferences,
                               outDir: String) {
        let root = DockRootView(store: store, ui: ui, prefs: prefs)

        // 深色幕布，方便看清黑色刘海
        let stage = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            root
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败: \(name)")
            return
        }
        let path = (outDir as NSString).appendingPathComponent(name)
        try? png.write(to: URL(fileURLWithPath: path))
        print("✓ \(name)  \(Int(size.width))×\(Int(size.height))")
    }
}
