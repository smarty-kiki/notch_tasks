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

    static let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")
    static let projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

    /// 从记录尾部往回找多少字节；标题会反复重写，尾部几乎总能命中
    private static let tailBytes = 256 * 1024
    /// 尾部没命中时退回整文件扫描的上限，别为一个几十 MB 的记录把轮询拖住
    private static let fullScanLimit = 8 * 1024 * 1024

    /// 记录文件 → 上次解析结果。轮询每 2 秒跑一次，靠它避免反复读同一条记录
    private static var titleCache: [String: (mtime: Date, size: Int, title: String?)] = [:]

    static func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        // 记录目录只列一次，之后每个会话在里面找自己的 <sessionId>.jsonl
        let projectDirs = ((try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [])
            .map { (projectsDir as NSString).appendingPathComponent($0) }

        var out: [ClaudeSession] = []
        for f in files where f.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

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
                aiTitle: transcriptTitle(sessionID: sessionID, in: projectDirs),
                status: obj["status"] as? String ?? "",
                waitingFor: (obj["waitingFor"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                updatedAt: updated,
                alive: isAlive(pid),
                isClaude: executablePath(pid)?.contains("claude") ?? false))
        }
        return out
    }

    /// 还活着的 claude 会话
    static func liveSessions() -> [ClaudeSession] {
        scan().filter { $0.alive && $0.isClaude }
    }

    // MARK: - 会话标题（= Claude 写进终端标签的那个名字）

    /// 会话记录的文件名就是 sessionId（UUID），所以按文件名找即可，
    /// 不用去猜 cwd 到目录名的转义规则
    private static func transcriptTitle(sessionID: String, in projectDirs: [String]) -> String? {
        guard !sessionID.isEmpty else { return nil }
        for dir in projectDirs {
            let path = (dir as NSString).appendingPathComponent("\(sessionID).jsonl")
            if let t = transcriptTitle(path: path) { return t }
        }
        return nil
    }

    private static func transcriptTitle(path: String) -> String? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 else { return nil }

        if let hit = titleCache[path], hit.mtime == mtime, hit.size == size {
            return hit.title
        }

        var found = lastAITitle(at: path, from: max(0, size - tailBytes))
        if found == nil, size > tailBytes, size <= fullScanLimit {
            found = lastAITitle(at: path, from: 0)
        }

        titleCache[path] = (mtime, size, found)
        // 会话来来去去，别让这个表无限涨；真溢出了清空重来也无所谓
        if titleCache.count > 128 { titleCache.removeAll() }
        return found
    }

    /// 从 offset 开始读到底，取最后一条 `{"type":"ai-title","aiTitle":"…"}` 里的标题
    private static func lastAITitle(at path: String, from offset: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.readToEnd() else { return nil }

        // 从任意字节偏移切进去可能把某个多字节字符劈成两半，解码失败就丢掉首行残缺部分
        func decode(_ d: Data) -> String? {
            if let s = String(data: d, encoding: .utf8) { return s }
            if let nl = d.firstIndex(of: 0x0A) {
                return String(data: d[d.index(after: nl)...], encoding: .utf8)
            }
            return nil
        }
        guard let text = decode(data) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("aiTitle") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let raw = obj["aiTitle"] as? String else { continue }
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
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
