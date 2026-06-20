import Foundation

/// Tails the NDJSON op-log file: each `poll()` returns the records appended
/// since the previous call. Detects rotation (the active file shrinking or
/// being replaced) and re-reads from the top. Partial trailing lines (no
/// terminating newline yet) are buffered until the rest arrives. Pure file
/// IO — the caller drives the polling cadence.
public final class OpLogTailReader {
    public let path: String
    private var offset: UInt64
    private var carry: Data   // unterminated trailing bytes from the last read

    /// `fromEnd: true` starts at the current end (follow-only, no history);
    /// `false` starts at 0 (read everything already in the file).
    public init(path: String, fromEnd: Bool) {
        self.path = path
        self.carry = Data()
        if fromEnd, let size = OpLogTailReader.fileSize(path) {
            self.offset = size
        } else {
            self.offset = 0
        }
    }

    public func poll() -> [NDJSONLogRecord] {
        guard let size = OpLogTailReader.fileSize(path) else { return [] }
        if size < offset {           // truncated or rotated → restart
            offset = 0
            carry = Data()
        }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return [] }
        offset += UInt64(chunk.count)

        var buffer = carry + chunk
        carry = Data()
        var records: [NDJSONLogRecord] = []
        let newline: UInt8 = 0x0A
        while let index = buffer.firstIndex(of: newline) {
            // Copy the line into a fresh Data so decoding never indexes a
            // non-zero-based slice (Foundation's subdata absolute-index trap).
            let lineData = Data(buffer[buffer.startIndex..<index])
            buffer = buffer[buffer.index(after: index)...]
            if let record = try? JSONDecoder().decode(NDJSONLogRecord.self, from: lineData) {
                records.append(record)
            }   // malformed → skip
        }
        carry = Data(buffer)         // keep the unterminated remainder
        return records
    }

    private static func fileSize(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else { return nil }
        return size
    }
}
