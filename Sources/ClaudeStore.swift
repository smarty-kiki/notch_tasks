import Foundation
import Darwin

/// 终端里一个 Claude Code CLI 会话（读自 ~/.claude/sessions/<pid>.json）
struct ClaudeSession {
    var pid: pid_t
    var sessionID: String
    var cwd: String
    /// 注册表里的会话名（多是派生的，如 `kiki-2d`）
    var name: String
    /// Claude 自己起的会话标题，也就是它写进终端标签的那个名字
    /// （读自会话记录的 `ai-title` 记录，见 ClaudeStore.transcriptTitle）
    var aiTitle: String?
    var status: String        // busy / idle / waiting
    var waitingFor: String?   // 仅 status == waiting 时出现，例如 "permission prompt"
    var updatedAt: Date
    var alive: Bool           // PID 存在
    var isClaude: Bool        // 该 PID 的可执行文件确实是 claude（排除 PID 复用）
    var source: Source = .registry

    /// 这条会话是怎么发现的
    enum Source: String {
        /// `~/.claude/sessions/<pid>.json` 里有它 —— status 是 Claude 自己写的，最准
        case registry
        /// 注册表里没有，但会话记录还在动 —— 状态只能从记录尾部推断
        case transcript
    }

    /// 正在干活
    var isBusy: Bool { status.lowercased() == "busy" }
    /// 停在等用户确认 / 授权
    var isWaiting: Bool { status.lowercased() == "waiting" }

    /// 列表里显示的名字：优先用 Claude 起的标题（和终端标签对得上），
    /// 会话刚开始、AI 还没来得及起标题时退回注册表里的派生名
    var displayTitle: String {
        if let t = aiTitle, !t.isEmpty { return t }
        return name.isEmpty ? "claude" : name
    }
}

/// 只读扫描 Claude Code 的会话注册表。
///
/// 数据源有两处，都是只读：
///
/// 1. `~/.claude/sessions/<pid>.json`（文件名就是 PID）——「现在还活着哪些会话」
///    ```json
///    {"pid":44187,"sessionId":"…","cwd":"…","name":"kiki-2d","nameSource":"derived",
///     "status":"busy","updatedAt":…,"statusUpdatedAt":…}
///    ```
///    `status` 已知取值：`busy`（干活）/ `idle`（等你输入）/ `waiting`（等你确认或授权，
///    此时会多一个 `waitingFor` 字段，例如 `"permission prompt"`）
///    文件名是 PID，所以可以用 `kill(pid,0)` + `proc_pidpath` 判断会话是否还活着，
///    并排除 PID 被复用的情况。注意 **这个目录会被 Claude Code 自己按日清理**
///    （见 `~/.claude/.last-cleanup`），清理后要等下一个会话注册进来才有内容。
///
/// 2. `~/.claude/projects/<cwd 转义>/<sessionId>.jsonl`——「这个会话在做什么」。
///    里面的 `{"type":"ai-title","aiTitle":"…"}` 记录就是 Claude 给会话起的标题，
///    会随会话推进反复重写（所以从文件尾部往前找最近的一条即可）。
enum ClaudeStore {

    static let sessionsDir = (UserHome.path as NSString).appendingPathComponent(".claude/sessions")
    static let projectsDir = (UserHome.path as NSString).appendingPathComponent(".claude/projects")

    /// 从记录尾部往回找多少字节；标题会反复重写，尾部几乎总能命中
    private static let tailBytes = 256 * 1024
    /// 尾部没命中时退回整文件扫描的上限，别为一个几十 MB 的记录把轮询拖住
    private static let fullScanLimit = 8 * 1024 * 1024

    /// 记录文件 → 上次解析结果。轮询每 2 秒跑一次，靠它避免反复读同一条记录
    private static var infoCache: [String: (mtime: Date, size: Int, info: TailInfo)] = [:]

    /// 注册表文件 → 上次解析成功的内容。
    /// 轮询正好撞上 Claude 写文件的瞬间时，会读到半截内容；这时沿用上一轮的值，
    /// 免得列表里的 CLI 行随每次写入闪断（下一轮就会刷新）。
    private static var lastGood: [String: [String: Any]] = [:]

    static func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        // 记录目录只列一次，之后每个会话在里面找自己的 <sessionId>.jsonl
        let projectDirs = ((try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [])
            .map { (projectsDir as NSString).appendingPathComponent($0) }

        // 会话文件被 Claude 按日清理掉之后，对应的缓存也丢掉
        let alive = Set(files)
        lastGood = lastGood.filter { alive.contains(($0.key as NSString).lastPathComponent) }

        var out: [ClaudeSession] = []
        for f in files where f.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path) else { continue }

            // 文件可能带尾部残片（见 firstJSONObject），也可能正好被读到写入中途
            let parsed = firstJSONObject(in: data)
            if let parsed = parsed {
                lastGood[path] = parsed
            } else {
                AppDebug.log("[claude] \(f) 未解析出完整 JSON（\(data.count) 字节），沿用上一轮的值")
            }
            guard let obj = parsed ?? lastGood[path] else {
                AppDebug.log("[claude] 跳过无法解析的会话文件: \(f)")
                continue
            }

