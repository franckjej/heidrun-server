import Foundation

/// Renders the unified log stream as an aligned, fixed-width table for
/// `heidrun-admin log --table`. Pure — no IO. Each fixed column pulls from the
/// record's metadata (blank when absent); the trailing ACTION column resolves
/// a generic `dispatch` op row's `transID` to a transaction name via
/// `HotlineTransactionName`.
public enum UnifiedLogTableFormatter {
    private struct Column: Sendable {
        let title: String
        let width: Int
        let value: @Sendable (UnifiedLogRecord) -> String
    }

    /// Columns after the leading timestamp, in order. ACTION is appended
    /// separately (variable width, never padded or truncated).
    private static let fixedColumns: [Column] = [
        Column(title: "S", width: 1) { $0.source == .audit ? "a" : "o" },
        Column(title: "LVL", width: 7) { $0.source == .op ? $0.tag : "—" },
        Column(title: "HOST", width: 21) { $0.metadata["remoteHost"] ?? "" },
        Column(title: "NICK", width: 10) { $0.metadata["nickname"] ?? $0.account ?? "" },
        Column(title: "ACCOUNT", width: 12) { $0.metadata["login"] ?? $0.account ?? "" },
        Column(title: "ADMIN", width: 5) { $0.metadata["isAdmin"] == "true" ? "yes" : "" },
        Column(title: "TLS", width: 5) { $0.metadata["tls"] ?? "" },
        Column(title: "TRANS", width: 5) { $0.metadata["transID"] ?? "" },
        Column(title: "SOCK", width: 5) { $0.metadata["socketID"] ?? "" },
        Column(title: "TASK", width: 6) { $0.metadata["taskNumber"] ?? "" },
        Column(title: "FLDS", width: 4) { $0.metadata["fieldCount"] ?? "" }
    ]

    /// The leading timestamp column — `TIME` (`HH:mm:ss`), or `TIMESTAMP`
    /// (`yyyy-MM-dd HH:mm:ss`) when `withDate` is set.
    private static func timeColumn(withDate: Bool) -> Column {
        if withDate {
            return Column(title: "TIMESTAMP", width: 19) {
                LogTimestamp.string($0.timestampMillis, withDate: true)
            }
        }
        return Column(title: "TIME", width: 8) {
            LogTimestamp.string($0.timestampMillis, withDate: false)
        }
    }

    public static func header(withDate: Bool = false) -> String {
        let cols = [timeColumn(withDate: withDate)] + fixedColumns
        let fixed = cols.map { cell($0.title, $0.width) }.joined(separator: " ")
        return "\(fixed) ACTION"
    }

    public static func row(_ record: UnifiedLogRecord, withDate: Bool = false) -> String {
        let cols = [timeColumn(withDate: withDate)] + fixedColumns
        let fixed = cols.map { cell($0.value(record), $0.width) }.joined(separator: " ")
        return "\(fixed) \(action(for: record))"
    }

    public static func rows(_ records: [UnifiedLogRecord], withDate: Bool = false) -> String {
        records.map { row($0, withDate: withDate) }.joined(separator: "\n")
    }

    /// A generic `dispatch` op row → resolved transaction name (`txn <id>`
    /// when unknown); any other row → its `text`.
    private static func action(for record: UnifiedLogRecord) -> String {
        guard record.source == .op, record.text == "dispatch" else { return record.text }
        guard let raw = record.metadata["transID"], let transID = UInt16(raw) else {
            return record.text
        }
        return HotlineTransactionName.name(for: transID) ?? "txn \(transID)"
    }

    /// Pad to `width`, or truncate with a trailing `…` when longer.
    private static func cell(_ value: String, _ width: Int) -> String {
        if value.count == width { return value }
        if value.count < width {
            return value + String(repeating: " ", count: width - value.count)
        }
        if width <= 1 { return String(value.prefix(width)) }
        return String(value.prefix(width - 1)) + "…"
    }
}
