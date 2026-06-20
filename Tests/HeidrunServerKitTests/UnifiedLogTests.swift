import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("NDJSONLogRecord")
struct NDJSONLogRecordTests {
    @Test("round-trips through JSON with stable compact keys")
    func roundTrip() throws {
        let record = NDJSONLogRecord(
            timestampMillis: 1_750_000_000_123, level: "info",
            label: "org.tastybytes.heidrun.server", message: "accepted connection",
            metadata: ["socket": "42"], source: "HeidrunServerKit"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"ts\":1750000000123"))
        #expect(text.contains("\"level\":\"info\""))
        #expect(text.contains("\"meta\":{\"socket\":\"42\"}"))
        #expect(text.contains("\"msg\":\"accepted connection\""))
        #expect(text.contains("\"src\":\"HeidrunServerKit\""))
        let decoded = try JSONDecoder().decode(NDJSONLogRecord.self, from: data)
        #expect(decoded == record)
    }
}
