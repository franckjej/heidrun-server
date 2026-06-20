import Foundation
import Logging

/// One row in the unified `heidrun-admin log` stream — either a structured
/// audit event or an operational log line, normalised for sorting, filtering
/// and rendering.
public struct UnifiedLogRecord: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable { case audit, op }

    public let timestampMillis: Int64
    public let source: Source
    /// Audit kind rawValue, or operational level (`info`, `warning`, …).
    public let tag: String
    public let text: String
    /// Account login when known — used by `--user` filtering.
    public let account: String?
    /// Operational-log metadata (e.g. `remoteHost`, `tls`, `socket`). Empty
    /// for audit rows, whose context is already folded into `text`.
    public let metadata: [String: String]

    public init(
        timestampMillis: Int64, source: Source, tag: String,
        text: String, account: String?, metadata: [String: String] = [:]
    ) {
        self.timestampMillis = timestampMillis
        self.source = source
        self.tag = tag
        self.text = text
        self.account = account
        self.metadata = metadata
    }

    public init(audit identified: IdentifiedAuditEvent) {
        let event = identified.event
        let who = event.account ?? event.nickname ?? "—"
        let target = event.target.map { " → \($0)" } ?? ""
        let detail = event.detail.map { " (\($0))" } ?? ""
        self.init(
            timestampMillis: Int64(event.timestamp.timeIntervalSince1970 * 1000),
            source: .audit,
            tag: event.kind.rawValue,
            text: "\(who)\(target)\(detail)",
            account: event.account
        )
    }

    public init(op record: NDJSONLogRecord) {
        self.init(
            timestampMillis: record.timestampMillis,
            source: .op,
            tag: record.level,
            text: record.message,
            account: nil,
            metadata: record.metadata
        )
    }
}

/// Merges audit + operational records into one timestamp-ordered stream.
/// New records are buffered; `emit(nowMillis:)` flushes everything older than
/// the watermark window in `timestampMillis` order, so near-simultaneous rows
/// from the two sources don't print out of order. The unsettled tail stays
/// buffered for the next tick.
public struct UnifiedLogMerger {
    public let windowMillis: Int64
    private var pending: [UnifiedLogRecord] = []

    public init(windowMillis: Int64) { self.windowMillis = max(0, windowMillis) }

    public mutating func add(_ records: [UnifiedLogRecord]) {
        pending.append(contentsOf: records)
    }

    public mutating func emit(nowMillis: Int64) -> [UnifiedLogRecord] {
        let cutoff = nowMillis - windowMillis
        pending.sort { $0.timestampMillis < $1.timestampMillis }
        let settled = Array(pending.prefix { $0.timestampMillis <= cutoff })
        pending.removeFirst(settled.count)
        return settled
    }

    public mutating func drain() -> [UnifiedLogRecord] {
        pending.sort { $0.timestampMillis < $1.timestampMillis }
        defer { pending.removeAll() }
        return pending
    }
}

/// Post-read filtering for the `log` command's flags.
public enum UnifiedLogFilter {
    public enum SourceFilter: String, Sendable {
        case audit, op, both
        public init(parsing raw: String) {
            self = SourceFilter(rawValue: raw.lowercased()) ?? .both
        }
    }

    public static func matches(
        _ record: UnifiedLogRecord,
        sourceFilter: SourceFilter,
        user: String?,
        minLevel: Logger.Level?,
        auditKinds: [String]?
    ) -> Bool {
        switch sourceFilter {
        case .audit where record.source != .audit: return false
        case .op where record.source != .op: return false
        default: break
        }
        if let user, record.account != user { return false }
        if let minLevel, record.source == .op {
            guard let level = Logger.Level(rawValue: record.tag), level >= minLevel else { return false }
        }
        if let auditKinds, record.source == .audit, !auditKinds.contains(record.tag) {
            return false
        }
        return true
    }
}

/// Renders unified records for the terminal or `--json`.
public enum UnifiedLogFormatter {
    /// `HH:mm:ss  [a|o] TAG            text`
    public static func line(_ record: UnifiedLogRecord) -> String {
        let seconds = TimeInterval(record.timestampMillis) / 1000
        let time = timeFormatter.string(from: Date(timeIntervalSince1970: seconds))
        let marker = record.source == .audit ? "a" : "o"
        let tag = record.tag.padding(toLength: 14, withPad: " ", startingAt: 0)
        let meta = record.metadata.isEmpty ? "" : "  " + record.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return "\(time)  [\(marker)] \(tag) \(record.text)\(meta)"
    }

    public static func lines(_ records: [UnifiedLogRecord]) -> String {
        records.map(line).joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}

/// JSON projection of one unified record for `--json`.
public struct UnifiedLogLineDTO: Encodable {
    public let timestamp: String
    public let source: String
    public let tag: String
    public let text: String
    public let account: String?
    public let metadata: [String: String]?

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    public init(_ record: UnifiedLogRecord) {
        self.timestamp = Self.isoFormatter.string(
            from: Date(timeIntervalSince1970: TimeInterval(record.timestampMillis) / 1000))
        self.source = record.source.rawValue
        self.tag = record.tag
        self.text = record.text
        self.account = record.account
        self.metadata = record.metadata.isEmpty ? nil : record.metadata
    }
}

/// Backfill: merge the most-recent audit + op records, sorted by time, capped
/// to the last `limit`.
public enum UnifiedLog {
    public static func backfill(
        audit: [IdentifiedAuditEvent], op: [NDJSONLogRecord], limit: Int
    ) -> [UnifiedLogRecord] {
        let merged = audit.map(UnifiedLogRecord.init(audit:)) + op.map(UnifiedLogRecord.init(op:))
        let sorted = merged.sorted { $0.timestampMillis < $1.timestampMillis }
        return Array(sorted.suffix(max(0, limit)))
    }
}
