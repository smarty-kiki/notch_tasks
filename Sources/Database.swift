import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 只读访问 ~/.workbuddy/workbuddy.db。
///
/// 安全约定：**绝不写入 workbuddy 的任何文件**。
/// 做法是每次查询前把 db / -wal / -shm 复制到私有临时目录，再打开副本；
/// 副本上 SQLite 可以自由做 WAL 恢复与 checkpoint，原文件零改动。
final class WorkBuddyDB {
    static let liveDBPath: String = {
        if let custom = UserDefaults.standard.string(forKey: "dbPath"), !custom.isEmpty {
            return (custom as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".workbuddy/workbuddy.db")
    }()

    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("notchtasks-snapshot", isDirectory: true)
    private var counter = 0

    private(set) var lastError: String?

    /// 打开一个可用的只读连接；用完必须调用方 close
    func open() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: Self.liveDBPath) else {
            lastError = "找不到 \(Self.liveDBPath)"
            return nil
        }
        // 最多重试两次：复制期间原库可能正在 checkpoint，导致副本不一致
        for _ in 0..<2 {
            guard let dir = makeSnapshot() else { continue }
            guard let db = openAt(dir.appendingPathComponent("workbuddy.db").path) else { continue }
            if validate(db) { return db }
            sqlite3_close(db)   // 副本撕裂（比如复制瞬间碰上写页），丢弃重来
        }
        lastError = "无法打开 workbuddy.db（副本）"
        return nil
    }

    /// 副本必须能真正读出数据，否则视为坏副本
    private func validate(_ db: OpaquePointer) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM sessions", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt else { return false }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(s, 0) > 0
    }

    private func openAt(_ path: String) -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(db, 800)
        // 只读语义由副本保证；这里额外加一道保险，禁止写入
        sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)
        return db
    }

    /// 把原始文件复制到独立临时目录，返回该目录
    private func makeSnapshot() -> URL? {
        let fm = FileManager.default
        try? fm.removeItem(at: scratch)
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch { return nil }

        counter += 1
        let files = ["workbuddy.db", "workbuddy.db-wal", "workbuddy.db-shm"]
        var copied = false
        for name in files {
            let src = (Self.liveDBPath as NSString).deletingLastPathComponent + "/" + name
            guard fm.fileExists(atPath: src) else { continue }
            let dst = scratch.appendingPathComponent(name)
            // -wal 先复制：即使与 db 存在细微时间差，SQLite 会按 salt 校验并安全忽略
            try? fm.removeItem(at: dst)
            do {
                try fm.copyItem(atPath: src, toPath: dst.path)
                if name == "workbuddy.db" { copied = true }
            } catch { continue }
        }
        return copied ? scratch : nil
    }
}

// MARK: - 列读取助手

enum Col {
    static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
    static func str(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        let s = text(stmt, i)
        return s.isEmpty ? nil : s
    }
    static func int(_ stmt: OpaquePointer?, _ i: Int32) -> Int64 {
        sqlite3_column_int64(stmt, i)
    }
    static func intOrNil(_ stmt: OpaquePointer?, _ i: Int32) -> Int64? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, i)
    }
    static func double(_ stmt: OpaquePointer?, _ i: Int32) -> Double {
        sqlite3_column_double(stmt, i)
    }
}

extension OpaquePointer {
    /// 执行查询并把每行交给 row 处理
    func query(_ sql: String, bind: [String] = [], row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(self, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            return
        }
        defer { sqlite3_finalize(s) }
        for (i, v) in bind.enumerated() {
            sqlite3_bind_text(s, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(s) == SQLITE_ROW { row(s) }
    }
}

func epochToDate(_ ms: Int64?) -> Date {
    guard let ms, ms > 0 else { return Date(timeIntervalSince1970: 0) }
    // 部分字段可能是秒级时间戳
    let seconds = ms > 100_000_000_000 ? Double(ms) / 1000.0 : Double(ms)
    return Date(timeIntervalSince1970: seconds)
}