            let pidFromName = pid_t(f.replacingOccurrences(of: ".json", with: "")) ?? -1
            let pid = (obj["pid"] as? NSNumber)?.int32Value ?? pidFromName
            guard pid > 0 else { continue }

            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? Date()
            let stamp = (obj["updatedAt"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? mtime
            // 状态字段和文件 mtime 取更晚的：mtime 能捕捉到状态字段没更新但文件被写过的情况
            let updated = max(stamp, mtime)

            let cwd = obj["cwd"] as? String ?? ""
            let name = (obj["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (cwd as NSString).lastPathComponent
            let sessionID = obj["sessionId"] as? String ?? ""

            out.append(ClaudeSession(
                pid: pid,
                sessionID: sessionID,
                cwd: cwd,
                name: name.isEmpty ? "claude" : name,
                aiTitle: transcriptInfo(sessionID: sessionID, in: projectDirs).title,
                status: obj["status"] as? String ?? "",
                waitingFor: (obj["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                updatedAt: updated,
                alive: isAlive(pid),
                isClaude: executablePath(pid)?.contains("claude") ?? false))
        }
        return out
    }

    /// 从注册表文件里取出**第一个完整的 JSON 对象**。
    ///
    /// 为什么不能只用 `JSONSerialization`：Claude Code 重写这个文件时存在
    /// 「内容变短但不截断」的竞态，旧内容更长时会在尾部留下上一次的残片，例如
    ///
    ///     {...完整对象...}51,"waitingFor":"permission prompt"}
    ///
    /// 这种 extra data 会让 `JSONSerialization` 直接抛错。原来用 `try?` 一包，
    /// 整条会话就被静默丢掉了 —— 现象是**进程明明活着、`sessions/` 里也有文件，
    /// 列表里却一个 CLI 会话都不显示**。这里做一次括号配对扫描，只截出第一个对象。
    ///
    /// 扫描时跟踪「是否在字符串内」和转义，避免把字符串里的花括号当成结构。
    static func firstJSONObject(in data: Data) -> [String: Any]? {
        // 绝大多数文件是干净的，先按原样解析一次，省掉扫描
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        let bytes = [UInt8](data)
        var start = -1          // 第一个 `{` 的下标
        var depth = 0
        var inString = false
        var escaped = false

        for (i, b) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if b == 0x5C { escaped = true }      // 反斜杠
                else if b == 0x22 { inString = false }    // 引号
                continue
            }
            switch b {
            case 0x22:                                // "
                inString = true
            case 0x7B:                                // {
                if start < 0 { start = i }
                depth += 1
            case 0x7D:                                // }
                depth -= 1
                if depth == 0, start >= 0 {
                    let slice = Data(bytes[start...i])
                    return try? JSONSerialization.jsonObject(with: slice) as? [String: Any]
                }
            default:
                break
            }
        }
        return nil
    }

    /// 还活着的 claude 会话（来自注册表）
    static func liveSessions() -> [ClaudeSession] {
        scan().filter { $0.alive && $0.isClaude }
    }

    /// 列表要显示的全部 CLI 会话 = 注册表里的 **∪** 只有会话记录在动的。
    static func all(transcriptWindow: TimeInterval = 15 * 60) -> [ClaudeSession] {
        let registered = liveSessions()
        let known = Set(registered.compactMap { $0.sessionID.isEmpty ? nil : $0.sessionID })
        return registered + recentFromTranscripts(within: transcriptWindow, excluding: known)
    }

    /// 只靠**会话记录**发现的会话。
    ///
    /// 为什么需要这个：`~/.claude/sessions/<pid>.json` 这个注册表并不可靠 ——
    /// 被程序 spawn 出来的 claude（比如 StaffDeck 起的数字员工）照样写会话记录、
    /// 照样在干活，却不会出现在注册表里。只看注册表，这类任务在列表里完全不见。
    ///
    /// （实测过：某个会话的记录文件持续在写、最后一条消息 stop_reason 还是 `tool_use`，
    ///   而同一时刻 `sessions/` 里只有另一个会话的文件 —— 两个会话是同时创建的，
    ///   一个注册了、一个没有，跟「按日清理」无关。）
    ///
    /// 所以这里反过来以**会话记录**为准：谁的文件最近还在动，谁就在跑。
    /// 代价是拿不到 Claude 自己写的 status，只能从记录尾部推断：
    /// 最后一条消息 `stop_reason == tool_use` → 在跑工具；`end_turn` → 已经答完。
    static func recentFromTranscripts(within window: TimeInterval,
                                      excluding known: Set<String>) -> [ClaudeSession] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsDir) else { return [] }
        let cutoff = Date().addingTimeInterval(-window)
        var out: [ClaudeSession] = []

        for d in dirs {
            let dirPath = (projectsDir as NSString).appendingPathComponent(d)
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = (dirPath as NSString).appendingPathComponent(f)

                // 先看 mtime（便宜），不在窗口内就不去读内容
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff,
                      let size = (attrs[.size] as? NSNumber)?.intValue, size > 0
                else { continue }

                let sid = f.replacingOccurrences(of: ".jsonl", with: "")
                guard !known.contains(sid) else { continue }

                let info = tailInfoCached(path: path, size: size, mtime: mtime)
                let cwd = info.cwd ?? ""

                out.append(ClaudeSession(
                    pid: 0,                       // 没有 PID：这条不是从注册表来的
                    sessionID: sid,
                    cwd: cwd,
                    name: (cwd as NSString).lastPathComponent,
                    aiTitle: info.title,
                    // 复用注册表那套词，让下游映射不用分叉
                    status: info.lastStop == "tool_use" ? "busy" : "idle",
                    waitingFor: nil,
                    updatedAt: mtime,
                    alive: true,                  // 文件刚动过就算活着
                    isClaude: true,
                    source: .transcript))
            }
        }
        return out
    }

    // MARK: - 会话记录的尾部

    /// 从会话记录尾部能读出来的东西
    struct TailInfo {
        /// Claude 给会话起的标题（= 终端标签名）
        var title: String?
        /// 会话的工作目录
        var cwd: String?
        /// 最后一条消息的 stop_reason：
        /// `tool_use` = 正在跑工具，`end_turn` = 已经答完在等你
        var lastStop: String?
        static let empty = TailInfo()
    }

    /// 会话记录的文件名就是 sessionId（UUID），所以按文件名找即可，
    /// 不用去猜 cwd 到目录名的转义规则
    private static func transcriptInfo(sessionID: String, in projectDirs: [String]) -> TailInfo {
        guard !sessionID.isEmpty else { return .empty }
        for dir in projectDirs {
            let path = (dir as NSString).appendingPathComponent("\(sessionID).jsonl")
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { continue }
            return tailInfoCached(path: path, size: size, mtime: mtime)
        }
        return .empty
    }

    /// 带缓存地读尾部；标题偶尔很久才写一条，尾部没命中就退回整文件扫一次
    private static func tailInfoCached(path: String, size: Int, mtime: Date) -> TailInfo {
        if let hit = infoCache[path], hit.mtime == mtime, hit.size == size {
            return hit.info
        }

        var info = tailInfo(at: path, from: max(0, size - tailBytes))
        if info.title == nil, size > tailBytes, size <= fullScanLimit {
            info.title = tailInfo(at: path, from: 0).title
        }

        infoCache[path] = (mtime, size, info)
        // 会话来来去去，别让这个表无限涨；真溢出了清空重来也无所谓
        if infoCache.count > 128 { infoCache.removeAll() }
        return info
    }

    /// 从 offset 开始读到底，一次拿齐「标题 / cwd / 最后一条消息的状态」。
    ///
    /// 三个字段各自取**最后一次出现**即可：从后往前扫，谁的坑还没填就顺手填上，
    /// 三个都填齐就提前退出 —— 不用为了读一个字段把整个文件解析一遍。
    private static func tailInfo(at path: String, from offset: Int) -> TailInfo {
        guard let text = readText(at: path, from: offset) else { return .empty }

        var info = TailInfo.empty
        for line in text.split(separator: "\n").reversed() {
            guard line.hasPrefix("{") else { continue }
            let needTitle = info.title == nil
            let needCwd = info.cwd == nil
            let needStop = info.lastStop == nil
            if !needTitle && !needCwd && !needStop { break }

            if needTitle, line.contains("aiTitle") {
                if let o = jsonObject(line), let raw = o["aiTitle"] as? String {
                    let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { info.title = t }
                }
            }
            if needCwd, line.contains("\"cwd\"") {
                if let o = jsonObject(line), let c = o["cwd"] as? String, !c.isEmpty {
                    info.cwd = c
                }
            }
            if needStop {
                if let o = jsonObject(line),
                   let type = o["type"] as? String, type == "user" || type == "assistant" {
                    info.lastStop = ((o["message"] as? [String: Any])?["stop_reason"] as? String) ?? ""
                }
            }
        }
        return info
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let d = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    /// 读文件的一段到结尾
    private static func readText(at path: String, from offset: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd() else { return nil }

        // 从任意字节偏移切进去可能把某个多字节字符劈成两半，解码失败就丢掉首行残缺部分
        if let s = String(data: data, encoding: .utf8) { return s }
        if let nl = data.firstIndex(of: 0x0A) {
            return String(data: data[data.index(after: nl)...], encoding: .utf8)
        }
        return nil
    }

    // MARK: - 进程存活

    private static func isAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM          // 存在但没权限发信号，同样算活着
    }

    /// 进程可执行文件路径；PID 已被复用时能据此排除
    private static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }
}
