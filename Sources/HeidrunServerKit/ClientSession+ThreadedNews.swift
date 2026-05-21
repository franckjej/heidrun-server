import Foundation
import HeidrunCore

extension ClientSession {
    /// Handle `getThreadedNewsBundles` (370): walk to the requested
    /// path and reply with one `newsBundleEntry` per child node.
    func handleGetNewsBundles(header: PacketHeader, fields: [PacketField]) async {
        let path = newsPath(from: fields)
        guard let nodes = await news.children(at: path) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 370
            ))
            return
        }
        try? await writer(PacketEncoder.newsBundlesReply(
            taskNumber: header.taskNumber,
            nodes: nodes,
            encoding: stringEncoding
        ))
    }

    /// Handle `getThreadedNewsCategoryContents` (371): walk to the
    /// requested category and reply with a single thread-list blob.
    func handleGetNewsCategory(header: PacketHeader, fields: [PacketField]) async {
        let path = newsPath(from: fields)
        guard let posts = await news.posts(at: path) else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 371
            ))
            return
        }
        try? await writer(PacketEncoder.newsCategoryReply(
            taskNumber: header.taskNumber,
            posts: posts,
            encoding: stringEncoding
        ))
    }

    /// Handle `getNewsThreadBody` (400): look up the article at
    /// `(path, articleID)` and reply with its full body.
    func handleGetNewsThread(header: PacketHeader, fields: [PacketField]) async {
        let path = newsPath(from: fields)
        let articleID = Int(fields.uint16(.newsArticleID) ?? 0)
        guard articleID > 0,
              let posts = await news.posts(at: path),
              articleID <= posts.count else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 400
            ))
            return
        }
        let post = posts[articleID - 1]
        try? await writer(PacketEncoder.newsThreadBodyReply(
            taskNumber: header.taskNumber,
            post: post,
            encoding: stringEncoding
        ))
    }

    /// Handle `postNewsThread` (410): append a new post to the
    /// addressed category and reply success / failure. Real Hotline
    /// servers don't broadcast a notification — the client polls
    /// fetchNewsThreads — so this handler is reply-only.
    func handlePostNewsThread(header: PacketHeader, fields: [PacketField]) async {
        let path = newsPath(from: fields)
        let title = fields.string(.newsTitle, encoding: stringEncoding) ?? "(untitled)"
        let body = fields.string(.newsData, encoding: stringEncoding) ?? ""
        let post = NewsPost(title: title, author: nickname, body: body)
        let ok = await news.appendPost(at: path, post: post)
        if ok {
            try? await writer(PacketEncoder.emptyReply(
                taskNumber: header.taskNumber,
                transactionID: 410
            ))
        } else {
            try? await writer(PacketEncoder.errorReply(
                taskNumber: header.taskNumber,
                transactionID: 410
            ))
        }
    }

    /// Decode the `.newsPath` (325) field into `[String]`. Defaults to
    /// `[]` (root) when the field is missing or malformed.
    fileprivate func newsPath(from fields: [PacketField]) -> [String] {
        guard let field = fields.first(.newsPath),
              let path = RemotePath(decoding: field.data, encoding: stringEncoding) else {
            return []
        }
        return path.components
    }
}
