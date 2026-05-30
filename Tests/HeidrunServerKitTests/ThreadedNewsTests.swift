import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("Threaded news", .serialized)
struct ThreadedNewsTests {
    private static let seed = NewsTree.Seed(threaded: [
        BundleNode(
            name: "General",
            kind: .bundle,
            children: [
                BundleNode(
                    name: "Announcements",
                    kind: .category,
                    posts: [
                        NewsPost(title: "Welcome", author: "Sysop", body: "Hello everyone!"),
                        NewsPost(title: "Rules", author: "Sysop", body: "Be kind.")
                    ]
                )
            ]
        )
    ])

    private static let configuration = ServerConfiguration(
        port: 0,
        serverName: "Heidrun integration test",
        newsSeed: seed
    )

    @Test("fetchNewsBundles at the root returns the seeded top-level folder")
    func readBundlesRoot() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let bundles = try await client.fetchNewsBundles(at: RemotePath(components: []))
            #expect(bundles.contains(where: { $0.title == "General" }))
        }
    }

    @Test("fetchNewsThreads on a seeded category returns all posts' titles")
    func readCategoryContents() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let threads = try await client.fetchNewsThreads(at: RemotePath(components: ["General", "Announcements"]))
            let titles = threads.compactMap { $0.elements.first?.title }
            #expect(Set(titles) == Set(["Welcome", "Rules"]))
        }
    }

    @Test("fetchNewsThread returns the requested post's metadata")
    func readThreadBody() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Frank")
            let thread = try await client.fetchNewsThread(
                at: RemotePath(components: ["General", "Announcements"]),
                threadID: 1,
                type: "text/plain"
            )
            #expect(thread.elements.first?.title == "Welcome")
        }
    }

    @Test("postNewsThread appends to the category and a subsequent fetch sees it")
    func postNewThread() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")

            try await client.postNewsThread(
                at: RemotePath(components: ["General", "Announcements"]),
                parentThreadID: 0,
                title: "Fresh post",
                type: "text/plain",
                body: "Hello from the integration test"
            )

            let threads = try await client.fetchNewsThreads(
                at: RemotePath(components: ["General", "Announcements"])
            )
            let titles = threads.compactMap { $0.elements.first?.title }
            #expect(titles.contains("Fresh post"))
        }
    }

    @Test("postNewsThread with a non-zero parentThreadID round-trips on TX 371")
    func replyParentRoundTrip() async throws {
        try await ServerTestHelpers.withRunningServer(configuration: Self.configuration) { _, port in
            let client = try await ServerTestHelpers.connectAndLogin(port: port, nickname: "Alice")
            let path = RemotePath(components: ["General", "Announcements"])

            // The seed lays down two top-level posts ("Welcome" /
            // "Rules") at indices 1 and 2. Reply to index 1.
            try await client.postNewsThread(
                at: path,
                parentThreadID: 1,
                title: "Re: Welcome",
                type: "text/plain",
                body: "Thanks for the welcome!"
            )

            let threads = try await client.fetchNewsThreads(at: path)
            let reply = threads.first { $0.elements.first?.title == "Re: Welcome" }
            #expect(reply != nil)
            // The actual regression check: the server used to
            // hard-code parentID: 0 on every 371 row, so all replies
            // rendered flat. Now the parent round-trips.
            #expect(reply?.parentID == 1)
        }
    }
}
