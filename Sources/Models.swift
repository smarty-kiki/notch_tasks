import Foundation
import SwiftUI

/// 任务状态（对外展示用）
enum TaskState: String {
    case running      // 执行中
    case idle         // 活着但空闲（终端里的 claude 停在提示符）
    case needConfirm  // 待确认（等你确认 / 选择，或有未读结果）
    case done         // 已完成
    case failed       // 失败 / 中断

    var label: String {
        switch self {
        case .running:     return "执行中"
        case .idle:        return "空闲"
        case .needConfirm: return "待确认"
        case .done:        return "已完成"
        case .failed:      return "失败"
        }
    }

    /// 排序权重，越小越靠前
    var sortRank: Int {
        switch self {
        case .needConfirm: return 0
        case .running:     return 1
        case .idle:        return 2
        case .failed:      return 3
        case .done:        return 4
        }
    }

    var color: Color {
        switch self {
        case .running:     return Color(red: 0.16, green: 0.56, blue: 1.00)
        case .idle:        return Color(red: 0.42, green: 0.62, blue: 0.72)
        case .needConfirm: return Color(red: 1.00, green: 0.62, blue: 0.04)
        case .done:        return Color(red: 0.20, green: 0.80, blue: 0.36)
        case .failed:      return Color(red: 1.00, green: 0.29, blue: 0.24)
        }
    }

    var symbol: String {
        switch self {
        case .running:     return "arrow.triangle.2.circlepath"
        case .idle:        return "pause.circle"
        case .needConfirm: return "exclamationmark.circle.fill"
        case .done:        return "checkmark.circle.fill"
        case .failed:      return "xmark.octagon.fill"
        }
    }

    /// 活跃 = 还在跑
    var isActive: Bool { self == .running }
}

/// 统一任务条目
struct TaskItem: Identifiable, Equatable {
    enum Kind: String {
        case session     // WorkBuddy 对话型任务
        case automation  // WorkBuddy 定时/自动化任务
        case claude      // 终端里的 Claude Code CLI

        /// 列表里显示的来源名称
        var sourceLabel: String {
            switch self {
            case .claude:               return "Claude CLI"
            case .session, .automation: return "WorkBuddy"
            }
        }

        /// 点击后跳到哪
        var target: String {
            switch self {
            case .claude:               return "iTerm2"
            case .session, .automation: return "WorkBuddy"
            }
        }

        /// 来源配色（标签用）。刻意和「状态」的配色体系分开：
        /// 状态是圆点+右侧文字，来源是这个标签
        var sourceColor: Color {
            switch self {
            case .claude:               return Color(red: 0.55, green: 0.78, blue: 0.62)
            case .session, .automation: return Color(red: 0.40, green: 0.66, blue: 1.00)
            }
        }
    }

    var id: String
    var kind: Kind = .session
    var title: String
    var detail: String?          // 当前正在做的子任务 / 结果摘要
    var cwd: String?
    var state: TaskState
    var updatedAt: Date
    var needsConfirm: Bool = false   // 等你确认 / 有未读结果

    /// 展示用状态：只要「等你关注」，列表里就一律显示成橙黄的「待确认」。
    /// 否则会出现标题栏写着「N 待确认」、列表里却看不出是哪一个的情况
    /// （典型场景：任务已完成但结果未读 → needsConfirm 为真、state 仍是 done）。
    var displayState: TaskState { needsConfirm ? .needConfirm : state }

    /// 工作目录的可读标签
    /// - WorkBuddy 的时间戳工作区（2026-10-02-16-56-30）→ 转成「10-02 16:56」这种可读时间
    /// - 普通工程目录 → 取最后两级，如 smarty/workbuddy_tasks
    var cwdName: String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        var parts = (cwd as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let i = parts.firstIndex(of: NSUserName()) { parts.removeFirst(i + 1) }
        guard let last = parts.last else { return nil }

        if Self.isTimestamped(last), last.count >= 16 {
            let s = Array(last)                       // YYYY-MM-DD-HH-MM-SS
            let date = String(s[5..<10])              // MM-DD
            let time = String(s[11..<16])             // HH:MM
            return "\(date) \(time) 工作区"
        }
        return parts.suffix(2).joined(separator: "/")
    }

    private static func isTimestamped(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    var relativeTime: String {
        let s = Date().timeIntervalSince(updatedAt)
        if s < 10 { return "刚刚" }
        if s < 60 { return "\(Int(s)) 秒前" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
    }
}

/// 刘海提醒级别
enum AlertLevel: Int, Comparable {
    case idle = 0     // 无动静
    case running = 1  // 有任务在跑
    case done = 2     // 有新完成
    case confirm = 3  // 有待确认（最高优先级）

    static func < (l: AlertLevel, r: AlertLevel) -> Bool { l.rawValue < r.rawValue }

    var color: Color {
        switch self {
        case .idle:    return Color(white: 0.35)
        case .running: return Color(red: 0.16, green: 0.56, blue: 1.00)
        case .done:    return Color(red: 0.20, green: 0.80, blue: 0.36)
        case .confirm: return Color(red: 1.00, green: 0.62, blue: 0.04)
        }
    }
}
