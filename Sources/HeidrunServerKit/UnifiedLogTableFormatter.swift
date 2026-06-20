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

    /// Fixed columns, in order. ACTION is appended separately (variable width,
    /// never padded or truncated).
    private static let columns: [Column] = [
        Column(title: "TIME", width: 8) { timeString($0.timestampMillis) },
        Column(title: "S", width: 1) { $0.source == .audit ? "a" : "o" },
        Column(title: "LVL", width: 7) { $0.source == .op ? $0.tag : "—" },
        Column(title: "HOST", width: 21) { $0.metadata["remoteHost"] ?? "" },
        Column(title: "NICK", width: 10) { $0.metadata["nickname"] ?? $0.account ?? "" },
        Column(title: "TLS", width: 5) { $0.metadata["tls"] ?? "" },
        Column(title: "TRANS", width: 5) { $0.metadata["transID"] ?? "" },
        Column(title: "SOCK", width: 5) { $0.metadata["socketID"] ?? "" },
        Column(title: "TASK", width: 6) { $0.metadata["taskNumber"] ?? "" },
        Column(title: "FLDS", width: 4) { $0.metadata["fieldCount"] ?? "" }
    ]

    public static func header() -> String {
        let fixed = columns.map { cell($0.title, $0.width) }.joined(separator: " ")
        return "\(fixed) ACTION"
    }

    public static func row(_ record: UnifiedLogRecord) -> String {
        let fixed = columns.map { cell($0.value(record), $0.width) }.joined(separator: " ")
        return "\(fixed) \(action(for: record))"
    }

    public static func rows(_ records: [UnifiedLogRecord]) -> String {
        records.map(row).joined(separator: "\n")
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

    private static func timeString(_ millis: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()
}
