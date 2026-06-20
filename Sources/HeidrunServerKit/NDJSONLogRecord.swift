import Foundation

/// On-disk shape of one operational log line in the NDJSON op-log file.
/// Written by `NDJSONFileLogHandler`, read back by `OpLogTailReader`, so the
/// encode/decode contract lives in one place.
public struct NDJSONLogRecord: Codable, Sendable, Equatable {
    /// Event time in epoch milliseconds (sub-second so it sorts cleanly
    /// against audit rows, whose `ts` is whole seconds).
    public var ts: Int64
    public var level: String
    public var label: String
    public var msg: String
    public var meta: [String: String]
    public var src: String

    public init(
        ts: Int64, level: String, label: String, msg: String,
        meta: [String: String], src: String
    ) {
        self.ts = ts
        self.level = level
        self.label = label
        self.msg = msg
        self.meta = meta
        self.src = src
    }
}
