import Testing
import Foundation
@testable import HeidrunServerKit

@Suite("UserEventStore")
struct UserEventStoreTests {
    @Test("records and returns events oldest-first within the window")
    func roundTripOrdering() async throws {
        let store = try UserEventStore()
        let now = Date()
        await store.record(.entered, nickname: "silve", socket: 7, at: now.addingTimeInterval(-120))
        await store.record(.left,    nickname: "silve", socket: 7, at: now.addingTimeInterval(-60))

        let events = await store.events(withinHours: 1)
        #expect(events.count == 2)
        #expect(events.map(\.kind) == [.entered, .left])
        #expect(events.map(\.nickname) == ["silve", "silve"])
        #expect(events[0].socket == 7)
    }

    @Test("events older than the window are excluded")
    func windowFilter() async throws {
        let store = try UserEventStore()
        let now = Date()
        await store.record(.entered, nickname: "inside",  socket: 1, at: now.addingTimeInterval(-1800)) // 30m ago
        await store.record(.entered, nickname: "outside", socket: 2, at: now.addingTimeInterval(-7200)) // 2h ago

        let events = await store.events(withinHours: 1)
        #expect(events.map(\.nickname) == ["inside"])
    }

    @Test("recording prunes rows older than 24h")
    func pruneOnWrite() async throws {
        let store = try UserEventStore()
        let now = Date()
        // A stale row from 25h ago, then a fresh write triggers the prune.
        await store.record(.entered, nickname: "stale", socket: 9, at: now.addingTimeInterval(-25 * 3600))
        await store.record(.entered, nickname: "fresh", socket: 9, at: now)

        let total = await store.count()
        #expect(total == 1)
        let events = await store.events(withinHours: 24)
        #expect(events.map(\.nickname) == ["fresh"])
    }
}
