import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("OpLogTailReader")
struct OpLogTailReaderTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).ndjson").path
    }

    private func line(_ index: Int) -> String {
        let record = NDJSONLogRecord(timestampMillis: Int64(index), level: "info",
                                     label: "t", message: "line \(index)", metadata: [:], source: "t")
        let data = (try? JSONEncoder().encode(record)) ?? Data()
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    @Test("returns only records appended since the last poll")
    func incremental() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (line(1) + line(2)).write(toFile: path, atomically: true, encoding: .utf8)
        let reader = OpLogTailReader(path: path, fromEnd: false)
        #expect(reader.poll().map(\.message) == ["line 1", "line 2"])
        #expect(reader.poll().isEmpty)
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line(3).utf8))
        try handle.close()
        #expect(reader.poll().map(\.message) == ["line 3"])
    }

    @Test("buffers a partial trailing line until its newline arrives")
    func partialLine() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let whole = line(1)
        let splitIndex = whole.index(whole.startIndex, offsetBy: whole.count - 4)
        try String(whole[..<splitIndex]).write(toFile: path, atomically: true, encoding: .utf8)
        let reader = OpLogTailReader(path: path, fromEnd: false)
        #expect(reader.poll().isEmpty)              // no newline yet
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(whole[splitIndex...]).utf8))
        try handle.close()
        #expect(reader.poll().map(\.message) == ["line 1"])
    }

    @Test("rotation (file shrinks) re-reads from the top")
    func rotation() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (line(1) + line(2) + line(3)).write(toFile: path, atomically: true, encoding: .utf8)
        let reader = OpLogTailReader(path: path, fromEnd: false)
        _ = reader.poll()
        try line(9).write(toFile: path, atomically: true, encoding: .utf8)   // smaller file
        #expect(reader.poll().map(\.message) == ["line 9"])
    }

    @Test("malformed lines are skipped")
    func malformed() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (line(1) + "not json\n" + line(2)).write(toFile: path, atomically: true, encoding: .utf8)
        let reader = OpLogTailReader(path: path, fromEnd: false)
        #expect(reader.poll().map(\.message) == ["line 1", "line 2"])
    }

    @Test("fromEnd skips existing history")
    func fromEnd() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (line(1) + line(2)).write(toFile: path, atomically: true, encoding: .utf8)
        let reader = OpLogTailReader(path: path, fromEnd: true)
        #expect(reader.poll().isEmpty)
    }
}
