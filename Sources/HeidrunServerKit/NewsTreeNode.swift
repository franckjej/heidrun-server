import Foundation
import HeidrunCore

/// One node in the threaded-news tree. A `.bundle` is a folder holding
/// further bundles + categories. A `.category` is a leaf holding posts.
public struct BundleNode: Sendable, Hashable {
    public var name: String
    public var kind: NewsBundle.Kind
    public var children: [BundleNode]
    public var posts: [NewsPost]

    public init(
        name: String,
        kind: NewsBundle.Kind,
        children: [BundleNode] = [],
        posts: [NewsPost] = []
    ) {
        self.name = name
        self.kind = kind
        self.children = children
        self.posts = posts
    }
}

/// One threaded-news post. `body` is the article text — what the
/// client receives in a `400` reply's `.newsData` field.
public struct NewsPost: Sendable, Hashable {
    public var title: String
    public var author: String
    public var body: String

    public init(title: String, author: String, body: String) {
        self.title = title
        self.author = author
        self.body = body
    }
}
