import Foundation
import GRDB

/// One recorded user join/leave event. `timestamp` is the wall-clock
/// moment the session entered or left.
public struct UserEvent: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case entered
        case left
    }
    public let timestamp: Date
    public let kind: Kind
    public let nickname: String
    public let socket: UInt16

    public init(timestamp: Date, kind: Kind, nickname: String, socket: UInt16) {
        self.timestamp = timestamp
        self.kind = kind
        self.nickname = nickname
        self.socket = socket
    }
}

/// GRDB-backed persistence for user join/leave history, surfaced by the
/// `/usershistory` admin chat command. Rides the same SQLite file as the
/// accounts DB (separate `DatabaseQueue`, namespaced `v1_user_events`
/// migration) exactly like `FileMetadataStore`; in-memory when no
/// `db_path` is configured. SQLite file-level locking serialises the two
/// queues' writes — no WAL needed at this write volume.
///
/// Retention is prune-on-write: every `record` deletes rows older than
/// `retentionSeconds` (24h) so the table never outgrows the max query
/// window. All DB errors collapse to a no-op / empty result — history is
/// best-effort and must never break a login or disconnect path.
public actor UserEventStore {
    /// 24 hours — the maximum `/usershistory` window.
    static let retentionSeconds: TimeInterval = 24 * 60 * 60

    private let dbQueue: DatabaseQueue

    public init(path: String? = nil) throws {
        if let path {
            self.dbQueue = try DatabaseQueue(path: path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        try Self.runMigrations(on: dbQueue)
    }

    /// Append one event, then prune everything older than the 24h
    /// retention window.
    public func record(
        _ kind: UserEvent.Kind,
        nickname: String,
        socket: UInt16,
        at timestamp: Date = Date()
    ) {
        let epoch = Int64(timestamp.timeIntervalSince1970)
        let cutoff = Int64(Date().timeIntervalSince1970 - Self.retentionSeconds)
        try? dbQueue.write { database in
            try database.execute(
                sql: "INSERT INTO user_events (ts, kind, nickname, socket) VALUES (?, ?, ?, ?)",
                arguments: [epoch, kind.rawValue, nickname, Int64(socket)]
            )
            try database.execute(
                sql: "DELETE FROM user_events WHERE ts < ?",
                arguments: [cutoff]
            )
        }
    }

    /// Events within the last `hours`, oldest first.
    public func events(withinHours hours: Int) -> [UserEvent] {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(hours) * 3600)
        guard let rows = try? dbQueue.read({ database in
            try Row.fetchAll(
                database,
                sql: "SELECT ts, kind, nickname, socket FROM user_events WHERE ts >= ? ORDER BY ts ASC",
                arguments: [cutoff]
            )
        }) else {
            return []
        }
        return rows.compactMap { row in
            let tsRaw: Int64 = row["ts"] ?? 0
            let kindRaw: String = row["kind"] ?? ""
            guard let kind = UserEvent.Kind(rawValue: kindRaw) else { return nil }
            let socketRaw: Int64 = row["socket"] ?? 0
            return UserEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(tsRaw)),
                kind: kind,
                nickname: row["nickname"] ?? "",
                socket: UInt16(truncatingIfNeeded: socketRaw)
            )
        }
    }

    /// Diagnostic row count. Tests only.
    public func count() -> Int {
        (try? dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM user_events") ?? 0
        }) ?? 0
    }

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_user_events") { database in
            try database.execute(sql: """
                CREATE TABLE user_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    nickname TEXT NOT NULL,
                    socket INTEGER NOT NULL
                )
                """)
            try database.execute(sql: "CREATE INDEX user_events_ts ON user_events(ts)")
        }
        try migrator.migrate(queue)
    }
}
