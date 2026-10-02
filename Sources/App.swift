import Foundation
import AppKit
import Combine
import SwiftUI
import UserNotifications

// MARK: - 系统通知

final class Notifier {
    static let shared = Notifier()
    private var authorized = false

    /// 非 bundle 环境下 UNUserNotificationCenter 会抛异常
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
    }

    func post(title: String, body: String) {
        guard available, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil   // 声音由 NSSound 单独播，避免双重
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - 刘海控制器

final class NotchController {

    let store = TaskStore()
    let ui = UIState()
    let prefs = Preferences()

    private var panel: DockPanel!
    private var container: HoverTrackingView!
    private var hosting: FirstMouseHostingView<DockRootView>!
    private var collapseWork: DispatchWorkItem?
    private var ackWork: DispatchWorkItem?
    private var shrinkWork: DispatchWorkItem?
    private var globalMonitor: Any?
    private var clickMonitor: Any?
    private var lastClickAt: Date = .distantPast
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    // MARK: 启动

    func start() {
        setupPanel()
        store.onTransition = { [weak self] item, state in self?.handleTransition(item, state) }
        store.maxRows = prefs.maxRows
        store.showFinished = prefs.showFinished

        // 面板高度跟随行数，任务增减时同步窗口
        store.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                let rows = max(2, min(items.count, self.store.maxRows))
                if self.ui.rows != rows { self.ui.rows = rows }
                self.syncFrame()
            }
            .store(in: &cancellables)

        // 告警级别变化会改变是否需要接收鼠标事件、以及光晕是否需要留白
        store.$alertLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMouseEventPolicy() }
            .store(in: &cancellables)

        SoundPlayer.shared.warmUp()   // 先把音频引擎起好，首声才没有延迟
        store.start()
        installGlobalMonitor()
        installClickMonitor()
        updateMouseEventPolicy()

        if let dir = ProcessInfo.processInfo.environment["NOTCHTASKS_ANIMPROBE"] {
            runAnimProbe(outDir: dir)
        }
        // 收起过程的抓帧：专门用来核对「面板是不是一开始就整个消失」
        if let dir = ProcessInfo.processInfo.environment["NOTCHTASKS_COLLAPSEPROBE"] {
            runCollapseProbe(outDir: dir)
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.applyFrame(expanded: self.ui.expanded)
                self.ui.objectWillChange.send()
            }
    }

    func stop() {
        store.stop()
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 窗口

    private func setupPanel() {
        let f = frame(expanded: false)
        let p = DockPanel(contentRect: f,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.ignoresMouseEvents = false

        let c = HoverTrackingView(frame: NSRect(origin: .zero, size: f.size))
        c.wantsLayer = true
        c.layer?.backgroundColor = NSColor.clear.cgColor
        c.onEnter = { [weak self] in self?.expand() }
        c.onExit = { [weak self] in self?.scheduleCollapse() }

        let host = FirstMouseHostingView(rootView: DockRootView(
            store: store, ui: ui, prefs: prefs))
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.onClickPoint = { [weak self] point in self?.handlePanelClick(at: point, source: "window") }
        c.addSubview(host)

        p.contentView = c
        self.panel = p
        self.container = c
        self.hosting = host

        applyFrame(expanded: false)
        p.orderFrontRegardless()
    }

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens.last!
    }

    // MARK: 几何
    //
    // 形状四周留了一圈 edgeMargin：既让面板不贴屏幕右边缘，也给告警光晕留出空间。
    // 窗口尺寸跟着当前形态走，而「形状的右上角」在两种状态下都落在同一个屏幕坐标
    // （s.maxX - edgeMargin, 屏顶 + shapeTopOffset），所以动画参考系恒定，
    // 视觉上必然是从把手本身长出来。

    /// 窗口在当前形态下应有的位置与大小
    private func frame(expanded: Bool) -> NSRect {
        let s = targetScreen().frame
        let size = expanded ? ui.expandedSize : ui.collapsedSize

        // 右边缘留 edgeMargin；展开时保持形状右上角不动，向左下生长
        let top = s.maxY - ui.windowTopOffset
        return NSRect(x: s.maxX - size.width,
                      y: top - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// 内容视图正好铺满窗口——形状自己在窗口内留边，所以这里不需要偏移
    private func contentFrame(windowSize: CGSize) -> NSRect {
        NSRect(origin: .zero, size: windowSize)
    }

    /// 形状在屏幕上的矩形（不含留白）。悬停判定用它，
    /// 这样加大留白不会顺带把悬停感应区撑大。
    private func shapeFrame(expanded: Bool) -> NSRect {
        let w = frame(expanded: expanded)
        let size = expanded ? ui.expandedShape : ui.collapsedShape
        return NSRect(x: w.maxX - ui.rightGap - size.width,
                      y: w.maxY - ui.edgeMargin - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// 空闲且收起时让窗口不接收鼠标事件：
    /// 有了它，光晕需要的 44pt 留白才不会变成一块吞掉点击的死区。
    /// 展开时、或有告警时都要接收事件。
    private func updateMouseEventPolicy() {
        let ignore = !(ui.expanded || store.alertLevel >= .done)
        guard panel.ignoresMouseEvents != ignore else { return }
        panel.ignoresMouseEvents = ignore
        AppDebug.log("[geom] 窗口接收鼠标事件 = \(!ignore)")
    }

    /// 同步窗口与内容视图的几何；所有位置变化都走这里
    private func applyFrame(expanded: Bool) {
        let f = frame(expanded: expanded)
        panel.setFrame(f, display: true)
        container.frame = NSRect(origin: .zero, size: f.size)
        hosting.frame = contentFrame(windowSize: f.size)

        if ProcessInfo.processInfo.environment["NOTCHTASKS_DEBUG"] != nil {
            let hostScreen = panel.convertToScreen(hosting.convert(hosting.bounds, to: nil))
            print(String(format: "[geom] expanded=%@ progress=%.3f window=%@ hostOnScreen=%@",
                         expanded ? "Y" : "N",
                         Double(ui.progress),
                         NSStringFromRect(f),
                         NSStringFromRect(hostScreen)))
            fflush(stdout)
        }
    }

    /// 动画落定后再记一条，确认 progress 真的收敛到 1 / 0
    private func logSettled() {
        guard ProcessInfo.processInfo.environment["NOTCHTASKS_DEBUG"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let t = self.ui.progress
            let w = self.ui.collapsedShape.width + (self.ui.expandedShape.width - self.ui.collapsedShape.width) * t
            let h = self.ui.collapsedShape.height + (self.ui.expandedShape.height - self.ui.collapsedShape.height) * t
            let r = self.ui.tabCornerRadius + (self.ui.panelCornerRadius - self.ui.tabCornerRadius) * t
            let shapeRight = self.targetScreen().frame.maxX - self.ui.rightGap
            print(String(format: "[settled] expanded=%@ progress=%.3f 形状=%.0f×%.0f 圆角≈%.0f 右缘x=%.0f(屏幕%.0f)",
                         self.ui.expanded ? "Y" : "N", Double(t),
                         Double(w), Double(h), Double(r),
                         Double(shapeRight), Double(self.targetScreen().frame.maxX)))
            fflush(stdout)
        }
    }

    /// 内容尺寸变化后同步几何；动画进行中不缩窗口，避免把动画裁掉
    private func syncFrame() {
        if ui.expanded {
            applyFrame(expanded: true)
        } else if ui.progress == 0 {
            applyFrame(expanded: false)
        }
    }

    /// 把窗口移到指定屏幕（菜单里可切换）
    func moveToScreen(index: Int) {
        guard index >= 0, index < NSScreen.screens.count else { return }
        UserDefaults.standard.set(index, forKey: "screenIndex")
        applyFrame(expanded: ui.expanded)
    }

    // MARK: 展开 / 收起

    /// 抓帧探针期间置 true：抑制「鼠标移开自动收起」，
    /// 否则探针还没轮到调用 collapse()，鼠标已经把它收掉了，抓到的全是收完的稳定态
    private var suppressAutoCollapse = false

    /// 鼠标离开后多久开始收起。从「离开那一刻」起算，不会因为继续移动而被推迟。
    /// 0.5s 等待 + 0.22s 收缩动画，感知上约 0.7s 就收干净。
    private let collapseDelay: TimeInterval = 0.50
    private let collapseAnimationDuration: TimeInterval = 0.22

    func expand() {
        cancelCollapse()
        shrinkWork?.cancel()
        shrinkWork = nil
        panel.allowsKey = true
        // 已经完整展开就没事可做；但「收到一半又回来」要能反向播回去，
        // 所以判据是 progress 而不是 expanded（后者在收回动画播完前一直是 true）
        guard !(ui.expanded && ui.progress >= 0.999) else { return }

        // 顺序很关键：
        // 1. 窗口先撑到展开尺寸，生长动画才不会被窗口边界裁掉
        // 2. ui.expanded 必须在 withAnimation **之外**翻转 —— 它一变，容器尺寸就从
        //    52×108 变成 440×314。若这一步进了动画事务，SwiftUI 会把容器尺寸也一起插值，
        //    于是 path(in:) 收到的 rect 变成「形状自己的尺寸」，rect.maxX - w 退化成
        //    左侧留白，看起来就是从左上角长出来
        // 3. 只让 progress 进动画
        applyFrame(expanded: true)
        ui.expanded = true
        updateMouseEventPolicy()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            ui.progress = 1
        }

        // 用户已经看到列表 → 延迟清掉瞬时提醒
        ackWork?.cancel()
        logSettled()
        let w = DispatchWorkItem { [weak self] in self?.store.acknowledge() }
        ackWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: w)
    }

    /// 开始收起倒计时。已在倒计时中则保持原有截止时间，不重置——
    /// 否则鼠标持续移动会把收起无限推迟。
    func scheduleCollapse() {
        guard !suppressAutoCollapse else { return }
        guard collapseWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            self?.collapseWork = nil
            self?.collapse()
        }
        collapseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: w)
    }

    private func cancelCollapse() {
        collapseWork?.cancel()
        collapseWork = nil
    }

    func collapse() {
        cancelCollapse()
        guard ui.expanded else { return }
        panel.allowsKey = false

        // 顺序和展开时一样讲究：
        // 1. **只**把 progress 放进动画事务，先把形状收回去。
        //    `ui.expanded` 与内容层这一拍都不动 —— 面板留在原地被越来越小的形状裁掉，
        //    这才是「收回去」。以前这里一进门就把 expanded 翻成 false，
        //    内容层瞬间从面板换成把手，屏幕上是「一块满尺寸的黑色空面板僵在
        //    那儿 0.22 秒，然后啪地收掉」，看着就是卡顿。
        // 2. 动画播完再切内容、缩窗口。此时形状已经小到把手尺寸，
        //    内容从面板换成把手正好无缝，也不会把动画裁掉。
        withAnimation(.easeInOut(duration: collapseAnimationDuration)) {
            ui.progress = 0
        }

        shrinkWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 动画期间又被悬停回来就别收尾（expand() 会把这条 cancel 掉）
            guard self.ui.progress < 0.001 else { return }
            self.finishCollapse()
        }
        shrinkWork = w
        logSettled()
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseAnimationDuration + 0.02, execute: w)
    }

    /// 收回动画播完后的收尾：切内容层、更新鼠标策略、把窗口缩回把手尺寸
    private func finishCollapse() {
        ui.expanded = false
        updateMouseEventPolicy()
        applyFrame(expanded: false)
    }

    func toggleExpand() {
        ui.expanded ? collapse() : expand()
    }

    // MARK: 实时动画抓帧（调试）

    /// 在真实窗口里展开一次，同时在若干时间点把 hosting view 渲染成 PNG。
    /// 离屏渲染只能验证几何函数，验证不了「窗口/容器在各时刻的实际状态」。
    func runAnimProbe(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        AppDebug.log("[probe] 1.2s 后触发展开")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.expand()
            let stamps: [Double] = [0.02, 0.08, 0.16, 0.26, 0.40, 0.70]
            for (i, t) in stamps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    self.captureFrame(index: i, at: t, outDir: outDir)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { exit(0) }
        }
    }

    /// 展开 → 停一下 → 收起，并在收回过程的**某一个**时间点抓一帧。
    ///
    /// 为什么只抓一帧：`cacheDisplay` 是同步渲染整棵视图树（近百万像素），
    /// 一次就要几十毫秒。若在一次动画里连抓五六帧，主线程基本被占满，
    /// 动画推进会被自己卡住，抓到的帧张张相同——那样量出来的不是动画，是阻塞。
    /// 所以抓帧时刻由 `NOTCHTASKS_COLLAPSEPROBE_AT` 指定，多次运行拼出时间曲线。
    func runCollapseProbe(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let at = ProcessInfo.processInfo.environment["NOTCHTASKS_COLLAPSEPROBE_AT"]
            .flatMap(Double.init) ?? 0.10
        AppDebug.log(String(format: "[probe] 1.2s 后展开，再 1.2s 后收起，在 t=%.3f 抓一帧", at))

        suppressAutoCollapse = true
        cancelCollapse()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.expand()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.collapse()
                DispatchQueue.main.asyncAfter(deadline: .now() + at) {
                    self.captureFrame(index: 0, at: at, outDir: outDir, prefix: "collapse")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { exit(0) }
            }
        }
    }

    private func captureFrame(index: Int, at t: Double, outDir: String, prefix: String = "live") {
        let v = hosting!
        let wRect = panel.frame
        AppDebug.log(String(format: "[probe] t=%.2f 窗口=%@ 容器=%@ progress=%.3f 内容=%@",
                            t, NSStringFromRect(wRect),
                            NSStringFromRect(v.frame), Double(ui.progress),
                            ui.expanded ? "面板" : "把手"))

        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)

        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        NSColor(deviceWhite: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: v.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: v.bounds.size))
        img.unlockFocus()

        guard let tiff = img.tiffRepresentation,
              let out = NSBitmapImageRep(data: tiff),
              let png = out.representation(using: .png, properties: [:]) else { return }
        let path = outDir + String(format: "/%@-%02d-%.2f.png", prefix, index, t)
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // MARK: 点击任务行

    /// 本 app 是 accessory、永不成为活跃 app，面板窗口不是 key，
    /// 落在它上面的点击由窗口系统交给了前台 app，所以这里用全局鼠标监听兜底，
    /// 自己把屏幕坐标换算成面板内的行号。
    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.ui.expanded else { return }
            let loc = NSEvent.mouseLocation           // 屏幕坐标（左下原点）
            let f = self.panel.frame
            guard f.contains(loc) else { return }
            let p = CGPoint(x: loc.x - f.minX, y: f.maxY - loc.y)   // 转成窗口内左上原点
            self.handlePanelClick(at: p, source: "global")
        }
    }

    /// 点在哪一行就切回 WorkBuddy（面板自己的坐标系：左上角原点）
    private func handlePanelClick(at p: CGPoint, source: String) {
        guard ui.expanded else { return }
        // 窗口监听和全局监听可能对同一次点击各触发一次，去重
        guard Date().timeIntervalSince(lastClickAt) > 0.25 else { return }

        switch ui.hitTest(p, rowCount: store.tasks.count) {
        case .row(let i):
            lastClickAt = Date()
            let task = store.tasks[i]
            AppDebug.log("[select/\(source)] 命中第 \(i + 1) 行：\(task.title) → \(task.kind.target)")
            AppActions.open(task)
        case .footer(let i):
            lastClickAt = Date()
            runFooterAction(i, source: source)
        case .none:
            AppDebug.log("[select/\(source)] 未命中行/按钮 (\(Int(p.x)), \(Int(p.y)))")
        }
    }

    private func runFooterAction(_ index: Int, source: String) {
        switch index {
        case 0:
            AppDebug.log("[select/\(source)] 底栏：打开 WorkBuddy")
            AppActions.openWorkBuddy()
        case 1:
            AppDebug.log("[select/\(source)] 底栏：刷新")
            store.refresh()
        case 2:
            AppDebug.log("[select/\(source)] 底栏：声音 \(prefs.notifySound ? "关" : "开")")
            prefs.notifySound.toggle()
        default:
            AppDebug.log("[select/\(source)] 底栏：退出")
            NSApp.terminate(nil)
        }
    }

    // MARK: 悬停检测

    /// 兜底：即使窗口不接受事件，也能感知鼠标是否贴到把手
    private func installGlobalMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved()
        }
    }

    private func handleMouseMoved() {
        let loc = NSEvent.mouseLocation
        if ui.expanded {
            let f = shapeFrame(expanded: true).insetBy(dx: -10, dy: -10)
            if f.contains(loc) {
                cancelCollapse()      // 回到面板上 → 撤销倒计时
            } else {
                scheduleCollapse()    // 已离开 → 倒计时已启动就不再推迟
            }
        } else {
            // 收起状态下把判定区放大，贴到右边缘附近就算悬停
            let f = shapeFrame(expanded: false).insetBy(dx: -24, dy: -18)
            if f.contains(loc) { expand() }
        }
    }

    // MARK: 状态变化 → 提醒

    private func handleTransition(_ item: TaskItem, _ state: TaskState) {
        // 由 store 先把 alertLevel 抬起，这里只负责声音 / 系统通知
        if prefs.notifySound {
            let name: String
            switch state {
            case .failed:      name = "Basso"
            case .needConfirm: name = "Ping"
            default:           name = "Glass"
            }
            SoundPlayer.shared.play(name)
        }
        guard prefs.notifySystem else { return }
        let title: String
        switch state {
        case .done:        title = "任务完成"
        case .needConfirm: title = "有待确认的任务"
        case .failed:      title = "任务失败"
        default:           title = "任务状态变化"
        }
        Notifier.shared.post(title: title, body: item.title)
    }
}

