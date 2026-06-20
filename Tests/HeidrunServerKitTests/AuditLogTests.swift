import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("AuditLog")
struct AuditLogTests {
    private func event(
        _ kind: AuditEvent.Kind,
        at offset: TimeInterval,
        account: String? = nil,
        nickname: String? = nil,
        target: String? = nil,
        bytes: Int64? = nil,
        result: String? = nil,
        ip: String? = nil
    ) -> AuditEvent {
        AuditEvent(
            timestamp: Date().addingTimeInterval(offset),
            kind: kind, account: account, nickname: nickname,
            socket: 7, ip: ip, target: target, bytes: bytes,
            result: result, detail: nil
        )
    }

    @Test("records and returns events oldest-first within the window")
    func roundTripOrdering() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -120, nickname: "silve"))
        await log.record(event(.leave, at: -60, nickname: "silve"))
        let rows = await log.query(type: nil, account: nil, withinHours: 1, limit: 50)
        #expect(rows.count == 2)
        #expect(rows.map(\.kind) == [.join, .leave])
    }

    @Test("type filter selects only matching kinds")
    func typeFilter() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -30, nickname: "a"))
        await log.record(event(.upload, at: -20, nickname: "a", target: "f.txt", bytes: 10))
        await log.record(event(.loginFail, at: -10, account: "bob"))
        let transfers = await log.query(type: [.upload, .download], account: nil, withinHours: 1, limit: 50)
        #expect(transfers.map(\.kind) == [.upload])
        #expect(transfers[0].target == "f.txt")
        #expect(transfers[0].bytes == 10)
    }

    @Test("account filter selects only that account")
    func accountFilter() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.loginOK, at: -30, account: "alice"))
        await log.record(event(.loginOK, at: -20, account: "bob"))
        let rows = await log.query(type: nil, account: "bob", withinHours: 1, limit: 50)
        #expect(rows.map(\.account) == ["bob"])
    }

    @Test("window excludes rows older than the requested hours")
    func windowFilter() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -1800, nickname: "inside"))
        await log.record(event(.join, at: -7200, nickname: "outside"))
        let rows = await log.query(type: nil, account: nil, withinHours: 1, limit: 50)
        #expect(rows.map(\.nickname) == ["inside"])
    }

    @Test("limit caps the number of returned rows (most recent kept)")
    func limitCaps() async throws {
        let log = try AuditLog(retentionDays: 90)
        for index in 0..<5 {
            await log.record(event(.join, at: TimeInterval(-index), nickname: "n\(index)"))
        }
        let rows = await log.query(type: nil, account: nil, withinHours: 1, limit: 2)
        #expect(rows.count == 2)
    }

    @Test("recording prunes rows older than retentionDays")
    func pruneOnWrite() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -91 * 24 * 3600, nickname: "stale"))
        await log.record(event(.join, at: 0, nickname: "fresh"))
        #expect(await log.count() == 1)
    }

    @Test("ip is stored verbatim when present and nil-safe when absent")
    func ipStorage() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.loginOK, at: -10, account: "a", ip: "203.0.113.7"))
        await log.record(event(.loginOK, at: -5, account: "b", ip: nil))
        let rows = await log.query(type: nil, account: nil, withinHours: 1, limit: 50)
        #expect(rows.map(\.ip) == ["203.0.113.7", nil])
    }

    @Test("recentIdentifiedEvents returns last N oldest-first with ascending ids")
    func recentIdentified() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -30, nickname: "aaa"))
        await log.record(event(.join, at: -20, nickname: "bbb"))
        await log.record(event(.join, at: -10, nickname: "ccc"))
        let rows = await log.recentIdentifiedEvents(limit: 2)
        #expect(rows.map(\.event.nickname) == ["bbb", "ccc"])
        #expect(rows[0].id < rows[1].id)
    }

    @Test("eventsAfter(id:) returns only rows past the cursor")
    func eventsAfterCursor() async throws {
        let log = try AuditLog(retentionDays: 90)
        await log.record(event(.join, at: -30, nickname: "aaa"))
        await log.record(event(.join, at: -20, nickname: "bbb"))
        let firstBatch = await log.recentIdentifiedEvents(limit: 10)
        let cursor = firstBatch[0].id
        await log.record(event(.join, at: -10, nickname: "ccc"))
        let after = await log.eventsAfter(id: cursor, limit: 10)
        #expect(after.map(\.event.nickname) == ["bbb", "ccc"])
    }
}
