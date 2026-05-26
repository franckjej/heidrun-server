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

    @Test("formatPlainNewsPost: classic header, CR newlines, trailing hairline")
    func classicPostFormat() {
        let post = ClientSession.formatPlainNewsPost(
            nickname: "Alice",
            body: "line1\nline2",
            date: Date(timeIntervalSince1970: 0)
        )
        #expect(post.hasPrefix("From Alice ("))
        // `From <nick> (<date>):` then a blank line then the CR-normalised body.
        #expect(post.contains("):\r\rline1\rline2"))
        // Hairline rides along with the post (so the push carries it too).
        #expect(post.hasSuffix("\r\(NewsTree.plainNewsSeparator)"))
        #expect(!post.contains("\n"))
    }

    @Test("plainNewsDateString carries a timezone token")
    func dateHasTimezone() {
        // EEE dd/MMM/yyyy hh:mm:ss a zzz → five space-delimited tokens.
        #expect(ClientSession.plainNewsDateString(Date()).split(separator: " ").count == 5)
    }

    @Test("hairline is a dashed line; plainFeed is newest-first")
    func feedHairline() async {
        #expect(NewsTree.plainNewsSeparator.allSatisfy { $0 == "-" })
        let newest = ClientSession.formatPlainNewsPost(nickname: "B", body: "two", date: Date())
        let oldest = ClientSession.formatPlainNewsPost(nickname: "A", body: "one", date: Date())
        let tree = NewsTree(seed: NewsTree.Seed(plain: [oldest, newest]))
        let feed = await tree.plainFeed()
        #expect(feed.hasPrefix("From B ("))            // newest first
        #expect(feed.contains(NewsTree.plainNewsSeparator))
    }
}
