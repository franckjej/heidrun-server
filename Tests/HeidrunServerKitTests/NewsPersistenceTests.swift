import Foundation
import Testing
import HeidrunCore
@testable import HeidrunServerKit

@Suite("News persistence", .serialized)
struct NewsPersistenceTests {

    private func withTempJSONPath<Result>(
        _ body: (String) async throws -> Result
    ) async throws -> Result {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "HeidrunServer-news-\(UUID().uuidString).json"
        )
        defer { try? fileManager.removeItem(at: url) }
        return try await body(url.path)
    }

    @Test("posting a plain-news item writes a JSON snapshot that round-trips on a new tree")
    func plainPostPersists() async throws {
        try await withTempJSONPath { path in
            let first = NewsTree(persistencePath: path)
            await first.appendPlainPost("Hello world")
            await first.appendPlainPost("Second post")

            let second = NewsTree(persistencePath: path)
            let feed = await second.plainFeed()
            #expect(feed.contains("Hello world"))
            #expect(feed.contains("Second post"))
        }
    }

    @Test("creating bundles, categories, and posts all survive a reload")
    func threadedTreePersists() async throws {
        try await withTempJSONPath { path in
            let writer = NewsTree(persistencePath: path)
            #expect(await writer.insertBundle(at: [], name: "Engineering", kind: .bundle))
            #expect(await writer.insertBundle(at: ["Engineering"], name: "Releases", kind: .category))
            #expect(await writer.appendPost(
                at: ["Engineering", "Releases"],
                post: NewsPost(title: "v1.0", author: "admin", body: "first cut")
            ))

            let reader = NewsTree(persistencePath: path)
            let topLevel = await reader.children(at: [])
            #expect(topLevel?.contains(where: { $0.name == "Engineering" && $0.kind == .bundle }) == true)
            let engChildren = await reader.children(at: ["Engineering"])
            #expect(engChildren?.contains(where: { $0.name == "Releases" && $0.kind == .category }) == true)
            let posts = await reader.posts(at: ["Engineering", "Releases"])
            #expect(posts?.count == 1)
            #expect(posts?.first?.title == "v1.0")
            #expect(posts?.first?.body == "first cut")
        }
    }

    @Test("removeBundle and removePost rewrite the snapshot")
    func deletesPersist() async throws {
        try await withTempJSONPath { path in
            let writer = NewsTree(persistencePath: path)
            _ = await writer.insertBundle(at: [], name: "Topics", kind: .category)
            _ = await writer.appendPost(
                at: ["Topics"],
                post: NewsPost(title: "post-a", author: "a", body: "")
            )
            _ = await writer.appendPost(
                at: ["Topics"],
                post: NewsPost(title: "post-b", author: "b", body: "")
            )
            _ = await writer.removePost(at: ["Topics"], articleID: 1)

            let reader = NewsTree(persistencePath: path)
            let posts = await reader.posts(at: ["Topics"])
            #expect(posts?.count == 1)
            #expect(posts?.first?.title == "post-b")

            _ = await writer.removeBundle(at: ["Topics"])
            let reader2 = NewsTree(persistencePath: path)
            let topLevel = await reader2.children(at: [])
            #expect(topLevel?.contains(where: { $0.name == "Topics" }) == false)
        }
    }

    @Test("ServerConfigurationFile.resolved derives <db>.news.json when news_state_path is omitted")
    func derivesNewsPathFromDB() async throws {
        let file = ServerConfigurationFile(dbPath: "/var/lib/heidrun/heidrun.sqlite")
        let resolved = file.resolved(environment: [:])
        #expect(resolved.newsStatePath == "/var/lib/heidrun/heidrun.news.json")
    }

    @Test("HEIDRUN_NEWS_PATH env var overrides the derived path")
    func envVarOverridesDerivation() async throws {
        let file = ServerConfigurationFile(dbPath: "/var/lib/heidrun/heidrun.sqlite")
        let resolved = file.resolved(environment: ["HEIDRUN_NEWS_PATH": "/custom/news.json"])
        #expect(resolved.newsStatePath == "/custom/news.json")
    }
}