// MARK: - 外部动作

enum AppDebug {
    static let on = ProcessInfo.processInfo.environment["NOTCHTASKS_DEBUG"] != nil
    static func log(_ s: String) {
        guard on else { return }
        print(s)
        fflush(stdout)
    }
}

enum AppActions {
    static let workBuddyBundleID = "com.tencent.workbuddy.mac"
    static let iTermBundleID = "com.googlecode.iterm2"

    /// 按任务来源跳转：WorkBuddy 任务回 WorkBuddy，终端 CLI 任务回 iTerm2
    static func open(_ task: TaskItem) {
        switch task.kind {
        case .claude:               activateITerm2()
        case .session, .automation: openWorkBuddy()
        }
    }

    static func activateITerm2() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: iTermBundleID).first {
            let ok = app.activate(options: [.activateAllWindows])
            AppDebug.log("[apps] activate iTerm2(运行中) -> \(ok)")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTermBundleID) else {
            AppDebug.log("[apps] 找不到 iTerm2")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        AppDebug.log("[apps] 启动 iTerm2")
    }

    static func openWorkBuddy() {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: workBuddyBundleID).first {
            let ok = running.activate(options: [.activateAllWindows])
            AppDebug.log("[apps] activate WorkBuddy(运行中) -> \(ok)")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: workBuddyBundleID) else {
            AppDebug.log("[apps] 找不到 WorkBuddy 安装位置")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        AppDebug.log("[apps] 启动 WorkBuddy")
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var controller: NotchController!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.requestAuthorization()
        controller = NotchController()
        controller.start()
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    // MARK: 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                   accessibilityDescription: "任务坞")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = controller.store
        let ui = controller.ui
        let prefs = controller.prefs

        let head = NSMenuItem(title: store.statusText, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        menu.addItem(makeItem("显示 / 收起面板", #selector(togglePanel), "t"))
        menu.addItem(makeItem("立即刷新", #selector(refresh), "r"))
        menu.addItem(.separator())

        menu.addItem(makeToggle("声音提醒", prefs.notifySound, #selector(toggleSound)))
        menu.addItem(makeToggle("系统通知", prefs.notifySystem, #selector(toggleSystem)))
        menu.addItem(makeToggle("显示已完成", prefs.showFinished, #selector(toggleFinished)))
        menu.addItem(.separator())

        let rowsParent = NSMenuItem(title: "显示条数", action: nil, keyEquivalent: "")
        let rowsMenu = NSMenu()
        for n in [4, 6, 8] {
            let it = NSMenuItem(title: "\(n) 条", action: #selector(setRows(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = (prefs.maxRows == n) ? .on : .off
            rowsMenu.addItem(it)
        }
        rowsParent.submenu = rowsMenu
        menu.addItem(rowsParent)

        if NSScreen.screens.count > 1 {
            let scrParent = NSMenuItem(title: "显示屏幕", action: nil, keyEquivalent: "")
            let scrMenu = NSMenu()
            let current = UserDefaults.standard.integer(forKey: "screenIndex")
            for (i, s) in NSScreen.screens.enumerated() {
                let it = NSMenuItem(title: "屏幕 \(i + 1)（\(Int(s.frame.width))×\(Int(s.frame.height))）",
                                    action: #selector(setScreen(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.state = (i == current) ? .on : .off
                scrMenu.addItem(it)
            }
            scrParent.submenu = scrMenu
            menu.addItem(scrParent)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("打开 WorkBuddy", #selector(openApp), ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出任务坞", #selector(quit), "q"))

        let _ = ui   // 保留引用，避免被编译器判定未使用
    }

    private func makeItem(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func makeToggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        return it
    }

    // MARK: 动作

    @objc private func togglePanel() { controller.toggleExpand() }
    @objc private func refresh() { controller.store.refresh() }
    @objc private func openApp() { AppActions.openWorkBuddy() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSound() {
        controller.prefs.notifySound.toggle()
    }
    @objc private func toggleSystem() {
        controller.prefs.notifySystem.toggle()
    }
    @objc private func toggleFinished() {
        controller.prefs.showFinished.toggle()
        controller.store.showFinished = controller.prefs.showFinished
        controller.store.refresh()
    }
    @objc private func setRows(_ sender: NSMenuItem) {
        controller.prefs.maxRows = sender.tag
        controller.store.maxRows = sender.tag
        controller.store.refresh()
    }
    @objc private func setScreen(_ sender: NSMenuItem) {
        controller.moveToScreen(index: sender.tag)
    }
}
