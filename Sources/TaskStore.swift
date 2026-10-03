import Foundation
import Combine
import SQLite3

/// 数据仓库：定时轮询 workbuddy 数据，产出统一任务列表 + 变化事件。
final class TaskStore: ObservableObject {

    // 对外状态
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var alertLevel: AlertLevel = .idle
    @Published private(set) var alertCount: Int = 0
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusText: String = "初始化…"
    @Published private(set) var isLive: Bool = false
    @Published private(set) var activeTotal: Int = 0
    @Published private(set) var confirmTotal: Int = 0

    // 设置
    @Published var maxRows: Int = 6
    /// 合成数据模式：完全不读本机数据，只产出 `demoItems()` 里那批假任务。
    /// 文档截图（docs/）就是它渲染的——仓库公开，所以标题与路径都必须是假的。
    /// 实时运行永远是 false。
    var demoData = false
    @Published var interval: TimeInterval = 2.0
    @Published var showFinished: Bool = true

    /// 状态跃迁回调（用于声音 / 系统通知）
    var onTransition: ((TaskItem, TaskState) -> Void)?

    private let db = WorkBuddyDB()
    private var timer: Timer?
    private var previous: [String: TaskState] = [:]
    private var baselineReady = false
    private var refreshInFlight = false
    private var doneBurst = 0

    /// 列表只看最近这段时间内的任务
    /// 已结束的任务（已完成 / 失败 / 空闲下来的会话）在列表里还留多久。
    /// 再久就没必要占位置了 —— 列表是「现在在发生什么」，不是历史记录。
    ///
    /// 配合 `TaskItem.recentDoneWindow`（10 分钟）看：结束 10 分钟内显示成明亮的
    /// 「空闲」，10~20 分钟沉成灰蓝的「已完成」，再过一会儿就从列表里消失。
    private let finishedWindow: TimeInterval = 20 * 60
    /// 未读结果只有在这个时间窗内才算「待确认」，更早的旧未读不再打扰
    private let confirmWindow: TimeInterval = 24 * 3_600

    // MARK: - 生命周期

