import Foundation
import GRDB

/// One recorded audit event. The envelope is common to every event
/// `Kind`; type-specific columns (`target`, `bytes`, `result`, `detail`)
/// are nullable and populated per kind.
public struct AuditEvent: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case join, leave
        case upload, download
        case loginOK = "login_ok"
        case loginFail = "login_fail"
        case accountCreate = "account_create"
        case accountModify = "account_modify"
        case accountDelete = "account_delete"
        case kick, broadcast, topic
    }

    public let timestamp: Date
    public let kind: Kind
    public let account: String?
    public let nickname: String?
    public let socket: UInt16?
    public let ip: String?
    public let target: String?
    public let bytes: Int64?
    public let result: String?
    public let detail: String?

    public init(
        timestamp: Date, kind: Kind, account: String?, nickname: String?,
        socket: UInt16?, ip: String?, target: String?, bytes: Int64?,
        result: String?, detail: String?
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.account = account
        self.nickname = nickname
        self.socket = socket
        self.ip = ip
        self.target = target
        self.bytes = bytes
        self.result = result
        self.detail = detail
    }
}

/// An audit event paired with its SQLite row id, for cursor-based tailing.
public struct IdentifiedAuditEvent: Sendable, Equatable {
    public let id: Int64
    public let event: AuditEvent
    public init(id: Int64, event: AuditEvent) {
        self.id = id
        self.event = event
    }
}

/// GRDB-backed audit log in its own SQLite file (separate from the
/// accounts DB), in-memory when no path is configured. Records presence,
/// transfers, auth, and admin events into one `audit_events` table keyed
/// by `type`. Retention is prune-on-write at `retentionDays`. All DB
/// errors collapse to a no-op / empty result — the audit log is
/// best-effort and must never break a login, transfer, or disconnect path.
public actor AuditLog {
    private let dbQueue: DatabaseQueue
    private let retentionSeconds: TimeInterval

    public init(path: String? = nil, retentionDays: Int) throws {
        if let path {
            self.dbQueue = try DatabaseQueue(path: path)
        } else {
            self.dbQueue = try DatabaseQueue()
        }
        self.retentionSeconds = TimeInterval(max(1, retentionDays)) * 86_400
        try Self.runMigrations(on: dbQueue)
    }

    /// Append one event, then prune everything older than the retention
    /// window.
    public func record(_ event: AuditEvent) {
        let epoch = Int64(event.timestamp.timeIntervalSince1970)
        let cutoff = Int64(Date().timeIntervalSince1970 - retentionSeconds)
        try? dbQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO audit_events
                      (ts, type, account, nickname, socket, ip, target, bytes, result, detail)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    epoch, event.kind.rawValue, event.account, event.nickname,
                    event.socket.map { Int64($0) }, event.ip, event.target,
                    event.bytes, event.result, event.detail
                ]
            )
            try database.execute(
                sql: "DELETE FROM audit_events WHERE ts < ?", arguments: [cutoff]
            )
        }
    }

    /// Events within the last `hours`, oldest first, optionally filtered
    /// by `type` (any of the kinds) and `account`. Capped at `limit`
    /// most-recent matches (returned oldest-first after the cap).
    public func query(
        type kinds: [AuditEvent.Kind]?,
        account: String?,
        withinHours hours: Int,
        limit: Int
    ) -> [AuditEvent] {
        let cutoff = Int64(Date().timeIntervalSince1970 - TimeInterval(hours) * 3600)
        var sql = "SELECT * FROM audit_events WHERE ts >= ?"
        var arguments: [DatabaseValueConvertible?] = [cutoff]
        if let kinds, !kinds.isEmpty {
            let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
            sql += " AND type IN (\(placeholders))"
            arguments.append(contentsOf: kinds.map { $0.rawValue })
        }
        if let account {
            sql += " AND account = ?"
            arguments.append(account)
        }
        // Cap to the most-recent `limit`, then present oldest-first.
        sql += " ORDER BY ts DESC, id DESC LIMIT ?"
        arguments.append(Int64(max(1, limit)))
        guard let rows = try? dbQueue.read({ database in
            try Row.fetchAll(database, sql: sql, arguments: StatementArguments(arguments))
        }) else {
            return []
        }
        return rows.compactMap(Self.decode).reversed()
    }

    /// Diagnostic row count. Tests only.
    public func count() -> Int {
        (try? dbQueue.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM audit_events") ?? 0
        }) ?? 0
    }

    /// Events with row id greater than `cursor`, oldest-first, capped at
    /// `limit`. The cursor for a live tail: pass the last id you saw.
    public func eventsAfter(id cursor: Int64, limit: Int) -> [IdentifiedAuditEvent] {
        let sql = "SELECT * FROM audit_events WHERE id > ? ORDER BY id ASC LIMIT ?"
        guard let rows = try? dbQueue.read({ database in
            try Row.fetchAll(database, sql: sql, arguments: [cursor, Int64(max(1, limit))])
        }) else { return [] }
        return rows.compactMap(Self.decodeIdentified)
    }

    /// The most-recent `limit` events, oldest-first, with ids — the backfill
    /// shown before a live tail begins.
    public func recentIdentifiedEvents(limit: Int) -> [IdentifiedAuditEvent] {
        let sql = "SELECT * FROM audit_events ORDER BY id DESC LIMIT ?"
        guard let rows = try? dbQueue.read({ database in
            try Row.fetchAll(database, sql: sql, arguments: [Int64(max(1, limit))])
        }) else { return [] }
        return rows.compactMap(Self.decodeIdentified).reversed()
    }

    private static func decode(_ row: Row) -> AuditEvent? {
        let tsRaw: Int64 = row["ts"] ?? 0
        guard let kind = AuditEvent.Kind(rawValue: row["type"] ?? "") else { return nil }
        let socketRaw: Int64? = row["socket"]
        return AuditEvent(
            timestamp: Date(timeIntervalSince1970: TimeInterval(tsRaw)),
            kind: kind,
            account: row["account"],
            nickname: row["nickname"],
            socket: socketRaw.map { UInt16(truncatingIfNeeded: $0) },
            ip: row["ip"],
            target: row["target"],
            bytes: row["bytes"],
            result: row["result"],
            detail: row["detail"]
        )
    }

    private static func decodeIdentified(_ row: Row) -> IdentifiedAuditEvent? {
        guard let event = decode(row) else { return nil }
        let rowId: Int64 = row["id"] ?? 0
        return IdentifiedAuditEvent(id: rowId, event: event)
    }

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_audit_events") { database in
            try database.execute(sql: """
                CREATE TABLE audit_events (
                    id       INTEGER PRIMARY KEY AUTOINCREMENT,
                    ts       INTEGER NOT NULL,
                    type     TEXT    NOT NULL,
                    account  TEXT,
                    nickname TEXT,
                    socket   INTEGER,
                    ip       TEXT,
                    target   TEXT,
                    bytes    INTEGER,
                    result   TEXT,
                    detail   TEXT
                )
                """)
            try database.execute(sql: "CREATE INDEX idx_audit_ts ON audit_events(ts)")
            try database.execute(sql: "CREATE INDEX idx_audit_type_ts ON audit_events(type, ts)")
            try database.execute(sql: "CREATE INDEX idx_audit_account_ts ON audit_events(account, ts)")
        }
        try migrator.migrate(queue)
    }
}
