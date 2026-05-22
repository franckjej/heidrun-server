import Foundation
import HeidrunCore

/// In-memory news store. Owns the legacy plain feed (a chronological
/// list of strings the 101 transaction joins with newlines) and the
/// threaded news tree (folders + categories + posts). Lives for the
/// lifetime of one `HeidrunServer` instance — restart wipes it.
/// Persistence lands in M3b.
public actor NewsTree {
    /// Initial state callers can pass via `ServerConfiguration.newsSeed`.
    /// Tests preload posts so they don't have to make a sequence of
    /// post calls before assertions.
    public struct Seed: Sendable {
        public var plain: [String]
        public var threaded: [BundleNode]

        public init(plain: [String] = [], threaded: [BundleNode] = []) {
            self.plain = plain
            self.threaded = threaded
        }
    }

    private var plain: [String]
    private var threaded: [BundleNode]

    public init(seed: Seed = Seed()) {
        self.plain = seed.plain
        self.threaded = seed.threaded
    }

    /// Plain news feed as one blob — `\r` separates posts. Newest
    /// posts come first; the 101 reply is read top-down by the client.
    public func plainFeed() -> String {
        plain.reversed().joined(separator: "\r")
    }

    /// Append a new plain-news post.
    public func appendPlainPost(_ stamped: String) {
        plain.append(stamped)
    }

    /// Walk to `path` and return the immediate child nodes — folders
    /// and category headers. Returns `nil` when the path doesn't exist
    /// or terminates in a leaf category (use `posts(at:)` for that case).
    public func children(at path: [String]) -> [BundleNode]? {
        Self.children(in: threaded, at: path)
    }

    /// Walk to a category at `path` and return its posts. Returns `nil`
    /// when the path doesn't exist or terminates at a folder.
    public func posts(at path: [String]) -> [NewsPost]? {
        Self.posts(in: threaded, at: path)
    }

    /// Append a post to the category at `path`. Returns `true` on
    /// success, `false` if the path doesn't exist or terminates in a
    /// folder (folders can't hold posts directly).
    public func appendPost(at path: [String], post: NewsPost) -> Bool {
        Self.insertPost(post, at: path, in: &threaded)
    }

    /// Insert a new bundle (folder) or category named `name` under the
    /// folder at `path`. Returns `true` on success; `false` when the
    /// path doesn't resolve to a folder, or a sibling with the same
    /// name already exists.
    public func insertBundle(at path: [String], name: String, kind: NewsBundle.Kind) -> Bool {
        Self.insert(BundleNode(name: name, kind: kind), at: path, in: &threaded)
    }

    /// Remove the bundle (folder *or* category) addressed by `path`.
    /// The full path identifies the target — e.g. `["root", "child"]`
    /// removes `child` from `root`. Returns `true` on success.
    public func removeBundle(at path: [String]) -> Bool {
        Self.remove(at: path, in: &threaded)
    }

    /// Remove the post at `articleID` (1-indexed) inside the category
    /// at `path`. Returns `true` on success; `false` for unknown path
    /// / out-of-range id / non-category targets.
    public func removePost(at path: [String], articleID: Int) -> Bool {
        Self.removePost(articleID: articleID, at: path, in: &threaded)
    }

    // MARK: - Recursive helpers (pure, value-type)

    private static func children(in pool: [BundleNode], at path: [String]) -> [BundleNode]? {
        if path.isEmpty { return pool }
        guard let head = path.first,
              let next = pool.first(where: { $0.name == head }) else { return nil }
        if next.kind == .category { return nil }
        return children(in: next.children, at: Array(path.dropFirst()))
    }

    private static func posts(in pool: [BundleNode], at path: [String]) -> [NewsPost]? {
        guard let head = path.first,
              let next = pool.first(where: { $0.name == head }) else { return nil }
        if path.count == 1 {
            return next.kind == .category ? next.posts : nil
        }
        if next.kind == .category { return nil }
        return posts(in: next.children, at: Array(path.dropFirst()))
    }

    private static func insertPost(
        _ post: NewsPost,
        at path: [String],
        in pool: inout [BundleNode]
    ) -> Bool {
        guard let head = path.first,
              let index = pool.firstIndex(where: { $0.name == head }) else { return false }
        if path.count == 1 {
            guard pool[index].kind == .category else { return false }
            pool[index].posts.append(post)
            return true
        }
        guard pool[index].kind == .bundle else { return false }
        return insertPost(post, at: Array(path.dropFirst()), in: &pool[index].children)
    }

    private static func insert(
        _ node: BundleNode,
        at path: [String],
        in pool: inout [BundleNode]
    ) -> Bool {
        if path.isEmpty {
            guard !pool.contains(where: { $0.name == node.name }) else { return false }
            pool.append(node)
            return true
        }
        guard let head = path.first,
              let index = pool.firstIndex(where: { $0.name == head }),
              pool[index].kind == .bundle else { return false }
        return insert(node, at: Array(path.dropFirst()), in: &pool[index].children)
    }

    private static func remove(at path: [String], in pool: inout [BundleNode]) -> Bool {
        guard let head = path.first else { return false }
        if path.count == 1 {
            guard let index = pool.firstIndex(where: { $0.name == head }) else { return false }
            pool.remove(at: index)
            return true
        }
        guard let index = pool.firstIndex(where: { $0.name == head }),
              pool[index].kind == .bundle else { return false }
        return remove(at: Array(path.dropFirst()), in: &pool[index].children)
    }

    private static func removePost(
        articleID: Int,
        at path: [String],
        in pool: inout [BundleNode]
    ) -> Bool {
        guard let head = path.first,
              let index = pool.firstIndex(where: { $0.name == head }) else { return false }
        if path.count == 1 {
            guard pool[index].kind == .category else { return false }
            let array = pool[index].posts
            let position = articleID - 1
            guard position >= 0, position < array.count else { return false }
            pool[index].posts.remove(at: position)
            return true
        }
        guard pool[index].kind == .bundle else { return false }
        return removePost(articleID: articleID, at: Array(path.dropFirst()), in: &pool[index].children)
    }
}
