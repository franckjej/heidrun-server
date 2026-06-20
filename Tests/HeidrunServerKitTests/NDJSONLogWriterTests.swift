import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("NDJSONLogWriter")
struct NDJSONLogWriterTests {
    private func tempPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("oplog-\(name)-\(UUID().uuidString).ndjson").path
    }

    private func record(_ index: Int) -> NDJSONLogRecord {
        NDJSONLogRecord(timestampMillis: Int64(index), level: "info", label: "t",
                        message: "line \(index)", metadata: [:], source: "t")
    }

    @Test("appends one JSON line per record")
    func appends() throws {
        let path = tempPath("append")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 1_000_000, keep: 3)
        writer.append(record(1))
        writer.append(record(2))
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { (try? JSONDecoder().decode(NDJSONLogRecord.self, from: Data($0.utf8))) != nil })
    }

    @Test("rotates at maxBytes and keeps at most `keep` archives")
    func rotates() throws {
        let path = tempPath("rotate")
        defer {
            for suffix in ["", ".1", ".2", ".3", ".4"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let writer = NDJSONLogWriter(path: path, maxBytes: 60, keep: 2)
        for index in 0..<20 { writer.append(record(index)) }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: path + ".1"))
        #expect(FileManager.default.fileExists(atPath: path + ".2"))
        #expect(!FileManager.default.fileExists(atPath: path + ".3"))
    }

    @Test("concurrent appends never corrupt or interleave lines")
    func concurrent() throws {
        let path = tempPath("concurrent")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 10_000_000, keep: 3)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            writer.append(record(index))
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 200)
        #expect(lines.allSatisfy { (try? JSONDecoder().decode(NDJSONLogRecord.self, from: Data($0.utf8))) != nil })
    }

    @Test("unwritable path fails soft (no crash, no file)")
    func failSoft() {
        let writer = NDJSONLogWriter(
            path: "/nonexistent-dir-\(UUID().uuidString)/op.ndjson",
            maxBytes: 1000, keep: 2)
        writer.append(record(1))   // must not crash
    }
}
