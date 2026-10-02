import Foundation
import Darwin

/// 终端里一个 Claude Code CLI 会话（读自 ~/.claude/sessions/<pid>.json）
struct ClaudeSession {
    var pid: pid_t
    var sessionID: String
    var cwd: String
    var name: String
    var status: String        // "idle" / 其它
    var updatedAt: Date
    var alive: Bool           // PID 存在
    var isClaude: Bool        // 该 PID 的可执行文件确实是 claude（排除 PID 复用）

    var isRunning: Bool {
        let s = status.lowercased()
        return !s.isEmpty && s != "idle"
    }
}

/// 只读扫描 Claude Code 的会话注册表。
///
/// 数据源：`~/.claude/sessions/<pid>.json`，形如
/// `{"pid":44187,"sessionId":"…","cwd":"…","name":"crewup-api-ef","status":"idle","updatedAt":…}`
/// 文件名就是 PID，所以可以用 `kill(pid,0)` + `proc_pidpath` 判断会话是否还活着，
/// 并排除 PID 被复用的情况。全程只读，不碰 Claude 的任何文件。
enum ClaudeStore {

    static let sessionsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/sessions")

    static func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

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

            out.append(ClaudeSession(
                pid: pid,
                sessionID: obj["sessionId"] as? String ?? "",
                cwd: cwd,
                name: name.isEmpty ? "claude" : name,
                status: obj["status"] as? String ?? "",
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
