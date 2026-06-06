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
        let configuration = ServerConfiguration(
            port: 0,
            bootstrapAdmin: ServerConfiguration.BootstrapAdmin(
                login: "admin", password: "admin", nickname: "Admin"
            )
        )
        try await ServerTestHelpers.withRunningServer(configuration: configuration) { _, port in
            // Alice logs in on the admin account (so she has postNews) but
            // keeps the "Alice" nickname the post line is stamped with.
            let alice = try await ServerTestHelpers.connectAndLogin(
                port: port, nickname: "Alice", loginName: "admin", password: "admin")
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

    @Test("reset wipes only the scoped store(s)")
    func resetScopes() async {
        let threadedSeed = [
            BundleNode(
                name: "General",
                kind: .category,
                posts: [NewsPost(title: "Hi", author: "Sysop", body: "Welcome")]
            )
        ]
        func freshTree() -> NewsTree {
            NewsTree(seed: NewsTree.Seed(plain: ["a post"], threaded: threadedSeed))
        }

        // .flat clears the plain feed, keeps the threaded tree.
        let flatTree = freshTree()
        await flatTree.reset(.flat)
        #expect(await flatTree.plainFeed().isEmpty)
        #expect(await flatTree.children(at: [])?.isEmpty == false)

        // .threaded clears the tree, keeps the plain feed.
        let threadedTree = freshTree()
        await threadedTree.reset(.threaded)
        #expect(await threadedTree.plainFeed() == "a post")
        #expect(await threadedTree.children(at: [])?.isEmpty == true)

        // .all clears both.
        let allTree = freshTree()
        await allTree.reset(.all)
        #expect(await allTree.plainFeed().isEmpty)
        #expect(await allTree.children(at: [])?.isEmpty == true)
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

    @Test("a guest cannot post plain news (lacks postNews)")
    func guestCannotPostPlainNews() async throws {
        try await ServerTestHelpers.withRunningServer { _, port in
            let guest = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Guest")
            var denied = false
            do {
                try await guest.postPlainNews("sneaky news")
            } catch let error as HotlineError {
                if case .serverError = error { denied = true }
            }
            #expect(denied)
            // Guest can still read (has readNews) — confirm nothing landed.
            let feed = try await guest.fetchNewsFeed()
            #expect(!feed.contains("sneaky news"))
        }
    }
}