    func start() {
        refresh()
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setInterval(_ v: TimeInterval) {
        interval = v
        scheduleTimer()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 用户已查看面板 → 清掉「刚完成」的瞬时提醒；待确认由数据本身决定，不清
    func acknowledge() {
        doneBurst = 0
        recomputeAlertLevel()
    }

    private func recomputeAlertLevel() {
        if confirmTotal > 0 {
            alertLevel = .confirm
        } else if doneBurst > 0 {
            alertLevel = .done
        } else if activeTotal > 0 {
            alertLevel = .running
        } else {
            alertLevel = .idle
        }
        switch alertLevel {
        case .confirm: alertCount = confirmTotal
        case .done:    alertCount = doneBurst
        default:       alertCount = 0
        }
        applyDebugOverride()
    }

    /// 调试用：NOTCHTASKS_FORCE_ALERT=confirm|done|running|idle 可强制指定提醒级别
    private func applyDebugOverride() {
        guard let v = ProcessInfo.processInfo.environment["NOTCHTASKS_FORCE_ALERT"] else { return }
        switch v {
        case "confirm": alertLevel = .confirm; alertCount = max(confirmTotal, 1)
        case "done":    alertLevel = .done;    alertCount = max(doneBurst, 1)
        case "running": alertLevel = .running; alertCount = activeTotal
        case "idle":    alertLevel = .idle;    alertCount = 0
        default: break
        }
    }

    private func isFresh(_ d: Date) -> Bool {
        Date().timeIntervalSince(d) < confirmWindow
    }

    // MARK: - 刷新

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        var items: [TaskItem]

        if demoData {
            // 预览 / 截图：不打开数据库，也不扫 ~/.claude
            items = Self.demoItems()
            isLive = true
            lastRefresh = Date()
        } else {
            guard let handle = db.open() else {
                isLive = false
                statusText = db.lastError ?? "读取失败"
                return
            }
            defer { sqlite3_close(handle) }

            let todos = fetchActiveTodos(handle)
            items = fetchSessions(handle, todos: todos)
            items.append(contentsOf: fetchAutomationRuns(handle))
            items.append(contentsOf: fetchClaudeSessions())
        }

        // 列表只留「还在跑的」和「刚结束的」。两处都不能按时间清：
        //   - 跑着的（running）本来就不该动
        //   - 等你确认的更不能动 —— 要是被时间清掉，提醒就等于丢了
        let finishedCutoff = Date().addingTimeInterval(-finishedWindow)
        items.removeAll { item in
            if item.needsConfirm || item.state == .needConfirm { return false }
            switch item.state {
            case .done, .failed, .idle:
                return item.updatedAt < finishedCutoff
            case .running, .needConfirm:
                return false
            }
        }

        isLive = true
        lastRefresh = Date()

        items.sort { a, b in
            // 按「展示状态」排：刚结束的（显示成空闲绿）要排在早就结束的（已完成灰）前面
            let ra = a.displayState.sortRank, rb = b.displayState.sortRank
            if ra != rb { return ra < rb }
            return a.updatedAt > b.updatedAt
        }

        // 去重
        var seen = Set<String>()
        var unique: [TaskItem] = []
        for it in items where !seen.contains("\(it.kind.rawValue):\(it.id)") {
            seen.insert("\(it.kind.rawValue):\(it.id)")
            unique.append(it)
        }

        detectTransitions(unique)

        let allActive = unique.filter { $0.state.isActive }
        let allConfirm = unique.filter { $0.needsConfirm }
        activeTotal = allActive.count
        confirmTotal = allConfirm.count
        statusText = "\(activeTotal) 执行中 · \(confirmTotal) 待确认"

        var shown = unique
        if !showFinished { shown = shown.filter { $0.state != .done } }
        tasks = Array(shown.prefix(maxRows))
        recomputeAlertLevel()
    }

    /// 与上一次快照比对，发现「刚完成 / 刚变待确认 / 刚失败」
    private func detectTransitions(_ items: [TaskItem]) {
        var current: [String: TaskState] = [:]
        for it in items { current["\(it.kind.rawValue):\(it.id)"] = it.state }

        defer {
            previous = current
            baselineReady = true
        }
        guard baselineReady else { return }   // 首轮只建基线

        var newest: (TaskItem, TaskState)?
        for it in items {
            let key = "\(it.kind.rawValue):\(it.id)"
            guard let old = previous[key], old != it.state else { continue }

            // 只认真正的状态跃迁：运行中→完成 / →待确认 / →失败
            // （避免「待确认」随时间窗自然衰减成「已完成」时误报）
            let isNewlyDone    = it.state == .done && old == .running
            let isNewlyConfirm = it.state == .needConfirm && old != .needConfirm
            let isNewlyFailed  = it.state == .failed && old != .failed
            guard isNewlyDone || isNewlyConfirm || isNewlyFailed else { continue }

            if newest == nil || it.updatedAt > newest!.0.updatedAt { newest = (it, it.state) }
        }
        guard let (item, state) = newest else { return }

        if state == .done { doneBurst += 1 }
        onTransition?(item, state)
    }

    // MARK: - 查询：活跃子任务（tasks/<sessionId>/*.json）

    static let tasksRoot = (UserHome.path as NSString).appendingPathComponent(".workbuddy/tasks")

    /// 返回 sessionId -> 当前正在做的子任务名
    private func fetchActiveTodos(_ db: OpaquePointer) -> [String: String] {
        let sql = """
        SELECT id FROM sessions
        WHERE status = 'working' AND (deleted_at IS NULL OR deleted_at = -1)
        ORDER BY COALESCE(last_activity_at, updated_at) DESC
        LIMIT 6
        """
        var ids: [String] = []
        db.query(sql) { st in ids.append(Col.text(st, 0)) }

        var out: [String: String] = [:]
        for sid in ids {
            if let todo = Self.currentTodo(sessionId: sid) { out[sid] = todo }
        }
        return out
    }

    /// 读取某个 session 目录下最新的 in_progress / pending 待办
    private static func currentTodo(sessionId: String) -> String? {
        let dir = (tasksRoot as NSString).appendingPathComponent(sessionId)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }

        var best: (Date, String, String)?
        for name in names where name.hasSuffix(".json") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if let b = best, mtime <= b.0 { continue }
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String,
                  status == "in_progress" || status == "pending",
                  let subject = obj["subject"] as? String else { continue }
            best = (mtime, subject, status)
        }
        guard let (_, subject, status) = best else { return nil }
        return status == "in_progress" ? "正在：\(subject)" : "待办：\(subject)"
    }

    // MARK: - 查询：sessions

    private func fetchSessions(_ db: OpaquePointer, todos: [String: String]) -> [TaskItem] {
        let sql = """
        SELECT id,
               COALESCE(NULLIF(custom_title, ''), title, '(未命名任务)') AS t,
               COALESCE(cwd, '')            AS cwd,
               status,
               COALESCE(last_activity_at, updated_at, created_at) AS ts,
               COALESCE(unread, 0)          AS unread
        FROM sessions
        WHERE (deleted_at IS NULL OR deleted_at = -1)
          AND status <> 'archived'
        ORDER BY ts DESC
        LIMIT 60
        """
        var out: [TaskItem] = []
        db.query(sql) { st in
            let id = Col.text(st, 0)
            let title = Col.text(st, 1)
            let cwd = Col.str(st, 2)
            let raw = Col.text(st, 3).lowercased()
            let ts = Col.int(st, 4)
            let unread = Col.int(st, 5)

            let updated = epochToDate(ts)
            let fresh = isFresh(updated)

            // WorkBuddy 的 status 实际取值：working / pending / completed /
            // error / terminated / archived（archived 已在 SQL 里排除）。
            // 注意 pending **不是「排队」**，而是停在等你确认 / 选择，
            // 所以映射成「待确认」（橙黄），并让它参与告警。
            let state: TaskState
            switch raw {
            case "working":             state = .running
            case "pending":             state = fresh ? .needConfirm : .done
            case "error", "terminated": state = .failed
            default:                    state = .done
            }
            // 「等你确认」和「有未读结果」都算待确认；
            // 都套时间窗，避免一个没人理会的旧状态让把手永久亮着
            let needsConfirm = fresh && (raw == "pending" || unread != 0)

            out.append(TaskItem(id: id,
                                kind: .session,
                                title: title,
                                detail: raw == "pending" ? (todos[id] ?? "等你确认") : todos[id],
                                cwd: cwd,
                                state: state,
                                updatedAt: updated,
                                needsConfirm: needsConfirm))
        }
        return out
    }

    // MARK: - 查询：终端里的 Claude Code CLI

    private func fetchClaudeSessions() -> [TaskItem] {
        // 用 all() 而不是 liveSessions()：注册表会漏会话（被程序 spawn 出来的 claude
        // 不写 sessions/<pid>.json），拿会话记录兜住，否则那些任务在列表里完全不见
        return ClaudeStore.all().map { s in
            // Claude Code 的 status 已知取值：busy / idle / waiting，
            // 和 WorkBuddy 那边的映射对齐（同一个词 = 同一件事）：
            //
            //   busy    → 执行中   （= WorkBuddy working）
            //   waiting → 待确认   （= WorkBuddy pending，且带 waitingFor）
            //   idle    → 空闲     （会话活着但停着；WorkBuddy 那边没有对应概念）
            //
            // 未知取值按「在跑」处理，原值只写进调试日志，不显示到界面上。
            let st = s.status.lowercased()
            let detail: String
            switch st {
            case "busy":    detail = "正在执行"
            case "idle":    detail = "等你输入"
            case "waiting": detail = Self.waitingText(s.waitingFor)
            default:
                // 未知取值只在调试日志里露出原始英文，界面上不显示
                AppDebug.log("[claude] 未知 status=\(st) name=\(s.name)")
                detail = "运行中"
            }

            let state: TaskState
            switch st {
            case "idle":    state = .idle
            case "waiting": state = .needConfirm
            default:        state = .running
            }

            // 从记录发现的会话没有 PID，用 sessionId 当 id —— 两种来源下都唯一
            let id = s.sessionID.isEmpty ? "\(s.pid)" : s.sessionID

            return TaskItem(id: id,
                            kind: .claude,
                            title: s.displayTitle,   // Claude 起的会话标题，和终端标签一致
                            detail: detail,
                            cwd: s.cwd.isEmpty ? nil : s.cwd,
                            state: state,
                            updatedAt: s.updatedAt,
                            // 等确认才算「待确认」，并套时间窗，避免僵尸会话一直亮着
                            needsConfirm: st == "waiting" && self.isFresh(s.updatedAt))
        }
    }

    /// waitingFor 的可读描述
    private static func waitingText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "等你确认" }
        switch raw.lowercased() {
        case "permission prompt", "permission": return "等你确认权限"
        case "question":                         return "等你回答"
        case "plan approval":                    return "等你批准计划"
        default: return "等你确认 · \(raw)"
        }
    }

    // MARK: - 合成数据（预览 / 文档截图）

    /// 一批覆盖全部展示状态的假任务，`demoData = true` 时用它替掉真实数据源。
    ///
    /// 两条硬约束：
    /// 1. **不读本机任何东西**——它会渲染进 docs/ 的图，仓库是公开的
    /// 2. 时间戳由「距今多少分钟」反推，所以工作区目录名（`10-02 21:40 工作区`）
    ///    和右上角的相对时间永远自洽，不会出现「3 分钟前 / 昨天的工作区」
    private static func demoItems() -> [TaskItem] {
        let home = UserHome.path

        func minutesAgo(_ m: Double) -> Date {
            Date().addingTimeInterval(-m * 60)
        }
        /// 造一个和 WorkBuddy 真实形态一致的时间戳工作区路径
        func workspace(_ m: Double) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            return home + "/WorkBuddy/" + f.string(from: minutesAgo(m))
        }

        return [
            TaskItem(id: "demo-s1", kind: .session,
                     title: "重构订单结算流程",
                     detail: "正在：拆分结算服务与优惠券逻辑",
                     cwd: workspace(0.4),
                     state: .running, updatedAt: minutesAgo(0.4)),

            TaskItem(id: "demo-s2", kind: .session,
                     title: "生成季度数据报表",
                     detail: "等你确认",
                     cwd: workspace(4),
                     state: .needConfirm, updatedAt: minutesAgo(4),
                     needsConfirm: true),

            // CLI 行的标题是 Claude 自己起的会话标题（ai-title），不是派生名
            TaskItem(id: "demo-c1", kind: .claude,
                     title: "补上接口层的集成测试",
                     detail: "正在执行",
                     cwd: home + "/Projects/example_api",
                     state: .running, updatedAt: minutesAgo(0.8)),

            // 刚结束 6 分钟 → 展示成「空闲」（明亮绿）
            TaskItem(id: "demo-s3", kind: .session,
                     title: "补充结算流程的单元测试",
                     detail: nil,
                     cwd: workspace(6),
                     state: .done, updatedAt: minutesAgo(6)),

            TaskItem(id: "demo-c2", kind: .claude,
                     title: "梳理示例服务的部署脚本",
                     detail: "等你输入",
                     cwd: home + "/Projects/example_server",
                     state: .idle, updatedAt: minutesAgo(13)),

            // 结束 1.5 小时 → 沉成「已完成」（灰蓝）
            TaskItem(id: "demo-s4", kind: .session,
                     title: "整理发布检查清单",
                     detail: nil,
                     cwd: workspace(95),
                     state: .done, updatedAt: minutesAgo(95)),

            TaskItem(id: "demo-a1", kind: .automation,
                     title: "每日构建巡检",
                     detail: "检查 main 分支的构建与冒烟测试",
                     cwd: workspace(200),
                     state: .done, updatedAt: minutesAgo(200)),
        ]
    }

    // MARK: - 查询：automation_runs

    private func fetchAutomationRuns(_ db: OpaquePointer) -> [TaskItem] {
        let sql = """
        SELECT ar.thread_id,
               COALESCE(NULLIF(ar.thread_title, ''), '') AS t,
               COALESCE(ar.source_cwd, '') AS cwd,
               COALESCE(ar.status, '')     AS stt,
               COALESCE(ar.updated_at, ar.created_at) AS ts,
               ar.read_at,
               COALESCE(ar.result_success, -1) AS ok,
               COALESCE(a.name, '')        AS aname
        FROM automation_runs ar
        LEFT JOIN automations a ON a.id = ar.automation_id
        ORDER BY ts DESC
        LIMIT 12
        """
        var out: [TaskItem] = []
        db.query(sql) { st in
            let tid = Col.text(st, 0)
            let rawTitle = Col.text(st, 1)
            let cwd = Col.str(st, 2)
            let stt = Col.text(st, 3).uppercased()
            let ts = Col.int(st, 4)
            let readAt = Col.intOrNil(st, 5)
            let ok = Col.int(st, 6)
            let aname = Col.text(st, 7)

            let updated = epochToDate(ts)
            // 未读结果只在时间窗内算「待确认」，更早的旧未读当作已完成
            let needsConfirm = (readAt == nil) && isFresh(updated)
            let state: TaskState
            if stt.contains("RUN") || stt.contains("EXEC") || stt.contains("START") || stt.contains("PENDING") {
                state = .running
            } else if ok == 0 {
                state = .failed
            } else {
                state = needsConfirm ? .needConfirm : .done
            }

            let title = aname.isEmpty ? "自动化任务" : aname
            out.append(TaskItem(id: tid,
                                kind: .automation,
                                title: title,
                                detail: Self.summarize(rawTitle),
                                cwd: cwd,
                                state: state,
                                updatedAt: updated,
                                needsConfirm: needsConfirm))
        }
        return out
    }

    /// 自动化 thread_title 常把多句挤在一起，压成一行摘要
    private static func summarize(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "\n", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let cut = t.prefix(48)
        return cut.count < t.count ? String(cut) + "…" : String(cut)
    }
}
