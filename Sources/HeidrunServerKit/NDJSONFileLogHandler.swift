import Foundation
import Logging

/// swift-log `LogHandler` that appends every record to an NDJSON op-log file
/// through a shared `NDJSONLogWriter`. Pair it with `StreamLogHandler` inside
/// a `MultiplexLogHandler` so stderr / `docker logs` output is unaffected.
public struct NDJSONFileLogHandler: LogHandler {
    private let label: String
    private let writer: NDJSONLogWriter
    public var logLevel: Logger.Level
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    public init(label: String, writer: NDJSONLogWriter, logLevel: Logger.Level) {
        self.label = label
        self.writer = writer
        self.logLevel = logLevel
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var merged = metadataProvider?.get() ?? [:]
        if !metadata.isEmpty { merged.merge(metadata) { _, handlerValue in handlerValue } }
        if let explicit = event.metadata { merged.merge(explicit) { _, latest in latest } }
        let flattened = merged.mapValues { "\($0)" }
        let record = NDJSONLogRecord(
            timestampMillis: Int64(Date().timeIntervalSince1970 * 1000),
            level: event.level.rawValue,
            label: label,
            message: event.message.description,
            metadata: flattened,
            source: event.source
        )
        writer.append(record)
    }
}
