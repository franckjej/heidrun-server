import Foundation

/// Thread-safe, size-rotating writer for the NDJSON operational log. One
/// shared instance backs every copy of `NDJSONFileLogHandler` (swift-log
/// copies the handler struct per `Logger`), so all writes funnel through one
/// lock and one file handle. Fail-soft: any IO error drops the line rather
/// than throwing into a logging call.
public final class NDJSONLogWriter: @unchecked Sendable {
    private let path: String
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private var handle: FileHandle?
    private var currentSize: Int

    public init(path: String, maxBytes: Int, keep: Int) {
        self.path = path
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // stable, diffable, testable
        self.encoder = encoder

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }
        let openedHandle = FileHandle(forWritingAtPath: path)
        self.handle = openedHandle
        if let openedHandle, let end = try? openedHandle.seekToEnd() {
            self.currentSize = Int(end)
        } else {
            self.currentSize = 0
        }
    }

    /// Append one record as a single JSON line. Rotates first if the line
    /// would push the active file past `maxBytes`.
    public func append(_ record: NDJSONLogRecord) {
        guard var payload = try? encoder.encode(record) else { return }
        payload.append(0x0A)   // '\n'
        lock.lock()
        defer { lock.unlock() }
        if currentSize > 0, currentSize + payload.count > maxBytes {
            rotate()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: payload)
            currentSize += payload.count
        } catch {
            // fail-soft: drop the line
        }
    }

    /// Shift `<path>.(keep-1)` → `.keep` … `<path>` → `.1`, then reopen a
    /// fresh active file. Called under `lock`.
    private func rotate() {
        let fileManager = FileManager.default
        try? handle?.close()
        handle = nil
        try? fileManager.removeItem(atPath: "\(path).\(keep)")
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) {
                let from = "\(path).\(index)"
                let into = "\(path).\(index + 1)"
                if fileManager.fileExists(atPath: from) {
                    try? fileManager.moveItem(atPath: from, toPath: into)
                }
            }
        }
        try? fileManager.moveItem(atPath: path, toPath: "\(path).1")
        fileManager.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        currentSize = 0
    }
}
