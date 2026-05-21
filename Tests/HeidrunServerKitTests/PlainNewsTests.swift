import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Plain news", .serialized)
struct PlainNewsTests {
    @Test("fetchNewsFeed returns the joined seed feed")
    func fetchSeedFeed() async throws {
        let configuration = ServerConfiguration(
            port: 0,
            serverName: "Heidrun integration test",
            newsSeed: NewsTree.Seed(plain: ["Hello world", "Second post"])
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let feed = try await client.fetchNewsFeed()
            #expect(feed.contains("Hello world"))
            #expect(feed.contains("Second post"))
        }
    }

    @Test("postPlainNews appends a stamped line, broadcasts 102, and the next fetch returns it")
    func postBroadcastsAndPersists() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let alice = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let bob = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Bob")
            try await Task.sleep(for: .milliseconds(200))

            let observer = Task { () -> String? in
                for await event in bob.events {
                    if case let .newsPosted(text) = event, text.contains("breaking") {
                        return text
                    }
                }
                return nil
            }

            try await alice.postPlainNews("breaking story")

            let received: String? = try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await Task.sleep(for: .seconds(2))
                    throw NSError(domain: "PlainNewsTests", code: 0)
                }
                group.addTask { _ = await observer.value }
                try await group.next()
                group.cancelAll()
                return await observer.value
            }

            #expect(received?.contains("Alice") == true)
            #expect(received?.contains("breaking story") == true)

            let feed = try await bob.fetchNewsFeed()
            #expect(feed.contains("breaking story"))
        }
    }
}
