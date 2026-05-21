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
}
