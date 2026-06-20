import Foundation

/// On-disk shape of one operational log line in the NDJSON op-log file.
/// Written by `NDJSONFileLogHandler`, read back by `OpLogTailReader`, so the
/// encode/decode contract lives in one place. The JSON keys stay compact
/// (`ts`/`msg`/`src`/…) via `CodingKeys`; the Swift properties are descriptive.
public struct NDJSONLogRecord: Codable, Sendable, Equatable {
    /// Event time in epoch milliseconds (sub-second so it sorts cleanly
    /// against audit rows, whose timestamps are whole seconds).
    public var timestampMillis: Int64
    public var level: String
    public var label: String
    public var message: String
    public var metadata: [String: String]
    public var source: String

    enum CodingKeys: String, CodingKey {
        case timestampMillis = "ts"
        case level
        case label
        case message = "msg"
        case metadata = "meta"
        case source = "src"
    }

    public init(
        timestampMillis: Int64, level: String, label: String, message: String,
        metadata: [String: String], source: String
    ) {
        self.timestampMillis = timestampMillis
        self.level = level
        self.label = label
        self.message = message
        self.metadata = metadata
        self.source = source
    }
}
