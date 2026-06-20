import Testing
import Foundation
import Logging
@testable import HeidrunServerKit

@Suite("NDJSONFileLogHandler")
struct NDJSONFileLogHandlerTests {
    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fh-\(UUID().uuidString).ndjson").path
    }

    @Test("a log call writes a decodable record with level, message, metadata")
    func writesRecord() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 1_000_000, keep: 2)
        var logger = Logger(label: "org.test.kit") { label in
            NDJSONFileLogHandler(label: label, writer: writer, logLevel: .info)
        }
        logger[metadataKey: "socket"] = "42"
        logger.info("accepted connection")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first)
        let record = try JSONDecoder().decode(NDJSONLogRecord.self, from: Data(line.utf8))
        #expect(record.level == "info")
        #expect(record.message == "accepted connection")
        #expect(record.label == "org.test.kit")
        #expect(record.metadata["socket"] == "42")
    }

    @Test("metadata-provider values are included; call metadata wins ties")
    func metadataProvider() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 1_000_000, keep: 2)
        let provider = Logger.MetadataProvider { ["env": "prod", "shared": "fromProvider"] }
        let logger = Logger(label: "org.test.kit") { label in
            var handler = NDJSONFileLogHandler(label: label, writer: writer, logLevel: .info)
            handler.metadataProvider = provider
            return handler
        }
        logger.info("hi", metadata: ["shared": "fromCall"])
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first)
        let record = try JSONDecoder().decode(NDJSONLogRecord.self, from: Data(line.utf8))
        #expect(record.metadata["env"] == "prod")
        #expect(record.metadata["shared"] == "fromCall")
    }

    @Test("level below the handler threshold is dropped")
    func levelFilter() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 1_000_000, keep: 2)
        let logger = Logger(label: "org.test.kit") { label in
            NDJSONFileLogHandler(label: label, writer: writer, logLevel: .warning)
        }
        logger.info("noise")        // below threshold
        logger.warning("kept")
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let messages = text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(NDJSONLogRecord.self, from: Data($0.utf8))
        }.map(\.message)
        #expect(messages == ["kept"])
    }
}

@Suite("OperationalLogging")
struct OperationalLoggingTests {
    @Test("with a writer, records reach the file (stderr unaffected)")
    func multiplexed() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opmux-\(UUID().uuidString).ndjson").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = NDJSONLogWriter(path: path, maxBytes: 1_000_000, keep: 2)
        let logger = Logger(label: "org.test.kit") { label in
            OperationalLogging.handler(label: label, level: .info, writer: writer)
        }
        logger.info("hello")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("\"msg\":\"hello\""))
    }

    @Test("nil writer produces a stderr-only handler that does not crash")
    func streamOnly() {
        let logger = Logger(label: "org.test.kit") { label in
            OperationalLogging.handler(label: label, level: .info, writer: nil)
        }
        logger.info("no file sink")   // must not crash
    }
}
