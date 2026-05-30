import Foundation
import HeidrunCore

/// On-disk snapshot of `NewsTree` state. Persists as JSON next to the
/// SQLite DB (default `<db>.news.json`). The schema is intentionally
/// flat and `Codable`-friendly so backups + manual edits stay readable.
///
/// `schemaVersion == 1` covers the initial layout. Bump the constant
/// when fields rename or drop, and add a migration in
/// `decodeWithMigration(...)` so older snapshots keep loading.
struct NewsStateSnapshot: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var plain: [String]
    var threaded: [SerializedBundle]

    init(plain: [String], threaded: [BundleNode]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.plain = plain
        self.threaded = threaded.map(SerializedBundle.init(from:))
    }

    var bundleNodes: [BundleNode] {
        threaded.map(\.bundleNode)
    }

    struct SerializedBundle: Codable, Sendable {
        var name: String
        var kind: UInt16
        var children: [SerializedBundle]
        var posts: [SerializedPost]

        init(from node: BundleNode) {
            self.name = node.name
            self.kind = node.kind.rawValue
            self.children = node.children.map(SerializedBundle.init(from:))
            self.posts = node.posts.map(SerializedPost.init(from:))
        }

        var bundleNode: BundleNode {
            BundleNode(
                name: name,
                kind: NewsBundle.Kind(rawValue: kind) ?? .bundle,
                children: children.map(\.bundleNode),
                posts: posts.map(\.newsPost)
            )
        }
    }

    struct SerializedPost: Codable, Sendable {
        var title: String
        var author: String
        var body: String
        /// Optional on the wire so existing v1 snapshots (written
        /// before `parentID` existed on `NewsPost`) keep decoding —
        /// missing key → nil → top-level (0). No schemaVersion bump
        /// needed for an additive optional field; synthesised
        /// Codable handles `Optional` via `decodeIfPresent`.
        var parentID: UInt16?

        init(from post: NewsPost) {
            self.title = post.title
            self.author = post.author
            self.body = post.body
            self.parentID = post.parentID
        }

        var newsPost: NewsPost {
            NewsPost(title: title, author: author, body: body, parentID: parentID ?? 0)
        }
    }

    /// Encode to pretty-printed JSON with stable key ordering so the
    /// file is human-readable and produces clean diffs.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode, applying any schema migrations needed for older
    /// snapshots. Unknown schemaVersions are rejected — callers should
    /// treat that as "fall back to defaults" rather than corruption.
    static func decode(from data: Data) throws -> NewsStateSnapshot {
        let snapshot = try JSONDecoder().decode(NewsStateSnapshot.self, from: data)
        guard snapshot.schemaVersion == currentSchemaVersion else {
            throw DecodeError.unknownSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    enum DecodeError: Error, Equatable {
        case unknownSchemaVersion(Int)
    }
}
