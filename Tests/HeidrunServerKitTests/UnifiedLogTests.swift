import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("NDJSONLogRecord")
struct NDJSONLogRecordTests {
    @Test("round-trips through JSON with stable keys")
    func roundTrip() throws {
        let record = NDJSONLogRecord(
            ts: 1_750_000_000_123, level: "info",
            label: "org.tastybytes.heidrun.server", msg: "accepted connection",
            meta: ["socket": "42"], src: "HeidrunServerKit"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"ts\":1750000000123"))
        #expect(text.contains("\"level\":\"info\""))
        #expect(text.contains("\"meta\":{\"socket\":\"42\"}"))
        let decoded = try JSONDecoder().decode(NDJSONLogRecord.self, from: data)
        #expect(decoded == record)
    }
}
