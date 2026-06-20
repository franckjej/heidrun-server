import Logging

/// Assembles the root `LogHandler` the executable bootstraps: stderr always
/// (so `docker logs` keeps working byte-for-byte), plus the NDJSON file sink
/// when the op-log is enabled. The shared `writer` is created once and reused
/// for every label.
public enum OperationalLogging {
    public static func handler(
        label: String, level: Logger.Level, writer: NDJSONLogWriter?
    ) -> LogHandler {
        var stream = StreamLogHandler.standardError(label: label)
        stream.logLevel = level
        guard let writer else { return stream }
        let file = NDJSONFileLogHandler(label: label, writer: writer, logLevel: level)
        return MultiplexLogHandler([stream, file])
    }
}
