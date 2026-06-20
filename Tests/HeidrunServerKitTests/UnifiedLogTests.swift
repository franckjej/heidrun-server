import Testing
import Foundation
import Logging
@testable import HeidrunServerKit

@Suite("UnifiedLogRecord")
struct UnifiedLogRecordTests {
    @Test("maps an audit event to a unified record")
    func fromAudit() {
        let event = AuditEvent(
            timestamp: Date(timeIntervalSince1970: 1700), kind: .upload,
            account: "alice", nickname: "ali", socket: 7, ip: nil,
            target: "f.txt", bytes: 10, result: nil, detail: "folder")
        let record = UnifiedLogRecord(audit: IdentifiedAuditEvent(id: 3, event: event))
        #expect(record.source == .audit)
        #expect(record.tag == "upload")
        #expect(record.account == "alice")
        #expect(record.timestampMillis == 1_700_000)
        #expect(record.text.contains("alice"))
        #expect(record.text.contains("f.txt"))
    }

    @Test("maps an op-log record to a unified record")
    func fromOp() {
        let operationalRecord = NDJSONLogRecord(timestampMillis: 1_700_500, level: "warning",
                                 label: "t", message: "tracker registration failed", metadata: [:], source: "t")
        let record = UnifiedLogRecord(op: operationalRecord)
        #expect(record.source == .op)
        #expect(record.tag == "warning")
        #expect(record.account == nil)
        #expect(record.text == "tracker registration failed")
    }
}

@Suite("UnifiedLogMerger")
struct UnifiedLogMergerTests {
    private func record(_ stamp: Int64, _ source: UnifiedLogRecord.Source) -> UnifiedLogRecord {
        UnifiedLogRecord(timestampMillis: stamp, source: source, tag: "x", text: "t\(stamp)", account: nil)
    }

    @Test("emits only records older than the watermark, in timestamp order")
    func watermark() {
        var merger = UnifiedLogMerger(windowMillis: 100)
        merger.add([record(300, .op), record(100, .audit), record(200, .op)])
        let firstFlush = merger.emit(nowMillis: 350)   // cutoff = 250
        #expect(firstFlush.map(\.timestampMillis) == [100, 200])
        let secondFlush = merger.emit(nowMillis: 500)  // cutoff = 400
        #expect(secondFlush.map(\.timestampMillis) == [300])
    }

    @Test("drain flushes everything regardless of window")
    func drain() {
        var merger = UnifiedLogMerger(windowMillis: 100)
        merger.add([record(900, .op), record(800, .audit)])
        #expect(merger.emit(nowMillis: 850).isEmpty)   // both still unsettled
        #expect(merger.drain().map(\.timestampMillis) == [800, 900])
    }
}

@Suite("UnifiedLogFilter")
struct UnifiedLogFilterTests {
    private func op(_ level: String) -> UnifiedLogRecord {
        UnifiedLogRecord(timestampMillis: 1, source: .op, tag: level, text: "x", account: nil)
    }
    private func audit(_ kind: String, account: String?) -> UnifiedLogRecord {
        UnifiedLogRecord(timestampMillis: 1, source: .audit, tag: kind, text: "x", account: account)
    }

    @Test("source filter selects audit / op / both")
    func sourceFilter() {
        #expect(!UnifiedLogFilter.matches(op("info"), sourceFilter: .audit, user: nil, minLevel: nil, auditKinds: nil))
        #expect(UnifiedLogFilter.matches(op("info"), sourceFilter: .op, user: nil, minLevel: nil, auditKinds: nil))
        #expect(UnifiedLogFilter.matches(op("info"), sourceFilter: .both, user: nil, minLevel: nil, auditKinds: nil))
    }

    @Test("min level drops op records below it; audit rows are unaffected")
    func levelFilter() {
        #expect(!UnifiedLogFilter.matches(op("info"), sourceFilter: .both, user: nil, minLevel: .warning, auditKinds: nil))
        #expect(UnifiedLogFilter.matches(op("error"), sourceFilter: .both, user: nil, minLevel: .warning, auditKinds: nil))
        #expect(UnifiedLogFilter.matches(audit("join", account: nil), sourceFilter: .both, user: nil, minLevel: .warning, auditKinds: nil))
    }

    @Test("user filter matches the account; audit kind filter matches the tag")
    func userAndKind() {
        #expect(UnifiedLogFilter.matches(audit("login_ok", account: "bob"), sourceFilter: .both, user: "bob", minLevel: nil, auditKinds: nil))
        #expect(!UnifiedLogFilter.matches(audit("login_ok", account: "ann"), sourceFilter: .both, user: "bob", minLevel: nil, auditKinds: nil))
        #expect(UnifiedLogFilter.matches(audit("join", account: nil), sourceFilter: .both, user: nil, minLevel: nil, auditKinds: ["join", "leave"]))
        #expect(!UnifiedLogFilter.matches(audit("kick", account: nil), sourceFilter: .both, user: nil, minLevel: nil, auditKinds: ["join", "leave"]))
    }
}

@Suite("UnifiedLogFormatter")
struct UnifiedLogFormatterTests {
    @Test("line carries the source marker, tag and text")
    func line() {
        let record = UnifiedLogRecord(timestampMillis: 1_700_000, source: .audit,
                                      tag: "join", text: "alice", account: "alice")
        let rendered = UnifiedLogFormatter.line(record)
        #expect(rendered.contains("[a]"))
        #expect(rendered.contains("join"))
        #expect(rendered.contains("alice"))
    }

    @Test("backfill merges and sorts both sources, keeping the last N")
    func backfill() {
        let event = AuditEvent(timestamp: Date(timeIntervalSince1970: 2), kind: .join,
                               account: nil, nickname: "xyz", socket: nil, ip: nil,
                               target: nil, bytes: nil, result: nil, detail: nil)
        let auditRows = [IdentifiedAuditEvent(id: 1, event: event)]
        let opRows = [NDJSONLogRecord(timestampMillis: 1_000, level: "info", label: "t", message: "a", metadata: [:], source: "t"),
                      NDJSONLogRecord(timestampMillis: 3_000, level: "info", label: "t", message: "b", metadata: [:], source: "t")]
        let merged = UnifiedLog.backfill(audit: auditRows, op: opRows, limit: 10)
        #expect(merged.map(\.timestampMillis) == [1_000, 2_000, 3_000])
        let capped = UnifiedLog.backfill(audit: auditRows, op: opRows, limit: 2)
        #expect(capped.map(\.timestampMillis) == [2_000, 3_000])
    }
}

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
